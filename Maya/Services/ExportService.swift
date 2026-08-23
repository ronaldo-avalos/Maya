import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import Foundation
import SwiftUI
import VideoToolbox

actor ExportService {
    struct Snapshot: @unchecked Sendable {
        /// Already inside the app's sandbox container — no security-scope dance required.
        let sourceVideoURL: URL
        let deviceFrame: DeviceFrame
        let scale: CGFloat
        let offsetFraction: CGSize
        let background: BackgroundOption
        let blurPosterCG: CGImage?
        let backgroundImageCG: CGImage?
        /// nil when `deviceFrame.kind == .none` — the compositor skips the overlay step.
        let frameOverlayCG: CGImage?
        /// Animations in absolute source-video coordinates. Export maps them through the
        /// same speed timeline as the source frames.
        let animations: [ZoomSegment]
        /// Press feedback in the same absolute source-video coordinate system.
        let tapEvents: [TapEvent]
        /// Constant-rate ranges in absolute source-video coordinates.
        let speedSegments: [SpeedSegment]
        let renderSize: CGSize
        let bareCornerRadius: CGFloat
        let bareBezelWidth: CGFloat
        let bareBezelColor: CIColor
        let shadow: PhoneShadow
        let shadowColor: CIColor
        /// Source range to export. When the user hasn't trimmed, this is the full clip.
        let trimRange: CMTimeRange
    }

    func exportWithBackground(
        project: Project,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let snap = try await MainActor.run { try ExportService.snapshot(from: project) }
        try await runWithBackground(snapshot: snap, outputURL: outputURL, progress: progress)
    }

    func exportTransparent(
        project: Project,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let snap = try await MainActor.run { try ExportService.snapshot(from: project) }
        try await runTransparent(snapshot: snap, outputURL: outputURL, progress: progress)
    }

    // MARK: - With background pipeline

    private func runWithBackground(snapshot: Snapshot, outputURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        // Source lives inside our sandbox already — no scope needed there. The save-panel
        // URL still requires scope for the writer to create the destination file.
        let outputAccess = outputURL.startAccessingSecurityScopedResource()
        defer { if outputAccess { outputURL.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: snapshot.sourceVideoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = videoTracks.first else { throw ExportError.noVideoTrack }
        let trimRange = snapshot.trimRange
        let retimed = try await buildRetimedComposition(
            asset: asset,
            sourceVideoTrack: sourceVideoTrack,
            trimRange: trimRange,
            speedSegments: snapshot.speedSegments
        )
        let duration = retimed.duration

        let renderSize = snapshot.renderSize
        let frameDuration = try await sourceVideoTrack.load(.minFrameDuration)
        let fps = frameDuration == .invalid || frameDuration.seconds <= 0 ? CMTime(value: 1, timescale: 60) : frameDuration

        let backgroundImage = try buildBackgroundCIImage(snapshot: snapshot, size: renderSize)
        let frameOverlay = snapshot.frameOverlayCG.map { CIImage(cgImage: $0) }

        let instruction = DeviceFrameCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.deviceFrame = snapshot.deviceFrame
        instruction.scale = snapshot.scale
        instruction.offsetFraction = snapshot.offsetFraction
        instruction.sourceTrackID = retimed.videoTrack.trackID
        instruction.sourceTransform = retimed.sourceTransformCI
        instruction.backgroundImage = backgroundImage
        instruction.frameOverlay = frameOverlay
        instruction.renderTransparent = false
        instruction.animations = Self.animationsRetimed(snapshot.animations, timeline: retimed.timeline)
        instruction.tapEvents = Self.tapEventsRetimed(snapshot.tapEvents, timeline: retimed.timeline)
        instruction.bareCornerRadius = snapshot.bareCornerRadius
        instruction.bareBezelWidth = snapshot.bareBezelWidth
        instruction.bareBezelColor = snapshot.bareBezelColor
        instruction.shadow = snapshot.shadow
        instruction.shadowColor = snapshot.shadowColor

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = fps
        videoComposition.renderSize = renderSize
        videoComposition.customVideoCompositorClass = DeviceFrameCompositor.self
        videoComposition.instructions = [instruction]

        guard let session = AVAssetExportSession(asset: retimed.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.cannotInitExportSession
        }
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let progressTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                progress(Double(session.progress))
                if session.status == .completed || session.status == .failed || session.status == .cancelled {
                    return
                }
            }
        }
        defer { progressTask.cancel() }

        try await session.export(to: outputURL, as: .mp4)
        progress(1.0)
    }

    // MARK: - Transparent pipeline

    private func runTransparent(snapshot: Snapshot, outputURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let outputAccess = outputURL.startAccessingSecurityScopedResource()
        defer { if outputAccess { outputURL.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: snapshot.sourceVideoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = videoTracks.first else { throw ExportError.noVideoTrack }
        let trimRange = snapshot.trimRange
        let retimed = try await buildRetimedComposition(
            asset: asset,
            sourceVideoTrack: sourceVideoTrack,
            trimRange: trimRange,
            speedSegments: snapshot.speedSegments
        )
        let duration = retimed.duration
        let rawFrameDuration = try await sourceVideoTrack.load(.minFrameDuration)
        let frameDuration: CMTime = (rawFrameDuration == .invalid || rawFrameDuration.seconds <= 0)
            ? CMTime(value: 1, timescale: 60)
            : rawFrameDuration

        let renderSize = snapshot.renderSize
        let frameOverlay = snapshot.frameOverlayCG.map { CIImage(cgImage: $0) }

        let instruction = DeviceFrameCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.deviceFrame = snapshot.deviceFrame
        instruction.scale = snapshot.scale
        instruction.offsetFraction = snapshot.offsetFraction
        instruction.sourceTrackID = retimed.videoTrack.trackID
        instruction.sourceTransform = retimed.sourceTransformCI
        instruction.backgroundImage = nil
        instruction.frameOverlay = frameOverlay
        instruction.renderTransparent = true
        instruction.animations = Self.animationsRetimed(snapshot.animations, timeline: retimed.timeline)
        instruction.tapEvents = Self.tapEventsRetimed(snapshot.tapEvents, timeline: retimed.timeline)
        instruction.bareCornerRadius = snapshot.bareCornerRadius
        instruction.bareBezelWidth = snapshot.bareBezelWidth
        instruction.bareBezelColor = snapshot.bareBezelColor
        instruction.shadow = snapshot.shadow
        instruction.shadowColor = snapshot.shadowColor

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = frameDuration
        videoComposition.renderSize = renderSize
        videoComposition.customVideoCompositorClass = DeviceFrameCompositor.self
        videoComposition.instructions = [instruction]

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let reader = try AVAssetReader(asset: retimed.composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: duration)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [retimed.videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = videoComposition
        if reader.canAdd(videoOutput) { reader.add(videoOutput) }

        let audioTracks = try await retimed.composition.loadTracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTracks.first {
            let o = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100
            ])
            if reader.canAdd(o) {
                reader.add(o)
                audioOutput = o
            }
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoCompressionProps: [String: Any] = [
            kVTCompressionPropertyKey_Quality as String: 0.85,
            kVTCompressionPropertyKey_AlphaChannelMode as String: kVTAlphaChannelMode_PremultipliedAlpha
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: videoCompressionProps
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128_000
            ]
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            a.expectsMediaDataInRealTime = false
            if writer.canAdd(a) {
                writer.add(a)
                audioInput = a
            }
        }

        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height)
            ]
        )

        guard reader.startReading() else { throw ExportError.readerStartFailed(reader.error) }
        guard writer.startWriting() else { throw ExportError.writerStartFailed(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let totalSeconds = duration.seconds

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                try await self.pumpVideo(
                    output: videoOutput,
                    input: videoInput,
                    adaptor: pixelAdaptor,
                    totalSeconds: totalSeconds,
                    timeOffset: .zero,
                    progress: progress
                )
            }
            if let ao = audioOutput, let ai = audioInput {
                group.addTask { [self] in
                    try await self.pumpAudio(output: ao, input: ai, timeOffset: .zero)
                }
            }
            try await group.waitForAll()
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        if writer.status == .failed { throw writer.error ?? ExportError.writerFinishFailed }
        progress(1.0)
    }

    private struct RetimedComposition {
        let composition: AVMutableComposition
        let videoTrack: AVMutableCompositionTrack
        let timeline: SpeedTimeline
        let duration: CMTime
        /// Source `preferredTransform` mapped into CoreImage's bottom-left
        /// origin space, ready to hand to the compositor.
        let sourceTransformCI: CGAffineTransform
    }

    /// `preferredTransform` is expressed in AVFoundation's top-left-origin,
    /// y-down space; CoreImage is bottom-left-origin, y-up. Conjugating the
    /// linear part by the y-flip (`F · L · F`) converts between them — without
    /// this a 90° rotation lands as 180°. Translation is dropped because the
    /// compositor re-anchors the extent after transforming.
    private static func coreImageTransform(from t: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(a: t.a, b: -t.b, c: -t.c, d: t.d, tx: 0, ty: 0)
    }

    /// Builds one zero-based composition for both export paths. Each source piece is
    /// inserted at the current output cursor, then scaled to `sourceDuration / rate`.
    /// Applying the same operation to audio keeps it synchronized with the video.
    private func buildRetimedComposition(
        asset: AVURLAsset,
        sourceVideoTrack: AVAssetTrack,
        trimRange: CMTimeRange,
        speedSegments: [SpeedSegment]
    ) async throws -> RetimedComposition {
        let sourceStart = trimRange.start.seconds
        let sourceEnd = CMTimeRangeGetEnd(trimRange).seconds
        let timeline = SpeedTimeline(
            sourceStart: sourceStart,
            sourceEnd: sourceEnd,
            segments: speedSegments
        )

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.cannotBuildComposition
        }
        let sourceTransform = try await sourceVideoTrack.load(.preferredTransform)
        videoTrack.preferredTransform = sourceTransform

        let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let audioTrack = sourceAudioTrack.flatMap { _ in
            composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }

        var outputCursor = CMTime.zero
        for piece in timeline.pieces {
            let sourceRange = CMTimeRange(
                start: CMTime(seconds: piece.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: piece.sourceDuration, preferredTimescale: 600)
            )
            let outputDuration = CMTime(seconds: piece.outputDuration, preferredTimescale: 600)

            try videoTrack.insertTimeRange(sourceRange, of: sourceVideoTrack, at: outputCursor)
            let insertedRange = CMTimeRange(start: outputCursor, duration: sourceRange.duration)
            if abs(piece.rate - 1) > 0.000_001 {
                videoTrack.scaleTimeRange(insertedRange, toDuration: outputDuration)
            }

            if let sourceAudioTrack, let audioTrack {
                try? audioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: outputCursor)
                if abs(piece.rate - 1) > 0.000_001 {
                    audioTrack.scaleTimeRange(insertedRange, toDuration: outputDuration)
                }
            }

            outputCursor = CMTimeAdd(outputCursor, outputDuration)
        }

        return RetimedComposition(
            composition: composition,
            videoTrack: videoTrack,
            timeline: timeline,
            duration: outputCursor,
            sourceTransformCI: Self.coreImageTransform(from: sourceTransform)
        )
    }

    private nonisolated func pumpVideo(
        output: AVAssetReaderVideoCompositionOutput,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        totalSeconds: Double,
        timeOffset: CMTime,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let queue = DispatchQueue(label: "maya.export.video", qos: .userInitiated)
        let state = ContinuationGuard<Void>()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            state.continuation = continuation
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        state.finish(.success(()))
                        return
                    }
                    let srcPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                    // Output file timeline starts at 0; subtract the trim-in offset.
                    let outPTS = CMTimeSubtract(srcPTS, timeOffset)
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                    if !adaptor.append(buffer, withPresentationTime: outPTS) {
                        input.markAsFinished()
                        state.finish(.failure(ExportError.appendFailed))
                        return
                    }
                    if totalSeconds > 0 {
                        let p = outPTS.seconds / totalSeconds
                        progress(min(max(p, 0), 0.99))
                    }
                }
            }
        }
    }

    private nonisolated func pumpAudio(
        output: AVAssetReaderTrackOutput,
        input: AVAssetWriterInput,
        timeOffset: CMTime
    ) async throws {
        let queue = DispatchQueue(label: "maya.export.audio", qos: .userInitiated)
        let state = ContinuationGuard<Void>()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            state.continuation = continuation
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        state.finish(.success(()))
                        return
                    }
                    // Shift the audio sample PTS to align with the output's zero baseline.
                    if let shifted = Self.shiftSamplePTS(sample, by: timeOffset) {
                        if !input.append(shifted) {
                            input.markAsFinished()
                            state.finish(.failure(ExportError.appendFailed))
                            return
                        }
                    } else if !input.append(sample) {
                        input.markAsFinished()
                        state.finish(.failure(ExportError.appendFailed))
                        return
                    }
                }
            }
        }
    }

    /// Returns a sample buffer whose presentation timestamp is shifted by `-offset`.
    /// Falls back to nil if rewriting fails; the caller should append the original sample.
    private nonisolated static func shiftSamplePTS(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return sample }
        var count = CMItemCount(0)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var infos = [CMSampleTimingInfo](repeating: .init(), count: count)
        let status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &infos, entriesNeededOut: nil)
        guard status == noErr else { return nil }
        for i in 0..<infos.count {
            if infos[i].presentationTimeStamp.isNumeric {
                infos[i].presentationTimeStamp = CMTimeSubtract(infos[i].presentationTimeStamp, offset)
            }
            if infos[i].decodeTimeStamp.isNumeric {
                infos[i].decodeTimeStamp = CMTimeSubtract(infos[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        let s = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: count,
            sampleTimingArray: infos,
            sampleBufferOut: &out
        )
        guard s == noErr else { return nil }
        return out
    }

    /// Converts source-anchored zooms into the zero-based, retimed export timeline.
    private nonisolated static func animationsRetimed(
        _ segments: [ZoomSegment],
        timeline: SpeedTimeline
    ) -> [ZoomSegment] {
        guard timeline.duration > 0 else { return [] }
        return segments.compactMap { seg in
            let sourceStart = max(seg.startTime, timeline.sourceStart)
            let sourceEnd = min(seg.endTime, timeline.sourceEnd)
            guard sourceEnd > sourceStart else { return nil }

            let outputStart = timeline.outputOffset(forSourceTime: sourceStart)
            let outputEnd = timeline.outputOffset(forSourceTime: sourceEnd)
            guard outputEnd > outputStart else { return nil }

            var s = seg
            s.startTime = outputStart
            s.duration = outputEnd - outputStart

            let sourceTransitionInEnd = min(seg.startTime + seg.transitionIn, sourceEnd)
            let outputTransitionInEnd = timeline.outputOffset(forSourceTime: sourceTransitionInEnd)
            s.transitionIn = max(0.001, min(outputTransitionInEnd - outputStart, s.duration / 2))

            let sourceTransitionOutStart = max(seg.endTime - seg.transitionOut, sourceStart)
            let outputTransitionOutStart = timeline.outputOffset(forSourceTime: sourceTransitionOutStart)
            s.transitionOut = max(0.001, min(outputEnd - outputTransitionOutStart, s.duration / 2))
            return s
        }
    }

    /// Converts source-anchored taps into the zero-based, retimed export timeline.
    private nonisolated static func tapEventsRetimed(
        _ events: [TapEvent],
        timeline: SpeedTimeline
    ) -> [TapEvent] {
        guard timeline.duration > 0 else { return [] }
        return events.compactMap { event in
            let sourceStart = max(event.startTime, timeline.sourceStart)
            let sourceEnd = min(event.endTime, timeline.sourceEnd)
            guard sourceEnd > sourceStart else { return nil }

            let outputStart = timeline.outputOffset(forSourceTime: sourceStart)
            let outputEnd = timeline.outputOffset(forSourceTime: sourceEnd)
            guard outputEnd > outputStart else { return nil }

            var shifted = event
            shifted.startTime = outputStart
            shifted.duration = outputEnd - outputStart
            return shifted.duration > 0.01 ? shifted : nil
        }
    }

    // MARK: - Helpers

    private func buildBackgroundCIImage(snapshot: Snapshot, size: CGSize) throws -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        switch snapshot.background {
        case .solid(let hex):
            let color = (Color(hex: hex) ?? .black).ciColor
            return CIImage(color: color).cropped(to: rect)
        case .gradient(let spec):
            let filter = CIFilter.linearGradient()
            filter.color0 = spec.startColor.ciColor
            filter.color1 = spec.endColor.ciColor
            let r = spec.angleDegrees * .pi / 180
            let half = max(size.width, size.height)
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            filter.point0 = CGPoint(x: mid.x - cos(r) * half, y: mid.y - sin(r) * half)
            filter.point1 = CGPoint(x: mid.x + cos(r) * half, y: mid.y + sin(r) * half)
            return (filter.outputImage ?? CIImage(color: .black)).cropped(to: rect)
        case .image:
            if let cg = snapshot.backgroundImageCG {
                let img = CIImage(cgImage: cg)
                let s = img.extent.size
                guard s.width > 0, s.height > 0 else { return CIImage(color: .black).cropped(to: rect) }
                let scale = max(size.width / s.width, size.height / s.height)
                var scaled = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                scaled = scaled.transformed(by: CGAffineTransform(
                    translationX: rect.midX - scaled.extent.midX,
                    y: rect.midY - scaled.extent.midY
                ))
                return scaled.cropped(to: rect)
            }
            return CIImage(color: .black).cropped(to: rect)
        case .videoBlur:
            if let cg = snapshot.blurPosterCG {
                let img = CIImage(cgImage: cg)
                let s = img.extent.size
                guard s.width > 0, s.height > 0 else { return CIImage(color: .black).cropped(to: rect) }
                let scale = max(size.width / s.width, size.height / s.height)
                var scaled = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                scaled = scaled.transformed(by: CGAffineTransform(
                    translationX: rect.midX - scaled.extent.midX,
                    y: rect.midY - scaled.extent.midY
                ))
                return scaled.cropped(to: rect)
            }
            return CIImage(color: .black).cropped(to: rect)
        case .none:
            // Should never reach here — transparent path uses renderTransparent flag instead.
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: rect)
        }
    }

    // MARK: - Snapshot builder (MainActor)

    @MainActor
    static func snapshot(from project: Project) throws -> Snapshot {
        guard let url = project.videoURL else { throw ExportError.noSourceVideo }
        let overlay: CGImage?
        if project.deviceFrame.kind == .none {
            overlay = nil
        } else {
            guard let img = FrameOverlayProvider.cgImage(for: project.deviceFrame) else {
                throw ExportError.missingFrameOverlay
            }
            overlay = img
        }
        var backgroundCG: CGImage?
        if case .image(let imageURL) = project.background {
            _ = imageURL.startAccessingSecurityScopedResource()
            defer { imageURL.stopAccessingSecurityScopedResource() }
            if let ns = NSImage(contentsOf: imageURL) {
                var r = NSRect(origin: .zero, size: ns.size)
                backgroundCG = ns.cgImage(forProposedRect: &r, context: nil, hints: nil)
            }
        }
        var blurPosterCG: CGImage?
        if case .videoBlur = project.background {
            blurPosterCG = BlurPosterCache.shared.cachedCGImage(for: url)
        }
        // Build the export trim range. If the user hasn't touched the trim, this is the
        // full asset duration.
        let trimStart = max(0, project.trimStartTime)
        let trimEnd = project.trimEndTime > 0 ? project.trimEndTime : project.durationSeconds
        let trimDuration = max(0.001, trimEnd - trimStart)
        let trimRange = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            duration: CMTime(seconds: trimDuration, preferredTimescale: 600)
        )

        return Snapshot(
            sourceVideoURL: url,
            deviceFrame: project.deviceFrame,
            scale: project.scale,
            offsetFraction: project.offset,
            background: project.background,
            blurPosterCG: blurPosterCG,
            backgroundImageCG: backgroundCG,
            frameOverlayCG: overlay,
            animations: project.animations,
            tapEvents: project.tapEvents,
            speedSegments: project.speedSegments,
            renderSize: project.canvasAspect.renderSize,
            bareCornerRadius: project.bareCornerRadius,
            bareBezelWidth: project.bareBezelWidth,
            bareBezelColor: (Color(hex: project.bareBezelHex) ?? .black).ciColor,
            shadow: project.shadow,
            shadowColor: (Color(hex: project.shadow.colorHex) ?? .black).ciColor,
            trimRange: trimRange
        )
    }
}

