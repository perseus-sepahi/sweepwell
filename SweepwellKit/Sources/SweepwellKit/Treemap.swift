import Foundation
import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing & van Wijk): rectangles whose areas are
/// proportional to `values`, kept as close to square as the input allows.
public enum Treemap {
    /// `values` should be sorted descending; the result is index-aligned with it.
    public static func layout(_ values: [Double], in bounds: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, bounds.width > 0, bounds.height > 0 else {
            return [CGRect](repeating: .zero, count: values.count)
        }
        let scale = Double(bounds.width * bounds.height) / total
        let areas = values.map { max(0, $0) * scale }
        var result = [CGRect](repeating: .zero, count: values.count)
        var free = bounds
        var start = 0

        while start < areas.count {
            let side = Double(min(free.width, free.height))
            guard side > 0 else { break }

            // Grow the row while doing so keeps its worst aspect ratio from getting worse.
            var end = start + 1
            var rowSum = areas[start]
            var worst = worstRatio(sum: rowSum, largest: areas[start], smallest: areas[start], side: side)
            while end < areas.count {
                let candidateSum = rowSum + areas[end]
                let candidate = worstRatio(sum: candidateSum, largest: areas[start], smallest: areas[end], side: side)
                if candidate > worst { break }
                rowSum = candidateSum
                worst = candidate
                end += 1
            }

            let thickness = rowSum / side
            var offset = 0.0
            let vertical = free.width >= free.height
            for index in start..<end {
                let length = thickness > 0 ? areas[index] / thickness : 0
                result[index] = vertical
                    ? CGRect(x: Double(free.minX), y: Double(free.minY) + offset, width: thickness, height: length)
                    : CGRect(x: Double(free.minX) + offset, y: Double(free.minY), width: length, height: thickness)
                offset += length
            }
            free = vertical
                ? CGRect(x: Double(free.minX) + thickness, y: Double(free.minY), width: max(0, Double(free.width) - thickness), height: Double(free.height))
                : CGRect(x: Double(free.minX), y: Double(free.minY) + thickness, width: Double(free.width), height: max(0, Double(free.height) - thickness))
            start = end
        }
        return result
    }

    private static func worstRatio(sum: Double, largest: Double, smallest: Double, side: Double) -> Double {
        guard sum > 0, smallest > 0 else { return .infinity }
        let s2 = side * side
        return max(s2 * largest / (sum * sum), (sum * sum) / (s2 * smallest))
    }
}
