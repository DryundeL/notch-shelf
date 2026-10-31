import Foundation

struct DisplaySnapshot: Equatable, Sendable {
    /// Runtime ID, не постоянный ключ настроек.
    var profileKey: String? = nil
    var name: String = "Дисплей"
    let runtimeID: UInt32
    let frame: CGRect
    let visibleFrame: CGRect
    let scale: CGFloat
    let hasNotch: Bool
}

enum DisplayPolicy {
    static func target(in displays: [DisplaySnapshot], sourceID: UInt32?, pointer: CGPoint,
                       mainID: UInt32?) -> DisplaySnapshot? {
        if let sourceID, let source = displays.first(where: { $0.runtimeID == sourceID }) { return source }
        if let hovered = displays.first(where: { $0.frame.contains(pointer) }) { return hovered }
        return displays.first(where: { $0.runtimeID == mainID }) ?? displays.first
    }
}

enum DisplayProfilePolicy {
    static func mode(for display: DisplaySnapshot, among displays: [DisplaySnapshot], settings: ShelfSettings) -> ShelfSettings.DisplayMode {
        guard let key = display.profileKey else { return .floating }
        guard displays.filter({ $0.profileKey == key }).count == 1 else { return .floating }
        let mode = settings.perDisplayModes[key] ?? settings.defaultDisplayMode
        return mode == .notch && !display.hasNotch ? .floating : mode
    }
}
