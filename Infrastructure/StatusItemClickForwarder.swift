import AppKit
import CoreGraphics

/// Kind of click the user made on a shelf button; forwarded verbatim to the original item.
struct ShelfItemClick: Equatable, Sendable {
    var secondary = false
    var option = false
    var control = false
    var shift = false

    @MainActor static func current() -> ShelfItemClick {
        let event = NSApplication.shared.currentEvent
        let flags = event?.modifierFlags ?? []
        return ShelfItemClick(secondary: event?.type == .rightMouseUp || event?.type == .rightMouseDown,
                              option: flags.contains(.option), control: flags.contains(.control), shift: flags.contains(.shift))
    }
}

/// Delivers one synthetic click to a *visible* status item window of another process.
/// Only window metadata (ID, owner PID, level, bounds) is read: no titles or contents,
/// so Screen Recording is not needed. Command is never forwarded: Command-drag reorders items.
@MainActor
final class StatusItemClickForwarder {
    enum Failure: Error, Equatable { case noPostEventAccess, notVisible, eventCreation }

    func windows() -> [StatusItemClickPolicy.WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return .init(id: number.uint32Value, pid: pid.int32Value, layer: layer.intValue, bounds: bounds)
        }
    }

    /// Menu bar strips and camera housings of all screens, in global top-left coordinates.
    func screenGeometry() -> (menuBars: [CGRect], blocked: [CGRect]) {
        guard let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return ([], []) }
        var menuBars: [CGRect] = [], blocked: [CGRect] = []
        for screen in NSScreen.screens {
            let frame = screen.frame
            let barHeight = max(frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 24)
            menuBars.append(StatusItemClickPolicy.topLeftRect(
                CGRect(x: frame.minX, y: frame.maxY - barHeight, width: frame.width, height: barHeight), primaryScreenMaxY: primaryMaxY))
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
                let notch = CGRect(x: left.maxX, y: frame.maxY - barHeight, width: right.minX - left.maxX, height: barHeight)
                blocked.append(StatusItemClickPolicy.topLeftRect(notch, primaryScreenMaxY: primaryMaxY))
            }
        }
        return (menuBars, blocked)
    }

    /// Posts mouse down/up at the item. The cursor stays there, next to the menu it opens. Returns the owner's on-screen
    /// window IDs from just before the click, the baseline for detecting what the click opened.
    func click(itemFrame: CGRect, window: StatusItemClickPolicy.WindowInfo, click: ShelfItemClick) -> Result<Set<CGWindowID>, Failure> {
        guard CGPreflightPostEventAccess() else { return .failure(.noPostEventAccess) }
        let geometry = screenGeometry()
        guard let point = StatusItemClickPolicy.clickPoint(frame: itemFrame, menuBars: geometry.menuBars, blocked: geometry.blocked) else {
            return .failure(.notVisible)
        }
        let baseline = Set(windows().filter { $0.pid == window.pid }.map(\.id))
        let source = CGEventSource(stateID: .hidSystemState)
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = click.secondary
            ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        var flags = CGEventFlags()
        if click.option { flags.insert(.maskAlternate) }
        if click.control { flags.insert(.maskControl) }
        if click.shift { flags.insert(.maskShift) }
        guard let downEvent = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: point, mouseButton: button),
              let upEvent = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: point, mouseButton: button) else {
            return .failure(.eventCreation)
        }
        for event in [downEvent, upEvent] {
            event.flags = flags
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.id))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.id))
            event.post(tap: .cgSessionEventTap)
        }
        return .success(baseline)
    }
}
