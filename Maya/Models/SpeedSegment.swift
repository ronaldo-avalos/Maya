import Foundation

/// A constant-speed range anchored to source-video time. Keeping the range in
/// source coordinates makes it stay attached to the same recorded frames when
/// the clip is moved or trimmed on the project timeline.
struct SpeedSegment: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var startTime: Double
    var duration: Double
    var rate: Double

    static let defaultDuration: Double = 2
    static let defaultRate: Double = 2
    static let minimumDuration: Double = 0.25
    static let rateRange: ClosedRange<Double> = 0.25...4

    var endTime: Double { startTime + duration }

    init(
        id: UUID = UUID(),
        startTime: Double,
        duration: Double = SpeedSegment.defaultDuration,
        rate: Double = SpeedSegment.defaultRate
    ) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.rate = rate
        normalize()
    }

    mutating func normalize(sourceDuration: Double? = nil) {
        startTime = max(0, startTime)
        rate = max(Self.rateRange.lowerBound, min(rate, Self.rateRange.upperBound))
        duration = max(Self.minimumDuration, duration)

        if let sourceDuration {
            let safeDuration = max(0, sourceDuration)
            startTime = min(startTime, max(safeDuration - Self.minimumDuration, 0))
            duration = min(duration, max(safeDuration - startTime, Self.minimumDuration))
        }
    }
}

/// Piecewise-linear mapping between source-video time and the retimed clip.
/// Gaps between speed segments run at 1×. The same value type is shared by the
/// editor preview, timeline layout, and exporter so all three agree exactly.
struct SpeedTimeline: Hashable, Sendable {
    struct Piece: Hashable, Sendable {
        let sourceStart: Double
        let sourceEnd: Double
        let rate: Double
        let outputStart: Double

        var sourceDuration: Double { sourceEnd - sourceStart }
        var outputDuration: Double { sourceDuration / rate }
        var outputEnd: Double { outputStart + outputDuration }
    }

    let sourceStart: Double
    let sourceEnd: Double
    let pieces: [Piece]

    init(sourceStart: Double, sourceEnd: Double, segments: [SpeedSegment]) {
        let lower = max(0, min(sourceStart, sourceEnd))
        let upper = max(lower, sourceEnd)
        self.sourceStart = lower
        self.sourceEnd = upper

        guard upper > lower else {
            pieces = []
            return
        }

        let clippedSegments: [(start: Double, end: Double, rate: Double)] = segments.compactMap { segment in
            let start = max(lower, segment.startTime)
            let end = min(upper, segment.endTime)
            guard end > start else { return nil }
            return (start, end, segment.rate)
        }

        var boundaries = [lower, upper]
        for segment in clippedSegments {
            boundaries.append(segment.start)
            boundaries.append(segment.end)
        }
        boundaries.sort()

        var uniqueBoundaries: [Double] = []
        for boundary in boundaries where uniqueBoundaries.last.map({ abs($0 - boundary) > 0.000_001 }) ?? true {
            uniqueBoundaries.append(boundary)
        }

        var outputCursor = 0.0
        var built: [Piece] = []
        for index in 0..<(uniqueBoundaries.count - 1) {
            let start = uniqueBoundaries[index]
            let end = uniqueBoundaries[index + 1]
            guard end > start else { continue }
            let midpoint = start + (end - start) / 2
            let rate = clippedSegments.last(where: {
                midpoint >= $0.start && midpoint < $0.end
            })?.rate ?? 1
            let piece = Piece(
                sourceStart: start,
                sourceEnd: end,
                rate: max(
                    SpeedSegment.rateRange.lowerBound,
                    min(rate, SpeedSegment.rateRange.upperBound)
                ),
                outputStart: outputCursor
            )
            built.append(piece)
            outputCursor = piece.outputEnd
        }
        pieces = built
    }

    var duration: Double { pieces.last?.outputEnd ?? 0 }

    func outputOffset(forSourceTime sourceTime: Double) -> Double {
        guard let first = pieces.first, let last = pieces.last else { return 0 }
        let clamped = max(sourceStart, min(sourceTime, sourceEnd))
        if clamped <= first.sourceStart { return 0 }
        if clamped >= last.sourceEnd { return duration }

        guard let piece = pieces.first(where: { clamped <= $0.sourceEnd + 0.000_001 }) else {
            return duration
        }
        return piece.outputStart + (clamped - piece.sourceStart) / piece.rate
    }

    func sourceTime(forOutputOffset outputOffset: Double) -> Double {
        guard let first = pieces.first, let last = pieces.last else { return sourceStart }
        let clamped = max(0, min(outputOffset, duration))
        if clamped <= 0 { return first.sourceStart }
        if clamped >= duration { return last.sourceEnd }

        guard let piece = pieces.first(where: { clamped <= $0.outputEnd + 0.000_001 }) else {
            return sourceEnd
        }
        return piece.sourceStart + (clamped - piece.outputStart) * piece.rate
    }

    func rate(atSourceTime sourceTime: Double) -> Double {
        guard !pieces.isEmpty else { return 1 }
        let clamped = max(sourceStart, min(sourceTime, sourceEnd))
        return pieces.first(where: {
            clamped >= $0.sourceStart && clamped < $0.sourceEnd
        })?.rate ?? pieces.last?.rate ?? 1
    }

    func outputDuration(fromSourceTime start: Double, toSourceTime end: Double) -> Double {
        max(0, outputOffset(forSourceTime: end) - outputOffset(forSourceTime: start))
    }
}
