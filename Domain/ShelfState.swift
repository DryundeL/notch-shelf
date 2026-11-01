/// Переходы панели независимы от AppKit и механизма анимации.
struct ShelfState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case closed, opening, open, closing }
    private(set) var phase: Phase = .closed

    mutating func requestOpen() {
        guard phase == .closed || phase == .closing else { return }
        phase = .opening
    }

    mutating func requestClose() {
        guard phase == .open || phase == .opening else { return }
        phase = .closing
    }

    mutating func finishOpening() {
        guard phase == .opening else { return }
        phase = .open
    }

    mutating func finishClosing() {
        guard phase == .closing else { return }
        phase = .closed
    }

    mutating func cancel() { phase = .closed }
}

/// Клик по значку и «клик снаружи» приходят одним mouseDown.
/// Закрывать по значку должен только toggle, иначе панель закроется и сразу откроется снова.
enum ShelfDismiss {
    static func shouldClose(armed: Bool, pointerOnStatusButton: Bool) -> Bool {
        armed && !pointerOnStatusButton
    }
}

/// Единственная политика допуска анимации; системное ограничение имеет приоритет.
enum ShelfAnimationPolicy {
    static func duration(settings: ShelfSettings, reduceMotion: Bool) -> Double {
        guard settings.isValid, settings.animationsEnabled, !reduceMotion else { return 0 }
        return Double(settings.animationDurationMs) / 1000
    }
}

/// Never exclude the manager or system applications from an experimental allow-list.
enum NativeVisibilityPolicy {
    static func sectionBundleIDs(discovered: Set<String>, shelf: Set<String>, own: String) -> Set<String> {
        discovered.subtracting(shelf).filter { !$0.isEmpty && !$0.hasPrefix("com.apple.") && $0 != own }
    }
    static func allowedBundleIDs(running: [String], selected: String, own: String) -> [String]? {
        guard !own.isEmpty, !selected.isEmpty, selected != own,
              !selected.hasPrefix("com.apple."), running.contains(selected),
              running.count <= 512 else { return nil }
        return Array(Set(running.filter { $0 != selected } + [own])).sorted()
    }
}


extension NativeVisibilityPolicy {
    static func allowedBundleIDs(running: [String], selected: Set<String>, own: String) -> [String]? {
        guard !selected.isEmpty, selected.allSatisfy({ !$0.isEmpty && $0 != own && !$0.hasPrefix("com.apple.") }),
              !own.isEmpty, running.count <= 512, selected.isSubset(of: Set(running)) else { return nil }
        return Array(Set(running).subtracting(selected).union([own])).sorted()
    }
}
