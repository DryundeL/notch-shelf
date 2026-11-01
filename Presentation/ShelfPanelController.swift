import AppKit
import QuartzCore

@MainActor
final class ShelfPanelController: NSObject, NSWindowDelegate {
    var onSettings: (() -> Void)?
    private let displays: any DisplayProvider
    private let applicationNotifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private(set) var isHoverSuspended = false
    private var panel: NSPanel?
    private var state = ShelfState()
    private var transitionID = UUID()
    private var collapsedFrame: CGRect?
    private var expandedHoverFrame: CGRect?
    private var contentTopInset: CGFloat = 36
    private var bodyWidth: CGFloat = 180
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private weak var anchorButton: NSStatusBarButton?
    private var dismissArmed = false
    private var dismissGeneration = 0
    private var hoverWindows: [NSPanel] = []
    private var hoverSettings: (() -> ShelfSettings)?
    private var hoverCloseTask: Task<Void, Never>?
    private var openedByHover = false
    private var contextMenuActive = false
    private var pendingContextMenu: (entries: [MenuBarScanner.MenuEntry], id: UUID, perform: (UUID) -> Void)?
    private var activationTimeout: Task<Void, Never>?

    func cancelContextMenuRequest(_ message: String) {
        pendingContextMenu = nil
        activationTimeout?.cancel()
        contextMenuActive = false
        showActionStatus(message)
        scheduleHoverClose()
    }

    @objc private func applicationActivated() {
        guard let pending = pendingContextMenu else { return }
        pendingContextMenu = nil
        activationTimeout?.cancel()
        showContextMenu(pending.entries, for: pending.id, perform: pending.perform)
    }
    private var contextAction: ((UUID) -> Void)?
    private weak var actionStatusLabel: NSTextField?

    func showActionStatus(_ message: String) {
        actionStatusLabel?.stringValue = message
        actionStatusLabel?.toolTip = message
    }
    private let resourceIcons = MenuBarResourceIconProvider()

    func configureHover(settings: @escaping () -> ShelfSettings) {
        hoverSettings = settings
        rebuildHoverWindows()
    }

    private func rebuildHoverWindows() {
        hoverCloseTask?.cancel()
        hoverWindows.forEach { $0.orderOut(nil) }
        hoverWindows.removeAll()
        guard !isHoverSuspended, !items.isEmpty, let settings = hoverSettings?() else { return }
        for screen in NSScreen.screens {
            guard let id = ScreenDisplayProvider.runtimeID(of: screen),
                  let snapshot = displays.snapshots.first(where: { $0.runtimeID == id }),
                  DisplayProfilePolicy.mode(for: snapshot, among: displays.snapshots, settings: settings) != .minimal else { continue }
            let hasNotch = snapshot.hasNotch
            let left = screen.auxiliaryTopLeftArea?.maxX
            let right = screen.auxiliaryTopRightArea?.minX
            guard let frame = HoverGeometry.trigger(screen: screen.frame, safeTop: hasNotch ? screen.safeAreaInsets.top : 0,
                notchLeft: left, notchRight: right) else { continue }
            let trigger = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            trigger.isOpaque = false
            trigger.backgroundColor = .clear
            trigger.hasShadow = false
            trigger.hidesOnDeactivate = false
            trigger.level = .statusBar
            trigger.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = ShelfHoverView(frame: CGRect(origin: .zero, size: frame.size))
            view.virtualNotch = !hasNotch
            view.toolTip = L("Notch Shelf — наведите для открытия")
            view.setAccessibilityLabel(L("Открыть Notch Shelf"))
            view.onEnter = { [weak self] in
                guard let self, !self.isHoverSuspended, let settings = self.hoverSettings?(), !self.items.isEmpty else { return }
                self.hoverCloseTask?.cancel()
                if self.panel?.isVisible == true && self.panel?.screen == screen && self.state.phase != .closing { return }
                self.close(animated: false)
                self.present(on: snapshot, sourceX: snapshot.frame.midX, anchor: nil, settings: settings, hover: true)
            }
            view.onExit = { [weak self] in self?.scheduleHoverClose() }
            trigger.contentView = view
            trigger.orderFrontRegardless()
            hoverWindows.append(trigger)
        }
    }

