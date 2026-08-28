import CoreGraphics
import Foundation

enum TapStyle: String, Hashable, Sendable, CaseIterable, Identifiable {
    case ripple
    case pulse
    case ring

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ripple: "Ripple"
        case .pulse: "Pulse"
        case .ring: "Ring"
        }
    }

    var symbol: String {
        switch self {
        case .ripple: "dot.radiowaves.left.and.right"
        case .pulse: "circle.inset.filled"
        case .ring: "circle"
        }
    }

    var previewName: String {
        "tap-\(id)"
    }
}

/// A visualized press on the recorded screen. Position is normalized inside the
/// device's screen using a top-left origin, so it stays attached to the same UI
/// location across canvas sizes, device frames, zooms, and exports.
struct TapEvent: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var startTime: Double
    var duration: Double
    var position: CGPoint
    var style: TapStyle
    var diameterFraction: CGFloat
    var colorHex: String

    static let defaultDuration: Double = 0.65
    static let defaultDiameterFraction: CGFloat = 0.18
    static let durationRange: ClosedRange<Double> = 0.25...2.0
    static let diameterRange: ClosedRange<CGFloat> = 0.08...0.36

    var endTime: Double { startTime + duration }

    init(
        id: UUID = UUID(),
        startTime: Double,
        duration: Double = TapEvent.defaultDuration,
        position: CGPoint = CGPoint(x: 0.5, y: 0.5),
        style: TapStyle = .ripple,
        diameterFraction: CGFloat = TapEvent.defaultDiameterFraction,
        colorHex: String = "#6466FA"
    ) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.position = position
        self.style = style
        self.diameterFraction = diameterFraction
        self.colorHex = colorHex
        normalize()
    }

    mutating func normalize() {
        duration = max(Self.durationRange.lowerBound, min(duration, Self.durationRange.upperBound))
        diameterFraction = max(
            Self.diameterRange.lowerBound,
            min(diameterFraction, Self.diameterRange.upperBound)
        )
        position.x = max(0, min(position.x, 1))
        position.y = max(0, min(position.y, 1))
    }
}

struct TapFeedbackSample: Equatable, Sendable {
    let ringScale: CGFloat
    let ringOpacity: Double
    let coreScale: CGFloat
    let coreOpacity: Double
}

enum TapFeedbackSampler {
    /// Samples the shared tap animation used by the live preview and exporter.
    /// Returning nil means the event is not visible at the requested time.
    static func sample(at seconds: Double, event: TapEvent) -> TapFeedbackSample? {
        guard event.duration > 0,
              seconds >= event.startTime,
              seconds <= event.endTime else {
            return nil
        }

        let progress = max(0, min(1, (seconds - event.startTime) / event.duration))
        let appear = smoothstep(max(0, min(1, progress / 0.10)))
        let fade = 1 - smoothstep(max(0, min(1, (progress - 0.58) / 0.42)))
        let expansion = easeOutCubic(progress)

        return TapFeedbackSample(
            ringScale: CGFloat(0.32 + 0.68 * expansion),
            ringOpacity: appear * (1 - progress) * 0.92,
            coreScale: CGFloat(0.72 + 0.28 * easeOutBack(min(progress / 0.28, 1))),
            coreOpacity: appear * fade * 0.88
        )
    }

    private static func smoothstep(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }

    private static func easeOutCubic(_ value: Double) -> Double {
        1 - pow(1 - value, 3)
    }

    private static func easeOutBack(_ value: Double) -> Double {
        let c1 = 1.35
        let c3 = c1 + 1
        let t = value - 1
        return 1 + c3 * t * t * t + c1 * t * t
    }
}
