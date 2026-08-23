import SwiftUI

/// Trim + position-aware video clip for the timeline.
///
/// The clip is a self-contained block on the timeline:
///   • Position on the timeline → `clipTimelineStart`
///   • Source IN/OUT inside the file → `trimStartTime` / `trimEndTime`
///
/// Drag the body to slide the whole clip horizontally (timeline position changes, the
/// underlying source range doesn't — thumbnails travel with it). Drag the yellow handles
/// to trim the source range. The left handle slides the clip so its *right* edge stays
/// anchored, matching NLE expectations.
struct TrimmableVideoClip: View {
    @Bindable var project: Project
    let height: CGFloat
    let thumbnailCount: Int

    @State private var isHovering: Bool = false
    @State private var activeHandle: TrimEdge?
    @State private var handleDragSnapshot: HandleSnapshot?
    @State private var bodyDragSnapshot: Double?
    @State private var isDraggingBody: Bool = false

    @State private var isHoveringBody: Bool = false
    @State private var hoveredHandle: TrimEdge?

    private enum TrimEdge { case start, end }
    private struct HandleSnapshot {
        let trimStart: Double
        let trimEnd: Double
        let clipTimelineEnd: Double
        let fullSpeedTimeline: SpeedTimeline
    }

    private let handleWidth: CGFloat = 10
    private let handleHitWidth: CGFloat = 22
    private let trimColor = Color(red: 1.0, green: 0.82, blue: 0.10)
    private let cornerRadius: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let timelineDuration = project.timelineDuration

            ZStack(alignment: .topLeading) {
                // Empty timeline track — shown wherever the clip isn't.
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(.white.opacity(0.06), lineWidth: 1)
                    )
                    .frame(width: width, height: height)

                if timelineDuration > 0, project.videoURL != nil {
                    let clipStartX = CGFloat(project.clipTimelineStart / timelineDuration) * width
                    let clipEndX = CGFloat(project.clipTimelineEnd / timelineDuration) * width
                    let clipWidth = max(0, clipEndX - clipStartX)

                    clipBlock(clipWidth: clipWidth, timelineWidth: width, timelineDuration: timelineDuration)
                        .frame(width: clipWidth, height: height)
                        .offset(x: clipStartX)

                    handle(edge: .start, x: clipStartX, timelineWidth: width, timelineDuration: timelineDuration)
                    handle(edge: .end, x: clipEndX, timelineWidth: width, timelineDuration: timelineDuration)

                    if let edge = activeHandle {
                        let displayTime = edge == .start ? project.clipTimelineStart : project.clipTimelineEnd
                        let x = edge == .start ? clipStartX : clipEndX
                        TimeTooltip(text: formatTimestamp(displayTime))
                            .offset(x: x - 28, y: -26)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(width: width, height: height)
            .onHover { isHovering = $0 }
        }
        .frame(height: height)
    }

