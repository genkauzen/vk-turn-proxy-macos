import Foundation

enum LANProxyConfiguration {
    static let enabledKey = "lanProxyEnabled"
    static let portKey = "lanProxyPort"
    static let defaultPort = 1080
    static let portRange = 1...65535

    static func port(in defaults: UserDefaults) -> Int {
        let value = defaults.integer(forKey: portKey)
        return portRange.contains(value) ? value : defaultPort
    }

    static func clampPort(_ value: Int) -> Int {
        min(portRange.upperBound, max(portRange.lowerBound, value))
    }
}
