import Foundation
import Network
import NetworkExtension

enum LANProxyUpstreamState {
    case ready
    case failed(Error?)
    case cancelled
}

protocol LANProxyUpstream: AnyObject {
    var stateHandler: ((LANProxyUpstreamState) -> Void)? { get set }

    func start()
    func receive(
        minimumLength: Int,
        maximumLength: Int,
        completion: @escaping (Data?, Bool, Error?) -> Void
    )
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func cancel()
}

final class LANProxy {
    private let port: UInt16
    private let upstreamFactory: (String, UInt16, DispatchQueue) -> LANProxyUpstream?
    private let queue = DispatchQueue(label: "com.vkturnproxy.tunnel.lan-proxy")
    private let log: (String) -> Void
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: LANProxyConnection] = [:]

    init(
        port: UInt16,
        upstreamFactory: @escaping (String, UInt16, DispatchQueue) -> LANProxyUpstream?,
        log: @escaping (String) -> Void
    ) {
        self.port = port
        self.upstreamFactory = upstreamFactory
        self.log = log
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }

            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .wifi
            parameters.acceptLocalOnly = true
            parameters.includePeerToPeer = false
            parameters.allowLocalEndpointReuse = true

            guard let endpointPort = NWEndpoint.Port(rawValue: self.port) else {
                self.log("LAN proxy: invalid port")
                return
            }

            do {
                let listener = try NWListener(using: parameters, on: endpointPort)
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.log("LAN proxy: SOCKS5 listening on Wi-Fi port \(self.port)")
                    case .failed(let error):
                        self.log("LAN proxy: listener failed (\(error.localizedDescription))")
                        self.stopOnQueue()
                    case .cancelled:
                        self.log("LAN proxy: listener stopped")
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener = listener
                listener.start(queue: self.queue)
            } catch {
                self.log("LAN proxy: could not create listener (\(error.localizedDescription))")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        let active = Array(connections.values)
        connections.removeAll()
        active.forEach { $0.stop() }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 64 else {
            connection.cancel()
            return
        }

        let client = LANProxyConnection(
            connection: connection,
            upstreamFactory: upstreamFactory,
            queue: queue,
            onClose: { [weak self] client in
                self?.remove(client)
            }
        )
        connections[ObjectIdentifier(client)] = client
        client.start()
    }

    private func remove(_ connection: LANProxyConnection) {
        queue.async { [weak self] in
            self?.connections.removeValue(forKey: ObjectIdentifier(connection))
        }
    }
}

private final class LANProxyConnection {
    private let client: NWConnection
    private let upstreamFactory: (String, UInt16, DispatchQueue) -> LANProxyUpstream?
    private let queue: DispatchQueue
    private let onClose: (LANProxyConnection) -> Void
    private var remote: LANProxyUpstream?
    private var readBuffer = Data()
    private var connectTimeout: DispatchWorkItem?
    private var relayStarted = false
    private var closed = false

    init(
        connection: NWConnection,
        upstreamFactory: @escaping (String, UInt16, DispatchQueue) -> LANProxyUpstream?,
        queue: DispatchQueue,
        onClose: @escaping (LANProxyConnection) -> Void
    ) {
        self.client = connection
        self.upstreamFactory = upstreamFactory
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.beginHandshake()
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        client.start(queue: queue)
    }

    func stop() {
        close()
    }

    private func beginHandshake() {
        receiveExactly(2) { [weak self] header in
            guard let self, let header,
                  header.count == 2, header[0] == 0x05 else {
                self?.close()
                return
            }

            let methodCount = Int(header[1])
            self.receiveExactly(methodCount) { [weak self] methods in
                guard let self, let methods,
                      methods.contains(0x00) else {
                    self?.sendAndClose(Data([0x05, 0xff]))
                    return
                }
                self.sendClient(Data([0x05, 0x00])) { [weak self] error in
                    guard let self, error == nil else {
                        self?.close()
                        return
                    }
                    self.readRequest()
                }
            }
        }
    }

    private func readRequest() {
        receiveExactly(4) { [weak self] header in
            guard let self, let header,
                  header.count == 4,
                  header[0] == 0x05,
                  header[1] == 0x01,
                  header[2] == 0x00 else {
                self?.sendAndClose(self?.failureReply(code: 0x07) ?? Data())
                return
            }

            switch header[3] {
            case 0x01:
                self.receiveExactly(6) { [weak self] body in
                    guard let self, let body, body.count == 6 else {
                        self?.close()
                        return
                    }
                    let host = body.prefix(4).map(String.init).joined(separator: ".")
                    self.connect(to: host, port: self.port(from: body.suffix(2)))
                }
            case 0x03:
                self.receiveExactly(1) { [weak self] lengthData in
                    guard let self, let lengthData, lengthData.count == 1 else {
                        self?.close()
                        return
                    }
                    let length = Int(lengthData[0])
                    guard length > 0 else {
                        self.sendAndClose(self.failureReply(code: 0x08))
                        return
                    }
                    self.receiveExactly(length + 2) { [weak self] body in
                        guard let self, let body, body.count == length + 2,
                              let host = String(data: body.prefix(length), encoding: .utf8),
                              !host.isEmpty,
                              !host.unicodeScalars.contains(where: {
                                  $0.value < 0x20 || $0.value == 0x7f
                              }) else {
                            self?.sendAndClose(self?.failureReply(code: 0x08) ?? Data())
                            return
                        }
                        self.connect(to: host, port: self.port(from: body.suffix(2)))
                    }
                }
            case 0x04:
                self.receiveExactly(18) { [weak self] body in
                    guard let self, let body, body.count == 18 else {
                        self?.close()
                        return
                    }
                    var groups: [String] = []
                    for index in stride(from: 0, to: 16, by: 2) {
                        let group = UInt16(body[index]) << 8 | UInt16(body[index + 1])
                        groups.append(String(group, radix: 16))
                    }
                    self.connect(to: groups.joined(separator: ":"), port: self.port(from: body.suffix(2)))
                }
            default:
                self.sendAndClose(self.failureReply(code: 0x08))
            }
        }
    }

