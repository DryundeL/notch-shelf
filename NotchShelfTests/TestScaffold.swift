import XCTest
import ApplicationServices
@testable import NotchShelf

final class MenuBarReportTests: XCTestCase {
    func testUnknownSelectionCannotActivateAnItem() async {
        let scanner = MenuBarScanner()
        let result = await scanner.press(UUID())
        XCTAssertEqual(result, L("Элемент устарел. Повторите сканирование."))
        let candidates = await scanner.availableCandidates()
        XCTAssertTrue(candidates.isEmpty)
    }

    func testUntrustedTextCannotInsertReportLines() {
        XCTAssertEqual(MenuBarScanner.safe("Name\n\t\r\u{0}Injected"), "NameInjected")
        XCTAssertEqual(MenuBarScanner.safe(String(repeating: "я", count: 200)).count, 128)
    }

    func testStatusesDistinguishMissingValueFromFailure() {
        XCTAssertEqual(MenuBarScanner.status(.noValue), L("значение отсутствует") + " [-25212]")
        XCTAssertEqual(MenuBarScanner.status(.cannotComplete), L("запрос не завершён") + " [-25204]")
        XCTAssertEqual(MenuBarScanner.status(.success), "OK [0]")
    }
}

final class ShelfStateTests: XCTestCase {
    func testRepeatedRequestsAreIdempotent() {
        var state = ShelfState()
        for _ in 0..<100 { state.requestOpen() }
        XCTAssertEqual(state.phase, .opening)
        state.finishOpening()
        state.requestOpen()
        XCTAssertEqual(state.phase, .open)
        for _ in 0..<100 { state.requestClose() }
        XCTAssertEqual(state.phase, .closing)
        state.finishClosing()
        XCTAssertEqual(state.phase, .closed)
    }

    func testCancellationIgnoresLateCompletion() {
        var state = ShelfState()
        state.requestOpen()
        state.cancel()
        state.finishOpening()
        XCTAssertEqual(state.phase, .closed)
        state.requestOpen()
        state.requestClose()
        state.finishOpening()
        XCTAssertEqual(state.phase, .closing)
        state.finishClosing()
        XCTAssertEqual(state.phase, .closed)
    }

    func testStatusClickDoesNotDismissAndOpeningClickIsIgnored() {
        XCTAssertFalse(ShelfDismiss.shouldClose(armed: false, pointerOnStatusButton: false))
        XCTAssertFalse(ShelfDismiss.shouldClose(armed: true, pointerOnStatusButton: true))
        XCTAssertTrue(ShelfDismiss.shouldClose(armed: true, pointerOnStatusButton: false))
    }
}

final class GeometryTests: XCTestCase {
    func testNegativeOriginAndOffscreenSourceAreClamped() throws {
        let frame = CGRect(x: -1920, y: -400, width: 1920, height: 1080)
        let visible = CGRect(x: -1920, y: -360, width: 1920, height: 1010)
        let result = try XCTUnwrap(ShelfGeometry.placement(visibleFrame: visible, screenFrame: frame, hasNotch: false, sourceX: 10000))
        XCTAssertTrue(visible.contains(result.frame))
        XCTAssertEqual(result.frame.maxX, visible.maxX - 8)
    }

    func testNotchUsesScreenCenterInPoints() throws {
        let frame = CGRect(x: 200, y: 500, width: 1500, height: 900)
        let result = try XCTUnwrap(ShelfGeometry.placement(visibleFrame: frame, screenFrame: frame, hasNotch: true, sourceX: 300))
        XCTAssertEqual(result.frame.midX, frame.midX)
    }

    func testSmallDisplayRequiresScrollAndInvalidInputIsRejected() throws {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        let result = try XCTUnwrap(ShelfGeometry.placement(visibleFrame: frame, screenFrame: frame, hasNotch: false, sourceX: 100))
        XCTAssertTrue(result.requiresScroll)
        XCTAssertTrue(frame.contains(result.frame))
        XCTAssertNil(ShelfGeometry.placement(visibleFrame: .zero, screenFrame: frame, hasNotch: false, sourceX: 0))
        XCTAssertNil(ShelfGeometry.placement(visibleFrame: frame, screenFrame: frame, hasNotch: false, sourceX: .nan))
    }
}

@MainActor
final class SettingsMigrationTests: XCTestCase {
    private func withStore(_ body: (UserDefaults, UserDefaultsSettingsStore) throws -> Void) throws {
        let suite = "NotchShelfTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, UserDefaultsSettingsStore(defaults: defaults))
    }

    func testRoundTrip() throws {
        try withStore { _, store in
            var settings = ShelfSettings.defaults
            settings.animationsEnabled = false
            try store.save(settings)
            XCTAssertEqual(store.load(), settings)
        }
    }

    func testCorruptDataIsBackedUpAndUsesDefaults() throws {
        try withStore { defaults, store in
            let data = Data("broken".utf8)
            defaults.set(data, forKey: "shelf.settings")
            XCTAssertEqual(store.load(), .defaults)
            XCTAssertEqual(defaults.data(forKey: "shelf.settings.corruptBackup"), data)
        }
    }

    func testFutureVersionIsPreserved() throws {
        try withStore { defaults, store in
            let data = Data("{\"schemaVersion\":2}".utf8)
            defaults.set(data, forKey: "shelf.settings")
            XCTAssertEqual(store.load(), .defaults)
            XCTAssertThrowsError(try store.save(.defaults))
            XCTAssertEqual(defaults.data(forKey: "shelf.settings"), data)
        }
    }

    func testUnknownKeysAreIgnoredAndInvalidValuesRejected() throws {
        try withStore { defaults, store in
            let data = try JSONEncoder().encode(ShelfSettings.defaults)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["autoHideNewItems"] = true
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "shelf.settings")
            XCTAssertEqual(store.load(), .defaults)
            for invalid in [0, -1, 1001, Int.max] {
                var settings = ShelfSettings.defaults
                settings.animationDurationMs = invalid
                XCTAssertThrowsError(try store.save(settings))
            }
            object["defaultDisplayMode"] = "unknown"
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "shelf.settings")
            XCTAssertEqual(store.load(), .defaults)
        }
    }
}

@MainActor
final class SettingsModelTests: XCTestCase {
    private final class MemoryStore: SettingsStore {
        var value = ShelfSettings.defaults
        var fail = false
        func load() -> ShelfSettings { value }
        func save(_ settings: ShelfSettings) throws {
            if fail { throw SettingsStoreError.unsupportedVersion }
            value = settings
        }
    }

