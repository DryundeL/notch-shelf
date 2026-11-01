import ServiceManagement
import Foundation

@MainActor
final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let key = "shelf.settings"
    private let backupKey = "shelf.settings.corruptBackup"
    private let maximumPayloadSize = 65_536

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private struct Version: Decodable { let schemaVersion: Int }

    func load() -> ShelfSettings {
        guard let data = defaults.data(forKey: key) else { return .defaults }
        guard data.count <= maximumPayloadSize else { return .defaults }
        guard let version = try? JSONDecoder().decode(Version.self, from: data) else {
            defaults.set(data, forKey: backupKey)
            return .defaults
        }
        // Не менять данные неизвестной схемы, включая будущую версию.
        guard version.schemaVersion == 1 else { return .defaults }
        guard let settings = try? JSONDecoder().decode(ShelfSettings.self, from: data), settings.isValid else {
            defaults.set(data, forKey: backupKey)
            return .defaults
        }
        return settings
    }

    func save(_ settings: ShelfSettings) throws {
        guard settings.isValid else { throw SettingsStoreError.invalidSettings }
        if let existing = defaults.data(forKey: key) {
            guard existing.count <= maximumPayloadSize else { throw SettingsStoreError.unsupportedVersion }
            if let version = try? JSONDecoder().decode(Version.self, from: existing), version.schemaVersion != 1 {
                throw SettingsStoreError.unsupportedVersion
            }
        }
        let data = try JSONEncoder().encode(settings)
        guard data.count <= maximumPayloadSize else { throw SettingsStoreError.invalidSettings }
        defaults.set(data, forKey: key)
    }
}


@MainActor
final class SystemLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class UserDefaultsVisibilityRecoveryStore: VisibilityRecoveryStore {
    private let defaults: UserDefaults
    private let key = "shelf.visibilitySessionActive"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var requiresRecovery: Bool { defaults.bool(forKey: key) }
    func markActive() { defaults.set(true, forKey: key) }
    func clear() { defaults.removeObject(forKey: key) }
}

// The native bridge and test doubles share the same visibility contract.
extension NSHNativeVisibility: NativeVisibilityService {}
