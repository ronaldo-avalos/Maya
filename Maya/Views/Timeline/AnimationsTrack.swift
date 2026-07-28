import SwiftUI

struct AnimationsTrack: View {
    @Bindable var project: Project
    let height: CGFloat
    let onSelectSegment: (ZoomSegment) -> Void

    @State private var hoverX: CGFloat?
    /// Set by a SegmentBlock during drag when its snapped time matches the playhead.
    /// We render a vertical guide line at that x coordinate as long as it is set.
    @State private var snapGuideX: CGFloat?
    /// Suppresses the hover-to-add affordance while an existing block is being
    /// moved or resized. Otherwise it flashes underneath the cursor as the
    /// block moves away from its model-backed position.
    @State private var isEditingSegment = false

    static let snapStep: Double = 0.25
    static let playheadSnapTolerance: Double = 0.15

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let duration = project.timelineDuration
            // Offset converting a segment's source-time startTime into a timeline-time x.
            let clipDisplayOffset = project.clipTimelineStart - project.trimStartTime

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )

                // Existing segments. Segments live in source coords; we shift them by
                // `clipDisplayOffset` so they appear under the clip's current timeline window.
                ForEach(project.animations) { segment in
                    let isLive = segment.endTime > project.trimStartTime && segment.startTime < project.trimEndTime
                    SegmentBlock(
                        segment: segment,
                        isSelected: project.selectedAnimationID == segment.id,
                        isLive: isLive,
                        trackWidth: width,
                        totalDuration: duration,
                        clipDisplayOffset: clipDisplayOffset,
                        playheadTime: project.currentSeconds,
                        height: height - 12,
                        onTap: {
                            project.selectedAnimationID = segment.id
                            onSelectSegment(segment)
                        },
                        onChange: { updated in
                            project.updateZoomSegment(updated)
                        },
                        onDelete: { project.removeZoomSegment(id: segment.id) },
                        onEditingChanged: { isEditingSegment = $0 },
                        onSnap: { snappedTime in
                            if let t = snappedTime, duration > 0 {
                                snapGuideX = CGFloat(t / duration) * width
                            } else {
                                snapGuideX = nil
                            }
                        }
                    )
                }

                // Snap guide: vertical accent line drawn at the snapped time during a drag.
                if let gx = snapGuideX {
                    Rectangle()
                        .fill(Color(red: 1.0, green: 0.82, blue: 0.10))
                        .frame(width: 1, height: height - 8)
                        .offset(x: gx - 0.5, y: 4)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // Hover-to-add: only when not over an existing segment.
                if !isEditingSegment, let hx = hoverX, duration > 0 {
                    let time = (Double(hx) / Double(width)) * duration
                    if project.segment(containing: time) == nil {
                        HoverAddButton(hx: hx, height: height) {
                            let snapped = Self.snap(time, toPlayhead: project.currentSeconds)
                            let segment = project.addZoomSegment(at: snapped)
                            onSelectSegment(segment)
                        }
                    }
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hoverX = max(0, min(p.x, width))
                case .ended:
                    hoverX = nil
                }
            }
        }
        .frame(height: height)
    }

    static func snap(_ t: Double, toPlayhead playheadTime: Double? = nil) -> Double {
        if let p = playheadTime, abs(t - p) < playheadSnapTolerance {
            return p
        }
        return (t / snapStep).rounded() * snapStep
    }
}

// MARK: - Time tooltip

struct TimeTooltip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            .fixedSize()
            .transition(.opacity)
    }
}

func formatTimestamp(_ t: Double) -> String {
    let safe = max(t, 0)
    let total = Int(safe)
    let m = total / 60
    let s = total % 60
    let cs = Int((safe - floor(safe)) * 100)
    return String(format: "%d:%02d.%02d", m, s, cs)
}

// MARK: - Segment block (movable + resizable)

private struct SegmentBlock: View {
    let segment: ZoomSegment
    let isSelected: Bool
    let isLive: Bool
    let trackWidth: CGFloat
    /// Timeline duration the track is mapped to (`project.timelineDuration`).
    let totalDuration: Double
    /// Constant offset to add to a source-time value to get a timeline-time value:
    /// `clipTimelineStart - trimStartTime`. Lets the block render at the right spot
    /// even as the clip is moved around on the timeline.
    let clipDisplayOffset: Double
    /// Playhead position in *timeline* coords (matches the on-screen ruler).
    let playheadTime: Double
    let height: CGFloat
    let onTap: () -> Void
    let onChange: (ZoomSegment) -> Void
    let onDelete: () -> Void
    let onEditingChanged: (Bool) -> Void
    /// Snap callback receives the *timeline* time it snapped to (or nil).
    let onSnap: (Double?) -> Void