    func testChangeIsSavedAndRestoredByNewModel() {
        let store = MemoryStore()
        let model = SettingsModel(store: store)
        model.update { $0.animationsEnabled = false }
        XCTAssertFalse(SettingsModel(store: store).settings.animationsEnabled)
        XCTAssertNil(model.errorMessage)
    }

    func testSaveFailureDoesNotChangeDisplayedSettings() {
        let store = MemoryStore()
        store.fail = true
        let model = SettingsModel(store: store)
        model.update { $0.animationsEnabled = false }
        XCTAssertEqual(model.settings, .defaults)
        XCTAssertEqual(store.value, .defaults)
        XCTAssertNotNil(model.errorMessage)
    }
}

final class ShelfAnimationPolicyTests: XCTestCase {
    func testAllMotionCombinations() {
        for enabled in [true, false] {
            for reduced in [true, false] {
                var settings = ShelfSettings.defaults
                settings.animationsEnabled = enabled
                XCTAssertEqual(ShelfAnimationPolicy.duration(settings: settings, reduceMotion: reduced),
                               enabled && !reduced ? 0.16 : 0)
            }
        }
    }

    func testInvalidDurationNeverStartsAnimation() {
        var settings = ShelfSettings.defaults
        settings.animationDurationMs = Int.max
        XCTAssertEqual(ShelfAnimationPolicy.duration(settings: settings, reduceMotion: false), 0)
    }
}

final class DisplayPolicyTests: XCTestCase {
    private let left = DisplaySnapshot(runtimeID: 1, frame: CGRect(x: -1000, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: -1000, y: 0, width: 1000, height: 770), scale: 1, hasNotch: false)
    private let right = DisplaySnapshot(runtimeID: 2, frame: CGRect(x: 0, y: 0, width: 1400, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1400, height: 860), scale: 2, hasNotch: true)

    func testSourceWinsOverPointerAndMain() {
        XCTAssertEqual(DisplayPolicy.target(in: [left, right], sourceID: 1, pointer: .zero, mainID: 2), left)
    }

    func testMissingSourceFallsBackToPointerThenMain() {
        XCTAssertEqual(DisplayPolicy.target(in: [left, right], sourceID: 99, pointer: CGPoint(x: -500, y: 50), mainID: 2), left)
        XCTAssertEqual(DisplayPolicy.target(in: [left, right], sourceID: nil, pointer: CGPoint(x: 9999, y: 9999), mainID: 2), right)
        XCTAssertNil(DisplayPolicy.target(in: [], sourceID: 1, pointer: .zero, mainID: 1))
    }
}

final class DisplayProfileTests: XCTestCase {
    func testDuplicateKeysFallBackWithoutSharingProfile() {
        let first = DisplaySnapshot(profileKey: "duplicate", name: "Monitor", runtimeID: 1,
            frame: .zero, visibleFrame: .zero, scale: 1, hasNotch: false)
        var second = first
        second.name = "Another name"
        var settings = ShelfSettings.defaults
        settings.perDisplayModes["duplicate"] = .minimal
        XCTAssertEqual(DisplayProfilePolicy.mode(for: first, among: [first, second], settings: settings), .floating)
    }

    func testExternalDoesNotUseNotchAndMinimalIsPreserved() {
        let display = DisplaySnapshot(profileKey: "external", runtimeID: 1,
            frame: .zero, visibleFrame: .zero, scale: 2, hasNotch: false)
        var settings = ShelfSettings.defaults
        settings.perDisplayModes["external"] = .notch
        XCTAssertEqual(DisplayProfilePolicy.mode(for: display, among: [display], settings: settings), .floating)
        settings.perDisplayModes["external"] = .minimal
        XCTAssertEqual(DisplayProfilePolicy.mode(for: display, among: [display], settings: settings), .minimal)
    }

    func testOldSettingsWithoutProfilesPreserveValues() throws {
        var settings = ShelfSettings.defaults
        settings.animationsEnabled = false
        let data = try JSONEncoder().encode(settings)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "perDisplayModes")
        let restored = try JSONDecoder().decode(ShelfSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored, settings)
    }
}

@MainActor
final class LoginItemTests: XCTestCase {
    private final class Service: LoginItemService {
        var status: LoginItemStatus = .notRegistered
        var fail = false
        var changes = 0
        func setEnabled(_ enabled: Bool) throws {
            changes += 1
            if fail { throw SettingsStoreError.invalidSettings }
            status = enabled ? .requiresApproval : .notRegistered
        }
        func openSettings() {}
    }
    private final class Store: SettingsStore {
        var value = ShelfSettings.defaults
        func load() -> ShelfSettings { value }
        func save(_ settings: ShelfSettings) throws { value = settings }
    }
    func testInitializationNeverRegistersAndUsesSystemStatus() {
        let service = Service()
        let store = Store()
        store.value.launchAtLogin = true
        let model = SettingsModel(store: store, loginItem: service)
        XCTAssertEqual(model.loginItemStatus, .notRegistered)
        XCTAssertEqual(service.changes, 0)
        model.stop()
    }
    func testApprovalAndDisableAndExternalChange() {
        let service = Service()
        let store = Store()
        let model = SettingsModel(store: store, loginItem: service)
        model.setLaunchAtLogin(true)
        XCTAssertEqual(model.loginItemStatus, .requiresApproval)
        XCTAssertTrue(store.value.launchAtLogin)
        model.setLaunchAtLogin(false)
        XCTAssertEqual(model.loginItemStatus, .notRegistered)
        XCTAssertFalse(store.value.launchAtLogin)
        service.status = .enabled
        model.refreshLoginItem()
        XCTAssertEqual(model.loginItemStatus, .enabled)
        model.stop()
    }
    func testNotFoundAllowsExplicitRegistration() {
        let service = Service()
        service.status = .notFound
        let store = Store()
        let model = SettingsModel(store: store, loginItem: service)
        model.setLaunchAtLogin(true)
        XCTAssertEqual(service.changes, 1)
        XCTAssertEqual(model.loginItemStatus, .requiresApproval)
        XCTAssertTrue(store.value.launchAtLogin)
        model.stop()
    }

    func testFailureKeepsActualStatusAndPreference() {
        let service = Service()
        service.fail = true
        let store = Store()
        let model = SettingsModel(store: store, loginItem: service)
        model.setLaunchAtLogin(true)
        XCTAssertEqual(model.loginItemStatus, .notRegistered)
        XCTAssertFalse(store.value.launchAtLogin)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(service.changes, 1)
        model.stop()
    }
}


