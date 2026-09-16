# VK TURN Proxy — macOS

Порт iOS-приложения на macOS. Это **то же приложение и тот же туннель**: обе платформы
собираются из одних Swift-исходников и одного Go-моста; всё платформенно-специфичное
сведено в `VKTurnProxy/VKTurnProxy/PlatformBridge.swift` и в блоки `#if os(iOS)` /
`#if os(macOS)` в общих файлах.

## Что входит

| Цель в `project.yml` | Тип | Bundle ID | Что это |
|---|---|---|---|
| `VKTurnProxyMac` | application (macOS 14+) | `com.vkturnproxy.app` | приложение: тот же `ContentView`, настройки, логи, спидтест, капча, вход в VK |
| `PacketTunnelMac` | app-extension (packet-tunnel) | `com.vkturnproxy.app.tunnel` | расширение NetworkExtension: тот же `PacketTunnelProvider` + Go-мост |

Bundle ID намеренно совпадают с iOS: `TunnelManager` называет провайдера
`com.vkturnproxy.app.tunnel`, App Group `group.com.vkturnproxy.app` и keychain-группа
`com.vkturnproxy.shared` прописаны в коде один раз, а Apple считает iOS+macOS одним App ID.

Чего на Mac **нет** (и не может быть):

- Live Activity / Dynamic Island (`ActivityKit`) — файлы `LiveActivityController.swift`,
  `LiveActivityIntents.swift`, `VPNActivityAttributes.swift` в macOS-цели не компилируются,
  вызовы в `TunnelManager` / `RoutingShortcuts` / точке входа — под `#if os(iOS)`;
  `TunnelManager.refreshLiveActivity()` на Mac — no-op. Widget-цели нет.
- SSID Wi-Fi в логах путей (`NEHotspotNetwork` — только iOS; на Mac для этого нужен CoreWLAN
  и разрешение на геолокацию). Путь Wi-Fi логируется без имени сети.
- Клавиатурные подсказки (`.keyboardType`, `.autocapitalization`) и «тап по пустому месту
  скрывает клавиатуру» — на Mac нет экранной клавиатуры.

Что заменено на AppKit-эквивалент (всё в `PlatformBridge.swift` и `ContentView.swift`):

| iOS | macOS |
|---|---|
| `UIViewRepresentable` для трёх `WKWebView` (вход VK, VK ID, капча) | `NSViewRepresentable` через протокол `PlatformViewRepresentable` — те же `makeUIView`/`updateUIView` |
| `UIDocumentPickerViewController` (импорт бэкапа) | `NSOpenPanel` |
| `UIActivityViewController` (экспорт бэкапа, «Share» лога) | `NSSavePanel` — файл сохраняется, куда укажет пользователь |
| `UITextView` (панель лога) | `NSTextView` в `NSScrollView` |
| `UIPasteboard.general` | `NSPasteboard.general` |
| `UIApplication.willEnterForegroundNotification` | `NSApplication.didBecomeActiveNotification` |
| `NavigationView` | `NavigationStack` (на Mac `NavigationView` — это split view, push-навигация в нём не работает) |
| `Color(.systemBackground)`, `Color(.systemGray6)` | `windowBackgroundColor`, `controlBackgroundColor` |
| UA капчи `… Mobile/15E148 Safari/604.1` | `… Safari/605.1.15` (WebKit сам говорит «Macintosh», токен Mobile ему противоречил бы) |

## Сборка

Нужны Xcode 16+ с macOS SDK, Go 1.26+, `xcodegen`.

```bash
# 1. Go-мост. Универсальный macOS-архив (arm64 + x86_64) в общем xcframework:
make -C WireGuardBridge xcframework          # iOS device + iOS sim + macOS
#   или только macOS, если iOS SDK не установлен:
make -C WireGuardBridge xcframework-macos

# 2. Проект
cd VKTurnProxy && xcodegen generate

# 3. Приложение
xcodebuild -project VKTurnProxy.xcodeproj -scheme VKTurnProxyMac \
  -destination 'platform=macOS' -configuration Debug build
```

Мост для macOS собирается с `GOOS=darwin` (не `ios`): расширение на Mac — обычный процесс с
доступным `sigaltstack`, iOS-специфичная обработка сигналов не нужна. Патченный GOROOT
(`mach_continuous_time` вместо `mach_absolute_time`) используется и для Mac — таймеры Go
продолжают идти после сна ноутбука; патч трогает `sys_darwin*`, общий для обеих ОС.

