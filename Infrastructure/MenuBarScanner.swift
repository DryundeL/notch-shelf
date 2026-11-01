import AppKit
import ApplicationServices

/// Диагностика: сканирование метаданных и отдельная явная проверка AXPress.
actor MenuBarScanner {
    struct Process: Sendable {
        let pid: pid_t
        let bundleID: String
        let name: String
    }

    struct Candidate: Sendable {
        let id: UUID
        let pid: pid_t
        let bundleID: String
        let label: String
    }
    private var elements: [UUID: AXUIElement] = [:]
    private var candidates: [Candidate] = []
    private var menuActions: [UUID: (AXUIElement, String)] = [:]

    nonisolated static func scanOrder(_ processes: [Process]) -> [Process] {
        processes.sorted { ($0.bundleID, $0.pid) < ($1.bundleID, $1.pid) }
    }

    func availableCandidates() -> [Candidate] { candidates }

    func press(_ id: UUID) -> String {
        guard !Task.isCancelled else { return "Проверка отменена." }
        guard let element = elements[id] else { return "Элемент устарел. Повторите сканирование." }
        guard AXIsProcessTrusted() else { return "Accessibility недоступен. Повторите сканирование после выдачи доступа." }
        var role: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard roleError == .success, role as? String == kAXMenuBarItemRole else {
            return "Элемент недоступен: \(Self.status(roleError)). Повторите сканирование."
        }
        var actions: CFArray?
        let error = AXUIElementCopyActionNames(element, &actions)
        guard error == .success else { return "Проверка действий: \(Self.status(error))" }
        guard (actions as? [String] ?? []).contains(kAXPressAction) else { return "AXPress больше недоступен." }
        guard !Task.isCancelled else { return "Проверка отменена." }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return "AXPress: \(Self.status(result)). Открытие меню подтвердите визуально."
    }

    func scan(_ processes: [Process]) async -> String {
        let previousElements = elements
        let previousByPID = Dictionary(grouping: candidates, by: \.pid)
        elements.removeAll()
        candidates.removeAll()
        menuActions.removeAll()
        guard AXIsProcessTrusted() else { return "Нет разрешения Accessibility. Выдайте его приложению и повторите сканирование." }
        // Глобально только для AX-вызовов нашего процесса; AppKit здесь не используется.
        let timeout = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2)
        guard timeout == .success else { return "Не удалось задать AX timeout: \(timeout.rawValue)" }
        let overallDeadline = ContinuousClock.now.advanced(by: .seconds(64))
        var lines = ["НАЙДЕННЫЕ ЭЛЕМЕНТЫ", "Наличие AXPress не подтверждает открытие меню."]
        var diagnostics: [String] = []
        var unavailable: [String: Int] = [:]
        for process in Self.scanOrder(processes) {
            await Task.yield()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(800))
            let owner = "\(Self.safe(process.name)) [\(Self.safe(process.bundleID))] PID \(process.pid)"
            guard !Task.isCancelled, ContinuousClock.now < overallDeadline else {
                lines.append("Проход ограничен по времени; не все процессы проверены.")
                break
            }
            guard AXIsProcessTrusted() else { lines.append("Разрешение Accessibility отозвано."); break }
            let app = AXUIElementCreateApplication(process.pid)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &value)
            guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                let reason = error == .success ? "неожиданный тип AX-значения" : Self.status(error)
                unavailable[reason, default: 0] += 1
                continue
            }
            let bar = unsafeDowncast(value, to: AXUIElement.self)
            var children: CFArray?
            let childrenError = AXUIElementCopyAttributeValues(bar, kAXChildrenAttribute as CFString, 0, 32, &children)
            guard childrenError == .success, let children else {
                diagnostics.append("\(owner): children — \(Self.status(childrenError))")
                continue
            }
            let items = children as [AnyObject]
            guard !items.isEmpty else { diagnostics.append("\(owner): элементов нет"); continue }
            lines.append("\n\(owner): \(items.count) элементов (лимит 32)")
            for (index, item) in items.enumerated() {
                guard !Task.isCancelled, ContinuousClock.now < deadline else { lines.append("Лимит времени внутри приложения."); break }
                guard CFGetTypeID(item) == AXUIElementGetTypeID() else { continue }
                let element = unsafeDowncast(item, to: AXUIElement.self)
                var role: CFTypeRef?
                let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                var identifier: CFTypeRef?
                let idError = AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier)
                var actions: CFArray?
                let actionsError = AXUIElementCopyActionNames(element, &actions)
                if roleError == .success, role as? String == kAXMenuBarItemRole,
                   actionsError == .success, (actions as? [String] ?? []).contains(kAXPressAction) {
                    var retainedID: UUID?
                    for previous in previousByPID[process.pid] ?? [] {
                        guard previous.pid == process.pid, previous.bundleID == process.bundleID,
                              let previousElement = previousElements[previous.id], elements[previous.id] == nil else { continue }
                        if CFEqual(previousElement, element) { retainedID = previous.id; break }
                    }
                    let id = retainedID ?? UUID()
                    elements[id] = element
                    candidates.append(Candidate(id: id, pid: process.pid, bundleID: process.bundleID,
                                                label: "\(Self.safe(process.name)) — #\(index) (PID \(process.pid))"))
                }
                // Чужие строки ограничены и очищены для текстового отчёта.
                let roleText = Self.safe(role as? String ?? "—")
                let actionText = (actions as? [String] ?? []).prefix(16).map(Self.safe).joined(separator: ", ")
                lines.append("  #\(index): роль=\(roleText) (\(Self.status(roleError))); идентификатор=\(identifier is String ? "есть" : "нет") (\(Self.status(idError))); действия=[\(actionText)] (\(Self.status(actionsError)))")
            }
        }
        lines.append("\nСВОДКА НЕДОСТУПНЫХ ПРОЦЕССОВ")
        lines.append("Отсутствие значения не доказывает отсутствие значка.")
        for reason in unavailable.keys.sorted() {
            lines.append("\(reason): \(unavailable[reason, default: 0])")
        }
        lines.append(contentsOf: diagnostics)
        return lines.joined(separator: "\n")
    }

    nonisolated static func status(_ error: AXError) -> String {
        let description: String
        switch error {
        case .success: description = "OK"
        case .noValue: description = "значение отсутствует"
        case .attributeUnsupported: description = "атрибут не поддерживается"
        case .cannotComplete: description = "запрос не завершён"
        case .apiDisabled: description = "AX API недоступен"
        case .invalidUIElement: description = "элемент недействителен"
        default: description = "ошибка AX"
        }
        return "\(description) [\(error.rawValue)]"
    }

    nonisolated static func safe(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(128))
    }
}

