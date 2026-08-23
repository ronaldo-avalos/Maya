import AppKit
import SwiftUI

struct SpeedTrack: View {
    @Bindable var project: Project
    let height: CGFloat
    let onSelectSegment: (SpeedSegment) -> Void

    @State private var hoverX: CGFloat?
    @State private var snapGuideX: CGFloat?
    @State private var isEditingSegment = false

    private let accent = Color(hex: "#14B8A6") ?? .teal

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let duration = project.timelineDuration

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )

                ForEach(project.speedSegments) { segment in
                    let isLive = segment.endTime > project.trimStartTime
                        && segment.startTime < project.trimEndTime
                    SpeedSegmentBlock(
                        project: project,
                        segment: segment,
                        isSelected: project.selectedSpeedSegmentID == segment.id,
                        isLive: isLive,
                        trackWidth: width,
                        totalDuration: duration,
                        height: height - 8,
                        onTap: {
                            project.selectedSpeedSegmentID = segment.id
                            onSelectSegment(segment)
                        },
                        onChange: project.updateSpeedSegment,
                        onDelete: { project.removeSpeedSegment(id: segment.id) },
                        onEditingChanged: { isEditingSegment = $0 },
                        onSnap: { time in
                            if let time, duration > 0 {
                                snapGuideX = CGFloat(time / duration) * width
                            } else {
                                snapGuideX = nil
                            }
                        }
                    )
                }

                if let snapGuideX {
                    Rectangle()
                        .fill(accent)
                        .frame(width: 1, height: height - 6)
                        .offset(x: snapGuideX - 0.5, y: 3)
                        .allowsHitTesting(false)
                }

                if !isEditingSegment, let hoverX, duration > 0 {
                    let time = Double(hoverX / width) * duration
                    if project.speedSegment(containing: time) == nil,
                       time >= project.clipTimelineStart,
                       time < project.clipTimelineEnd {
                        Button {
                            let snapped = AnimationsTrack.snap(time, toPlayhead: project.currentSeconds)
                            if let segment = project.addSpeedSegment(at: snapped) {
                                onSelectSegment(segment)
                            }
                        } label: {
                            Image(systemName: "speedometer")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(accent))
                                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                        .position(x: hoverX, y: height / 2)
                        .help("Add speed segment here")
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

private struct SpeedSegmentBlock: View {
    @Bindable var project: Project
    let segment: SpeedSegment
    let isSelected: Bool
    let isLive: Bool
    let trackWidth: CGFloat
    let totalDuration: Double
    let height: CGFloat
    let onTap: () -> Void
    let onChange: (SpeedSegment) -> Void
    let onDelete: () -> Void
    let onEditingChanged: (Bool) -> Void
    let onSnap: (Double?) -> Void

    @State private var snapshot: DragSnapshot?
    @State private var pendingSegment: SpeedSegment?
    @State private var pendingEdit: PendingEdit?
    @State private var tooltipText: String?
    @State private var isHovering = false

    private let accent = Color(hex: "#14B8A6") ?? .teal

    private struct DragSnapshot {
        let segment: SpeedSegment
        let displayStart: Double
        let displayEnd: Double
    }

    private enum PendingEdit: Equatable { case move, leading, trailing }

    private var renderedSegment: SpeedSegment { pendingSegment ?? segment }

    private var renderedTimeline: SpeedTimeline {
        let segments = project.speedSegments.map {
            $0.id == renderedSegment.id ? renderedSegment : $0
        }
        return SpeedTimeline(
            sourceStart: project.trimStartTime,
            sourceEnd: project.trimEndTime,
            segments: segments
        )
    }

    private var displayStart: Double {
        project.clipTimelineStart
            + renderedTimeline.outputOffset(forSourceTime: renderedSegment.startTime)
    }

    private var displayEnd: Double {
        project.clipTimelineStart
            + renderedTimeline.outputOffset(forSourceTime: renderedSegment.endTime)
    }

    private var startX: CGFloat {
        guard totalDuration > 0 else { return 0 }
        return CGFloat(displayStart / totalDuration) * trackWidth
    }

    private var blockWidth: CGFloat {
        guard totalDuration > 0 else { return 40 }
        return max(CGFloat((displayEnd - displayStart) / totalDuration) * trackWidth, 40)
    }

    var body: some View {
        ZStack {
            content
            handle(isLeading: true)
            handle(isLeading: false)
        }
        .frame(width: blockWidth, height: height)
        .overlay(alignment: .top) {
            if let tooltipText {
                TimeTooltip(text: tooltipText)
                    .offset(y: -28)
                    .zIndex(10)
            }
        }
        .position(x: startX + blockWidth / 2, y: height / 2 + 4)
        .brightness(isHovering && pendingSegment == nil ? 0.07 : 0)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Edit speed") { onTap() }
            Button(role: .destructive, action: onDelete) {
                Label("Delete speed segment", systemImage: "trash")
            }
        }
    }

    private var content: some View {
        HStack(spacing: 5) {
            Image(systemName: "speedometer")
                .font(.system(size: 11, weight: .semibold))
            Text(String(format: "%.2g×", renderedSegment.rate))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [accent.opacity(0.82), accent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? Color.white : Color.white.opacity(0.16), lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
        .opacity(isLive ? 1 : 0.4)
        .saturation(isLive ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("tracksSpace"))
                .onChanged { value in
                    let snap = beginSnapshotIfNeeded()
                    let delta = Double(value.translation.width / trackWidth) * totalDuration
                    let desiredDisplayStart = snap.displayStart + delta
                    var updated = snap.segment
                    updated.startTime = project.timelineToSource(desiredDisplayStart)
                    updated.startTime = max(
                        project.trimStartTime,
                        min(updated.startTime, project.trimEndTime - updated.duration)
                    )
                    pendingSegment = updated
                    pendingEdit = .move
                    tooltipText = "\(formatTimestamp(displayStart)) → \(formatTimestamp(displayEnd))"
                    updateSnapGuide(for: displayStart)
                }
                .onEnded { _ in commitPending() }
        )
    }

    private func handle(isLeading: Bool) -> some View {
        Capsule()
            .fill(Color.white.opacity(isSelected ? 0.72 : 0.34))
            .frame(width: 3, height: height * 0.55)
            .padding(.horizontal, 6)
            .background(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: isLeading ? .leading : .trailing)
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("tracksSpace"))
                    .onChanged { value in
                        let snap = beginSnapshotIfNeeded()
                        let delta = Double(value.translation.width / trackWidth) * totalDuration
                        var updated = snap.segment
                        if isLeading {
                            let desiredDisplayStart = snap.displayStart + delta
                            let sourceStart = project.timelineToSource(desiredDisplayStart)
                            let maximumStart = snap.segment.endTime - SpeedSegment.minimumDuration
                            updated.startTime = max(project.trimStartTime, min(sourceStart, maximumStart))
                            updated.duration = snap.segment.endTime - updated.startTime
                            pendingEdit = .leading
                            pendingSegment = updated
                            tooltipText = formatTimestamp(displayStart)
                            updateSnapGuide(for: displayStart)
                        } else {
                            let desiredDisplayEnd = snap.displayEnd + delta
                            let sourceEnd = project.timelineToSource(desiredDisplayEnd)
                            let minimumEnd = snap.segment.startTime + SpeedSegment.minimumDuration
                            let end = max(minimumEnd, min(sourceEnd, project.trimEndTime))
                            updated.duration = end - snap.segment.startTime
                            pendingEdit = .trailing
                            pendingSegment = updated
                            tooltipText = formatTimestamp(displayEnd)
                            updateSnapGuide(for: displayEnd)
                        }
                    }
                    .onEnded { _ in commitPending() }
            )
    }

    private func beginSnapshotIfNeeded() -> DragSnapshot {
        if let snapshot { return snapshot }
        let newSnapshot = DragSnapshot(
            segment: segment,
            displayStart: project.sourceToTimeline(segment.startTime),
            displayEnd: project.sourceToTimeline(segment.endTime)
        )
        snapshot = newSnapshot
        onEditingChanged(true)
        return newSnapshot
    }

    private func commitPending() {
        if var pendingSegment {
            switch pendingEdit {
            case .move, .leading:
                let snapped = AnimationsTrack.snap(displayStart, toPlayhead: project.currentSeconds)
                let sourceStart = project.timelineToSource(snapped)
                if pendingEdit == .leading {
                    let fixedEnd = pendingSegment.endTime
                    pendingSegment.startTime = min(sourceStart, fixedEnd - SpeedSegment.minimumDuration)
                    pendingSegment.duration = fixedEnd - pendingSegment.startTime
                } else {
                    pendingSegment.startTime = sourceStart
                }
            case .trailing:
                let snapped = AnimationsTrack.snap(displayEnd, toPlayhead: project.currentSeconds)
                let sourceEnd = project.timelineToSource(snapped)
                pendingSegment.duration = max(
                    SpeedSegment.minimumDuration,
                    sourceEnd - pendingSegment.startTime
                )
            case nil:
                break
            }
            onChange(pendingSegment)
        }
        pendingSegment = nil
        pendingEdit = nil
        snapshot = nil
        tooltipText = nil
        onSnap(nil)
        onEditingChanged(false)
    }

    private func updateSnapGuide(for displayTime: Double) {
        onSnap(abs(displayTime - project.currentSeconds) < AnimationsTrack.playheadSnapTolerance
            ? project.currentSeconds
            : nil)
    }
}
