import AVFoundation
import AppKit
import CoreMedia
import SwiftUI

struct TimelineView: View {
    @Bindable var project: Project
    let onSelectSegment: (ZoomSegment) -> Void
    let onSelectTap: (TapEvent) -> Void
    let onSelectSpeed: (SpeedSegment) -> Void

    @State private var isScrubbing: Bool = false

    private let rowLabelWidth: CGFloat = 96
    private let rulerHeight: CGFloat = 20
    private let zoomsHeight: CGFloat = 60
    private let tapsHeight: CGFloat = 44
    private let speedsHeight: CGFloat = 44
    private let videoHeight: CGFloat = 56
    private let thumbnailCount: Int = 18

    var body: some View {
        VStack(spacing: 0) {
            TimelineToolbar(project: project)
            Divider().opacity(0.4)
            HStack(alignment: .top, spacing: 12) {
                rowLabels
                tracks
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.black.opacity(0.35))
    }

    private var rowLabels: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Space matching the ruler row
            Color.clear.frame(height: rulerHeight)

            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("Zooms")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(height: zoomsHeight, alignment: .center)

            HStack(spacing: 6) {
                Image(systemName: "hand.tap.fill")
                Text("Taps")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(height: tapsHeight, alignment: .center)

            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                Text("Speed")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(height: speedsHeight, alignment: .center)

            HStack(spacing: 6) {
                Image(systemName: "iphone")
                Text(project.deviceFrame.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(height: videoHeight, alignment: .center)
        }
        .frame(width: rowLabelWidth, alignment: .leading)
    }

    private var tracks: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let duration = project.timelineDuration
            let totalHeight = rulerHeight + zoomsHeight + tapsHeight + speedsHeight + videoHeight + 16

            ZStack(alignment: .topLeading) {
                VStack(spacing: 4) {
                    TimeRuler(duration: duration, width: width, height: rulerHeight)
                    AnimationsTrack(
                        project: project,
                        height: zoomsHeight,
                        onSelectSegment: onSelectSegment
                    )
                    TapEventsTrack(
                        project: project,
                        height: tapsHeight,
                        onSelectTap: onSelectTap
                    )
                    SpeedTrack(
                        project: project,
                        height: speedsHeight,
                        onSelectSegment: onSelectSpeed
                    )
                    TrimmableVideoClip(
                        project: project,
                        height: videoHeight,
                        thumbnailCount: thumbnailCount
                    )
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { point in
                    if duration > 0 {
                        let raw = Double(point.x / width) * duration
                        project.seek(to: raw)
                    }
                }

                // Draggable playhead with time tooltip. Position is in timeline coords.
                if duration > 0 {
                    let x = CGFloat(project.currentSeconds / duration) * width
                    Playhead(
                        height: totalHeight,
                        timeText: isScrubbing ? formatTimestamp(project.currentSeconds) : nil
                    )
                    .position(x: x, y: totalHeight / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("tracksSpace"))
                            .onChanged { v in
                                guard duration > 0 else { return }
                                isScrubbing = true
                                let t = max(0, min(Double(v.location.x / width) * duration, duration))
                                project.seek(to: t)
                            }
                            .onEnded { _ in isScrubbing = false }
                    )
                }
            }
            .coordinateSpace(name: "tracksSpace")
        }
        .frame(height: rulerHeight + zoomsHeight + tapsHeight + speedsHeight + videoHeight + 16)
    }

}

