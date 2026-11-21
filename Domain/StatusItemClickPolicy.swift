import CoreGraphics
import Foundation

/// Pure rules for forwarding a shelf click to the original status item.
/// All rectangles are global, top-left origin (Quartz/AX space), in points.
enum StatusItemClickPolicy {
    struct WindowInfo: Equatable, Sendable {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
    }

    /// `kCGStatusWindowLevel`: the level of NSStatusItem windows.
    static let statusLayer = 25
    /// `kCGNormalWindowLevel`: ordinary document windows are not "menus" of a status item.
    static let normalLayer = 0

    static func isPlausibleItemFrame(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.width <= 1024 && frame.height > 0 && frame.height <= 128
    }

    /// The only status window of `pid` matching the item's AX frame. Ambiguity is a refusal:
    /// a click must never land on a window we cannot attribute to this exact item.
    static func statusWindow(for frame: CGRect, pid: pid_t, windows: [WindowInfo], tolerance: CGFloat = 2) -> WindowInfo? {
        guard isPlausibleItemFrame(frame), pid > 0, tolerance >= 0 else { return nil }
        let matches = windows.filter { window in
            window.pid == pid && window.layer == statusLayer
                && abs(window.bounds.minX - frame.minX) <= tolerance
                && abs(window.bounds.maxX - frame.maxX) <= tolerance
                && window.bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Center of the item if it is really visible: inside some menu bar strip and clear of
    /// the camera housing (an item pushed behind the notch cannot receive a click).
    static func clickPoint(frame: CGRect, menuBars: [CGRect], blocked: [CGRect]) -> CGPoint? {
        guard isPlausibleItemFrame(frame) else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard menuBars.contains(where: { $0.contains(center) }),
              !blocked.contains(where: { $0.intersects(frame) }) else { return nil }
        return center
    }

    /// Windows the click produced: menus, popovers and panels of the owner, not its status windows
    /// that existed before and not ordinary document windows (those do not keep the icon revealed).
    static func openedWindows(before: Set<CGWindowID>, now: [WindowInfo], pid: pid_t) -> Set<CGWindowID> {
        Set(now.filter { $0.pid == pid && $0.layer != normalLayer && !before.contains($0.id) }.map(\.id))
    }

    /// Converts an AppKit rectangle (bottom-left origin) into global top-left coordinates.
    static func topLeftRect(_ rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenMaxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
