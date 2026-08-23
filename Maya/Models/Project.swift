import AVFoundation
import Foundation
import Observation
import SwiftUI

enum TimelineEventSelection: Equatable, Sendable {
    case zoom(ZoomSegment.ID)
    case tap(TapEvent.ID)
    case speed(SpeedSegment.ID)
}

@Observable
final class Project {
    /// URL of the working copy inside the app's sandbox. The user's original file is never
    /// referenced after load — we hard-link (same volume) or copy it into our Caches dir so
    /// every subsequent read (preview, thumbnails, export) has unrestricted sandbox access
    /// from any thread. This sidesteps the entire security-scoped-resource dance, which is
    /// unreliable for drag-drop URLs across actor/queue boundaries.
    var videoURL: URL?
    /// Display name (the user's original file name) for UI labels.
    var displayName: String?
    var player: AVPlayer?
    var videoNaturalSize: CGSize = .zero
    var videoDuration: CMTime = .zero
    var currentSeconds: Double = 0

    var scale: CGFloat = 0.85
    var offset: CGSize = .zero
    var background: BackgroundOption = .gradient(GradientSpec.presets[0])
    var canvasAspect: CanvasAspectRatio = .square
    var shadow: PhoneShadow = PhoneShadow()

    /// Device picker state. We track model + color separately so switching models
    /// can gracefully fall back to that model's default color.
    var deviceModelID: String = DeviceModel.iPhone17Pro.id
    var deviceColorID: String = DeviceModel.iPhone17Pro.defaultColor.id

    /// Corner radius for the bare video, used when the active device is
    /// `.none` or `.generic`. Normalized to the screen's short side: 0 = sharp,
    /// 0.5 = fully rounded (stadium / circle).
    var bareCornerRadius: CGFloat = 0.15

    /// Stroke width of the generic device bezel, normalized to phone width
    /// (0 → no bezel, 0.1 → fat bezel).
    var bareBezelWidth: CGFloat = 0.025

    /// Color of the generic device bezel, stored as hex so it survives
    /// snapshot/export without bridging through NSColor on background queues.
    var bareBezelHex: String = "#000000"

    var deviceModel: DeviceModel {
        DeviceModel.model(id: deviceModelID) ?? .iPhone17Pro
    }

    var deviceColor: DeviceColor {
        deviceModel.color(id: deviceColorID) ?? deviceModel.defaultColor
    }

    var deviceFrame: DeviceFrame {
        deviceModel.frame(for: deviceColor)
    }

    func selectDeviceModel(_ model: DeviceModel) {
        deviceModelID = model.id
        if model.color(id: deviceColorID) == nil {
            deviceColorID = model.defaultColor.id
        }
    }

    func selectDeviceColor(_ color: DeviceColor) {
        guard deviceModel.color(id: color.id) != nil else { return }
        deviceColorID = color.id
    }

    var animations: [ZoomSegment] = []
    var tapEvents: [TapEvent] = []
    var speedSegments: [SpeedSegment] = []
    var selectedEvent: TimelineEventSelection?

    var selectedAnimationID: ZoomSegment.ID? {
        get {
            guard case .zoom(let id) = selectedEvent else { return nil }
            return id
        }
        set {
            selectedEvent = newValue.map(TimelineEventSelection.zoom)
        }
    }

    var selectedTapEventID: TapEvent.ID? {
        get {
            guard case .tap(let id) = selectedEvent else { return nil }
            return id
        }
        set {
            selectedEvent = newValue.map(TimelineEventSelection.tap)
        }
    }

    var selectedSpeedSegmentID: SpeedSegment.ID? {
        get {
            guard case .speed(let id) = selectedEvent else { return nil }
            return id
        }
        set {
            selectedEvent = newValue.map(TimelineEventSelection.speed)
        }
    }

    /// In/out points on the *source* video. Non-destructive: the underlying file is untouched.
    /// Together with `clipTimelineStart` they define an "edit": which portion of the source
    /// to play and where to place it on the project timeline.
    var trimStartTime: Double = 0
    var trimEndTime: Double = 0

    /// Where the trimmed clip sits on the project timeline. This is independent from
    /// `trimStartTime` — the user can grab the clip and slide it anywhere on the
    /// timeline without changing which source frames play. NLE-style.
    var clipTimelineStart: Double = 0