final class NativeVisibilityPolicyTests: XCTestCase {
    func testOnlySelectedAppIsExcludedAndManagerIsRetained() {
        XCTAssertEqual(NativeVisibilityPolicy.allowedBundleIDs(running: ["third.party", "another.app", "com.apple.controlcenter"], selected: "third.party", own: "local.notchshelf.app"),
                       ["another.app", "com.apple.controlcenter", "local.notchshelf.app"])
    }
    func testSystemSelfAndStaleSelectionsAreRejected() {
        for selected in ["com.apple.controlcenter", "local.notchshelf.app", "missing", ""] {
            XCTAssertNil(NativeVisibilityPolicy.allowedBundleIDs(running: ["com.apple.controlcenter", "local.notchshelf.app"], selected: selected, own: "local.notchshelf.app"))
        }
    }
}


@MainActor
final class MenuBarSelectionTests: XCTestCase {
    private final class Store: SettingsStore {
        func load() -> ShelfSettings { .defaults }
        func save(_ settings: ShelfSettings) throws {}
    }
    func testPermissionFailureClearsUnusableSelectionAndIsNotShownAsEmptyScan() {
        let model = SettingsModel(store: Store())
        let candidate = MenuBarScanner.Candidate(id: UUID(), pid: 1, bundleID: "first.app", label: "First")
        model.setMenuBarItems([candidate])
        model.beginInventoryRefresh(permissionGranted: false)
        XCTAssertEqual(model.inventoryState, .permissionRequired)
        XCTAssertTrue(model.menuBarItems.isEmpty)
        XCTAssertNil(model.selectedMenuBarItem)
        model.beginInventoryRefresh(permissionGranted: true)
        XCTAssertEqual(model.inventoryState, .scanning)
        model.setMenuBarItems([])
        XCTAssertEqual(model.inventoryState, .empty)
        model.setMenuBarItems([candidate])
        XCTAssertEqual(model.inventoryState, .ready)
        XCTAssertEqual(model.selectedMenuBarItem, candidate.id)
        model.stop()
    }

    func testApplicationsWithoutIconsCannotRemainSelectedForHiding() {
        let model = SettingsModel(store: Store(), iconAvailability: { $0.bundleID == "supported.app" })
        model.pendingHiddenBundleIDs = ["supported.app", "missing-icon.app"]
        model.setMenuBarItems([
            .init(id: UUID(), pid: 1, bundleID: "supported.app", label: "Supported"),
            .init(id: UUID(), pid: 2, bundleID: "missing-icon.app", label: "Missing")
        ])
        XCTAssertEqual(model.iconAvailableBundleIDs, ["supported.app"])
        XCTAssertEqual(model.pendingHiddenBundleIDs, ["supported.app"])
        XCTAssertEqual(model.menuBarItems.count, 2)
        model.stop()
    }

    func testRefreshRemovesSelectionWhenPreviouslyAvailableIconDisappears() {
        var available = true
        let model = SettingsModel(store: Store(), iconAvailability: { _ in available })
        let item = MenuBarScanner.Candidate(id: UUID(), pid: 1, bundleID: "changing.app", label: "Changing")
        model.setMenuBarItems([item])
        model.pendingHiddenBundleIDs = [item.bundleID]
        available = false
        model.setMenuBarItems([item])
        XCTAssertTrue(model.iconAvailableBundleIDs.isEmpty)
        XCTAssertTrue(model.pendingHiddenBundleIDs.isEmpty)
        model.stop()
    }

    func testRefreshPreservesSelectionOfSameLiveElement() {
        let model = SettingsModel(store: Store())
        let first = MenuBarScanner.Candidate(id: UUID(), pid: 1, bundleID: "first.app", label: "First")
        let second = MenuBarScanner.Candidate(id: UUID(), pid: 2, bundleID: "second.app", label: "Second")
        model.setMenuBarItems([first, second])
        model.selectedMenuBarItem = second.id
        model.setMenuBarItems([first, second])
        XCTAssertEqual(model.selectedMenuBarItem, second.id)
        model.setMenuBarItems([])
        XCTAssertNil(model.selectedMenuBarItem)
        model.stop()
    }
}

final class HiddenApplicationSettingsTests: XCTestCase {
    func testOversizedHiddenApplicationListIsRejected() throws {
        let encoded = try JSONEncoder().encode(ShelfSettings.defaults)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["hiddenBundleIDs"] = (0..<129).map { "example.app\($0)" }
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertFalse(try JSONDecoder().decode(ShelfSettings.self, from: data).isValid)
    }
}

final class HiddenApplicationPersistenceTests: XCTestCase {
    func testOldSchemaAndMultipleApplicationsRoundTrip() throws {
        let encoded = try JSONEncoder().encode(ShelfSettings.defaults)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "hiddenBundleIDs")
        let old = try JSONDecoder().decode(ShelfSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.hiddenBundleIDs.isEmpty)
        var changed = old
        changed.hiddenBundleIDs = ["org.example.one", "org.example.two"]
        XCTAssertEqual(try JSONDecoder().decode(ShelfSettings.self, from: JSONEncoder().encode(changed)), changed)
        changed.hiddenBundleIDs = ["org.example.one", "org.example.one"]
        XCTAssertFalse(changed.isValid)
        changed.hiddenBundleIDs = ["../invalid"]
        XCTAssertFalse(changed.isValid)
    }

    func testMultipleSelectionKeepsAllUnselectedApplications() {
        XCTAssertEqual(NativeVisibilityPolicy.allowedBundleIDs(running: ["a", "b", "c", "com.apple.controlcenter"], selected: Set(["a", "b"]), own: "manager"), ["c", "com.apple.controlcenter", "manager"])
        XCTAssertNil(NativeVisibilityPolicy.allowedBundleIDs(running: ["a"], selected: Set(["missing"]), own: "manager"))
    }
}

@MainActor
final class VisibilityRecoveryTests: XCTestCase {
    private final class Marker: VisibilityRecoveryStore {
        var requiresRecovery = true
        func markActive() { requiresRecovery = true }
        func clear() { requiresRecovery = false }
    }
    private final class Store: SettingsStore {
        func load() -> ShelfSettings { .defaults }
        func save(_ settings: ShelfSettings) throws {}
    }
    func testUncleanSessionPausesAutomaticReapplication() {
        let marker = Marker()
        let model = SettingsModel(store: Store(), recovery: marker)
        XCTAssertTrue(model.visibilityPausedAfterCrash)
        model.applyHiddenApplications(saveSelection: false)
        XCTAssertTrue(model.hiddenCandidates.isEmpty)
        model.restoreVisibility()
        XCTAssertFalse(marker.requiresRecovery)
        XCTAssertTrue(model.visibilityPausedAfterCrash)
        model.stop()
    }
}

