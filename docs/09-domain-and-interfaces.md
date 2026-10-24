# Domain-модели и контракты Swift

Ниже **эскиз API**, не готовые компилируемые файлы. Уточнить actor isolation, threading и error semantics при реализации.

```swift
import Foundation
import CoreGraphics

struct MenuItemID: Hashable, Codable, Sendable {
    let ownerBundleID: String
    let observedKey: String // ephemeral/heuristic; collision handling required
}

struct MenuItemSnapshot: Sendable {
    let id: MenuItemID
    let displayName: String?
    let isReachable: Bool
    let observedAt: Date
}

enum BackendCapability: Hashable, Sendable {
    case discover
    case revealSection
    case concealSection
    case activateItem
    case restoreAll
}

enum BackendError: Error {
    case unsupported
    case permissionDenied
    case staleItem
    case unavailable
    case conflict
}

protocol MenuBarBackend: Sendable {
    func capabilities() async -> Set<BackendCapability>
    func snapshot() async throws -> [MenuItemSnapshot]
    func revealSection() async throws
    func concealSection() async throws
    func activate(_ id: MenuItemID) async throws
    func restoreUserAccess() async throws
}
```

## Rule model
```swift
struct ItemRule: Codable, Sendable {
    enum Policy: String, Codable, Sendable {
        case pinVisible, preferHidden, ask
    }
    let ownerBundleID: String
    let observedItemKey: String?
    let policy: Policy
}
```
RuleEngine: pure function `(known items, rules, capabilities) -> proposed actions`. Every action checked against backend capabilities; `ask` default for unknown if auto hide disabled.

## Display
```swift
struct DisplaySnapshot: Sendable {
    let runtimeID: UInt32
    let stableProfileKey: String?  // best effort, not guaranteed
    let framePoints: CGRect
    let visibleFramePoints: CGRect
    let scale: CGFloat
    let hasNotch: Bool
}
enum ShelfMode: String, Codable, Sendable {
    case notch, floating, minimal
}
```
`hasNotch` derived from safe area/auxiliary top regions and availability, never inferred solely from model name.

## Coordination
- `@MainActor` PanelCoordinator + AppKit UI.
- `actor MenuBarCoordinator` serializes backend actions.
- DisplayService immutable `DisplaySnapshot` stream.
- `SettingsStore` protocol with `load/save`; migration in infrastructure.

## Error policies
| Error | UX | Recovery |
|---|---|---|
| AX permission denied | настройки -> системный prompt | disable advanced functions |
| stale item | refresh snapshot once | reveal native section |
| backend unsupported | label feature unavailable | fallback |
| display disappeared | close/reanchor | main screen |
| corrupted settings | keep backup + defaults | no automatic hiding |
