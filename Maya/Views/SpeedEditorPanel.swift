import SwiftUI

struct SpeedEditorPanel: View {
    @Bindable var project: Project
    let segmentID: SpeedSegment.ID
    let onDismiss: () -> Void

    private let presets: [Double] = [0.5, 1, 1.5, 2, 3, 4]
    private let accent = Color(hex: "#14B8A6") ?? .teal

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let binding = segmentBinding() {
                        summary(binding.wrappedValue)
                        presetsSection(binding: binding)
                        Divider()
                        rateSection(binding: binding)
                        Divider()
                        timingSection(binding: binding)
                        Divider()
                        actionsSection
                    } else {
                        Text("Speed segment not found.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Speed segment", systemImage: "speedometer")
                .font(.headline)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Close panel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func summary(_ segment: SpeedSegment) -> some View {
        let outputDuration = project.speedTimeline.outputDuration(
            fromSourceTime: segment.startTime,
            toSourceTime: segment.endTime
        )
        let description = segment.rate < 1 ? "Slow motion" : (segment.rate > 1 ? "Faster playback" : "Normal speed")

        return VStack(alignment: .leading, spacing: 6) {
            Text(description)
                .font(.callout.weight(.semibold))
            Text(String(format: "%.2fs of source becomes %.2fs on the timeline", segment.duration, outputDuration))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.22), lineWidth: 1))
    }

    private func presetsSection(binding: Binding<SpeedSegment>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Presets")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                ForEach(presets, id: \.self) { rate in
                    let isSelected = abs(binding.wrappedValue.rate - rate) < 0.001
                    Button {
                        var segment = binding.wrappedValue
                        segment.rate = rate
                        binding.wrappedValue = segment
                    } label: {
                        Text(String(format: "%g×", rate))
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? accent : Color.gray.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isSelected ? Color.white.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func rateSection(binding: Binding<SpeedSegment>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Playback rate")
            HStack {
                Text("Speed")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "%.2f×", binding.wrappedValue.rate))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { binding.wrappedValue.rate },
                    set: { rate in
                        var segment = binding.wrappedValue
                        segment.rate = rate
                        binding.wrappedValue = segment
                    }
                ),
                in: SpeedSegment.rateRange,
                step: 0.05
            )
        }
    }

    private func timingSection(binding: Binding<SpeedSegment>) -> some View {
        let segment = binding.wrappedValue
        let totalDuration = max(project.durationSeconds, SpeedSegment.minimumDuration)
        let maximumSegmentDuration = max(
            SpeedSegment.minimumDuration,
            totalDuration - segment.startTime
        )

        return VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Source range")
            labeledSlider(
                title: "Start",
                value: Binding(
                    get: { binding.wrappedValue.startTime },
                    set: { start in
                        var updated = binding.wrappedValue
                        updated.startTime = start
                        binding.wrappedValue = updated
                    }
                ),
                range: 0...max(totalDuration - SpeedSegment.minimumDuration, 0),
                display: formatTimestamp(segment.startTime)
            )
            labeledSlider(
                title: "Duration",
                value: Binding(
                    get: { binding.wrappedValue.duration },
                    set: { duration in
                        var updated = binding.wrappedValue
                        updated.duration = duration
                        binding.wrappedValue = updated
                    }
                ),
                range: SpeedSegment.minimumDuration...maximumSegmentDuration,
                display: String(format: "%.2fs", segment.duration)
            )
        }
    }

    private var actionsSection: some View {
        HStack {
            Button(role: .destructive) {
                project.removeSpeedSegment(id: segmentID)
            } label: {
                Label("Delete", systemImage: "trash")
            }

            Spacer()

            Button {
                _ = project.duplicateSpeedSegment(id: segmentID)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }
        .controlSize(.regular)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func labeledSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(display)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func segmentBinding() -> Binding<SpeedSegment>? {
        guard project.speedSegments.contains(where: { $0.id == segmentID }) else { return nil }
        return Binding(
            get: {
                project.speedSegments.first(where: { $0.id == segmentID })
                    ?? SpeedSegment(startTime: 0)
            },
            set: project.updateSpeedSegment
        )
    }
}