extension MenuBarScanner {
    struct MenuEntry: Sendable {
        let actionID: UUID?
        let title: String
        let enabled: Bool
        let checked: Bool
        let separator: Bool
        let children: [MenuEntry]
    }

    /// Reads only the selected item's exposed menu. Never opens it at the old location.
    func menuSnapshot(_ id: UUID) -> [MenuEntry] {
        menuActions.removeAll()
        guard AXIsProcessTrusted(), let element = elements[id], !Task.isCancelled else { return [] }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var remaining = 128
        return readMenu(element, depth: 0, remaining: &remaining, deadline: deadline)
    }

    private func readMenu(_ root: AXUIElement, depth: Int, remaining: inout Int, deadline: ContinuousClock.Instant) -> [MenuEntry] {
        guard depth < 6, remaining > 0, ContinuousClock.now < deadline, !Task.isCancelled else { return [] }
        var value: CFArray?
        guard AXUIElementCopyAttributeValues(root, kAXChildrenAttribute as CFString, 0, min(remaining, 128), &value) == .success,
              let children = value as? [AnyObject] else { return [] }
        var result: [MenuEntry] = []
        for object in children {
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { continue }
            let child = unsafeDowncast(object, to: AXUIElement.self)
            guard remaining > 0, ContinuousClock.now < deadline, !Task.isCancelled else { break }
            remaining -= 1
            var roleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue) == .success else { continue }
            let role = roleValue as? String
            if role == kAXMenuRole {
                result += readMenu(child, depth: depth + 1, remaining: &remaining, deadline: deadline)
                continue
            }
            guard role == kAXMenuItemRole else { continue }
            var titleValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleValue)
            let rawTitle = titleValue as? String ?? ""
            guard rawTitle.utf8.count <= 4096 else { continue }
            let title = Self.safe(rawTitle)
            var enabledValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(child, kAXEnabledAttribute as CFString, &enabledValue)
            let enabled = enabledValue as? Bool ?? false
            var mark: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(child, "AXMenuItemMarkChar" as CFString, &mark)
            let nested = readMenu(child, depth: depth + 1, remaining: &remaining, deadline: deadline)
            var actions: CFArray?
            _ = AXUIElementCopyActionNames(child, &actions)
            let actionable = enabled && (actions as? [String] ?? []).contains(kAXPressAction)
            let token = actionable && !title.isEmpty ? UUID() : nil
            if let token { menuActions[token] = (child, rawTitle) }
            result.append(MenuEntry(actionID: token, title: title, enabled: enabled && (actionable || !nested.isEmpty),
                checked: !(mark as? String ?? "").isEmpty, separator: title.isEmpty && nested.isEmpty, children: nested))
        }
        return result
    }

    func performMenuAction(_ id: UUID) -> String {
        guard AXIsProcessTrusted(), !Task.isCancelled, let (element, expectedTitle) = menuActions[id] else {
            return "Действие устарело или Accessibility недоступен. Откройте меню заново."
        }
        var currentTitle: CFTypeRef?
        var enabled: CFTypeRef?
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              role as? String == kAXMenuItemRole,
              AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &currentTitle) == .success,
              currentTitle as? String == expectedTitle,
              AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success,
              enabled as? Bool == true else { return "Пункт меню изменился или недоступен. Откройте меню заново." }
        menuActions.removeAll()
        return "Действие меню: \(Self.status(AXUIElementPerformAction(element, kAXPressAction as CFString)))."
    }
}
