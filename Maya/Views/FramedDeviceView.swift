import AppKit
import SwiftUI

struct FramedDeviceView: View {
    @Bindable var project: Project
    let canvasSize: CGSize

    @State private var dragAnchor: CGSize?

    static let naturalHeightFraction: CGFloat = AnimationSampler.baseHeightFraction

    /// Drag/offset is normalized against the short side so feel stays consistent
    /// across canvas aspects (matches the compositor's use of `min(w, h)`).
    private var offsetReference: CGFloat {
        min(canvasSize.width, canvasSize.height)
    }

    /// For `.none` and `.generic` modes we don't have a frame PNG — the "phone
    /// box" follows the source video's own aspect so playback isn't letterboxed
    /// inside a fake hull.
    private var effectiveAspectRatio: CGFloat {
        switch project.deviceFrame.kind {
        case .none, .generic:
            let s = project.videoNaturalSize
            if s.width > 0 && s.height > 0 {
                return s.width / s.height
            }
            return project.deviceFrame.frameAspectRatio
        case .physical:
            return project.deviceFrame.frameAspectRatio
        }
    }

    /// Fits the device inside `naturalHeightFraction` of *both* canvas axes
    /// while preserving aspect. For portrait devices (iPhone, aspect < 1) the
    /// height is the binding constraint, matching the previous behavior; for
    /// landscape devices (MacBook, aspect > 1) the width becomes the constraint
    /// so the laptop never overflows the canvas.
    private var phoneSize: CGSize {
        let maxH = canvasSize.height * Self.naturalHeightFraction
        let maxW = canvasSize.width * Self.naturalHeightFraction
        let aspect = effectiveAspectRatio
        let w = min(maxW, maxH * aspect)
        let h = aspect > 0 ? w / aspect : maxH
        return CGSize(width: w, height: h)
    }

    private var screenRect: CGRect {
        project.deviceFrame.screenRect(in: phoneSize)
    }

    /// Absolute corner radius (in pt) used to mask the video.
    private var screenCornerRadius: CGFloat {
        switch project.deviceFrame.kind {
        case .physical:
            return project.deviceFrame.screenCornerRadiusNormalized * phoneSize.width
        case .none, .generic:
            return project.bareCornerRadius * min(screenRect.width, screenRect.height)
        }
    }

    private var screenCornerFraction: CGFloat {
        screenRect.width > 0 ? screenCornerRadius / screenRect.width : 0
    }

    /// Stroke width for the generic device bezel, scaled with the phone box.
    /// 0 when the user dialed the slider all the way down.
    private var bezelWidth: CGFloat {
        max(0, phoneSize.width * project.bareBezelWidth)
    }

    private var bezelColor: Color {
        Color(hex: project.bareBezelHex) ?? .black
    }

    private var sampled: AnimationSample {
        // `currentSeconds` is in timeline coords but the sampler compares against
        // animations stored in source coords. Convert before sampling so animations
        // fire on the right source frame regardless of where the clip sits.
        AnimationSampler.sample(
            at: project.timelineToSource(project.currentSeconds),
            segments: project.animations,
            baseScale: project.scale,
            baseOffset: project.offset
        )
    }

    private var sourceSeconds: Double {
        project.timelineToSource(project.currentSeconds)
    }

    var body: some View {
        let s = sampled
        let ref = offsetReference
        ZStack(alignment: .topLeading) {
            // 1. Drop shadow caster sitting *behind* the video. We render the
            //    silhouette in its own layer (a duplicate of the device frame
            //    PNG, or a rounded rect when no PNG is in play) and attach the
            //    `.shadow()` only to it. Keeping the shadow off the parent
            //    ZStack stops SwiftUI from mixing the AVPlayerLayer-hosted
            //    video into the shadow mask — which used to make the shadow
            //    look like it was applied on top of the screen content.
            shadowCaster

            // 2. Video.
            VideoPlayerNSView(
                player: project.player,
                cornerRadiusFraction: screenCornerFraction
            )
            .frame(width: screenRect.width, height: screenRect.height)
            .offset(x: screenRect.minX, y: screenRect.minY)

            // 3. Tap feedback is composited inside the screen before the frame,
            //    so the physical bezel/notch masks effects near the edges.
            TapFeedbackLayer(events: project.tapEvents, seconds: sourceSeconds)
                .frame(width: screenRect.width, height: screenRect.height)
                .clipped()
                .offset(x: screenRect.minX, y: screenRect.minY)

            // 4. Device frame on top of the video so its bezel masks the
            //    video bleed at the screen edges.
            switch project.deviceFrame.kind {
            case .physical:
                DeviceFrameOverlay(frame: project.deviceFrame)
                    .frame(width: phoneSize.width, height: phoneSize.height)
                    .allowsHitTesting(false)
            case .generic:
                if bezelWidth > 0 {
                    genericBezel
                        .allowsHitTesting(false)
                }
            case .none:
                EmptyView()
            }

            // 5. When editing a tap, capture clicks inside the visible screen
            //    and show a positioning marker that is not included in export.
            if let selectedID = project.selectedTapEventID,
               let event = project.tapEvents.first(where: { $0.id == selectedID }) {
                TapPlacementOverlay(event: event) { position in
                    project.positionTapEvent(id: selectedID, at: position)
                }
                .frame(width: screenRect.width, height: screenRect.height)
                .clipped()
                .offset(x: screenRect.minX, y: screenRect.minY)
            }
        }
        .frame(width: phoneSize.width, height: phoneSize.height)
        .scaleEffect(s.scale)
        .offset(
            x: s.offsetX * ref,
            y: s.offsetY * ref
        )
        .gesture(
            DragGesture()
                .onChanged { value in
                    if dragAnchor == nil { dragAnchor = project.offset }
                    let anchor = dragAnchor ?? .zero
                    project.offset = CGSize(
                        width: anchor.width + value.translation.width / ref,
                        height: anchor.height + value.translation.height / ref
                    )
                }
                .onEnded { _ in dragAnchor = nil }
        )
    }

