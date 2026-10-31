import AppKit
import SwiftUI
@preconcurrency import ApplicationServices

/// Собственный status item; управление чужими значками сюда не входит.
@MainActor
final class StatusItemController: NSObject {
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

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.title = ""
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.setAccessibilityLabel("Notch Shelf")

        shelf.onSettings = { [weak self] in self?.showSettings() }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

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

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        shelf.toggle(from: button, settings: settingsStore.load())
    }

    private func showSettings() {
        shelf.close()
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Notch Shelf — Настройки"
        window.isReleasedWhenClosed = false
        let model = SettingsModel(store: settingsStore)
        settingsModel = model
        window.contentView = NSHostingView(rootView: SettingsView(model: model,
            scan: { [weak self] in self?.scanMenuBar() },
            showReport: { [weak self] in self?.reopenReport() },
            quit: { NSApplication.shared.terminate(nil) }))
        settingsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func scanMenuBar() {
        guard scanTask == nil, pressTask == nil else { return }
        guard AXIsProcessTrusted() else {
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
            self.showReport(report)
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
        shelf.stop()
        settingsModel?.stop()
        settingsModel = nil
        settingsWindow?.close()
        settingsWindow = nil
        pressTask?.cancel()
        pressTask = nil
        scanTask?.cancel()
        scanTask = nil
        reportWindow?.close()
        reportWindow = nil
        latestReport = ""
        for marker in sectionMarkers {
            NSStatusBar.system.removeStatusItem(marker)
        }
        sectionMarkers.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