    private func scheduleHoverClose() {
        guard openedByHover, !contextMenuActive else { return }
        hoverCloseTask?.cancel()
        hoverCloseTask = Task { @MainActor [weak self] in
            // Let the adjacent tracking area receive mouseEntered before checking.
            await Task.yield()
            guard !Task.isCancelled, let self, self.openedByHover, !self.contextMenuActive else { return }
            let pointer = NSEvent.mouseLocation
            if self.state.phase == .opening, self.expandedHoverFrame?.contains(pointer) == true { return }
            if let window = self.panel, let background = window.contentView as? ShelfHoverEffectView {
                let local = background.convert(window.convertPoint(fromScreen: pointer), from: nil)
                if background.containsShelfPoint(local) { return }
            }
            if self.hoverWindows.contains(where: { $0.frame.contains(pointer) }) { return }
            self.close()
        }
    }
    private var items: [MenuBarScanner.Candidate] = []
    private var activateItem: ((UUID) -> Void)?
    private weak var itemsDocument: NSView?
    private weak var itemsScroll: NSScrollView?

    func setItems(_ candidates: [MenuBarScanner.Candidate], activate: @escaping (UUID) -> Void) {
        contextMenuActive = false
        resourceIcons.invalidate()
        items = candidates
        activateItem = activate
        updateItemButtons()
        rebuildHoverWindows()
    }

