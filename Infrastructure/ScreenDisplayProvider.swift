import AppKit
import CoreGraphics

@MainActor
final class ScreenDisplayProvider: NSObject, DisplayProvider {
    private(set) var snapshots: [DisplaySnapshot] = []
    private var observers: [UUID: ([DisplaySnapshot]) -> Void] = [:]
    private var pending: Task<Void, Never>?

    override init() {
        super.init()
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleRefresh),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    static func runtimeID(of screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    @objc private func scheduleRefresh() {
        guard pending == nil else { return }
        // Один короткий отложенный проход на серию событий, не idle polling.
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.refresh()
        }
    }

    func refresh() {
        let next = NSScreen.screens.compactMap { screen -> DisplaySnapshot? in
            guard let id = Self.runtimeID(of: screen) else { return nil }
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            let key = uuid.map { CFUUIDCreateString(nil, $0) as String }
            return DisplaySnapshot(profileKey: key, name: screen.localizedName, runtimeID: id, frame: screen.frame, visibleFrame: screen.visibleFrame,
                scale: screen.backingScaleFactor,
                hasNotch: screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil)
        }.sorted { $0.runtimeID < $1.runtimeID }
        guard next != snapshots else { return }
        snapshots = next
        // Copy first: a handler may unsubscribe while being notified.
        for handler in Array(observers.values) { handler(next) }
    }

    func addObserver(_ handler: @escaping ([DisplaySnapshot]) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) { observers[token] = nil }

    func stop() {
        pending?.cancel()
        pending = nil
        observers.removeAll()
        NotificationCenter.default.removeObserver(self)
    }
}
