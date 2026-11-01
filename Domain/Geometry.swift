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

/// Include the reachable strip below the camera, rather than a tiny edge target.
enum HoverGeometry {
    static func trigger(screen: CGRect, safeTop: CGFloat, notchLeft: CGFloat?, notchRight: CGFloat?) -> CGRect? {
        guard [screen.minX, screen.minY, screen.width, screen.height, safeTop].allSatisfy(\.isFinite),
              screen.width >= 120, screen.height >= 40, safeTop >= 0, safeTop < screen.height else { return nil }
        if safeTop > 0, let left = notchLeft, let right = notchRight,
           left.isFinite, right.isFinite, left >= screen.minX, right <= screen.maxX, right > left {
            let bottom = max(screen.minY, screen.maxY - safeTop - 16)
            return CGRect(x: left, y: bottom, width: right - left, height: screen.maxY - bottom)
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


/// A continuous silhouette: fixed neck through the menu bar, curved shoulders below it.
enum ConnectedShelfShape {
    static func path(size: CGSize, neckWidth: CGFloat, neckHeight: CGFloat, bodyWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard [size.width, size.height, neckWidth, neckHeight, bodyWidth].allSatisfy(\.isFinite),
              size.width > 0, size.height > 0 else { return path }
        let center = size.width / 2
        let neck = min(size.width, max(1, neckWidth))
        let leftNeck = center - neck / 2, rightNeck = center + neck / 2
        let bottomOfNeck = max(0, size.height - max(0, neckHeight))
        guard bottomOfNeck > 0 else {
            path.addRect(CGRect(x: leftNeck, y: 0, width: neck, height: size.height))
            return path
        }
        let width = min(size.width, max(1, bodyWidth))
        let left = center - width / 2, right = center + width / 2
        let bodyTop = max(0, bottomOfNeck - 12)
        let radius = min(20, width / 2, bodyTop / 2)
        path.move(to: CGPoint(x: leftNeck, y: size.height))
        path.addLine(to: CGPoint(x: rightNeck, y: size.height))
        path.addLine(to: CGPoint(x: rightNeck, y: bottomOfNeck))
        path.addCurve(to: CGPoint(x: right, y: bodyTop - radius),
                      control1: CGPoint(x: rightNeck, y: bodyTop + 6), control2: CGPoint(x: right, y: bodyTop + 6))
        path.addLine(to: CGPoint(x: right, y: radius))
        path.addQuadCurve(to: CGPoint(x: right - radius, y: 0), control: CGPoint(x: right, y: 0))
        path.addLine(to: CGPoint(x: left + radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: left, y: radius), control: CGPoint(x: left, y: 0))
        path.addLine(to: CGPoint(x: left, y: bodyTop - radius))
        path.addCurve(to: CGPoint(x: leftNeck, y: bottomOfNeck),
                      control1: CGPoint(x: left, y: bodyTop + 6), control2: CGPoint(x: leftNeck, y: bodyTop + 6))
        path.addLine(to: CGPoint(x: leftNeck, y: size.height))
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