private struct TimeRuler: View {
    let duration: Double
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Canvas { ctx, size in
            guard duration > 0 else { return }
            let major = majorInterval(duration: duration)
            let minor = major / 4

            // Minor ticks first (drawn behind majors).
            var t = 0.0
            while t <= duration {
                let x = CGFloat(t / duration) * size.width
                if !nearlyMultiple(t, of: major) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height - 3))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(path, with: .color(.white.opacity(0.22)), lineWidth: 1)
                }
                t += minor
            }

            // Major ticks + labels.
            t = 0.0
            while t <= duration {
                let x = CGFloat(t / duration) * size.width
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height - 6))
                path.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(path, with: .color(.white.opacity(0.55)), lineWidth: 1)

                ctx.draw(
                    Text(format(time: t))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.75)),
                    at: CGPoint(x: x, y: 4),
                    anchor: .top
                )
                t += major
            }
        }
        .frame(width: width, height: height)
    }

    private func majorInterval(duration: Double) -> Double {
        switch duration {
        case ..<10: 1
        case ..<30: 2
        case ..<90: 5
        case ..<300: 15
        default: 30
        }
    }

    /// Treats values within a tiny epsilon as multiples — guards against floating drift.
    private func nearlyMultiple(_ t: Double, of step: Double) -> Bool {
        guard step > 0 else { return false }
        let r = t.truncatingRemainder(dividingBy: step)
        return r < 0.001 || abs(r - step) < 0.001
    }

    private func format(time t: Double) -> String {
        let total = Int(t.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Compact transport bar above the tracks. Play/pause, current time, total/trimmed duration,
/// trim badge with reset, and a mute toggle. Kept slim so the timeline still has room.
private struct TimelineToolbar: View {
    @Bindable var project: Project

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { project.togglePlayback() }) {
                Image(systemName: project.player?.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .help("Play/Pause (space)")

            HStack(spacing: 4) {
                Text(formatTimestamp(project.currentSeconds))
                    .foregroundStyle(.white.opacity(0.95))
                Text("/")
                    .foregroundStyle(.white.opacity(0.5))
                Text(formatTimestamp(displayedDuration))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))

            addZoomButton
            addTapButton
            addSpeedButton

            if project.isTrimmed {
                trimBadge
            }

            Spacer()

            HStack(spacing: 10) {
                shortcutHint("I", description: "Mark in")
                shortcutHint("O", description: "Mark out")
                shortcutHint("⌫", description: "Reset trim")
            }
            .help("Keyboard shortcuts")

            Button(action: { project.toggleMute() }) {
                Image(systemName: project.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(project.isMuted ? "Unmute (m)" : "Mute (m)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var displayedDuration: Double {
        project.timelineDuration
    }

    /// Adds a zoom segment at the current playhead. If the playhead is already inside an
    /// existing segment, selects it instead of stacking a new one on top.
    private var addZoomButton: some View {
        Button(action: addZoomAtPlayhead) {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Add zoom")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: "#6466FA") ?? .accentColor)
            )
        }
        .buttonStyle(.plain)
        .disabled(project.videoURL == nil)
        .opacity(project.videoURL == nil ? 0.4 : 1.0)
        .help("Add a zoom at the playhead")
    }

    private func addZoomAtPlayhead() {
        guard project.videoURL != nil else { return }
        let t = project.currentSeconds
        if let existing = project.segment(containing: t) {
            project.selectedAnimationID = existing.id
            return
        }
        _ = project.addZoomSegment(at: t)
    }

    private var addTapButton: some View {
        Button(action: addTapAtPlayhead) {
            HStack(spacing: 4) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Add tap")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: "#EC4899") ?? .pink)
            )
        }
        .buttonStyle(.plain)
        .disabled(project.videoURL == nil)
        .opacity(project.videoURL == nil ? 0.4 : 1)
        .help("Add a tap at the playhead")
    }

    private func addTapAtPlayhead() {
        guard project.videoURL != nil else { return }
        let time = project.currentSeconds
        if let existing = project.tapEvent(containing: time) {
            project.selectedTapEventID = existing.id
            return
        }
        _ = project.addTapEvent(at: time)
    }

    private var addSpeedButton: some View {
        Button(action: addSpeedAtPlayhead) {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                    .font(.system(size: 11, weight: .semibold))
                Text("Add speed")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: "#14B8A6") ?? .teal)
            )
        }
        .buttonStyle(.plain)
        .disabled(project.videoURL == nil)
        .opacity(project.videoURL == nil ? 0.4 : 1)
        .help("Add a speed segment at the playhead")
    }

    private func addSpeedAtPlayhead() {
        guard project.videoURL != nil else { return }
        let time = project.currentSeconds
        if let existing = project.speedSegment(containing: time) {
            project.selectedSpeedSegmentID = existing.id
            return
        }
        _ = project.addSpeedSegment(at: time)
    }

    private var trimBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "scissors")
            Text(String(format: "%.2fs trimmed", max(0, project.durationSeconds - project.sourceClipDuration)))
            Button {
                project.trimStartTime = 0
                project.trimEndTime = project.durationSeconds
                project.clipTimelineStart = 0
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
            .help("Reset trim")
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(.black.opacity(0.85))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color(red: 1.0, green: 0.82, blue: 0.10))
        )
    }

    private func shortcutHint(_ key: String, description: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .frame(minWidth: 14)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
            Text(description)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct Playhead: View {
    let height: CGFloat
    let timeText: String?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Capsule()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                Rectangle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 2, height: height - 12)
            }
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            .allowsHitTesting(false)

            // Wider invisible grab zone for the drag gesture
            Color.white.opacity(0.001)
                .frame(width: 18, height: height)

            if let text = timeText {
                TimeTooltip(text: text)
                    .offset(y: -(height / 2) - 14)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
    }
}