final class HoverGeometryTests: XCTestCase {
    func testVirtualNotchOnMonitorWithNegativeOrigin() throws {
        let screen = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let trigger = try XCTUnwrap(HoverGeometry.trigger(screen: screen, safeTop: 0, notchLeft: nil, notchRight: nil))
        XCTAssertTrue(screen.contains(trigger))
        XCTAssertEqual(trigger.midX, screen.midX)
        XCTAssertEqual(trigger.maxY, screen.maxY)
    }
    func testPhysicalNotchTracksLowerEdge() throws {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let trigger = try XCTUnwrap(HoverGeometry.trigger(screen: frame, safeTop: 32, notchLeft: 650, notchRight: 862))
        XCTAssertEqual(trigger.width, 212)
        XCTAssertEqual(trigger.maxY, frame.maxY)
        XCTAssertTrue(trigger.contains(CGPoint(x: 756, y: 938)))
        XCTAssertFalse(trigger.contains(CGPoint(x: 756, y: 930)))
        XCTAssertTrue(frame.contains(trigger))
    }
    func testInvalidFramesAreRejected() {
        XCTAssertNil(HoverGeometry.trigger(screen: .zero, safeTop: 0, notchLeft: nil, notchRight: nil))
        XCTAssertNil(HoverGeometry.trigger(screen: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100), safeTop: 0, notchLeft: nil, notchRight: nil))
    }
}



final class LocalMenuSafetyTests: XCTestCase {
    func testUnknownItemCannotOpenNativeMenuOrSupplyActions() async {
        let scanner = MenuBarScanner()
        let entries = await scanner.menuSnapshot(UUID())
        XCTAssertTrue(entries.isEmpty)
        let result = await scanner.performMenuAction(UUID())
        XCTAssertEqual(result, L("Действие устарело или Accessibility недоступен. Откройте меню заново."))
    }
}

@MainActor
final class ShelfContextMenuTests: XCTestCase {
    func testLocalMenuPreservesDisabledCheckedAndSubmenuItems() {
        let shelf = ShelfPanelController()
        let commandID = UUID()
        let submenu = MenuBarScanner.MenuEntry(actionID: commandID, title: "Действие", enabled: true, checked: true, separator: false, children: [])
        let menu = shelf.makeContextMenu([
            MenuBarScanner.MenuEntry(actionID: nil, title: "Недоступно", enabled: false, checked: false, separator: false, children: []),
            MenuBarScanner.MenuEntry(actionID: nil, title: "", enabled: false, checked: false, separator: true, children: []),
            MenuBarScanner.MenuEntry(actionID: nil, title: "Подменю", enabled: true, checked: false, separator: false, children: [submenu])
        ])
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        let command = menu.items[2].submenu?.items.first
        XCTAssertEqual(command?.title, "Действие")
        XCTAssertEqual(command?.state, .on)
        XCTAssertEqual(command?.representedObject as? String, commandID.uuidString)
        XCTAssertNotNil(command?.action)
        shelf.stop()
    }
}