    private func updateItemButtons() {
        itemsScroll?.isHidden = items.isEmpty
        guard let document = itemsDocument else { return }
        document.subviews.forEach { $0.removeFromSuperview() }
        let width = max(44, itemsScroll?.contentSize.width ?? 388)
        let frames = BubbleIconGrid.frames(itemCount: items.count, width: width)
        let height = max(44, (frames.map(\.maxY).max() ?? 42) + 2)
        document.setFrameSize(NSSize(width: width, height: height))
        for (index, item) in items.enumerated() {
            let button = ShelfItemButton(title: "", target: self, action: #selector(activateShelfItem(_:)))
            guard frames.indices.contains(index) else { continue }
            button.frame = frames[index]
            button.tag = index
            button.title = String((NSRunningApplication(processIdentifier: item.pid)?.localizedName ?? item.bundleID).prefix(4))
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 10, weight: .medium)])
            button.contentTintColor = .white
            if let url = NSRunningApplication(processIdentifier: item.pid)?.bundleURL,
               let image = resourceIcons.image(bundleID: item.bundleID, bundleURL: url) {
                button.image = image
                button.imageScaling = .scaleProportionallyDown
                button.imagePosition = .imageOnly
            } else { button.imagePosition = .noImage }
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.toolTip = item.label
            button.setAccessibilityLabel(item.label)
            document.addSubview(button)
        }
        let visibleHeight = itemsScroll?.contentSize.height ?? height
        document.scroll(NSPoint(x: 0, y: max(0, height - visibleHeight)))
    }

    @objc private func activateShelfItem(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        hoverCloseTask?.cancel()
        contextMenuActive = true
        showActionStatus(L("Открываем меню…"))
        NSApplication.shared.activate(ignoringOtherApps: true)
        activateItem?(items[sender.tag].id)
    }

    func showContextMenu(_ entries: [MenuBarScanner.MenuEntry], for id: UUID, perform: @escaping (UUID) -> Void) {
        guard panel?.isVisible == true else { cancelContextMenuRequest(""); return }
        if !NSApplication.shared.isActive {
            pendingContextMenu = (entries, id, perform)
            activationTimeout?.cancel()
            activationTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.cancelContextMenuRequest(L("macOS не активировала окно для показа меню."))
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        defer { contextMenuActive = false; scheduleHoverClose() }
        guard panel?.isVisible == true, let index = items.firstIndex(where: { $0.id == id }),
              let button = itemsDocument?.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.tag == index }) else { return }
        contextAction = perform
        showActionStatus("")
        defer { contextAction = nil }
        let menu = makeContextMenu(entries)
        if menu.items.isEmpty {
            let message = NSMenuItem(title: L("Приложение не предоставляет меню для шторки"), action: nil, keyEquivalent: "")
            message.isEnabled = false
            menu.addItem(message)
        }
        let cell = Self.makeDropDownCell(menu: menu)
        cell.performClick(withFrame: button.bounds, in: button)
    }

    static func makeDropDownCell(menu: NSMenu) -> NSPopUpButtonCell {
        let cell = NSPopUpButtonCell(textCell: "", pullsDown: true)
        cell.preferredEdge = .minY
        cell.arrowPosition = .noArrow
        cell.isBordered = false
        // A pull-down reserves its first item for the closed control's title.
        menu.insertItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""), at: 0)
        cell.menu = menu
        cell.altersStateOfSelectedItem = false
        return cell
    }

    func makeContextMenu(_ entries: [MenuBarScanner.MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            if entry.separator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.title, action: entry.actionID == nil ? nil : #selector(performContextAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.actionID?.uuidString
            item.isEnabled = entry.enabled
            item.state = entry.checked ? .on : .off
            if !entry.children.isEmpty { item.submenu = makeContextMenu(entry.children) }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performContextAction(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        contextAction?(id)
    }

    override convenience init() {
        self.init(displays: ScreenDisplayProvider())
    }

    init(displays: any DisplayProvider, applicationNotifications: NotificationCenter = .default,
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.displays = displays
        self.applicationNotifications = applicationNotifications
        self.workspaceNotifications = workspaceNotifications
        super.init()
        applicationNotifications.addObserver(self, selector: #selector(applicationActivated), name: NSApplication.didBecomeActiveNotification, object: nil)
        displays.onChange = { [weak self] _ in self?.screenChanged() }
        workspaceNotifications.addObserver(self, selector: #selector(screenChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func toggle(from button: NSStatusBarButton, settings: ShelfSettings) {
        if state.phase == .open || state.phase == .opening { close(); return }
        displays.refresh()
        guard let screen = DisplayPolicy.target(in: displays.snapshots,
            sourceID: ScreenDisplayProvider.runtimeID(of: button.window?.screen),
            pointer: NSEvent.mouseLocation, mainID: ScreenDisplayProvider.runtimeID(of: NSScreen.main)) else { return }
        let source = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        present(on: screen, sourceX: source.midX, anchor: button, settings: settings, hover: false)
    }

    private func present(on screen: DisplaySnapshot, sourceX: CGFloat, anchor: NSStatusBarButton?, settings: ShelfSettings, hover: Bool) {
        guard !isHoverSuspended else { return }
        resourceIcons.invalidate()
        let mode = DisplayProfilePolicy.mode(for: screen, among: displays.snapshots, settings: settings)
        if mode == .minimal { if !hover { onSettings?() }; return }
        guard let nativeScreen = NSScreen.screens.first(where: { ScreenDisplayProvider.runtimeID(of: $0) == screen.runtimeID }) else { return }
        let cutout: CGRect?
        if screen.hasNotch, let left = nativeScreen.auxiliaryTopLeftArea?.maxX, let right = nativeScreen.auxiliaryTopRightArea?.minX {
            cutout = CGRect(x: left, y: screen.frame.maxY - nativeScreen.safeAreaInsets.top,
                            width: right - left, height: nativeScreen.safeAreaInsets.top)
        } else { cutout = nil }
        let menuBarHeight = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
        guard let layout = NotchShelfGeometry.layout(screen: screen.frame, cutout: cutout, itemCount: items.count, menuBarHeight: menuBarHeight) else { return }
        openedByHover = hover
        transitionID = UUID()
        let currentTransition = transitionID
        state.cancel()
        state.requestOpen()
        collapsedFrame = layout.collapsed
        expandedHoverFrame = layout.expanded
        contentTopInset = layout.contentTopInset
        bodyWidth = layout.body.width
        let window = panel ?? makePanel()
        panel = window
        if let background = window.contentView as? ShelfHoverEffectView {
            background.neckWidth = layout.neckWidth
            background.neckHeight = layout.neckHeight
            background.bodyWidth = layout.body.width
            background.bodyHeight = layout.body.height
        }
        anchorButton = anchor
        dismissArmed = false
        let duration = ShelfAnimationPolicy.duration(settings: settings,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        window.setFrame(duration > 0 ? layout.collapsed : layout.expanded, display: false)
        window.alphaValue = 1
        if hover { window.orderFrontRegardless() } else { window.makeKeyAndOrderFront(nil) }
        if !hover { NSApplication.shared.activate(ignoringOtherApps: true) }
        layoutPanelContent(size: layout.expanded.size)
        if duration > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(layout.expanded, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.transitionID == currentTransition else { return }
                    self.layoutPanelContent(size: layout.expanded.size)
                    self.state.finishOpening()
                    self.scheduleHoverClose()
                }
            }
        } else { state.finishOpening() }
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
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Notch Shelf"
        window.isReleasedWhenClosed = false
        window.becomesKeyOnlyIfNeeded = true
        window.isFloatingPanel = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.hidesOnDeactivate = false
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        let background = ShelfHoverEffectView()
        background.onEnter = { [weak self] in self?.hoverCloseTask?.cancel() }
        background.onExit = { [weak self] in self?.scheduleHoverClose() }
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.cgColor
        background.layer?.masksToBounds = true
        window.contentView = background
        let itemScroll = NSScrollView()
        itemScroll.drawsBackground = false
        itemScroll.hasVerticalScroller = true
        itemScroll.autohidesScrollers = true
        itemScroll.scrollerStyle = .overlay
        let document = NSView()
        itemScroll.documentView = document
        background.addSubview(itemScroll)
        itemsScroll = itemScroll
        itemsDocument = document
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 10)
        status.textColor = .white.withAlphaComponent(0.7)
        status.lineBreakMode = .byTruncatingTail
        background.addSubview(status)
        actionStatusLabel = status
        return window
    }

    private func layoutPanelContent(size: CGSize) {
        itemsScroll?.frame = CGRect(x: (size.width - bodyWidth) / 2 + 16, y: 16, width: max(44, bodyWidth - 32), height: max(44, size.height - contentTopInset - 16))
        actionStatusLabel?.frame = CGRect(x: (size.width - bodyWidth) / 2 + 16, y: 0, width: max(44, bodyWidth - 32), height: 16)
        updateItemButtons()
    }

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if self.contextMenuActive { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }
                return event
            }
            if event.window === self.panel { return event }
            if self.outsideClickShouldClose() { self.close() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, !self.contextMenuActive else { return }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close() }
                return
            }
            if self.outsideClickShouldClose() { self.close() }
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

    func close(animated: Bool = true) {
        pendingContextMenu = nil
        activationTimeout?.cancel()
        activationTimeout = nil
        hoverCloseTask?.cancel()
        hoverCloseTask = nil
        openedByHover = false
        expandedHoverFrame = nil
        contextMenuActive = false
        transitionID = UUID()
        let closingTransition = transitionID
        state.requestClose()
        removeMonitors()
        anchorButton = nil
        dismissArmed = false
        dismissGeneration += 1
        let settings = hoverSettings?() ?? .defaults
        let duration = animated ? min(0.18, ShelfAnimationPolicy.duration(settings: settings,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) : 0
        if duration > 0, let window = panel, window.isVisible, let collapsedFrame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().setFrame(collapsedFrame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.transitionID == closingTransition else { return }
                    self.panel?.orderOut(nil)
                    self.state.finishClosing()
                }
            }
        } else {
            panel?.orderOut(nil)
            state.finishClosing()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !contextMenuActive && outsideClickShouldClose() { close() }
    }
    @objc private func screenChanged() { close(animated: false); state.cancel(); rebuildHoverWindows() }

    @objc private func willSleep() {
        isHoverSuspended = true
        screenChanged()
    }

    @objc private func didWake() {
        guard isHoverSuspended else { return }
        isHoverSuspended = false
        let previous = displays.snapshots
        displays.refresh()
        // A changed snapshot already rebuilds through onChange.
        if displays.snapshots == previous { screenChanged() }
    }

    func stop() {
        close(animated: false)
        hoverWindows.forEach { $0.orderOut(nil) }
        hoverWindows.removeAll()
        hoverSettings = nil
        displays.stop()
        applicationNotifications.removeObserver(self)
        workspaceNotifications.removeObserver(self)
        panel?.delegate = nil
        panel = nil
    }
}