enum ExportError: LocalizedError {
    case noSourceVideo
    case noVideoTrack
    case cannotBuildComposition
    case cannotInitExportSession
    case missingFrameOverlay
    case readerStartFailed(Error?)
    case writerStartFailed(Error?)
    case writerFinishFailed
    case appendFailed

    var errorDescription: String? {
        switch self {
        case .noSourceVideo: "No source video loaded."
        case .noVideoTrack: "Source file has no video track."
        case .cannotBuildComposition: "Failed to build the AV composition."
        case .cannotInitExportSession: "Could not initialize the export session."
        case .missingFrameOverlay: "Could not produce the iPhone frame overlay."
        case .readerStartFailed(let e): "Reader failed to start: \(e?.localizedDescription ?? "unknown")"
        case .writerStartFailed(let e): "Writer failed to start: \(e?.localizedDescription ?? "unknown")"
        case .writerFinishFailed: "Writer failed to finish."
        case .appendFailed: "Failed to append sample buffer."
        }
    }
}

final class ContinuationGuard<T>: @unchecked Sendable {
    nonisolated(unsafe) var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    nonisolated init() {}

    nonisolated func finish(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return }
        switch result {
        case .success(let v): c.resume(returning: v)
        case .failure(let e): c.resume(throwing: e)
        }
    }
}

@MainActor
enum FrameOverlayProvider {
    static func cgImage(for frame: DeviceFrame) -> CGImage? {
        if let ns = NSImage(named: frame.imageName), ns.size.width > 1 {
            var r = NSRect(origin: .zero, size: ns.size)
            return ns.cgImage(forProposedRect: &r, context: nil, hints: nil)
        }
        // Rasterize placeholder
        let height: CGFloat = 2622
        let width = height * frame.frameAspectRatio
        let renderer = ImageRenderer(content:
            PlaceholderFrameView(frame: frame)
                .frame(width: width, height: height)
        )
        renderer.scale = 1
        return renderer.cgImage
    }
}