    /// Minimum length you can trim a clip down to. Mirrors Apple Photos' behavior.
    static let minTrimDuration: Double = 0.5

    var isExporting: Bool = false
    var exportProgress: Double = 0
    var lastExportError: String?

    var isMuted: Bool = true {
        didSet { player?.isMuted = isMuted }
    }

    private var loopObserver: NSObjectProtocol?
    private var timeObserver: Any?

    deinit {
        if let o = loopObserver { NotificationCenter.default.removeObserver(o) }
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
        }
        Self.cleanupCachedSource(at: videoURL)
    }

    var durationSeconds: Double {
        let s = videoDuration.seconds
        return (s.isFinite && s > 0) ? s : 0
    }

    /// Length of the selected source range before speed adjustments.
    var sourceClipDuration: Double {
        max(0, trimEndTime - trimStartTime)
    }

    var speedTimeline: SpeedTimeline {
        SpeedTimeline(
            sourceStart: trimStartTime,
            sourceEnd: trimEndTime,
            segments: speedSegments
        )
    }

    /// Length of the clip on the project timeline after trim and speed changes.
    var clipDuration: Double {
        speedTimeline.duration
    }

    /// Backwards-compat alias used by the toolbar and export.
    var trimmedDuration: Double { clipDuration }

    /// Right edge of the clip on the project timeline.
    var clipTimelineEnd: Double {
        clipTimelineStart + clipDuration
    }

    /// Length of the project timeline shown in the editor. It grows when the clip is moved
    /// later or slowed enough to extend beyond the source recording's natural duration.
    var timelineDuration: Double {
        max(durationSeconds, clipTimelineEnd)
    }

    /// True when the user has trimmed something off either end or shifted the clip.
    var isTrimmed: Bool {
        guard durationSeconds > 0 else { return false }
        return trimStartTime > 0.001
            || trimEndTime < durationSeconds - 0.001
            || clipTimelineStart > 0.001
    }

    /// Converts a project-timeline second to its source-video second. Speed ranges make this
    /// mapping piecewise linear rather than a simple offset.
    func timelineToSource(_ t: Double) -> Double {
        if t <= clipTimelineStart { return trimStartTime }
        if t >= clipTimelineEnd { return trimEndTime }
        return speedTimeline.sourceTime(forOutputOffset: t - clipTimelineStart)
    }

    /// Inverse of `timelineToSource`.
    func sourceToTimeline(_ s: Double) -> Double {
        clipTimelineStart + speedTimeline.outputOffset(forSourceTime: s)
    }

    func setTrimStart(_ t: Double) {
        let maxStart = max(0, trimEndTime - Self.minTrimDuration)
        trimStartTime = max(0, min(t, maxStart))
    }

    func setTrimEnd(_ t: Double) {
        let minEnd = min(durationSeconds, trimStartTime + Self.minTrimDuration)
        trimEndTime = max(minEnd, min(t, durationSeconds))
    }

    /// Clamps a timeline second into the clip's window.
    func clampedToClip(_ t: Double) -> Double {
        guard clipDuration > 0 else { return clipTimelineStart }
        if t < clipTimelineStart { return clipTimelineStart }
        if t > clipTimelineEnd { return clipTimelineEnd }
        return t
    }

    /// Looks up the segment under a *timeline* second. Returns nil if the timeline time
    /// lies outside the clip window (no source frame is playing there).
    func segment(containing timelineTime: Double) -> ZoomSegment? {
        guard timelineTime >= clipTimelineStart, timelineTime <= clipTimelineEnd else { return nil }
        let s = timelineToSource(timelineTime)
        return animations.first { s >= $0.startTime && s <= $0.endTime }
    }

    /// Adds a zoom anchored at the given *timeline* second. Stored internally in source
    /// coords so the animation stays attached to the same source frame even if the clip
    /// is later moved or re-trimmed.
    func addZoomSegment(at timelineTime: Double) -> ZoomSegment {
        let dur = ZoomSegment.defaultDuration
        let sourceAtPlayhead = timelineToSource(clampedToClip(timelineTime))
        let sourceStart = max(trimStartTime, min(sourceAtPlayhead, max(trimEndTime - dur, trimStartTime)))
        var segment = ZoomSegment(
            startTime: sourceStart,
            duration: min(dur, max(trimEndTime - sourceStart, 0.4)),
            scale: ZoomSegment.defaultScale,
            focus: .center
        )
        segment.normalize()
        animations.append(segment)
        selectedAnimationID = segment.id
        return segment
    }

    func updateZoomSegment(_ segment: ZoomSegment) {
        guard let idx = animations.firstIndex(where: { $0.id == segment.id }) else { return }
        var s = segment
        s.normalize()
        animations[idx] = s
    }

    func removeZoomSegment(id: ZoomSegment.ID) {
        animations.removeAll { $0.id == id }
        if selectedAnimationID == id { selectedAnimationID = nil }
    }

    @discardableResult
    func duplicateZoomSegment(id: ZoomSegment.ID) -> ZoomSegment? {
        guard let original = animations.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.startTime = min(original.endTime + 0.1, max(durationSeconds - copy.duration, 0))
        copy.normalize()
        animations.append(copy)
        selectedAnimationID = copy.id
        return copy
    }

    /// Returns the tap under a timeline second. Tap events use source coordinates
    /// internally, matching zoom segments.
    func tapEvent(containing timelineTime: Double) -> TapEvent? {
        guard timelineTime >= clipTimelineStart, timelineTime <= clipTimelineEnd else { return nil }
        let sourceTime = timelineToSource(timelineTime)
        return tapEvents.first { sourceTime >= $0.startTime && sourceTime <= $0.endTime }
    }

    /// Adds a tap at the playhead and selects it for on-canvas positioning.
    func addTapEvent(at timelineTime: Double) -> TapEvent {
        let duration = TapEvent.defaultDuration
        let sourceAtPlayhead = timelineToSource(clampedToClip(timelineTime))
        let sourceStart = max(
            trimStartTime,
            min(sourceAtPlayhead, max(trimEndTime - duration, trimStartTime))
        )
        var event = TapEvent(
            startTime: sourceStart,
            duration: min(duration, max(trimEndTime - sourceStart, TapEvent.durationRange.lowerBound))
        )
        event.normalize()
        tapEvents.append(event)
        selectedTapEventID = event.id
        return event
    }

    func updateTapEvent(_ event: TapEvent) {
        guard let index = tapEvents.firstIndex(where: { $0.id == event.id }) else { return }
        var normalized = event
        normalized.normalize()
        tapEvents[index] = normalized
    }

    func positionTapEvent(id: TapEvent.ID, at normalizedPosition: CGPoint) {
        guard var event = tapEvents.first(where: { $0.id == id }) else { return }
        event.position = normalizedPosition
        updateTapEvent(event)
    }

    func removeTapEvent(id: TapEvent.ID) {
        tapEvents.removeAll { $0.id == id }
        if selectedTapEventID == id { selectedEvent = nil }
    }

    @discardableResult
    func duplicateTapEvent(id: TapEvent.ID) -> TapEvent? {
        guard let original = tapEvents.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.startTime = min(
            original.endTime + 0.1,
            max(durationSeconds - copy.duration, 0)
        )
        copy.normalize()
        tapEvents.append(copy)
        selectedTapEventID = copy.id
        return copy
    }

    // MARK: - Speed segments

    func speedSegment(containing timelineTime: Double) -> SpeedSegment? {
        guard timelineTime >= clipTimelineStart, timelineTime <= clipTimelineEnd else { return nil }
        let sourceTime = timelineToSource(timelineTime)
        return speedSegments.first { sourceTime >= $0.startTime && sourceTime < $0.endTime }
    }

    @discardableResult
    func addSpeedSegment(at timelineTime: Double) -> SpeedSegment? {
        let sourceAtPlayhead = timelineToSource(clampedToClip(timelineTime))
        if let existing = speedSegments.first(where: {
            sourceAtPlayhead >= $0.startTime && sourceAtPlayhead < $0.endTime
        }) {
            selectedSpeedSegmentID = existing.id
            return existing
        }

        let nextStart = speedSegments
            .filter { $0.startTime > sourceAtPlayhead }
            .map(\.startTime)
            .min() ?? trimEndTime
        let available = max(0, min(nextStart, trimEndTime) - sourceAtPlayhead)
        guard available >= SpeedSegment.minimumDuration else { return nil }

        let segment = SpeedSegment(
            startTime: sourceAtPlayhead,
            duration: min(SpeedSegment.defaultDuration, available),
            rate: SpeedSegment.defaultRate
        )
        speedSegments.append(segment)
        speedSegments.sort { $0.startTime < $1.startTime }
        selectedSpeedSegmentID = segment.id
        refreshTimelineAfterSpeedChange()
        return segment
    }

    func updateSpeedSegment(_ segment: SpeedSegment) {
        guard let index = speedSegments.firstIndex(where: { $0.id == segment.id }) else { return }
        let sourceBeforeChange = currentSourceTime
        var updated = segment
        updated.normalize(sourceDuration: durationSeconds)
        updated.startTime = min(max(updated.startTime, trimStartTime), max(trimEndTime - SpeedSegment.minimumDuration, trimStartTime))
        updated.duration = min(updated.duration, max(trimEndTime - updated.startTime, SpeedSegment.minimumDuration))

        let others = speedSegments.filter { $0.id != updated.id }.sorted { $0.startTime < $1.startTime }
        if let overlappingPrevious = others.last(where: {
            $0.startTime <= updated.startTime && $0.endTime > updated.startTime
        }) {
            updated.startTime = overlappingPrevious.endTime
        }
        if let next = others.first(where: { $0.startTime >= updated.startTime }) {
            updated.duration = min(updated.duration, next.startTime - updated.startTime)
        }
        updated.duration = min(updated.duration, max(trimEndTime - updated.startTime, 0))
        guard updated.duration >= SpeedSegment.minimumDuration else { return }

        speedSegments[index] = updated
        speedSegments.sort { $0.startTime < $1.startTime }
        refreshTimelineAfterSpeedChange(sourceTime: sourceBeforeChange)
    }

    func removeSpeedSegment(id: SpeedSegment.ID) {
        let sourceBeforeChange = currentSourceTime
        speedSegments.removeAll { $0.id == id }
        if selectedSpeedSegmentID == id { selectedEvent = nil }
        refreshTimelineAfterSpeedChange(sourceTime: sourceBeforeChange)
    }

    @discardableResult
    func duplicateSpeedSegment(id: SpeedSegment.ID) -> SpeedSegment? {
        guard let original = speedSegments.first(where: { $0.id == id }) else { return nil }
        let proposedStart = original.endTime
        let nextStart = speedSegments
            .filter { $0.startTime >= proposedStart }
            .map(\.startTime)
            .min() ?? trimEndTime
        let available = min(nextStart, trimEndTime) - proposedStart
        guard available >= SpeedSegment.minimumDuration else { return nil }

        var copy = original
        copy.id = UUID()
        copy.startTime = proposedStart
        copy.duration = min(copy.duration, available)
        speedSegments.append(copy)
        speedSegments.sort { $0.startTime < $1.startTime }
        selectedSpeedSegmentID = copy.id
        refreshTimelineAfterSpeedChange()
        return copy
    }

    func toggleMute() {
        isMuted.toggle()
    }

    /// Seek to a project-timeline second. The player itself runs in source coords so we
    /// translate before issuing the seek.
    func seek(to timelineSeconds: Double) {
        guard let player else { return }
        let clamped = clampedToClip(timelineSeconds)
        let source = timelineToSource(clamped)
        let time = CMTime(seconds: source, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentSeconds = clamped
        updatePlaybackRate(at: source)
    }

    private var currentSourceTime: Double {
        let seconds = player?.currentTime().seconds ?? timelineToSource(currentSeconds)
        return seconds.isFinite ? seconds : trimStartTime
    }

    private func refreshTimelineAfterSpeedChange(sourceTime: Double? = nil) {
        let source = sourceTime ?? currentSourceTime
        currentSeconds = sourceToTimeline(source)
        updatePlaybackRate(at: source)
    }

    private func updatePlaybackRate(at sourceTime: Double) {
        guard let player, player.timeControlStatus == .playing else { return }
        let rate = Float(speedTimeline.rate(atSourceTime: sourceTime))
        if abs(player.rate - rate) > 0.001 {
            player.rate = rate
        }
    }

    /// Loads a video. `url` must already be inside the app sandbox (use
    /// `Project.adoptIntoSandbox(_:)` first). Cleans up the previous working copy.
    func loadVideo(url: URL) async {
        let previousURL = videoURL
        let asset = AVURLAsset(url: url)
        var naturalSize = CGSize.zero
        var duration = CMTime.zero
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize) {
                // `naturalSize` is the stored pixel size, which ignores rotation:
                // a landscape screen recording is often stored portrait with a
                // 90° `preferredTransform`. Report the *displayed* size so the
                // `.none` / `.generic` aspect matches what the player shows.
                naturalSize = size
                if let transform = try? await track.load(.preferredTransform) {
                    let displayed = size.applying(transform)
                    naturalSize = CGSize(
                        width: abs(displayed.width),
                        height: abs(displayed.height)
                    )
                }
            }
        }
        if let d = try? await asset.load(.duration) {
            duration = d
        }

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = isMuted

        if let o = loopObserver { NotificationCenter.default.removeObserver(o) }
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak newPlayer] _ in
            let target = self?.trimStartTime ?? 0
            let time = CMTime(seconds: target, preferredTimescale: 600)
            newPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            let rate = Float(self?.speedTimeline.rate(atSourceTime: target) ?? 1)
            newPlayer?.playImmediately(atRate: rate)
        }

        if let observer = timeObserver, let oldPlayer = self.player {
            oldPlayer.removeTimeObserver(observer)
        }

        self.videoURL = url
        self.videoNaturalSize = naturalSize
        self.videoDuration = duration
        self.player = newPlayer
        // Initialize trim to the full clip and place the clip at timeline 0 on every new video.
        let durSeconds = duration.seconds.isFinite ? duration.seconds : 0
        self.trimStartTime = 0
        self.trimEndTime = max(durSeconds, 0)
        self.clipTimelineStart = 0
        self.currentSeconds = 0
        self.speedSegments = []
        self.selectedEvent = nil

        // Now safe to remove the previous working copy.
        Self.cleanupCachedSource(at: previousURL)

        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let sourceTime = time.seconds
            // If the player crosses the trim-out point while playing, snap back to trim-in.
            if self.clipDuration > 0, sourceTime >= self.trimEndTime - 0.01 {
                let target = CMTime(seconds: self.trimStartTime, preferredTimescale: 600)
                self.player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                self.currentSeconds = self.clipTimelineStart
                self.updatePlaybackRate(at: self.trimStartTime)
            } else {
                self.currentSeconds = self.sourceToTimeline(sourceTime)
                self.updatePlaybackRate(at: sourceTime)
            }
        }

        newPlayer.playImmediately(atRate: 1)
    }

    func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            // If the playhead drifted outside the clip, snap to clip-in (timeline coords).
            if currentSeconds < clipTimelineStart || currentSeconds >= clipTimelineEnd - 0.01 {
                seek(to: clipTimelineStart)
            }
            let source = timelineToSource(currentSeconds)
            player.playImmediately(atRate: Float(speedTimeline.rate(atSourceTime: source)))
        }
    }

    // MARK: - Sandbox file adoption
    //
    // macOS App Sandbox restricts file access by path. URLs obtained via drag-drop or
    // NSOpenPanel only carry usable scope on the thread / queue that received them, and
    // bookmark-with-security-scope creation is unreliable for drop URLs. The robust way
    // to handle this for any subsequent processing (preview, AVAssetReader on a background
    // thread, AVAssetExportSession, AVAssetImageGenerator…) is to bring the file *into*
    // the sandbox once, then operate on the local copy.
    //
    // We try a hard link first (instant, no extra disk usage, works on the same volume),
    // then fall back to a regular copy. The caller is responsible for opening the
    // security scope of the source URL before invoking this and stopping it afterward —
    // we don't bother capturing a bookmark because we no longer need post-callback access.

    static func cacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("VideoSources", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func adoptIntoSandbox(_ source: URL) throws -> (sandboxURL: URL, displayName: String) {
        let originalName = source.lastPathComponent
        let cleanedName = originalName.replacingOccurrences(of: "/", with: "-")
        let dest = try cacheDirectory()
            .appendingPathComponent("\(UUID().uuidString)-\(cleanedName)")

        do {
            try FileManager.default.linkItem(at: source, to: dest)
        } catch {
            try FileManager.default.copyItem(at: source, to: dest)
        }
        return (dest, originalName)
    }

    static func cleanupCachedSource(at url: URL?) {
        guard let url else { return }
        let dir = (try? cacheDirectory().path) ?? ""
        guard !dir.isEmpty, url.path.hasPrefix(dir) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
