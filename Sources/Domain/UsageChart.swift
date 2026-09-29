import Foundation

/// T3 Usage chart scale and Fritsch–Carlson monotone cubics.
public enum UsageChartMath {
    public static let tickCount = 4
    public static let plotTop: Double = 8
    public static let plotHeight: Double = 224

    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct CurveSegment: Equatable, Sendable {
        public var from: Point
        public var c1: Point
        public var c2: Point
        public var to: Point
    }

    public static func niceScale(peak: Double, count: Int = tickCount) -> (max: Double, ticks: [Double]) {
        guard peak > 0, count > 0 else { return (0, [0]) }
        let rawStep = peak / Double(count)
        let magnitude = pow(10, floor(log10(rawStep)))
        let normalized = rawStep / magnitude
        let step: Double
        if normalized > 5 {
            step = 10 * magnitude
        } else if normalized > 2 {
            step = 5 * magnitude
        } else if normalized > 1 {
            step = 2 * magnitude
        } else {
            step = magnitude
        }
        let max = ceil(peak / step) * step
        var ticks: [Double] = []
        var value = 0.0
        while value <= max + step * 1e-6 {
            ticks.append(value)
            value += step
        }
        return (max, ticks)
    }

    public static func y(value: Double, max: Double, height: Double = plotHeight) -> Double {
        if max == 0 { return height }
        return height - (value / max) * (height - plotTop)
    }

    public static func monotoneTangents(_ points: [Point]) -> [Double] {
        let count = points.count
        guard count >= 2 else { return [0] }
        var slopes: [Double] = []
        for index in 0..<(count - 1) {
            let dx = points[index + 1].x - points[index].x
            let dy = points[index + 1].y - points[index].y
            slopes.append(dx == 0 ? 0 : dy / dx)
        }
        var tangents = Array(repeating: 0.0, count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]
        if count > 2 {
            for index in 1..<(count - 1) {
                let previous = slopes[index - 1]
                let next = slopes[index]
                tangents[index] = previous * next <= 0 ? 0 : (previous + next) / 2
            }
        }
        for index in 0..<(count - 1) {
            let slope = slopes[index]
            if slope == 0 {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }
            let a = tangents[index] / slope
            let b = tangents[index + 1] / slope
            let magnitude = a * a + b * b
            if magnitude > 9 {
                let scale = 3 / sqrt(magnitude)
                tangents[index] = scale * a * slope
                tangents[index + 1] = scale * b * slope
            }
        }
        return tangents
    }

    public static func smoothCurve(_ points: [Point]) -> [CurveSegment] {
        guard points.count >= 2 else { return [] }
        let tangents = monotoneTangents(points)
        var segments: [CurveSegment] = []
        for index in 0..<(points.count - 1) {
            let from = points[index]
            let to = points[index + 1]
            let dx = to.x - from.x
            segments.append(
                CurveSegment(
                    from: from,
                    c1: Point(x: from.x + dx / 3, y: from.y + (tangents[index] * dx) / 3),
                    c2: Point(x: to.x - dx / 3, y: to.y - (tangents[index + 1] * dx) / 3),
                    to: to
                )
            )
        }
        return segments
    }
}