## Подпись и распространение

macOS загружает **app-extension** типа packet-tunnel только из приложения, подписанного
provisioning-профилем команды (Development или Mac App Store), с включённым App Sandbox
у приложения и у расширения. Поэтому:

- В `project.yml` для обеих macOS-целей стоит `ENABLE_APP_SANDBOX: YES` и
  `ENABLE_HARDENED_RUNTIME: YES`; entitlements — `VKTurnProxyMac/VKTurnProxyMac.entitlements`
  и `PacketTunnelMac/PacketTunnelMac.entitlements` (NE, App Group, keychain-группа, sandbox,
  `network.client`, у приложения ещё `files.user-selected.read-write` для панелей открытия/сохранения).
- Подставьте свой `DEVELOPMENT_TEAM` в `project.yml` (и, как и на iOS, `canonicalAccessGroup`
  в `VKCookieStore.swift` привязан к team id). В App ID на портале нужна capability
  **Network Extensions** для `com.vkturnproxy.app` и `com.vkturnproxy.app.tunnel` — на **macOS**,
  и App Group `group.com.vkturnproxy.app`.
- Ad-hoc подпись (`codesign -s -`) и `CODE_SIGNING_ALLOWED=NO` дают приложение, которое
  **запускается и показывает UI**, но с NE-entitlement в подписи macOS откажет в запуске
  (launchd error 163), а без него VPN-конфигурация не установится. Для проверки одного UI
  подписывайте с урезанными entitlements (только sandbox + network.client).
- **Developer ID** (распространение вне App Store) для packet-tunnel требует **System
  Extension**, а не app extension: другой бандл (`Contents/Library/SystemExtensions/*.systemextension`),
  активация через `OSSystemExtensionRequest`, одобрение пользователя в Системных настройках.
  Эта цель такого не производит; это следующий шаг, если понадобится раздача без App Store.
- App Group записан в iOS-стиле (`group.…`); macOS принимает это написание начиная с 14/15 при
  наличии профиля, поэтому deployment target — macOS 14.

## Проверено

- `xcodebuild … -scheme VKTurnProxyMac` собирается, в `PacketTunnel.appex` и в приложении
  прилинкованы символы моста (`wgStartVKBootstrap`, `wgAttachWireGuard`, `wgProbeVKCreds`).
- iOS-цель после изменений собирается (`-scheme VKTurnProxy`, arm64 simulator);
  `tools/swiftcheck/run.sh` проходит.
- Приложение, подписанное ad-hoc с урезанными entitlements, запускается в sandbox без ошибок
  в системном логе. **Установка VPN-профиля и сам туннель на Mac не проверялись** — для этого
  нужна сборка, подписанная профилем команды с NE capability для macOS.

## Известные шероховатости

- Иконка: macOS-размеры сгенерированы `sips` из `icon_1024.png`; для магазина стоит
  отрисовать их вручную.
- `.onChange(of:perform:)` — deprecated-предупреждения на macOS 14; поведение не меняется,
  а поднимать сигнатуру нельзя без потери iOS 15.
- Экспорт бэкапа/лога на Mac — это «сохранить файл», без списка получателей как на iOS.

## Без Network Extension: консольный клиент

Если подписать сборку профилем с NE capability нечем, на Mac есть путь, которого нет на
iOS: `tools/native_client` — тот же Go-конвейер (proxy → VK TURN → SRTP → WireGuard),
открывающий utun напрямую от root. Никаких entitlements не нужно.

```bash
go build -o native_client ./tools/native_client
sudo ./native_client -server 31.56.185.53:56000 \
  -vk-link https://vk.ru/call/join/<id> \
  -vk-cookie-file cookie.txt \
  -wg-key-file wg.key -wg-psk-file wg.psk -wg-peer-key <server pubkey> \
  -address 10.66.66.5/24 -conns 30 -route 77.88.8.8
```

`-route` пускает через туннель отдельные хосты; `-default-route` — весь трафик
(откажется, если default route уже смотрит в другой VPN). `-vk-cookie-file` включает
cookie-авторизацию из приложения (заголовок `remixsid=…; p=…`); без него — анонимная
выдача TURN-кредов по ссылке, возможна капча. Ctrl-C снимает маршруты и интерфейс.
