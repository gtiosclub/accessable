import CoreGraphics

extension CGRect {
    /// Area of the intersection divided by the area of the union, 0...1. Zero for disjoint
    /// or empty rectangles.
    func intersectionOverUnion(with other: CGRect) -> CGFloat {
        let overlap = intersectionArea(with: other)
        let union = area + other.area - overlap
        return union > 0 ? overlap / union : 0
    }

    /// Area of the intersection divided by the area of the smaller rectangle, 0...1. Unlike
    /// IoU this stays high when one box sits inside a much larger one.
    func overlapOfSmaller(with other: CGRect) -> CGFloat {
        let smaller = min(area, other.area)
        return smaller > 0 ? intersectionArea(with: other) / smaller : 0
    }

    /// Area of the intersection divided by the area of the larger rectangle, 0...1. Low
    /// when a small box merely sits inside a much larger one.
    func overlapOfLarger(with other: CGRect) -> CGFloat {
        let larger = max(area, other.area)
        return larger > 0 ? intersectionArea(with: other) / larger : 0
    }

    private var area: CGFloat {
        isNull ? 0 : abs(width * height)
    }

    private func intersectionArea(with other: CGRect) -> CGFloat {
        let overlap = intersection(other)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }
}
