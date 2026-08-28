import SwiftUI

struct TapEditorPanel: View {
    @Bindable var project: Project
    let eventID: TapEvent.ID
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let binding = eventBinding() {
                        placementHelp
                        styleSection(binding: binding)
                        Divider()
                        timingSection(binding: binding)
                        Divider()
                        appearanceSection(binding: binding)
                        Divider()
                        positionSection(binding: binding)
                        Divider()
                        actionsSection
                    } else {
                        Text("Tap event not found.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Tap event", systemImage: "hand.tap.fill")
                .font(.headline)
            Spacer()
            Button {
                onDismiss()
            } label: {
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

    private var placementHelp: some View {
        Label {
            Text("Click the device screen to position this tap.")
                .font(.callout.weight(.medium))
        } icon: {
            Image(systemName: "scope")
                .foregroundStyle(Color(hex: "#EC4899") ?? .pink)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((Color(hex: "#EC4899") ?? .pink).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke((Color(hex: "#EC4899") ?? .pink).opacity(0.20), lineWidth: 1)
        )
    }

    private func styleSection(binding: Binding<TapEvent>) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]

        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Style")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(TapStyle.allCases) { style in
                    PresetPreviewCard(
                        name: style.label,
                        resourceName: style.previewName,
                        placeholderSymbol: style.symbol,
                        accent: Color(hex: "#EC4899") ?? .pink,
                        tapStyle: style,
                        isSelected: binding.wrappedValue.style == style
                    ) {
                        var event = binding.wrappedValue
                        event.style = style
                        binding.wrappedValue = event
                    }
                }
            }
        }
    }

    private func timingSection(binding: Binding<TapEvent>) -> some View {
        let totalDuration = max(project.durationSeconds, TapEvent.durationRange.lowerBound)

        return VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Timing")

            labeledSlider(
                title: "Start",
                value: Binding(
                    get: { binding.wrappedValue.startTime },
                    set: { newValue in
                        var event = binding.wrappedValue
                        let maxStart = max(totalDuration - event.duration, 0)
                        event.startTime = max(0, min(newValue, maxStart))
                        binding.wrappedValue = event
                    }
                ),
                range: 0...totalDuration,
                display: formatTimestamp(binding.wrappedValue.startTime)
            )

            labeledSlider(
                title: "Duration",
                value: Binding(
                    get: { binding.wrappedValue.duration },
                    set: { newValue in
                        var event = binding.wrappedValue
                        let available = max(
                            totalDuration - event.startTime,
                            TapEvent.durationRange.lowerBound
                        )
                        event.duration = min(newValue, available)
                        binding.wrappedValue = event
                    }
                ),
                range: TapEvent.durationRange,
                display: String(format: "%.2fs", binding.wrappedValue.duration)
            )
        }
    }

    private func appearanceSection(binding: Binding<TapEvent>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Appearance")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Color")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(binding.wrappedValue.colorHex)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: { Color(hex: binding.wrappedValue.colorHex) ?? .white },
                            set: { color in
                                var event = binding.wrappedValue
                                event.colorHex = color.hexString
                                binding.wrappedValue = event
                            }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }
            }

            labeledSlider(
                title: "Size",
                value: Binding(
                    get: { binding.wrappedValue.diameterFraction },
                    set: { newValue in
                        var event = binding.wrappedValue
                        event.diameterFraction = newValue
                        binding.wrappedValue = event
                    }
                ),
                range: TapEvent.diameterRange,
                display: "\(Int(binding.wrappedValue.diameterFraction * 100))%"
            )
        }
    }

    private func positionSection(binding: Binding<TapEvent>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                sectionTitle("Position")
                Spacer()
                Button("Center") {
                    var event = binding.wrappedValue
                    event.position = CGPoint(x: 0.5, y: 0.5)
                    binding.wrappedValue = event
                }
                .controlSize(.small)
            }

            labeledSlider(
                title: "Horizontal",
                value: Binding(
                    get: { binding.wrappedValue.position.x },
                    set: { newValue in
                        var event = binding.wrappedValue
                        event.position.x = newValue
                        binding.wrappedValue = event
                    }
                ),
                range: CGFloat(0)...CGFloat(1),
                display: "\(Int(binding.wrappedValue.position.x * 100))%"
            )

            labeledSlider(
                title: "Vertical",
                value: Binding(
                    get: { binding.wrappedValue.position.y },
                    set: { newValue in
                        var event = binding.wrappedValue
                        event.position.y = newValue
                        binding.wrappedValue = event
                    }
                ),
                range: CGFloat(0)...CGFloat(1),
                display: "\(Int(binding.wrappedValue.position.y * 100))%"
            )
        }
    }

    private var actionsSection: some View {
        HStack {
            Button(role: .destructive) {
                project.removeTapEvent(id: eventID)
            } label: {
                Label("Delete", systemImage: "trash")
            }

            Spacer()

            Button {
                _ = project.duplicateTapEvent(id: eventID)
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

    private func labeledSlider<V: BinaryFloatingPoint>(
        title: String,
        value: Binding<V>,
        range: ClosedRange<V>,
        display: String
    ) -> some View where V.Stride: BinaryFloatingPoint {
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

    private func eventBinding() -> Binding<TapEvent>? {
        guard project.tapEvents.contains(where: { $0.id == eventID }) else { return nil }
        return Binding(
            get: {
                project.tapEvents.first(where: { $0.id == eventID })
                    ?? TapEvent(startTime: 0)
            },
            set: { updated in
                project.updateTapEvent(updated)
            }
        )
    }
}
