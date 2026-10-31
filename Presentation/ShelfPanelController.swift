import AppKit

@MainActor
final class ShelfPanelController: NSObject, NSWindowDelegate {
    var onSettings: (() -> Void)?
    private let displays = ScreenDisplayProvider()
    private var panel: NSPanel?
    private var state = ShelfState()
    private var transitionID = UUID()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private weak var anchorButton: NSStatusBarButton?
    private var dismissArmed = false
    private var dismissGeneration = 0

    override init() {
        super.init()
        displays.onChange = { [weak self] _ in self?.screenChanged() }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenChanged), name: name, object: nil)
        }
    }

    func toggle(from button: NSStatusBarButton, settings: ShelfSettings) {
        if state.phase == .open || state.phase == .opening { close(); return }
        displays.refresh()
        guard let screen = DisplayPolicy.target(in: displays.snapshots,
            sourceID: ScreenDisplayProvider.runtimeID(of: button.window?.screen),
            pointer: NSEvent.mouseLocation, mainID: ScreenDisplayProvider.runtimeID(of: NSScreen.main)) else { return }
        let mode = DisplayProfilePolicy.mode(for: screen, among: displays.snapshots, settings: settings)
        if mode == .minimal { close(); onSettings?(); return }
        let source = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        guard let placement = ShelfGeometry.placement(visibleFrame: screen.visibleFrame, screenFrame: screen.frame,
            hasNotch: (mode == .automatic || mode == .notch) && screen.hasNotch,
            sourceX: source.midX) else { return }
        transitionID = UUID()
        let currentTransition = transitionID
        state.requestOpen()
        let window = panel ?? makePanel()
        panel = window
        anchorButton = button
        dismissArmed = false
        window.setFrame(placement.frame, display: false)
        let duration = ShelfAnimationPolicy.duration(settings: settings,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        window.alphaValue = duration > 0 ? 0 : 1
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if duration > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                window.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.transitionID == currentTransition else { return }
                    self.state.finishOpening()
                }
            }
        } else {
            state.finishOpening()
        }
        installMonitors()
        // Текущий mouseDown не должен считаться кликом снаружи.
        dismissGeneration += 1
        let generation = dismissGeneration
        Task { @MainActor [weak self] in
            guard let self, self.dismissGeneration == generation else { return }
            self.dismissArmed = true
        }
    }

    private func makePanel() -> NSPanel {
        let window = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Notch Shelf"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.delegate = self
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        window.contentView = background
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        background.addSubview(scroll)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 145))
        let title = NSTextField(labelWithString: "Notch Shelf")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.frame = NSRect(x: 12, y: 105, width: 290, height: 28)
        let message = NSTextField(wrappingLabelWithString: "Ваше пространство в строке меню.\nДиагностика и управление доступны в настройках.")
        message.textColor = .secondaryLabelColor
        message.frame = NSRect(x: 12, y: 46, width: 290, height: 50)
        content.addSubview(title)
        content.addSubview(message)
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Открыть настройки") ?? NSImage(),
                                target: self, action: #selector(openSettings))
        settings.bezelStyle = .recessed
        settings.toolTip = "Настройки Notch Shelf"
        settings.frame = NSRect(x: 230, y: 6, width: 34, height: 32)
        content.addSubview(settings)
        let quit = NSButton(image: NSImage(systemSymbolName: "power", accessibilityDescription: "Выйти из Notch Shelf") ?? NSImage(),
                            target: NSApplication.shared, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .recessed
        quit.toolTip = "Выйти из Notch Shelf"
        quit.frame = NSRect(x: 274, y: 6, width: 34, height: 32)
        content.addSubview(quit)
        scroll.documentView = content
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12)
        ])
        return window
    }

    @objc private func openSettings() { onSettings?() }

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }
                return event
            }
            if event.window === self.panel { return event }
            if self.outsideClickShouldClose() { self.close() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.outsideClickShouldClose() else { return }
            self.close()
        }
    }

    private func outsideClickShouldClose() -> Bool {
        ShelfDismiss.shouldClose(armed: dismissArmed, pointerOnStatusButton: pointerIsOnAnchorButton())
    }

    private func pointerIsOnAnchorButton() -> Bool {
        guard let button = anchorButton, let window = button.window else { return false }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return rect.contains(NSEvent.mouseLocation)
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    func close() {
        transitionID = UUID()
        state.requestClose()
        panel?.orderOut(nil)
        // Перебить незавершённый fade без ожидания и очереди переходов.
        if let panel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
        }
        removeMonitors()
        anchorButton = nil
        dismissArmed = false
        dismissGeneration += 1
        state.finishClosing()
    }

    func windowDidResignKey(_ notification: Notification) {
        if outsideClickShouldClose() { close() }
    }
    @objc private func screenChanged() { close(); state.cancel() }

    func stop() {
        close()
        displays.stop()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        panel?.delegate = nil
        panel = nil
    }
}
