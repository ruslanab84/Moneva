import CoreGraphics
import Foundation

/// Heights of the banners currently on screen, one entry per banner. The floating buttons
/// clear the tallest one. Per-banner entries (not one shared number) so that a banner leaving
/// the screen cannot zero the offset of another that is still showing.
struct BannerHeights {
    private var heights: [UUID: CGFloat] = [:]

    var height: CGFloat { heights.values.max() ?? 0 }

    mutating func report(_ id: UUID, height: CGFloat) { heights[id] = height }
    mutating func remove(_ id: UUID) { heights[id] = nil }
}