@MainActor
final class StatusMenuTests: XCTestCase {
    func testStatusMenuListsApplicationsAndOffersSettingsAndQuitImmediately() {
        let menu = StatusItemController.makeStatusMenu(applicationNames: ["VPN", "Telegram", "VPN"], settingsTarget: nil)
        XCTAssertEqual(menu.items.map(\.title), [L("Приложения в шторке"), "Telegram", "VPN", "", L("Настройки…"), L("Выйти из Notch Shelf")])
        XCTAssertFalse(menu.items[1].isEnabled)
        XCTAssertTrue(menu.items[4].isEnabled)
        XCTAssertEqual(menu.items[5].action, #selector(NSApplication.terminate(_:)))
    }
    func testEmptyShelfStillHasSettingsAndQuit() {
        let menu = StatusItemController.makeStatusMenu(applicationNames: [], settingsTarget: nil)
        XCTAssertEqual(menu.items.first?.title, L("В шторке пока нет приложений"))
        XCTAssertEqual(menu.items.suffix(2).map(\.title), [L("Настройки…"), L("Выйти из Notch Shelf")])
    }
}



@MainActor
final class ShelfFirstClickTests: XCTestCase {
    func testItemButtonAcceptsClickWithoutFirstActivatingPanel() {
        let button = ShelfItemButton(title: "", target: nil, action: nil)
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        XCTAssertFalse(button.needsPanelToBecomeKey)
    }
}

final class AttachedShelfGeometryTests: XCTestCase {
    func testBubbleExpandsBelowCameraWithoutCoveringMenuBar() throws {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let notch = CGRect(x: 650, y: 950, width: 212, height: 32)
        let layout = try XCTUnwrap(NotchShelfGeometry.layout(screen: screen, cutout: notch, itemCount: 7))
        XCTAssertEqual(layout.collapsed, notch)
        XCTAssertEqual(layout.expanded.maxY, notch.maxY)
        XCTAssertLessThan(layout.body.maxY, notch.minY)
        XCTAssertEqual(layout.expanded.midX, notch.midX)
        XCTAssertLessThanOrEqual(layout.collapsed.width, notch.width)
        XCTAssertTrue(screen.contains(layout.expanded))
    }
    func testVirtualShapeOnExternalMonitorAndInvalidScreen() throws {
        let screen = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let layout = try XCTUnwrap(NotchShelfGeometry.layout(screen: screen, cutout: nil, itemCount: 30))
        XCTAssertLessThanOrEqual(layout.collapsed.width, 180)
        XCTAssertLessThan(layout.body.maxY, screen.maxY - 24)
        XCTAssertTrue(screen.contains(layout.expanded))
        XCTAssertNil(NotchShelfGeometry.layout(screen: .zero, cutout: nil, itemCount: 1))
    }
}

final class BubbleSizingTests: XCTestCase {
    func testBubbleGrowsWithIconCountAndCentersShortRows() throws {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let notch = CGRect(x: 650, y: 950, width: 212, height: 32)
        let one = try XCTUnwrap(NotchShelfGeometry.layout(screen: screen, cutout: notch, itemCount: 1))
        let six = try XCTUnwrap(NotchShelfGeometry.layout(screen: screen, cutout: notch, itemCount: 6))
        let seven = try XCTUnwrap(NotchShelfGeometry.layout(screen: screen, cutout: notch, itemCount: 7))
        XCTAssertEqual(one.body.width, 76)
        XCTAssertLessThan(one.body.width, six.body.width)
        XCTAssertGreaterThan(seven.expanded.height, six.expanded.height)
        XCTAssertLessThan(seven.body.maxY, notch.minY)
        let width = seven.body.width - 32
        let frames = BubbleIconGrid.frames(itemCount: 7, width: width)
        XCTAssertEqual(frames.count, 7)
        let rows = Dictionary(grouping: frames, by: \.minY)
        XCTAssertEqual(rows.values.map(\.count).sorted(), [3, 4])
        for row in rows.values {
            let minX = try XCTUnwrap(row.map(\.minX).min())
            let maxX = try XCTUnwrap(row.map(\.maxX).max())
            XCTAssertEqual((minX + maxX) / 2, width / 2)
        }
    }
}


final class BubbleMenuBarBoundaryTests: XCTestCase {
    func testExternalBubbleStaysBelowActualMenuBarEvenWhenMarkerIsShorter() throws {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let layout = try XCTUnwrap(NotchShelfGeometry.layout(screen: screen, cutout: nil, itemCount: 4, menuBarHeight: 36))
        XCTAssertEqual(layout.body.maxY, screen.maxY - 36 - 12)
        XCTAssertEqual(layout.expanded.maxY, screen.maxY)
    }
}


final class ConnectedShelfShapeTests: XCTestCase {
    func testNeckKeepsItsWidthInsideMenuBarAndConnectsToBody() {
        let size = CGSize(width: 296, height: 124)
        let path = ConnectedShelfShape.path(size: size, neckWidth: 212, neckHeight: 32, bodyWidth: 296)
        XCTAssertTrue(path.contains(CGPoint(x: 148, y: 120)))
        XCTAssertFalse(path.contains(CGPoint(x: 10, y: 120)))
        XCTAssertTrue(path.contains(CGPoint(x: 10, y: 40)))
        for y in stride(from: 1, through: 123, by: 1) {
            XCTAssertTrue(path.contains(CGPoint(x: 148, y: y)))
        }
    }
    func testCollapsedShapeIsExactlyTheNeck() {
        let path = ConnectedShelfShape.path(size: CGSize(width: 212, height: 32), neckWidth: 212, neckHeight: 32, bodyWidth: 296)
        XCTAssertEqual(path.boundingBox, CGRect(x: 0, y: 0, width: 212, height: 32))
    }
}

@MainActor
final class ResourceStatusIconTests: XCTestCase {
    private func fixture(includeStatusIcon: Bool, owner: String = "ru.keepcoder.Telegram", resourcePath: String = "StatusIcon.png") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("app")
        let resources = url.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleIdentifier": owner, "CFBundlePackageType": "APPL", "CFBundleName": "Fixture", "CFBundleIconFile": "AppIcon"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        if let bytes = bitmap.bitmapData { memset(bytes, 0, bitmap.bytesPerRow * bitmap.pixelsHigh) }
        bitmap.setColor(.black, atX: 8, y: 8)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: resources.appendingPathComponent("AppIcon.png"))
        if includeStatusIcon {
            let resourceURL = resources.appendingPathComponent(resourcePath)
            try FileManager.default.createDirectory(at: resourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: resourceURL)
        }
        return url
    }

    func testLoadsOriginalNamedStatusResourceAsTemplate() throws {
        let url = try fixture(includeStatusIcon: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try XCTUnwrap(MenuBarResourceIconProvider().image(bundleID: "ru.keepcoder.Telegram", bundleURL: url))
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
        XCTAssertTrue(image.isTemplate)
    }

    func testMissingStatusResourceDoesNotFallBackToDockIcon() throws {
        let url = try fixture(includeStatusIcon: false)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(MenuBarResourceIconProvider().image(bundleID: "ru.keepcoder.Telegram", bundleURL: url))
    }

    func testUnknownOwnerCannotUseAnotherApplicationResource() throws {
        let url = try fixture(includeStatusIcon: true)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(MenuBarResourceIconProvider().image(bundleID: "other.app", bundleURL: url))
    }
}

final class CapturePreferenceRemovalTests: XCTestCase {
    func testOldCapturePreferenceIsIgnoredWithoutLosingHiddenApplications() throws {
        var settings = ShelfSettings.defaults
        settings.hiddenBundleIDs = ["ru.keepcoder.Telegram"]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        object["menuBarSnapshotsEnabled"] = true
        let restored = try JSONDecoder().decode(ShelfSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored, settings)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        XCTAssertNil(saved["menuBarSnapshotsEnabled"])
    }
}


@MainActor
extension ResourceStatusIconTests {
    func testLoadsAdditionalOwnersFromTheirRealResourceLayouts() throws {
        let layouts = ["com.vorssaint.utils": "MenuBarIcon.png", "com.jh.AWDLControl": "MenuIcon.png",
                       "pro.betterdisplay.BetterDisplay": "BetterDisplayStatus.png", "com.docker.docker": "statusItemIcon-0.png",
                       "com.todesktop.230313mzl4w4u92": "app/molten/dist/tray/darwin/trayTemplate.png"]
        for (owner, path) in layouts {
            let url = try fixture(includeStatusIcon: true, owner: owner, resourcePath: path)
            defer { try? FileManager.default.removeItem(at: url) }
            let image = try XCTUnwrap(MenuBarResourceIconProvider().image(bundleID: owner, bundleURL: url))
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
            XCTAssertTrue(image.isTemplate)
        }
    }

    func testIdenticalNestedTrayCopiesAreNotAmbiguous() throws {
        let owner = "org.example.ElectronTool"
        let url = try fixture(includeStatusIcon: true, owner: owner, resourcePath: "app/resources/darwin/trayTemplate.png")
        defer { try? FileManager.default.removeItem(at: url) }
        let root = url.appendingPathComponent("Contents/Resources")
        let second = root.appendingPathComponent("app/molten/dist/tray/darwin/trayTemplate.png")
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("app/resources/darwin/trayTemplate.png"), to: second)
        XCTAssertNotNil(MenuBarResourceIconProvider().image(bundleID: owner, bundleURL: url))
    }

    func testUnsupportedVpnOwnersDoNotUseDockImage() throws {
        for owner in ["org.redshieldvpn.redshieldvpn", "org.openvpn.client.app"] {
            let url = try fixture(includeStatusIcon: false, owner: owner)
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertNil(MenuBarResourceIconProvider().image(bundleID: owner, bundleURL: url))
        }
    }
}

@MainActor
extension ResourceStatusIconTests {
    func testPreviouslyUnknownOwnerIsDiscoveredWithoutBundleIDRegistration() throws {
        let url = try fixture(includeStatusIcon: true, owner: "org.example.NewMenuBarTool")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotNil(MenuBarResourceIconProvider().image(bundleID: "org.example.NewMenuBarTool", bundleURL: url))
    }
}

