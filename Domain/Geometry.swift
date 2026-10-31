import Foundation

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