    /// The clip block: thumbnails for the trim range + yellow border + body drag. The thumbnail
    /// strip is scaled so its `[trimStart, trimEnd]` slice fills the clip's visual frame — so
    /// when you drag the body, the thumbnails move with the border (not change content).
    private func clipBlock(clipWidth: CGFloat, timelineWidth: CGFloat, timelineDuration: Double) -> some View {
        let sourceDuration = max(project.durationSeconds, 0.001)
        let sourceClipDuration = max(project.sourceClipDuration, 0.001)
        let virtualStripWidth = clipWidth * (sourceDuration / sourceClipDuration)
        let stripOffsetX = -CGFloat(project.trimStartTime / sourceDuration) * virtualStripWidth

        return ZStack {
            if let url = project.videoURL {
                VideoThumbnailStrip(
                    url: url,
                    thumbnailCount: thumbnailCount,
                    height: height
                )
                .frame(width: virtualStripWidth, height: height)
                .offset(x: stripOffsetX)
                .frame(width: clipWidth, height: height, alignment: .leading)
                .clipped()
            }

            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    activeHandle != nil || isDraggingBody
                        ? trimColor
                        : trimColor.opacity(isHovering ? 0.9 : 0.55),
                    lineWidth: activeHandle != nil || isDraggingBody ? 3 : 2
                )
                .frame(width: clipWidth, height: height)
                .animation(.easeOut(duration: 0.15), value: activeHandle)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                .animation(.easeOut(duration: 0.15), value: isDraggingBody)
        }
        .frame(width: clipWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringBody = hovering
            applyCursor()
        }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .local)
                .onChanged { v in
                    if bodyDragSnapshot == nil {
                        bodyDragSnapshot = project.clipTimelineStart
                    }
                    isDraggingBody = true
                    applyCursor()
                    guard let snapStart = bodyDragSnapshot,
                          timelineWidth > 0,
                          timelineDuration > 0 else { return }
                    let dt = (Double(v.translation.width) / Double(timelineWidth)) * timelineDuration
                    let proposed = max(0, snapStart + dt)
                    project.clipTimelineStart = proposed
                    if project.currentSeconds < project.clipTimelineStart {
                        project.seek(to: project.clipTimelineStart)
                    } else if project.currentSeconds > project.clipTimelineEnd {
                        project.seek(to: project.clipTimelineEnd)
                    }
                }
                .onEnded { _ in
                    bodyDragSnapshot = nil
                    isDraggingBody = false
                    applyCursor()
                }
        )
    }

    private func handle(edge: TrimEdge, x: CGFloat, timelineWidth: CGFloat, timelineDuration: Double) -> some View {
        let isActive = activeHandle == edge

        return ZStack {
            Color.white.opacity(0.001)
                .frame(width: handleHitWidth, height: height)

            RoundedRectangle(cornerRadius: 3)
                .fill(trimColor)
                .frame(width: handleWidth, height: height + 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 2, height: height * 0.4)
                )
                .shadow(color: .black.opacity(0.35), radius: isActive ? 6 : 2, y: 1)
                .scaleEffect(isActive ? 1.08 : (isHovering ? 1.02 : 1.0))
                .animation(.easeOut(duration: 0.15), value: isActive)
                .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .contentShape(Rectangle())
        .position(x: x, y: height / 2)
        .onHover { hovering in
            if hovering {
                hoveredHandle = edge
            } else if hoveredHandle == edge {
                hoveredHandle = nil
            }
            applyCursor()
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { v in
                    if handleDragSnapshot == nil {
                        handleDragSnapshot = HandleSnapshot(
                            trimStart: project.trimStartTime,
                            trimEnd: project.trimEndTime,
                            clipTimelineEnd: project.clipTimelineEnd,
                            fullSpeedTimeline: SpeedTimeline(
                                sourceStart: 0,
                                sourceEnd: project.durationSeconds,
                                segments: project.speedSegments
                            )
                        )
                    }
                    activeHandle = edge
                    guard let snap = handleDragSnapshot,
                          timelineWidth > 0,
                          timelineDuration > 0 else { return }
                    let dt = (Double(v.translation.width) / Double(timelineWidth)) * timelineDuration
                    switch edge {
                    case .start:
                        // Move the source IN and slide the clip together so the *right* edge
                        // stays anchored on the timeline.
                        let initialOutput = snap.fullSpeedTimeline.outputOffset(
                            forSourceTime: snap.trimStart
                        )
                        let proposedTrim = snap.fullSpeedTimeline.sourceTime(
                            forOutputOffset: initialOutput + dt
                        )
                        let clampedTrim = max(0, min(proposedTrim, snap.trimEnd - Project.minTrimDuration))
                        project.trimStartTime = clampedTrim
                        project.clipTimelineStart = max(0, snap.clipTimelineEnd - project.clipDuration)
                        if project.currentSeconds < project.clipTimelineStart {
                            project.seek(to: project.clipTimelineStart)
                        }
                    case .end:
                        // Move the source OUT. The clip's left edge stays put.
                        let initialOutput = snap.fullSpeedTimeline.outputOffset(
                            forSourceTime: snap.trimEnd
                        )
                        let proposedTrim = snap.fullSpeedTimeline.sourceTime(
                            forOutputOffset: initialOutput + dt
                        )
                        let clamped = max(snap.trimStart + Project.minTrimDuration, min(proposedTrim, project.durationSeconds))
                        project.trimEndTime = clamped
                        if project.currentSeconds > project.clipTimelineEnd {
                            project.seek(to: project.clipTimelineEnd)
                        }
                    }
                }
                .onEnded { _ in
                    handleDragSnapshot = nil
                    activeHandle = nil
                    // The trim handle slid to a new x position during the drag, so the
                    // mouse may no longer be on top of it. Clear the hover state and
                    // re-derive the cursor; if the pointer is now resting on the body
                    // (the common case) we'll fall through to `openHand`.
                    hoveredHandle = nil
                    applyCursor()
                }
        )
    }

    /// Centralized cursor logic — handles always win over the body, dragging body shows
    /// closed hand, hovering body shows open hand, nothing → arrow.
    private func applyCursor() {
        if hoveredHandle != nil {
            NSCursor.resizeLeftRight.set()
        } else if isDraggingBody {
            NSCursor.closedHand.set()
        } else if isHoveringBody {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}