@MainActor
final class ShelfDropDownDirectionTests: XCTestCase {
    func testDropDownUsesLowerEdgeWithoutHidingFirstApplicationCommand() {
        let menu = NSMenu()
        menu.addItem(withTitle: "First command", action: nil, keyEquivalent: "")
        let cell = ShelfPanelController.makeDropDownCell(menu: menu)
        XCTAssertEqual(cell.preferredEdge, .minY)
        XCTAssertTrue(cell.pullsDown)
        XCTAssertEqual(cell.menu?.items[1].title, "First command")
    }
}


final class CompleteApplicationInventoryTests: XCTestCase {
    func testMoreThan128OwnersRemainInScanOrder() {
        let processes = (1...200).map { MenuBarScanner.Process(pid: Int32($0), bundleID: "org.example.Tool\($0)", name: "Tool") }
        let ordered = MenuBarScanner.scanOrder(processes)
        XCTAssertEqual(ordered.count, 200)
        XCTAssertEqual(Set(ordered.map(\.pid)), Set(processes.map(\.pid)))
    }
}

@MainActor
final class ShelfContourHoverTests: XCTestCase {
    func testMovingIntoTransparentSideLeavesBubbleBeforeLeavingWindowFrame() throws {
        let view = ShelfHoverEffectView(frame: CGRect(x: 0, y: 0, width: 212, height: 108))
        view.wantsLayer = true
        view.neckWidth = 212
        view.neckHeight = 32
        view.bodyHeight = 64
        view.bodyWidth = 76
        var entered = 0
        var exited = 0
        view.onEnter = { entered += 1 }
        view.onExit = { exited += 1 }
        for point in [CGPoint(x: 106, y: 30), CGPoint(x: 15, y: 30), CGPoint(x: 10, y: 30), CGPoint(x: 106, y: 30)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0))
            view.mouseMoved(with: event)
        }
        XCTAssertEqual(entered, 2)
        XCTAssertEqual(exited, 1)
        XCTAssertFalse(view.containsShelfPoint(CGPoint(x: 15, y: 30)))
        XCTAssertTrue(view.containsShelfPoint(CGPoint(x: 106, y: 30)))
    }
}

@MainActor
final class ShelfSleepWakeTests: XCTestCase {
    private final class Displays: DisplayProvider {
        var snapshots: [DisplaySnapshot] = []
        var onChange: (([DisplaySnapshot]) -> Void)?
        var refreshCount = 0
        var stopped = false
        func refresh() { refreshCount += 1 }
        func stop() { stopped = true; onChange = nil }
    }

    func testSleepSuspendsHoverUntilWakeAndRefreshesDisplaysOnce() {
        let displays = Displays()
        let notifications = NotificationCenter()
        let controller = ShelfPanelController(displays: displays, applicationNotifications: NotificationCenter(), workspaceNotifications: notifications)
        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertTrue(controller.isHoverSuspended)
        displays.onChange?([])
        XCTAssertTrue(controller.isHoverSuspended)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertFalse(controller.isHoverSuspended)
        XCTAssertEqual(displays.refreshCount, 1)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(displays.refreshCount, 1)
        controller.stop()
    }

    func testStopRemovesSleepWakeObservers() {
        let displays = Displays()
        let notifications = NotificationCenter()
        let controller = ShelfPanelController(displays: displays, applicationNotifications: NotificationCenter(), workspaceNotifications: notifications)
        controller.stop()
        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertFalse(controller.isHoverSuspended)
        XCTAssertEqual(displays.refreshCount, 0)
        XCTAssertTrue(displays.stopped)
    }
}

@MainActor
final class AccessibilityRecoveryTests: XCTestCase {
    private final class Store: SettingsStore {
        var value = ShelfSettings.defaults
        init() { value.hiddenBundleIDs = ["org.example.Tool"] }
        func load() -> ShelfSettings { value }
        func save(_ settings: ShelfSettings) throws { value = settings }
    }
    private final class Marker: VisibilityRecoveryStore {
        var requiresRecovery = false
        func markActive() { requiresRecovery = true }
        func clear() { requiresRecovery = false }
    }

    func testPermissionLossRestoresVisibilityWithoutErasingUserPreferences() {
        var trusted = true
        let store = Store()
        let marker = Marker()
        let model = SettingsModel(store: store, recovery: marker, iconAvailability: { _ in true }, accessibilityTrusted: { trusted })
        model.setMenuBarItems([.init(id: UUID(), pid: 1, bundleID: "org.example.Tool", label: "Tool")])
        marker.markActive()
        var restored = false
        model.onHiddenItems = { restored = $0.isEmpty }
        trusted = false
        XCTAssertFalse(model.requireAccessibility())
        XCTAssertTrue(restored)
        XCTAssertFalse(marker.requiresRecovery)
        XCTAssertEqual(model.inventoryState, .permissionRequired)
        XCTAssertTrue(model.menuBarItems.isEmpty)
        XCTAssertTrue(model.hiddenCandidates.isEmpty)
        XCTAssertFalse(model.visibilityBusy)
        XCTAssertTrue(model.visibilityNeedsExplicitRetry)
        XCTAssertEqual(model.settings.hiddenBundleIDs, ["org.example.Tool"])
        XCTAssertEqual(model.pendingHiddenBundleIDs, ["org.example.Tool"])
        trusted = true
        XCTAssertTrue(model.requireAccessibility())
        XCTAssertTrue(model.visibilityNeedsExplicitRetry)
        let message = model.visibilityMessage
        model.applyHiddenApplications(saveSelection: false)
        XCTAssertEqual(model.visibilityMessage, message)
        model.stop()
    }

    func testApplyingWithoutPermissionInvalidatesPreviouslyScannedItems() {
        let model = SettingsModel(store: Store(), iconAvailability: { _ in true }, accessibilityTrusted: { false })
        model.setMenuBarItems([.init(id: UUID(), pid: 1, bundleID: "org.example.Tool", label: "Tool")])
        model.applyHiddenApplications()
        XCTAssertEqual(model.inventoryState, .permissionRequired)
        XCTAssertTrue(model.menuBarItems.isEmpty)
        XCTAssertTrue(model.visibilityNeedsExplicitRetry)
        model.stop()
    }

    func testRecoveryMarkerSurvivesRecreatingStoreAndClearsExplicitly() throws {
        let suite = "NotchShelf.RecoveryTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        UserDefaultsVisibilityRecoveryStore(defaults: defaults).markActive()
        XCTAssertTrue(UserDefaultsVisibilityRecoveryStore(defaults: defaults).requiresRecovery)
        UserDefaultsVisibilityRecoveryStore(defaults: defaults).clear()
        XCTAssertFalse(UserDefaultsVisibilityRecoveryStore(defaults: defaults).requiresRecovery)
    }
}

