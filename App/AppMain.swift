import AppKit

/// Точка входа agent-приложения. Полная оркестрация появится в AppCoordinator (задача 13).
@main
@MainActor
final class AppMain: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppMain()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.stop()
        statusItemController = nil
    }
}