    /// Silhouette used purely to drop a shadow behind the device. Matches the
    /// visible frame so the halo follows the real outline. The frame PNG is
    /// drawn again on top in the main ZStack, which hides this copy.
    @ViewBuilder
    private var shadowCaster: some View {
        if project.shadow.enabled, project.shadow.opacity > 0 {
            let shadowColor = (Color(hex: project.shadow.colorHex) ?? .black)
                .opacity(project.shadow.opacity)
            Group {
                switch project.deviceFrame.kind {
                case .physical:
                    DeviceFrameOverlay(frame: project.deviceFrame)
                        .frame(width: phoneSize.width, height: phoneSize.height)
                case .generic:
                    RoundedRectangle(cornerRadius: screenCornerRadius + bezelWidth / 2)
                        .fill(Color.black)
                        .frame(width: phoneSize.width + bezelWidth, height: phoneSize.height + bezelWidth)
                        .offset(x: -bezelWidth / 2, y: -bezelWidth / 2)
                case .none:
                    RoundedRectangle(cornerRadius: screenCornerRadius)
                        .fill(Color.black)
                        .frame(width: screenRect.width, height: screenRect.height)
                        .offset(x: screenRect.minX, y: screenRect.minY)
                }
            }
            .shadow(
                color: shadowColor,
                radius: project.shadow.radius,
                x: project.shadow.offsetX,
                y: project.shadow.offsetY
            )
        }
    }

    /// Stroke positioned so its INNER edge meets the video bounds and the
    /// stroke grows outward from there — matches the user's "border outside,
    /// not inside" requirement.
    private var genericBezel: some View {
        let w = bezelWidth
        // Stroked radius is the inner radius + half stroke so the stroke's
        // inner edge coincides with the video's rounded corner.
        return RoundedRectangle(cornerRadius: screenCornerRadius + w / 2)
            .stroke(bezelColor, lineWidth: w)
            .frame(width: phoneSize.width + w, height: phoneSize.height + w)
            .offset(x: -w / 2, y: -w / 2)
            .shadow(color: .black.opacity(0.18), radius: w * 0.6, y: w * 0.2)
    }
}

struct DeviceFrameOverlay: View {
    let frame: DeviceFrame

    var body: some View {
        if let nsImage = NSImage(named: frame.imageName), nsImage.size.width > 1 {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
        } else {
            PlaceholderFrameView(frame: frame)
        }
    }
}

struct PlaceholderFrameView: View {
    let frame: DeviceFrame

    var body: some View {
        GeometryReader { g in
            let size = g.size
            let bezelRadius = size.width * 0.135
            let screenRect = frame.screenRect(in: size)
            let screenRadius = frame.screenCornerRadius(in: size)

            ZStack {
                RoundedRectangle(cornerRadius: bezelRadius)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.16), Color(white: 0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: bezelRadius)
                            .stroke(
                                LinearGradient(
                                    colors: [Color(white: 0.45), Color(white: 0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: max(1, size.width * 0.004)
                            )
                    )

                RoundedRectangle(cornerRadius: screenRadius)
                    .frame(width: screenRect.width, height: screenRect.height)
                    .position(x: screenRect.midX, y: screenRect.midY)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.35), radius: size.width * 0.04, x: 0, y: size.width * 0.02)
        }
    }
}