    private func connect(to host: String, port: UInt16) {
        guard port != 0, let upstream = upstreamFactory(host, port, queue) else {
            sendAndClose(failureReply(code: 0x08))
            return
        }

        remote = upstream
        connectTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.relayStarted, !self.closed else { return }
            self.sendAndClose(self.failureReply(code: 0x04))
        }
        connectTimeout = timeout
        queue.asyncAfter(deadline: .now() + 30, execute: timeout)

        upstream.stateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connectTimeout?.cancel()
                self.sendClient(self.successReply()) { [weak self] error in
                    guard let self, error == nil else {
                        self?.close()
                        return
                    }
                    self.relayStarted = true
                    self.pumpClientToRemote()
                    self.pumpRemoteToClient()
                }
            case .failed:
                if !self.relayStarted {
                    self.sendAndClose(self.failureReply(code: 0x05))
                } else {
                    self.close()
                }
            case .cancelled:
                self.close()
            }
        }
        upstream.start()
    }

    private func pumpClientToRemote() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.remote?.send(data) { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil || complete || error != nil {
                        self.close()
                    } else {
                        self.pumpClientToRemote()
                    }
                }
            } else if complete || error != nil {
                self.close()
            } else {
                self.pumpClientToRemote()
            }
        }
    }

    private func pumpRemoteToClient() {
        remote?.receive(minimumLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.client.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil || complete || error != nil {
                        self.close()
                    } else {
                        self.pumpRemoteToClient()
                    }
                })
            } else if complete || error != nil {
                self.close()
            } else {
                self.pumpRemoteToClient()
            }
        }
    }

    private func receiveExactly(_ count: Int, completion: @escaping (Data?) -> Void) {
        guard !closed else { return }
        if readBuffer.count >= count {
            let data = readBuffer.prefix(count)
            readBuffer.removeFirst(count)
            completion(Data(data))
            return
        }

        let missing = max(1, count - readBuffer.count)
        client.receive(minimumIncompleteLength: missing, maximumLength: max(4096, missing)) {
            [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.readBuffer.append(data)
            }
            if error != nil || (complete && self.readBuffer.count < count) {
                self.close()
                return
            }
            self.receiveExactly(count, completion: completion)
        }
    }

    private func sendClient(_ data: Data, completion: @escaping (Error?) -> Void) {
        client.send(content: data, completion: .contentProcessed { error in
            completion(error)
        })
    }

    private func sendAndClose(_ data: Data) {
        guard !closed else { return }
        sendClient(data) { [weak self] _ in
            self?.close()
        }
    }

    private func successReply() -> Data {
        Data([0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    private func failureReply(code: UInt8) -> Data {
        Data([0x05, code, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    private func port(from bytes: Data.SubSequence) -> UInt16 {
        guard bytes.count == 2 else { return 0 }
        return UInt16(bytes[bytes.startIndex]) << 8
            | UInt16(bytes[bytes.index(after: bytes.startIndex)])
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connectTimeout?.cancel()
        client.cancel()
        remote?.cancel()
        remote = nil
        onClose(self)
    }
}

@available(iOS 18.0, *)
final class LANProxyNWUpstream: LANProxyUpstream {
    var stateHandler: ((LANProxyUpstreamState) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.stateHandler?(.ready)
            case .failed(let error):
                self.stateHandler?(.failed(error))
            case .cancelled:
                self.stateHandler?(.cancelled)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func receive(
        minimumLength: Int,
        maximumLength: Int,
        completion: @escaping (Data?, Bool, Error?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: minimumLength, maximumLength: maximumLength) {
            data, _, isComplete, error in
            completion(data, isComplete, error)
        }
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    func cancel() {
        connection.cancel()
    }
}

final class LANProxyLegacyUpstream: LANProxyUpstream {
    var stateHandler: ((LANProxyUpstreamState) -> Void)?

    private let connection: NWTCPConnection
    private let queue: DispatchQueue
    private var stateObservation: NSKeyValueObservation?
    private var connected = false
    private var terminal = false

    init(connection: NWTCPConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        stateObservation = connection.observe(\NWTCPConnection.state, options: [.initial, .new]) {
            [weak self] connection, _ in
            self?.queue.async { [weak self] in
                self?.handle(state: connection.state)
            }
        }
    }

    func receive(
        minimumLength: Int,
        maximumLength: Int,
        completion: @escaping (Data?, Bool, Error?) -> Void
    ) {
        connection.readMinimumLength(minimumLength, maximumLength: maximumLength) {
            [weak self] data, error in
            guard let self else { return }
            self.queue.async {
                completion(data, data == nil, error)
            }
        }
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection.write(data) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                completion(error)
            }
        }
    }

    func cancel() {
        terminal = true
        stateObservation = nil
        connection.cancel()
    }

    private func handle(state: NWTCPConnectionState) {
        guard !terminal else { return }
        switch state {
        case .connected:
            guard !connected else { return }
            connected = true
            stateHandler?(.ready)
        case .disconnected, .invalid:
            terminal = true
            stateHandler?(.failed(connection.error))
        case .cancelled:
            terminal = true
            stateHandler?(.cancelled)
        default:
            break
        }
    }
}
