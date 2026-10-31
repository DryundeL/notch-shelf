import XCTest
import ApplicationServices
@testable import NotchShelf

final class MenuBarReportTests: XCTestCase {
    func testUnknownSelectionCannotActivateAnItem() async {
        let scanner = MenuBarScanner()
        let result = await scanner.press(UUID())
        XCTAssertEqual(result, "Элемент устарел. Повторите сканирование.")
        let candidates = await scanner.availableCandidates()
        XCTAssertTrue(candidates.isEmpty)
    }

    func testUntrustedTextCannotInsertReportLines() {
        XCTAssertEqual(MenuBarScanner.safe("Name\n\t\r\u{0}Injected"), "NameInjected")
        XCTAssertEqual(MenuBarScanner.safe(String(repeating: "я", count: 200)).count, 128)
    }

    func testStatusesDistinguishMissingValueFromFailure() {
        XCTAssertEqual(MenuBarScanner.status(.noValue), "значение отсутствует [-25212]")
        XCTAssertEqual(MenuBarScanner.status(.cannotComplete), "запрос не завершён [-25204]")
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