    @State private var dragSnapshot: (start: Double, duration: Double)?
    /// Keeps high-frequency movement local; the final snapped value is committed
    /// to the project once the pointer is released.
    @State private var pendingSegment: ZoomSegment?
    @State private var pendingEdit: PendingEdit?
    @State private var isShowingPlayheadSnap = false
    @State private var tooltipText: String?
    @State private var isHovering: Bool = false

    private var renderedSegment: ZoomSegment {
        pendingSegment ?? segment
    }

    /// Timeline position to render this segment's left edge at.
    private var displayStartTime: Double { renderedSegment.startTime + clipDisplayOffset }

    private var startX: CGFloat {
        guard totalDuration > 0 else { return 0 }
        return CGFloat(displayStartTime / totalDuration) * trackWidth
    }

    private var blockWidth: CGFloat {
        guard totalDuration > 0 else { return 60 }
        return max(CGFloat(renderedSegment.duration / totalDuration) * trackWidth, 36)
    }

    var body: some View {
        ZStack {
            content
            // Left handle
            handle(alignment: .leading)
            // Right handle
            handle(alignment: .trailing)
        }
        .frame(width: blockWidth, height: height)
        .overlay(alignment: .top) {
            if let text = tooltipText {
                TimeTooltip(text: text)
                    .offset(y: -28)
                    .zIndex(10)
            }
        }
        .position(x: startX + blockWidth / 2, y: (height + 12) / 2)
        .brightness(isHovering && pendingSegment == nil ? 0.06 : 0)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Edit zoom") { onTap() }
            Button(role: .destructive) { onDelete() } label: { Label("Delete zoom", systemImage: "trash") }
        }
    }

    private var content: some View {
        VStack(spacing: 2) {
            Image(systemName: renderedSegment.focus.systemImage)
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 4) {
                Text(String(format: "%.1f×", renderedSegment.scale))
                Text("·")
                Text(String(format: "%.1fs", renderedSegment.duration))
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(hex: "#818CF8") ?? .indigo, Color(hex: "#6466FA") ?? .indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.white : Color.white.opacity(0.15),
                        lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        // When the panel is editing this segment, glow ring around the block makes the
        // connection between block and panel unambiguous.
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "#6466FA") ?? .accentColor, lineWidth: 2)
                .blur(radius: 6)
                .opacity(isSelected ? 0.85 : 0)
                .padding(-3)
                .allowsHitTesting(false)
        )
        .opacity(isLive ? 1.0 : 0.4)
        .saturation(isLive ? 1.0 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .gesture(
            DragGesture(
                minimumDistance: 3,
                coordinateSpace: .named("tracksSpace")
            )
                .onChanged { v in
                    let snapshot = dragSnapshot ?? (segment.startTime, segment.duration)
                    if dragSnapshot == nil {
                        dragSnapshot = snapshot
                        onEditingChanged(true)
                    }
                    let dt = (Double(v.translation.width) / Double(trackWidth)) * totalDuration
                    let raw = snapshot.start + dt
                    var s = segment
                    s.startTime = max(
                        0,
                        min(raw, max(totalDuration - clipDisplayOffset - s.duration, 0))
                    )
                    pendingSegment = s
                    pendingEdit = .move
                    let displayStart = s.startTime + clipDisplayOffset
                    let displayEnd = s.endTime + clipDisplayOffset
                    tooltipText = "\(formatTimestamp(displayStart)) → \(formatTimestamp(displayEnd))"
                    updatePlayheadSnap(for: displayStart)
                }
                .onEnded { _ in
                    commitPendingChange()
                }
        )
    }

    private func handle(alignment: HorizontalAlignment) -> some View {
        let isLeading = alignment == .leading
        return Capsule()
            .fill(Color.white.opacity(isSelected ? 0.7 : 0.32))
            .frame(width: 3, height: height * 0.55)
            .padding(.horizontal, 6)
            .background(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: isLeading ? .leading : .trailing)
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(
                    minimumDistance: 2,
                    coordinateSpace: .named("tracksSpace")
                )
                    .onChanged { v in
                        let snapshot = dragSnapshot ?? (segment.startTime, segment.duration)
                        if dragSnapshot == nil {
                            dragSnapshot = snapshot
                            onEditingChanged(true)
                        }
                        resize(
                            isLeading ? .leading : .trailing,
                            translation: v.translation.width,
                            snapshot: snapshot
                        )
                    }
                    .onEnded { _ in
                        commitPendingChange()
                    }
            )
    }

    private enum Edge { case leading, trailing }
    private enum PendingEdit { case move, leading, trailing }

    private func resize(
        _ edge: Edge,
        translation: CGFloat,
        snapshot snap: (start: Double, duration: Double)
    ) {
        let dt = (Double(translation) / Double(trackWidth)) * totalDuration
        var s = segment
        switch edge {
        case .leading:
            let endTime = snap.start + snap.duration
            let minimumStart = max(
                0,
                endTime - ZoomSegment.durationRange.upperBound
            )
            let maximumStart = endTime - ZoomSegment.durationRange.lowerBound
            s.startTime = max(minimumStart, min(snap.start + dt, maximumStart))
            s.duration = endTime - s.startTime
            pendingEdit = .leading
            let displayStart = s.startTime + clipDisplayOffset
            tooltipText = formatTimestamp(displayStart)
            updatePlayheadSnap(for: displayStart)
        case .trailing:
            let maxDur = min(totalDuration - clipDisplayOffset - s.startTime, ZoomSegment.durationRange.upperBound)
            s.duration = max(
                ZoomSegment.durationRange.lowerBound,
                min(snap.duration + dt, maxDur)
            )
            pendingEdit = .trailing
            let displayEnd = s.endTime + clipDisplayOffset
            tooltipText = "\(formatTimestamp(displayEnd)) · \(String(format: "%.2fs", s.duration))"
            updatePlayheadSnap(for: displayEnd)
        }
        pendingSegment = s
    }

    private func commitPendingChange() {
        if var committed = pendingSegment {
            let playheadSource = playheadTime - clipDisplayOffset
            switch pendingEdit {
            case .move:
                let maxStart = max(totalDuration - clipDisplayOffset - committed.duration, 0)
                committed.startTime = max(
                    0,
                    min(
                        AnimationsTrack.snap(
                            committed.startTime,
                            toPlayhead: playheadSource
                        ),
                        maxStart
                    )
                )

            case .leading:
                let fixedEnd = committed.endTime
                let minimumStart = max(
                    0,
                    fixedEnd - ZoomSegment.durationRange.upperBound
                )
                let maximumStart = fixedEnd - ZoomSegment.durationRange.lowerBound
                committed.startTime = max(
                    minimumStart,
                    min(
                        AnimationsTrack.snap(
                            committed.startTime,
                            toPlayhead: playheadSource
                        ),
                        maximumStart
                    )
                )
                committed.duration = fixedEnd - committed.startTime

            case .trailing:
                let minimumEnd = committed.startTime + ZoomSegment.durationRange.lowerBound
                let maximumEnd = min(
                    totalDuration - clipDisplayOffset,
                    committed.startTime + ZoomSegment.durationRange.upperBound
                )
                let endTime = max(
                    minimumEnd,
                    min(
                        AnimationsTrack.snap(
                            committed.endTime,
                            toPlayhead: playheadSource
                        ),
                        maximumEnd
                    )
                )
                committed.duration = endTime - committed.startTime

            case nil:
                break
            }
            onChange(committed)
        }
        pendingSegment = nil
        pendingEdit = nil
        dragSnapshot = nil
        tooltipText = nil
        updatePlayheadSnap(for: nil)
        onEditingChanged(false)
    }

    private func updatePlayheadSnap(for displayTime: Double?) {
        let shouldShow = displayTime.map {
            abs($0 - playheadTime) < AnimationsTrack.playheadSnapTolerance
        } ?? false
        guard shouldShow != isShowingPlayheadSnap else { return }
        isShowingPlayheadSnap = shouldShow
        onSnap(shouldShow ? playheadTime : nil)
    }
}

// MARK: - Hover add affordance

private struct HoverAddButton: View {
    let hx: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white, Color(hex: "#6466FA") ?? .indigo)
                .background(Circle().fill(.black.opacity(0.4)))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .position(x: hx, y: height / 2)
        .help("Add zoom event here")
        .transition(.opacity)
    }
}
