import Foundation
import CoreGraphics

/// Входные координаты и размер — в points, в системе координат AppKit.
enum ShelfGeometry {
    struct Placement: Equatable {
        let frame: CGRect
        let requiresScroll: Bool
    }

    static func placement(visibleFrame: CGRect, screenFrame: CGRect, hasNotch: Bool,
                          sourceX: CGFloat, desiredSize: CGSize = CGSize(width: 360, height: 180),
                          margin: CGFloat = 8) -> Placement? {
        let numbers = [visibleFrame.minX, visibleFrame.minY, visibleFrame.width, visibleFrame.height,
                       screenFrame.minX, screenFrame.minY, screenFrame.width, screenFrame.height,
                       sourceX, desiredSize.width, desiredSize.height, margin]
        guard numbers.allSatisfy(\.isFinite), margin >= 0,
              desiredSize.width > 0, desiredSize.height > 0,
              visibleFrame.width > margin * 2, visibleFrame.height > margin * 2 else { return nil }
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        let size = CGSize(width: min(desiredSize.width, bounds.width), height: min(desiredSize.height, bounds.height))
        let centerX = hasNotch ? screenFrame.midX : sourceX
        let x = min(max(centerX - size.width / 2, bounds.minX), bounds.maxX - size.width)
        return Placement(frame: CGRect(x: x, y: bounds.maxY - size.height, width: size.width, height: size.height),
                         requiresScroll: size.height < desiredSize.height || size.width < desiredSize.width)
    }
}

/// The trigger is exactly the camera housing. It must not extend below the menu bar:
/// the trigger window swallows clicks, and the strip under the notch belongs to other apps
/// (tab bars, toolbars). The top screen edge already makes the notch an infinite-height target.
enum HoverGeometry {
    static func trigger(screen: CGRect, safeTop: CGFloat, notchLeft: CGFloat?, notchRight: CGFloat?) -> CGRect? {
        guard [screen.minX, screen.minY, screen.width, screen.height, safeTop].allSatisfy(\.isFinite),
              screen.width >= 120, screen.height >= 40, safeTop >= 0, safeTop < screen.height else { return nil }
        if safeTop > 0, let left = notchLeft, let right = notchRight,
           left.isFinite, right.isFinite, left >= screen.minX, right <= screen.maxX, right > left {
            return CGRect(x: left, y: screen.maxY - safeTop, width: right - left, height: safeTop)
        }
        let width = min(180, screen.width)
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - 24, width: width, height: 24)
    }
}

/// A fixed-width neck and an adaptive body form one connected shape.
enum NotchShelfGeometry {
    struct Layout {
        let collapsed: CGRect
        let expanded: CGRect
        let contentTopInset: CGFloat
        let body: CGRect
        let neckWidth: CGFloat
        let neckHeight: CGFloat
    }

    static func layout(screen: CGRect, cutout: CGRect?, itemCount: Int, menuBarHeight: CGFloat = 24) -> Layout? {
        guard [screen.minX, screen.minY, screen.width, screen.height].allSatisfy(\.isFinite),
              screen.width >= 240, screen.height >= 160, menuBarHeight.isFinite,
              menuBarHeight >= 0, menuBarHeight <= screen.height - 100, (0...4096).contains(itemCount) else { return nil }
        let anchor: CGRect
        if let cutout, [cutout.minX, cutout.minY, cutout.width, cutout.height].allSatisfy(\.isFinite),
           screen.contains(cutout), cutout.width >= 40, cutout.height >= 1, cutout.height <= screen.height - 120,
           abs(cutout.maxY - screen.maxY) < 1 {
            anchor = cutout
        } else {
            anchor = CGRect(x: screen.midX - 90, y: screen.maxY - 24, width: 180, height: 24)
        }
        let count = max(1, itemCount)
        let maximumColumns = min(6, max(1, Int((screen.width - 56) / 44)))
        let totalRows = (count + maximumColumns - 1) / maximumColumns
        let columns = (count + totalRows - 1) / totalRows
        let bodyWidth = CGFloat(columns * 44) + 32
        let neckHeight = max(anchor.height, menuBarHeight)
        let bodyHeight = min(CGFloat(min(3, totalRows) * 44) + 20, screen.height - neckHeight - 24)
        let width = max(anchor.width, bodyWidth)
        let height = neckHeight + 12 + bodyHeight
        let x = min(max(anchor.midX - width / 2, screen.minX), screen.maxX - width)
        let expanded = CGRect(x: x, y: screen.maxY - height, width: width, height: height)
        let body = CGRect(x: expanded.midX - bodyWidth / 2, y: expanded.minY, width: bodyWidth, height: bodyHeight)
        return Layout(collapsed: anchor, expanded: expanded, contentTopInset: neckHeight + 16,
                      body: body, neckWidth: anchor.width, neckHeight: neckHeight)
    }
}