@MainActor
final class LocalizationTests: XCTestCase {
    private func table(_ language: String) throws -> [String: String] {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
        let url = URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }
    func testBothLanguagesHaveCompleteMatchingKeysAndFormatArguments() throws {
        let ru = try table("ru"), en = try table("en")
        XCTAssertGreaterThan(ru.count, 120)
        XCTAssertEqual(Set(ru.keys), Set(en.keys))
        let format = try NSRegularExpression(pattern: "%(@|ld)")
        for key in ru.keys {
            let russian = try XCTUnwrap(ru[key]), english = try XCTUnwrap(en[key])
            XCTAssertFalse(english.isEmpty, key)
            func tokens(_ value: String) -> [String] {
                let string = value as NSString
                return format.matches(in: value, range: NSRange(location: 0, length: string.length)).map { string.substring(with: $0.range) }
            }
            XCTAssertEqual(tokens(russian), tokens(english), key)
        }
        XCTAssertEqual(en["Настройки…"], "Settings…")
        XCTAssertEqual(ru["Настройки…"], "Настройки…")
        XCTAssertEqual(en["Язык приложения"], "Application language")
    }
    func testFormattedTranslationKeepsUntrustedTextAsData() throws {
        let en = try table("en")
        let format = try XCTUnwrap(en["%@ — не найдено"])
        XCTAssertEqual(String(format: format, "app%@"), "app%@ — not found")
    }
}

@MainActor
final class MenuBarSectionModeTests: XCTestCase {
    private final class Store: SettingsStore {
        var value = ShelfSettings.defaults
        init() { value.menuBarSectionEnabled = true; value.hiddenBundleIDs = ["org.example.Shelf"]; value.menuBarSectionBundleIDs = ["org.example.Row"] }
        func load() -> ShelfSettings { value }
        func save(_ settings: ShelfSettings) throws { value = settings }
    }
    private final class Service: NativeVisibilityService {
        var allowed: [String] = []
        var restoreCount = 0
        var completion: (@Sendable (String?) -> Void)?
        func hide(withAllowedBundleIDs bundleIDs: [String], completion: @escaping @Sendable (String?) -> Void) {
            allowed = bundleIDs
            self.completion = completion
        }
        func restore() { restoreCount += 1 }
    }
    func testCollapseAndExpandKeepShelfHiddenAndReturnOriginalRowIcons() async {
        let service = Service(), store = Store()
        let own = Bundle.main.bundleIdentifier!
        let processes = [MenuBarScanner.Process(pid: 1, bundleID: "org.example.Shelf", name: "Shelf"),
                         .init(pid: 2, bundleID: "org.example.Row", name: "Row"),
                         .init(pid: 3, bundleID: "com.apple.controlcenter", name: "System"),
                         .init(pid: 4, bundleID: own, name: "Notch Shelf")]
        let model = SettingsModel(store: store, iconAvailability: { $0.bundleID == "org.example.Shelf" },
            accessibilityTrusted: { true }, nativeVisibility: service, installedApplication: { true }, runningProcesses: { processes })
        model.setMenuBarItems(processes.map { .init(id: UUID(), pid: $0.pid, bundleID: $0.bundleID, label: $0.name) })
        let collapsed = expectation(description: "Both groups hidden")
        model.onHiddenItems = { items in
            if model.menuBarSectionCollapsed && items.map(\.bundleID) == ["org.example.Shelf"] { collapsed.fulfill() }
        }
        model.applyHiddenApplications(saveSelection: false, sectionCollapsed: true)
        XCTAssertFalse(service.allowed.contains("org.example.Row"))
        XCTAssertFalse(service.allowed.contains("org.example.Shelf"))
        XCTAssertTrue(service.allowed.contains(own))
        XCTAssertTrue(service.allowed.contains("com.apple.controlcenter"))
        service.completion?(nil)
        await fulfillment(of: [collapsed], timeout: 2)
        XCTAssertTrue(model.menuBarSectionCollapsed)
        XCTAssertFalse(model.iconAvailableBundleIDs.contains("org.example.Row"))
        let rescanned = expectation(description: "Row collapse survives inventory refresh")
        model.onHiddenItems = { items in
            if model.menuBarSectionCollapsed && items.map(\.bundleID) == ["org.example.Shelf"] { rescanned.fulfill() }
        }
        model.setMenuBarItems(processes.map { .init(id: UUID(), pid: $0.pid, bundleID: $0.bundleID, label: $0.name) })
        model.applyHiddenApplications(saveSelection: false)
        XCTAssertFalse(service.allowed.contains("org.example.Row"))
        service.completion?(nil)
        await fulfillment(of: [rescanned], timeout: 2)
        let expanded = expectation(description: "Only shelf remains hidden")
        model.onHiddenItems = { items in
            if !model.menuBarSectionCollapsed && items.map(\.bundleID) == ["org.example.Shelf"] { expanded.fulfill() }
        }
        model.applyHiddenApplications(saveSelection: false, sectionCollapsed: false)
        XCTAssertTrue(service.allowed.contains("org.example.Row"))
        XCTAssertFalse(service.allowed.contains("org.example.Shelf"))
        service.completion?(nil)
        await fulfillment(of: [expanded], timeout: 2)
        XCTAssertEqual(store.value.hiddenBundleIDs, ["org.example.Shelf"])
        model.revealAll()
        XCTAssertFalse(model.menuBarSectionCollapsed)
        XCTAssertTrue(model.hiddenCandidates.isEmpty)
        XCTAssertTrue(store.value.hiddenBundleIDs.isEmpty)
        model.onHiddenItems = nil
        model.stop()
    }
    func testFailureRestoresBothGroupsAndPausesAutomaticRetry() async {
        let service = Service(), store = Store()
        let processes = [MenuBarScanner.Process(pid: 1, bundleID: "org.example.Shelf", name: "Shelf"), .init(pid: 2, bundleID: "org.example.Row", name: "Row")]
        let model = SettingsModel(store: store, iconAvailability: { _ in true }, accessibilityTrusted: { true }, nativeVisibility: service,
            installedApplication: { true }, runningProcesses: { processes })
        model.setMenuBarItems(processes.map { .init(id: UUID(), pid: $0.pid, bundleID: $0.bundleID, label: $0.name) })
        model.applyHiddenApplications(saveSelection: false, sectionCollapsed: true)
        let finished = expectation(description: "Failure handled")
        let observer = model.$visibilityNeedsExplicitRetry.dropFirst().sink { value in if value { finished.fulfill() } }
        service.completion?("Test failure")
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(model.menuBarSectionCollapsed)
        XCTAssertTrue(model.hiddenCandidates.isEmpty)
        XCTAssertFalse(model.visibilityBusy)
        XCTAssertGreaterThan(service.restoreCount, 0)
        observer.cancel()
        model.stop()
    }
    func testRowModeWorksWithoutShelfOrResourceImagesAndRejectsLateCompletion() async {
        let service = Service(), store = Store()
        store.value.hiddenBundleIDs = []
        let processes = [MenuBarScanner.Process(pid: 2, bundleID: "org.example.Row", name: "Row")]
        let model = SettingsModel(store: store, iconAvailability: { _ in false }, accessibilityTrusted: { true }, nativeVisibility: service,
            installedApplication: { true }, runningProcesses: { processes })
        model.setMenuBarItems(processes.map { .init(id: UUID(), pid: $0.pid, bundleID: $0.bundleID, label: $0.name) })
        let collapsed = expectation(description: "Original row icons hidden without copied images")
        model.onHiddenItems = { _ in if model.menuBarSectionCollapsed { collapsed.fulfill() } }
        model.applyHiddenApplications(saveSelection: false, sectionCollapsed: true)
        XCTAssertNotNil(service.completion)
        XCTAssertFalse(service.allowed.contains("org.example.Row"))
        service.completion?(nil)
        await fulfillment(of: [collapsed], timeout: 2)
        XCTAssertTrue(model.hiddenCandidates.isEmpty)
        model.applyHiddenApplications(saveSelection: false, sectionCollapsed: true)
        let late = service.completion
        model.revealAll()
        let mustNotRehide = expectation(description: "Cancelled completion cannot hide again")
        mustNotRehide.isInverted = true
        model.onHiddenItems = { _ in if model.menuBarSectionCollapsed { mustNotRehide.fulfill() } }
        late?(nil)
        await fulfillment(of: [mustNotRehide], timeout: 0.1)
        XCTAssertFalse(model.menuBarSectionCollapsed)
        model.onHiddenItems = nil
        model.stop()
    }

