import SwiftUI

struct TapEventsTrack: View {
    @Bindable var project: Project
    let height: CGFloat
    let onSelectTap: (TapEvent) -> Void

    @State private var hoverX: CGFloat?
    @State private var snapGuideX: CGFloat?

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

                if let hoverX, duration > 0 {
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
    let onSnap: (Double?) -> Void

    @State private var dragStartTime: Double?
    @State private var tooltipText: String?
    @State private var isHovering = false

    private var displayStartTime: Double {
        event.startTime + clipDisplayOffset
    }

    private var startX: CGFloat {
        guard totalDuration > 0 else { return 0 }
        return CGFloat(displayStartTime / totalDuration) * trackWidth
    }

    private var blockWidth: CGFloat {
        guard totalDuration > 0 else { return 44 }
        return max(CGFloat(event.duration / totalDuration) * trackWidth, 38)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(String(format: "%.2fs", event.duration))
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
        .brightness(isHovering ? 0.07 : 0)
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
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if dragStartTime == nil {
                        dragStartTime = event.startTime
                    }
                    let delta = (Double(value.translation.width) / Double(trackWidth))
                        * totalDuration
                    let rawStart = (dragStartTime ?? event.startTime) + delta
                    let playheadSource = playheadTime - clipDisplayOffset
                    let snapped = AnimationsTrack.snap(rawStart, toPlayhead: playheadSource)

                    var updated = event
                    updated.startTime = max(
                        0,
                        min(snapped, max(sourceDuration - event.duration, 0))
                    )
                    onChange(updated)

                    let displayStart = updated.startTime + clipDisplayOffset
                    tooltipText = formatTimestamp(displayStart)
                    onSnap(abs(displayStart - playheadTime) < 0.001 ? playheadTime : nil)
                }
                .onEnded { _ in
                    dragStartTime = nil
                    tooltipText = nil
                    onSnap(nil)
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