/// Balance row lengths and center each row rather than leaving a short row left-aligned.
enum BubbleIconGrid {
    static func frames(itemCount: Int, width: CGFloat) -> [CGRect] {
        guard (1...4096).contains(itemCount), width.isFinite, width >= 44 else { return [] }
        let columns = min(6, itemCount, max(1, Int(width / 44)))
        let rows = (itemCount + columns - 1) / columns
        let baseCount = itemCount / rows
        let extra = itemCount % rows
        var frames: [CGRect] = []
        frames.reserveCapacity(itemCount)
        for row in 0..<rows {
            let count = baseCount + (row < extra ? 1 : 0)
            let left = (width - CGFloat(count * 44)) / 2
            for column in 0..<count {
                frames.append(CGRect(x: left + CGFloat(column * 44) + 2,
                    y: CGFloat((rows - 1 - row) * 44) + 2, width: 40, height: 40))
            }
        }
        return frames
    }
}


/// One silhouette that morphs from the camera housing (`progress` 0) into the open shelf (`progress` 1).
/// Every progress value produces the same sequence of path elements, so Core Animation can
/// interpolate `CAShapeLayer.path` directly instead of resizing the window every frame.
/// Coordinates are AppKit view coordinates (y grows up); `top` is the screen edge.
enum NotchMorphShape {
    static let shoulderHeight: CGFloat = 12
    /// Close to the bottom radius of the physical camera housing, so the closed shape blends into it.
    static let collapsedRadius: CGFloat = 8
    static let expandedRadius: CGFloat = 20

    static func path(centerX: CGFloat, top: CGFloat, neckWidth: CGFloat, neckHeight: CGFloat,
                     bodyWidth: CGFloat, bodyHeight: CGFloat, progress: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard [centerX, top, neckWidth, neckHeight, bodyWidth, bodyHeight, progress].allSatisfy(\.isFinite) else { return path }
        let p = min(1, max(0, progress))
        let neck = max(1, neckWidth)
        let neckBottom = top - max(0, neckHeight)
        let width = max(1, neck + (max(1, bodyWidth) - neck) * p)
        let bottom = neckBottom - (shoulderHeight + max(0, bodyHeight)) * p
        let radius = max(0, min(collapsedRadius + (expandedRadius - collapsedRadius) * p, width / 2, (top - bottom) / 2))
        let shoulderEnd = max(bottom + radius, neckBottom - shoulderHeight * p)
        let shoulderStart = max(shoulderEnd, neckBottom)
        let shoulderMid = (shoulderStart + shoulderEnd) / 2
        let leftNeck = centerX - neck / 2, rightNeck = centerX + neck / 2
        let left = centerX - width / 2, right = centerX + width / 2

        path.move(to: CGPoint(x: leftNeck, y: top))
        path.addLine(to: CGPoint(x: rightNeck, y: top))
        path.addLine(to: CGPoint(x: rightNeck, y: shoulderStart))
        path.addCurve(to: CGPoint(x: right, y: shoulderEnd),
                      control1: CGPoint(x: rightNeck, y: shoulderMid), control2: CGPoint(x: right, y: shoulderMid))
        path.addLine(to: CGPoint(x: right, y: bottom + radius))
        path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom + radius), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: shoulderEnd))
        path.addCurve(to: CGPoint(x: leftNeck, y: shoulderStart),
                      control1: CGPoint(x: left, y: shoulderMid), control2: CGPoint(x: leftNeck, y: shoulderMid))
        path.closeSubpath()
        return path
    }
}

/// Command-drag changes membership only after a real move across the manager's sides.
enum MenuBarDragPolicy {
    static func membership(source: CGPoint, before: CGRect, after: CGRect, anchor: CGRect) -> Bool? {
        let values = [source.x, source.y, before.minX, before.minY, before.width, before.height,
                      after.minX, after.minY, after.width, after.height,
                      anchor.minX, anchor.minY, anchor.width, anchor.height]
        guard values.allSatisfy(\.isFinite), before.width > 0, before.height > 0,
              after.width > 0, after.height > 0, anchor.width > 0, anchor.height > 0,
              before.contains(source), abs(before.midX - after.midX) > 2 || abs(before.midY - after.midY) > 2,
              after.minY < anchor.maxY, after.maxY > anchor.minY else { return nil }
        if after.midX < anchor.minX { return true }
        if after.midX > anchor.maxX { return false }
        return nil
    }
}
