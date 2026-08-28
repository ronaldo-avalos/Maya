import SwiftUI

/// Visual-only tap layer shared by the editor preview. The layer is placed
/// inside the device's screen rect, so normalized positions remain stable.
struct TapFeedbackLayer: View {
    let events: [TapEvent]
    let seconds: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let shortSide = min(size.width, size.height)

            ZStack(alignment: .topLeading) {
                ForEach(events) { event in
                    if let sample = TapFeedbackSampler.sample(at: seconds, event: event) {
                        TapFeedbackEffect(
                            event: event,
                            sample: sample,
                            diameter: shortSide * event.diameterFraction
                        )
                        .position(
                            x: event.position.x * size.width,
                            y: event.position.y * size.height
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Editor-only hit target and selection marker. This never appears in exports.
struct TapPlacementOverlay: View {
    let event: TapEvent
    let onPosition: (CGPoint) -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let markerDiameter = max(28, min(size.width, size.height) * event.diameterFraction)

            ZStack(alignment: .topLeading) {
                Color.clear

                ZStack {
                    Circle()
                        .stroke(
                            Color.white,
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: markerDiameter + 8, height: 1)
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 1, height: markerDiameter + 8)
                    Circle()
                        .fill(Color.black.opacity(0.7))
                        .frame(width: 7, height: 7)
                }
                .frame(width: markerDiameter, height: markerDiameter)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .position(
                    x: event.position.x * size.width,
                    y: event.position.y * size.height
                )
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                guard size.width > 0, size.height > 0 else { return }
                onPosition(
                    CGPoint(
                        x: max(0, min(point.x / size.width, 1)),
                        y: max(0, min(point.y / size.height, 1))
                    )
                )
            }
        }
        .help("Click to position the tap")
    }
}

/// A lightweight preset demonstration that uses the same sampler and shapes as
/// the canvas and exporter, avoiding recorded GIF assets drifting out of date.
struct TapStylePreview: View {
    let style: TapStyle
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let eventDuration = TapEvent.defaultDuration
    private let cycleDuration = 1.05

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            GeometryReader { proxy in
                let diameter = min(proxy.size.width, proxy.size.height) * 0.62
                let event = TapEvent(
                    startTime: 0,
                    duration: eventDuration,
                    style: style,
                    diameterFraction: TapEvent.defaultDiameterFraction,
                    colorHex: "#EC4899"
                )
                let seconds = reduceMotion
                    ? eventDuration * 0.28
                    : timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: cycleDuration)

                ZStack {
                    LinearGradient(
                        colors: [accent.opacity(0.18), accent.opacity(0.045)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Circle()
                        .fill(accent.opacity(0.12))
                        .frame(width: diameter * 0.18, height: diameter * 0.18)

                    if let sample = TapFeedbackSampler.sample(at: seconds, event: event) {
                        TapFeedbackEffect(event: event, sample: sample, diameter: diameter)
                    }
                }
            }
        }
    }
}

struct TapFeedbackEffect: View {
    let event: TapEvent
    let sample: TapFeedbackSample
    let diameter: CGFloat

    private var color: Color {
        Color(hex: event.colorHex) ?? .white
    }

    var body: some View {
        ZStack {
            switch event.style {
            case .ripple:
                expandingRing(lineWidth: max(2, diameter * 0.055))
                Circle()
                    .fill(color.opacity(sample.coreOpacity))
                    .frame(width: diameter * 0.22, height: diameter * 0.22)
                    .scaleEffect(sample.coreScale)

            case .pulse:
                Circle()
                    .fill(color.opacity(sample.coreOpacity * 0.82))
                    .frame(width: diameter * 0.58, height: diameter * 0.58)
                    .scaleEffect(sample.coreScale)
                expandingRing(lineWidth: max(2, diameter * 0.035), opacityMultiplier: 0.42)

            case .ring:
                expandingRing(lineWidth: max(2, diameter * 0.07))
                Circle()
                    .stroke(color.opacity(sample.coreOpacity * 0.72), lineWidth: max(1.5, diameter * 0.035))
                    .frame(width: diameter * 0.36, height: diameter * 0.36)
                    .scaleEffect(sample.coreScale)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func expandingRing(
        lineWidth: CGFloat,
        opacityMultiplier: Double = 1
    ) -> some View {
        Circle()
            .stroke(color.opacity(sample.ringOpacity * opacityMultiplier), lineWidth: lineWidth)
            .frame(width: diameter, height: diameter)
            .scaleEffect(sample.ringScale)
    }
}