@MainActor
private final class ShelfHoverView: NSView {
    var virtualNotch = false
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseDown(with event: NSEvent) { onEnter?() }
    override func draw(_ dirtyRect: NSRect) {
        guard virtualNotch else { return }
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        NSColor.white.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 12, y: 5, width: 24, height: 2), xRadius: 1, yRadius: 1).fill()
    }
}

@MainActor
final class ShelfHoverEffectView: NSView {
    var neckWidth: CGFloat = 180 { didSet { updateShape() } }
    var neckHeight: CGFloat = 24 { didSet { updateShape() } }
    var bodyWidth: CGFloat = 180 { didSet { updateShape() } }
    var bodyHeight: CGFloat = 80 { didSet { updateShape() } }
    private var pointerInside = false

    func containsShelfPoint(_ point: NSPoint) -> Bool {
        (layer?.mask as? CAShapeLayer)?.path?.contains(point) == true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard containsShelfPoint(local) else { return nil }
        return super.hitTest(point)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateShape()
    }

    private func updateShape() {
        guard let layer else { return }
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        let progress = min(1, max(0, (bounds.height - neckHeight) / max(1, bodyHeight + 12)))
        let flowingWidth = neckWidth + (bodyWidth - neckWidth) * progress
        mask.path = ConnectedShelfShape.path(size: bounds.size, neckWidth: neckWidth, neckHeight: neckHeight, bodyWidth: flowingWidth)
        layer.mask = mask
        CATransaction.commit()
    }

    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    private func updatePointer(with event: NSEvent) {
        let inside = containsShelfPoint(convert(event.locationInWindow, from: nil))
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside { onEnter?() } else { onExit?() }
    }
    override func mouseEntered(with event: NSEvent) { updatePointer(with: event) }
    override func mouseMoved(with event: NSEvent) { updatePointer(with: event) }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        onExit?()
    }
}


@MainActor
final class ShelfItemButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}
