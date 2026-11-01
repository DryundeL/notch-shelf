import Foundation

struct ShelfSettings: Codable, Equatable, Sendable {
    enum FallbackMode: String, Codable, Sendable { case ownPanel }
    enum DisplayMode: String, Codable, Sendable { case automatic, floating, notch, minimal }

    var hiddenBundleIDs: [String] = []
    var perDisplayModes: [String: DisplayMode] = [:]
    let schemaVersion: Int
    var launchAtLogin: Bool
    var animationsEnabled: Bool
    var animationDurationMs: Int
    var dismissDelayMs: Int
    var fallbackMode: FallbackMode
    var defaultDisplayMode: DisplayMode

    static let defaults = ShelfSettings(schemaVersion: 1, launchAtLogin: false,
        animationsEnabled: true, animationDurationMs: 160, dismissDelayMs: 700,
        fallbackMode: .ownPanel, defaultDisplayMode: .automatic)

    var isValid: Bool {
        hiddenBundleIDs.count <= 128 && Set(hiddenBundleIDs).count == hiddenBundleIDs.count &&
        hiddenBundleIDs.allSatisfy { !$0.isEmpty && $0.utf8.count <= 255 && $0.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0) } } &&
        perDisplayModes.count <= 64 && perDisplayModes.keys.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 } &&
        schemaVersion == 1 && (1...1000).contains(animationDurationMs) && (1...5000).contains(dismissDelayMs)
    }
}

@MainActor
protocol SettingsStore {
    func load() -> ShelfSettings
    func save(_ settings: ShelfSettings) throws
}

enum SettingsStoreError: Error {
    case unsupportedVersion
    case invalidSettings
}

extension ShelfSettings {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, launchAtLogin, animationsEnabled, animationDurationMs, dismissDelayMs
        case fallbackMode, defaultDisplayMode, perDisplayModes, hiddenBundleIDs
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        launchAtLogin = try values.decode(Bool.self, forKey: .launchAtLogin)
        animationsEnabled = try values.decode(Bool.self, forKey: .animationsEnabled)
        animationDurationMs = try values.decode(Int.self, forKey: .animationDurationMs)
        dismissDelayMs = try values.decode(Int.self, forKey: .dismissDelayMs)
        fallbackMode = try values.decode(FallbackMode.self, forKey: .fallbackMode)
        defaultDisplayMode = try values.decode(DisplayMode.self, forKey: .defaultDisplayMode)
        hiddenBundleIDs = try values.decodeIfPresent([String].self, forKey: .hiddenBundleIDs) ?? []
        perDisplayModes = try values.decodeIfPresent([String: DisplayMode].self, forKey: .perDisplayModes) ?? [:]
    }
}

// Registration is changed only by an explicit user action.
enum LoginItemStatus: Equatable {
    case notRegistered, enabled, requiresApproval, notFound
    var isRegistered: Bool { self == .enabled || self == .requiresApproval }
}

@MainActor
protocol LoginItemService {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    func openSettings()
}

@MainActor
protocol VisibilityRecoveryStore {
    var requiresRecovery: Bool { get }
    func markActive()
    func clear()
}
