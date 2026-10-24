import AppKit

/// Собственный status item; управление чужими значками сюда не входит.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "NS"
        statusItem.button?.setAccessibilityLabel("Notch Shelf")

        let menu = NSMenu(title: "Notch Shelf")
        let quitItem = NSMenuItem(
            title: "Выйти из Notch Shelf",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func stop() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
