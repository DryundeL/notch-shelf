import AppKit
import SwiftUI
@preconcurrency import ApplicationServices

/// Собственный status item и явно включаемый эксперимент секции.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate, NSMenuDelegate {
    private let settingsStore = UserDefaultsSettingsStore()
    private var settingsModel: SettingsModel?
    private let shelf = ShelfPanelController()
    private var settingsWindow: NSWindow?
    private let scanner = MenuBarScanner()
    private var candidates: [MenuBarScanner.Candidate] = []
    private var candidatePicker: NSPopUpButton?
    private var actionStatus: NSTextField?
    private var pressButton: NSButton?
    private var pressTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var reportWindow: NSWindow?
    private var latestReport = ""
    private let statusItem: NSStatusItem
    private var sectionMarkers: [NSStatusItem] = []
    private var sectionBoundary: NSStatusItem?
    private var sectionControl: NSStatusItem?
    private var sectionCollapsed = false
    private var applicationObservation: NSKeyValueObservation?
    private var inventoryRefreshTask: Task<Void, Never>?
    private var knownProcessIDs: Set<pid_t> = []
    private func applySelection(saveSelection: Bool = true) {
        guard let model = settingsModel, !model.visibilityBusy, scanTask == nil, pressTask == nil else { return }
        model.applyHiddenApplications(saveSelection: saveSelection)
    }

    @objc private func checkAccessibility() {
        guard settingsModel?.hiddenCandidates.isEmpty == false, !AXIsProcessTrusted() else { return }
        settingsModel?.restoreVisibility()
        settingsModel?.beginInventoryRefresh(permissionGranted: false)
    }

    private func scheduleInventoryRefresh() {
        guard inventoryRefreshTask == nil,
              settingsWindow?.isVisible == true || settingsModel?.settings.hiddenBundleIDs.isEmpty == false else { return }
        inventoryRefreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            self.inventoryRefreshTask = nil
            self.refreshMenuBarItems(showReport: false, requestPermission: false)
        }
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.title = ""
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.setAccessibilityLabel("Notch Shelf")

        shelf.onSettings = { [weak self] in self?.showSettings() }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "Приложения в шторке, настройки и выход"

        if ProcessInfo.processInfo.arguments.contains("--collapsible-section-poc") {
            let boundary = NSStatusBar.system.statusItem(withLength: 12)
            boundary.autosaveName = "NotchShelf.CollapseBoundary"
            boundary.button?.title = "│"
            boundary.button?.setAccessibilityLabel("Граница сворачиваемой секции")
            sectionBoundary = boundary
            sectionControl = statusItem
            statusItem.button?.toolTip = "Приложения в шторке, настройки и выход"
            sectionMarkers.append(boundary)
        }

        // Только явный запуск PoC; обычный запуск не создаёт разделители.
        if ProcessInfo.processInfo.arguments.contains("--section-markers-poc") {
            for title in ["│ A", "│ B"] {
                let marker = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                marker.autosaveName = "NotchShelf.SectionMarker.\(title)"
                marker.button?.title = title
                marker.button?.setAccessibilityLabel("Тестовый разделитель \(title)")
                sectionMarkers.append(marker)
            }
        }
        let model = ensureSettingsModel()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(checkAccessibility), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        knownProcessIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        applicationObservation = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let next = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
                guard next != self.knownProcessIDs else { return }
                self.knownProcessIDs = next
                self.scheduleInventoryRefresh()
            }
        }
        shelf.configureHover(settings: { [weak self] in self?.settingsStore.load() ?? .defaults })
        if !model.settings.hiddenBundleIDs.isEmpty {
            refreshMenuBarItems(showReport: false, requestPermission: false)
        }
    }

    private func revealSection() {
        sectionBoundary?.button?.title = "│"
        sectionBoundary?.length = 12
        sectionCollapsed = false
        sectionControl?.button?.toolTip = "Приложения в шторке, настройки и выход"
    }

    @objc private func toggleSection() {
        guard let boundary = sectionBoundary, let control = sectionControl else { return }
        if sectionCollapsed {
            boundary.button?.title = "│"
            boundary.length = 12
            sectionCollapsed = false
            control.button?.toolTip = "Приложения в шторке, настройки и выход"
            return
        }
        guard let boundaryWindow = boundary.button?.window,
              let controlWindow = control.button?.window,
              let screen = controlWindow.screen,
              boundaryWindow.screen == screen,
              boundaryWindow.frame.maxX <= controlWindow.frame.minX else {
            let alert = NSAlert()
            alert.messageText = "Расположите разделитель слева от NS"
            alert.informativeText = "Удерживая Command, переместите │ левее NS, а сворачиваемые значки — левее │. Затем нажмите NS."
            alert.runModal()
            return
        }
        guard let width = SectionWidthPolicy.collapsedWidth(screenWidths: NSScreen.screens.map { $0.frame.width }) else {
            revealSection()
            return
        }
        boundary.length = width
        sectionCollapsed = true
        control.button?.toolTip = "Приложения в шторке, настройки и выход"
    }

    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            // Верхний край с центральным вырезом; простая форма читается в 1x.
            let top = NSBezierPath(roundedRect: NSRect(x: 2, y: 10, width: 16, height: 6), xRadius: 2, yRadius: 2)
            top.fill()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: NSRect(x: 7, y: 13, width: 6, height: 5), xRadius: 1.5, yRadius: 1.5).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: 18, height: 4), xRadius: 2, yRadius: 2).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Notch Shelf"
        return image
    }

    static func makeStatusMenu(applicationNames: [String], settingsTarget: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let names = Array(Set(applicationNames)).sorted()
        let header = NSMenuItem(title: names.isEmpty ? "В шторке пока нет приложений" : "Приложения в шторке", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for name in names {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Настройки…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = settingsTarget
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Выйти из Notch Shelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        menu.addItem(quit)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        shelf.close()
        let names = (settingsModel?.hiddenCandidates ?? []).map {
            NSRunningApplication(processIdentifier: $0.pid)?.localizedName ?? $0.bundleID
        }
        let contents = Self.makeStatusMenu(applicationNames: names, settingsTarget: self)
        menu.removeAllItems()
        for item in contents.items { contents.removeItem(item); menu.addItem(item) }
    }

    private func ensureSettingsModel() -> SettingsModel {
        if let settingsModel { return settingsModel }
        let model = SettingsModel(store: settingsStore, recovery: UserDefaultsVisibilityRecoveryStore())
        model.setMenuBarItems(candidates)
        model.onHiddenItems = { [weak self] candidates in
            guard let self else { return }
            self.shelf.setItems(candidates) { [weak self] id in
                guard let self else { return }
                guard self.pressTask == nil,
                      let candidate = self.candidates.first(where: { $0.id == id }),
                      let app = NSRunningApplication(processIdentifier: candidate.pid),
                      !app.isTerminated, app.bundleIdentifier == candidate.bundleID else {
                    self.shelf.cancelContextMenuRequest("Приложение недоступно или предыдущая операция ещё выполняется.")
                    return
                }
                guard AXIsProcessTrusted() else {
                    self.settingsModel?.restoreVisibility()
                    self.settingsModel?.beginInventoryRefresh(permissionGranted: false)
                    self.showSettings()
                    return
                }
                self.pressTask = Task { [weak self] in
                    guard let self else { return }
                    let menu = await self.scanner.menuSnapshot(id)
                    self.pressTask = nil
                    self.shelf.showContextMenu(menu, for: id) { [weak self] actionID in
                        guard let self, self.pressTask == nil else { return }
                        self.pressTask = Task { [weak self] in
                            guard let self else { return }
                            let result = await self.scanner.performMenuAction(actionID)
                            self.settingsModel?.visibilityMessageForActivation(result)
                            self.shelf.showActionStatus(result)
                            self.pressTask = nil
                        }
                    }
                }
            }
        }
        model.onInventoryChanged = { [weak self] in self?.scheduleInventoryRefresh() }
        settingsModel = model
        return model
    }

    @objc func showSettings() {
        shelf.close()
        let application = NSApplication.shared
        let dockWarning = "macOS не удалось показать значок приложения в Dock."
        if settingsModel?.errorMessage == dockWarning { settingsModel?.errorMessage = nil }
        if application.activationPolicy() != .regular {
            let changed = application.setActivationPolicy(.regular)
            if !changed && application.activationPolicy() != .regular {
                settingsModel?.errorMessage = dockWarning
            }
        }
        if let settingsWindow {
            if settingsWindow.isMiniaturized { settingsWindow.deminiaturize(nil) }
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            if settingsModel?.visibilityBusy != true { refreshMenuBarItems(showReport: false, requestPermission: false) }
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Notch Shelf — Настройки"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let model = ensureSettingsModel()
        window.contentView = NSHostingView(rootView: SettingsView(model: model,
            scan: { [weak self] in self?.scanMenuBar() },
            showReport: { [weak self] in self?.reopenReport() },
            quit: { NSApplication.shared.terminate(nil) },
            applySelection: { [weak self] in self?.applySelection() },
            refreshInventory: { [weak self] in self?.refreshMenuBarItems(showReport: false, requestPermission: true) },
            revealSection: sectionBoundary == nil ? nil : { [weak self] in self?.revealSection() }))
        settingsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        refreshMenuBarItems(showReport: false, requestPermission: false)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        // Demote after AppKit has removed the closing settings window.
        Task { @MainActor [weak self] in
            guard let self, let settingsWindow = self.settingsWindow,
                  !settingsWindow.isVisible, !settingsWindow.isMiniaturized else { return }
            _ = NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    @objc private func scanMenuBar() {
        refreshMenuBarItems(showReport: true, requestPermission: true)
    }

    private func refreshMenuBarItems(showReport shouldShowReport: Bool, requestPermission: Bool) {
        guard scanTask == nil, pressTask == nil else { return }
        settingsModel?.restoreVisibility()
        let trusted = AXIsProcessTrusted()
        settingsModel?.beginInventoryRefresh(permissionGranted: trusted)
        guard trusted else {
            guard requestPermission else { return }
            let alert = NSAlert()
            alert.messageText = "Доступ к значкам menu bar"
            alert.informativeText = "Для чтения ролей и доступных действий нужен Accessibility. Содержимое меню и снимки не собираются. После выдачи доступа повторите сканирование."
            alert.addButton(withTitle: "Запросить доступ")
            alert.addButton(withTitle: "Отмена")
            if alert.runModal() == .alertFirstButtonReturn {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            return
        }
        let processes = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
            .map { MenuBarScanner.Process(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "pid:\($0.processIdentifier)", name: $0.localizedName ?? "Без названия") }
        pressButton?.isEnabled = false
        let scanner = self.scanner
        scanTask = Task { [weak self] in
            let report = await scanner.scan(processes)
            let candidates = await scanner.availableCandidates()
            guard !Task.isCancelled, let self else { return }
            self.scanTask = nil
            self.candidates = candidates
            self.settingsModel?.setMenuBarItems(candidates)
            if self.settingsModel?.settings.hiddenBundleIDs.isEmpty == false {
                self.applySelection(saveSelection: false)
            }
            if shouldShowReport { self.showReport(report) }
            else { self.latestReport = report }
        }
    }

    @objc private func pressSelectedItem() {
        guard scanTask == nil, pressTask == nil, let picker = candidatePicker,
              candidates.indices.contains(picker.indexOfSelectedItem) else { return }
        let candidate = candidates[picker.indexOfSelectedItem]
        guard let app = NSRunningApplication(processIdentifier: candidate.pid), !app.isTerminated,
              app.bundleIdentifier == candidate.bundleID else {
            actionStatus?.stringValue = "Процесс завершён или сменился. Повторите сканирование."
            return
        }
        pressButton?.isEnabled = false
        actionStatus?.stringValue = "Проверка…"
        // Убираем окно диагностики, чтобы оно не закрывало чужое меню фокусом.
        reportWindow?.orderOut(nil)
        let scanner = self.scanner
        pressTask = Task { [weak self] in
            let result = await scanner.press(candidate.id)
            guard !Task.isCancelled, let self else { return }
            self.pressTask = nil
            self.pressButton?.isEnabled = true
            self.actionStatus?.stringValue = result
            self.latestReport += "\nПРОВЕРКА \(candidate.label): \(result)"
            // Не активируем окно обратно: это может закрыть открывшееся меню.
        }
    }

    @objc private func reopenReport() {
        if reportWindow == nil, !latestReport.isEmpty { showReport(latestReport); return }
        reportWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latestReport, forType: .string)
    }

    @objc private func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "notch-shelf-ax-report.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try latestReport.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось сохранить отчёт"
            alert.informativeText = "Проверьте доступ к выбранной папке и попробуйте снова."
            alert.runModal()
        }
    }

    private func showReport(_ report: String) {
        latestReport = report
        let window = reportWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Диагностика значков"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autoresizingMask = [.width, .height]
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isRichText = false
        text.isSelectable = true
        text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = report
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.documentView = text
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
        scroll.frame = NSRect(x: 0, y: 115, width: 760, height: 365)
        let picker = NSPopUpButton(frame: NSRect(x: 12, y: 78, width: 420, height: 28))
        picker.addItems(withTitles: candidates.map(\.label))
        picker.autoresizingMask = [.width]
        content.addSubview(picker)
        candidatePicker = picker
        let press = NSButton(title: "Проверить открытие", target: self, action: #selector(pressSelectedItem))
        press.frame = NSRect(x: 445, y: 78, width: 205, height: 28)
        press.autoresizingMask = [.minXMargin]
        press.isEnabled = !candidates.isEmpty
        pressButton = press
        content.addSubview(press)
        let status = NSTextField(labelWithString: "AXPress может выполнить действие значка. Окно скроется; вернуть: Настройки → Показать отчёт.")
        status.frame = NSRect(x: 12, y: 42, width: 736, height: 32)
        status.autoresizingMask = [.width]
        actionStatus = status
        content.addSubview(status)
        let copy = NSButton(title: "Скопировать отчёт", target: self, action: #selector(copyReport))
        copy.frame = NSRect(x: 12, y: 8, width: 190, height: 28)
        content.addSubview(scroll)
        content.addSubview(copy)
        let save = NSButton(title: "Сохранить отчёт…", target: self, action: #selector(saveReport))
        save.frame = NSRect(x: 210, y: 8, width: 190, height: 28)
        content.addSubview(save)
        window.contentView = content
        reportWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        applicationObservation?.invalidate()
        applicationObservation = nil
        inventoryRefreshTask?.cancel()
        inventoryRefreshTask = nil
        shelf.stop()
        settingsModel?.stop()
        settingsModel = nil
        settingsWindow?.delegate = nil
        settingsWindow?.close()
        settingsWindow = nil
        pressTask?.cancel()
        pressTask = nil
        scanTask?.cancel()
        scanTask = nil
        reportWindow?.close()
        reportWindow = nil
        latestReport = ""
        sectionBoundary?.button?.title = "│"
        sectionBoundary?.length = 12
        for marker in sectionMarkers {
            NSStatusBar.system.removeStatusItem(marker)
        }
        sectionMarkers.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
