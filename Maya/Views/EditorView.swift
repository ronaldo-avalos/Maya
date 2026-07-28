import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @State private var project = Project()
    @State private var blurPoster: NSImage?
    @State private var exporter = ExportService()

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(project: project, onExport: runExport)
                .navigationSplitViewColumnWidth(min: 320, ideal: 340, max: 420)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    CanvasView(project: project, blurPoster: blurPoster)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let url = urls.first else { return false }
                            importVideo(from: url)
                            return true
                        }

                    if project.videoURL != nil {
                        TimelineView(project: project) { segment in
                            project.selectedAnimationID = segment.id
                        }
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .background(keyboardShortcuts)

                if let selectedID = project.selectedAnimationID,
                   project.animations.contains(where: { $0.id == selectedID }) {
                    Divider()
                    AnimationEditorPanel(project: project, segmentID: selectedID) {
                        project.selectedAnimationID = nil
                    }
                    .frame(width: 340)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: project.selectedAnimationID)
        }
        .navigationTitle("Maya")
        .onChange(of: project.videoURL) { _, _ in updateBlurPoster() }
        .onChange(of: project.background) { _, _ in updateBlurPoster() }
    }

    /// Hidden buttons attach app-wide shortcuts without needing focus management.
    /// macOS automatically routes the key to the first responder first — so text
    /// fields keep typing spaces, deletes, etc., and these only fire when nothing
    /// else claims the event.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { project.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
            Button("") { deleteSelectedSegment() }
                .keyboardShortcut(.delete, modifiers: [])
            Button("") { duplicateSelectedSegment() }
                .keyboardShortcut("d", modifiers: .command)
            Button("") { scrub(-0.25) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { scrub(+0.25) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { scrub(-1.0) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("") { scrub(+1.0) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
            Button("") { project.toggleMute() }
                .keyboardShortcut("m", modifiers: [])

            // Trim shortcuts (Final Cut / iMovie convention).
            Button("") { markTrimIn() }
                .keyboardShortcut("i", modifiers: [])
            Button("") { markTrimOut() }
                .keyboardShortcut("o", modifiers: [])
            Button("") { resetTrim() }
                .keyboardShortcut(.delete, modifiers: .option)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func markTrimIn() {
        guard project.videoURL != nil else { return }
        // currentSeconds is in timeline coords; convert to source for the trim handle, and
        // anchor the clip's right edge so the trim doesn't push the rest of the clip around.
        let newSource = project.timelineToSource(project.currentSeconds)
        let delta = newSource - project.trimStartTime
        project.setTrimStart(newSource)
        project.clipTimelineStart += delta
    }

    private func markTrimOut() {
        guard project.videoURL != nil else { return }
        let newSource = project.timelineToSource(project.currentSeconds)
        project.setTrimEnd(newSource)
    }

    private func resetTrim() {
        guard project.videoURL != nil else { return }
        project.trimStartTime = 0
        project.trimEndTime = project.durationSeconds
        project.clipTimelineStart = 0
    }

    private func deleteSelectedSegment() {
        guard let id = project.selectedAnimationID else { return }
        project.removeZoomSegment(id: id)
    }

    private func duplicateSelectedSegment() {
        guard let id = project.selectedAnimationID else { return }
        _ = project.duplicateZoomSegment(id: id)
    }

    private func scrub(_ delta: Double) {
        guard project.videoURL != nil else { return }
        project.seek(to: project.currentSeconds + delta)
    }

    private func updateBlurPoster() {
        guard case .videoBlur = project.background,
              let url = project.videoURL else {
            blurPoster = nil
            return
        }
        Task {
            let image = await BlurPosterCache.shared.poster(for: url)
            await MainActor.run { self.blurPoster = image }
        }
    }

    private func importVideo(from url: URL) {
        let didStart = url.startAccessingSecurityScopedResource()
        do {
            let adopted = try Project.adoptIntoSandbox(url)
            if didStart { url.stopAccessingSecurityScopedResource() }
            Task {
                project.displayName = adopted.displayName
                await project.loadVideo(url: adopted.sandboxURL)
            }
        } catch {
            if didStart { url.stopAccessingSecurityScopedResource() }
            project.lastExportError = "Could not import video: \(error.localizedDescription)"
        }
    }

    private func runExport() {
        let isTransparent = project.background.isTransparent
        let suggestedName = isTransparent ? "Maya-export.mov" : "Maya-export.mp4"
        let types: [UTType] = isTransparent ? [.quickTimeMovie] : [.mpeg4Movie]

        runSavePanel(suggestedName: suggestedName, allowedTypes: types) { url in
            Task {
                project.isExporting = true
                project.lastExportError = nil
                project.exportProgress = 0
                do {
                    if isTransparent {
                        try await exporter.exportTransparent(
                            project: project,
                            to: url,
                            progress: { p in Task { @MainActor in project.exportProgress = p } }
                        )
                    } else {
                        try await exporter.exportWithBackground(
                            project: project,
                            to: url,
                            progress: { p in Task { @MainActor in project.exportProgress = p } }
                        )
                    }
                } catch {
                    await MainActor.run { project.lastExportError = error.localizedDescription }
                }
                project.isExporting = false
            }
        }
    }

    private func runSavePanel(suggestedName: String, allowedTypes: [UTType], onPick: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = allowedTypes
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url)
        }
    }
}
