import SwiftUI

struct TapEventsTrack: View {
    @Bindable var project: Project
    let height: CGFloat
    let onSelectTap: (TapEvent) -> Void

    @State private var hoverX: CGFloat?
    @State private var snapGuideX: CGFloat?
    /// Suppresses the hover-to-add affordance while an existing block is being
    /// moved. Otherwise it flashes underneath the cursor as the block moves away
    /// from its model-backed position. Mirrors `AnimationsTrack`.
    @State private var isEditingEvent = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let duration = project.timelineDuration
            let clipDisplayOffset = project.clipTimelineStart - project.trimStartTime

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )

                ForEach(project.tapEvents) { event in
                    let isLive = event.endTime > project.trimStartTime
                        && event.startTime < project.trimEndTime

                    TapEventBlock(
                        event: event,
                        isSelected: project.selectedTapEventID == event.id,
                        isLive: isLive,
                        trackWidth: width,
                        totalDuration: duration,
                        sourceDuration: project.durationSeconds,
                        clipDisplayOffset: clipDisplayOffset,
                        playheadTime: project.currentSeconds,
                        height: height - 8,
                        onTap: {
                            project.selectedTapEventID = event.id
                            onSelectTap(event)
                        },
                        onChange: project.updateTapEvent,
                        onDelete: { project.removeTapEvent(id: event.id) },
                        onEditingChanged: { isEditingEvent = $0 },
                        onSnap: { snappedTime in
                            if let snappedTime, duration > 0 {
                                snapGuideX = CGFloat(snappedTime / duration) * width
                            } else {
                                snapGuideX = nil
                            }
                        }
                    )
                }

                if let snapGuideX {
                    Rectangle()
                        .fill(Color(red: 1.0, green: 0.82, blue: 0.10))
                        .frame(width: 1, height: height - 6)
                        .offset(x: snapGuideX - 0.5, y: 3)
                        .allowsHitTesting(false)
                }

                if !isEditingEvent, let hoverX, duration > 0 {
                    let time = (Double(hoverX) / Double(width)) * duration
                    if project.tapEvent(containing: time) == nil {
                        TapHoverAddButton(x: hoverX, height: height) {
                            let snapped = AnimationsTrack.snap(
                                time,
                                toPlayhead: project.currentSeconds
                            )
                            let event = project.addTapEvent(at: snapped)
                            onSelectTap(event)
                        }
                    }
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverX = max(0, min(point.x, width))
                case .ended:
                    hoverX = nil
                }
            }
        }
        .frame(height: height)
    }
}

private struct TapEventBlock: View {
    let event: TapEvent
    let isSelected: Bool
    let isLive: Bool
    let trackWidth: CGFloat
    let totalDuration: Double
    let sourceDuration: Double
    let clipDisplayOffset: Double
    let playheadTime: Double
    let height: CGFloat
    let onTap: () -> Void
    let onChange: (TapEvent) -> Void
    let onDelete: () -> Void
    let onEditingChanged: (Bool) -> Void
    let onSnap: (Double?) -> Void

    @State private var dragStartTime: Double?
    /// Keeps high-frequency movement local; the final snapped value is committed
    /// to the project once the pointer is released.
    @State private var pendingEvent: TapEvent?
    @State private var isShowingPlayheadSnap = false
    @State private var tooltipText: String?
    @State private var isHovering = false

    private var renderedEvent: TapEvent {
        pendingEvent ?? event
    }

    private var displayStartTime: Double {
        renderedEvent.startTime + clipDisplayOffset
    }

    private var startX: CGFloat {
        guard totalDuration > 0 else { return 0 }
        return CGFloat(displayStartTime / totalDuration) * trackWidth
    }

    private var blockWidth: CGFloat {
        guard totalDuration > 0 else { return 44 }
        return max(CGFloat(renderedEvent.duration / totalDuration) * trackWidth, 38)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(String(format: "%.2fs", renderedEvent.duration))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(width: blockWidth, height: height)
        .background(
            LinearGradient(
                colors: [
                    Color(hex: "#F472B6") ?? .pink,
                    Color(hex: "#EC4899") ?? .pink
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    isSelected ? Color.white : Color.white.opacity(0.15),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color(hex: "#EC4899") ?? .pink, lineWidth: 2)
                .blur(radius: 6)
                .opacity(isSelected ? 0.85 : 0)
                .padding(-3)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
        .opacity(isLive ? 1 : 0.4)
        .saturation(isLive ? 1 : 0.5)
        .brightness(isHovering && pendingEvent == nil ? 0.07 : 0)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovering = $0 }
        .overlay(alignment: .top) {
            if let tooltipText {
                TimeTooltip(text: tooltipText)
                    .offset(y: -28)
                    .zIndex(10)
            }
        }
        .position(x: startX + blockWidth / 2, y: height / 2 + 4)
        .gesture(
            DragGesture(
                minimumDistance: 3,
                coordinateSpace: .named("tracksSpace")
            )
                .onChanged { value in
                    let startTime = dragStartTime ?? event.startTime
                    if dragStartTime == nil {
                        dragStartTime = startTime
                        onEditingChanged(true)
                    }
                    let delta = (Double(value.translation.width) / Double(trackWidth))
                        * totalDuration
                    let rawStart = startTime + delta

                    var updated = event
                    updated.startTime = clampedStart(rawStart, duration: updated.duration)
                    pendingEvent = updated

                    let displayStart = updated.startTime + clipDisplayOffset
                    tooltipText = formatTimestamp(displayStart)
                    updatePlayheadSnap(for: displayStart)
                }
                .onEnded { _ in
                    commitPendingChange()
                }
        )
        .contextMenu {
            Button("Edit tap") { onTap() }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete tap", systemImage: "trash")
            }
        }
    }

    /// Keeps the event inside the source video regardless of where the clip
    /// currently sits on the timeline.
    private func clampedStart(_ start: Double, duration: Double) -> Double {
        max(0, min(start, max(sourceDuration - duration, 0)))
    }

    private func commitPendingChange() {
        if var committed = pendingEvent {
            let playheadSource = playheadTime - clipDisplayOffset
            committed.startTime = clampedStart(
                AnimationsTrack.snap(committed.startTime, toPlayhead: playheadSource),
                duration: committed.duration
            )
            onChange(committed)
        }
        pendingEvent = nil
        dragStartTime = nil
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

private struct TapHoverAddButton: View {
    let x: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(hex: "#EC4899") ?? .pink))
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.55), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .position(x: x, y: height / 2)
        .help("Add tap event here")
    }
}