    func testOldSettingsKeepRowModeOffAndNewSettingsRoundTrip() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ShelfSettings.defaults)) as? [String: Any])
        json.removeValue(forKey: "menuBarSectionEnabled")
        let old = try JSONDecoder().decode(ShelfSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.menuBarSectionEnabled)
        var new = old
        new.menuBarSectionEnabled = true
        new.hiddenBundleIDs = ["org.example.Shelf"]
        XCTAssertEqual(try JSONDecoder().decode(ShelfSettings.self, from: JSONEncoder().encode(new)), new)
    }
}

final class CommandDragPolicyTests: XCTestCase {
    private let anchor = CGRect(x: 500, y: 950, width: 32, height: 24)
    func testMovingAcrossManagerAssignsAndRemovesMembership() {
        let before = CGRect(x: 600, y: 950, width: 20, height: 24)
        let after = CGRect(x: 400, y: 950, width: 20, height: 24)
        XCTAssertEqual(MenuBarDragPolicy.membership(source: CGPoint(x: 610, y: 960), before: before, after: after, anchor: anchor), true)
        XCTAssertEqual(MenuBarDragPolicy.membership(source: CGPoint(x: 410, y: 960), before: after, after: before, anchor: anchor), false)
    }
    func testClicksUnrelatedItemsAndOffBarDropsDoNotChangeMembership() {
        let frame = CGRect(x: 400, y: 950, width: 20, height: 24)
        XCTAssertNil(MenuBarDragPolicy.membership(source: CGPoint(x: 410, y: 960), before: frame, after: frame, anchor: anchor))
        XCTAssertNil(MenuBarDragPolicy.membership(source: CGPoint(x: 100, y: 960), before: frame, after: frame.offsetBy(dx: 200, dy: 0), anchor: anchor))
        XCTAssertNil(MenuBarDragPolicy.membership(source: CGPoint(x: 410, y: 960), before: frame, after: frame.offsetBy(dx: 0, dy: -100), anchor: anchor))
        XCTAssertNil(MenuBarDragPolicy.membership(source: CGPoint(x: 410, y: 960), before: frame, after: CGRect(x: 510, y: 950, width: 10, height: 24), anchor: anchor))
    }
}

@MainActor
final class ExplicitRowMembershipTests: XCTestCase {
    private final class Store: SettingsStore {
        var value = ShelfSettings.defaults
        init() { value.menuBarSectionEnabled = true }
        func load() -> ShelfSettings { value }
        func save(_ settings: ShelfSettings) throws { value = settings }
    }
    func testOnlyExplicitMembersJoinTheGroupAndRevealAllClearsThem() {
        let model = SettingsModel(store: Store(), iconAvailability: { _ in true })
        let items = [MenuBarScanner.Candidate(id: UUID(), pid: 1, bundleID: "org.example.One", label: "One"),
                     .init(id: UUID(), pid: 2, bundleID: "org.example.Two", label: "Two")]
        model.setMenuBarItems(items)
        XCTAssertTrue(model.availableSectionBundleIDs.isEmpty)
        XCTAssertTrue(model.setSectionMembership(bundleID: items[0].bundleID, hidden: true))
        XCTAssertEqual(model.availableSectionBundleIDs, [items[0].bundleID])
        XCTAssertFalse(model.setSectionMembership(bundleID: "com.apple.controlcenter", hidden: true))
        XCTAssertTrue(model.setSectionMembership(bundleID: items[0].bundleID, hidden: false))
        XCTAssertTrue(model.availableSectionBundleIDs.isEmpty)
        XCTAssertTrue(model.setSectionMembership(bundleID: items[1].bundleID, hidden: true))
        model.revealAll()
        XCTAssertTrue(model.settings.menuBarSectionBundleIDs.isEmpty)
        model.stop()
    }
    func testOldEnabledModeDoesNotImplicitlySelectAllApplications() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ShelfSettings.defaults)) as? [String: Any])
        json["menuBarSectionEnabled"] = true
        json.removeValue(forKey: "menuBarSectionBundleIDs")
        let settings = try JSONDecoder().decode(ShelfSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(settings.menuBarSectionEnabled)
        XCTAssertTrue(settings.menuBarSectionBundleIDs.isEmpty)
        var invalid = settings
        invalid.menuBarSectionBundleIDs = ["org.example.One", "org.example.One"]
        XCTAssertFalse(invalid.isValid)
    }
}
