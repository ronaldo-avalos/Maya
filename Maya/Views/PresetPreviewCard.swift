import AppKit
import SwiftUI

/// Shared preset card used when a short visual preview communicates the effect
/// better than an icon. MP4 and animated GIF resources are both supported; a
/// styled placeholder keeps the editor complete until preview media is added.
struct PresetPreviewCard: View {
    let name: String
    let resourceName: String
    let placeholderSymbol: String
    let accent: Color
    let tapStyle: TapStyle?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                PresetPreviewMedia(
                    resourceName: resourceName,
                    placeholderSymbol: placeholderSymbol,
                    accent: accent,
                    tapStyle: tapStyle
                )
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)

                HStack(spacing: 4) {
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? accent : Color.gray.opacity(0.12))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? accent : Color.gray.opacity(0.2),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help(name)
    }
}

private struct PresetPreviewMedia: View {
    let resourceName: String
    let placeholderSymbol: String
    let accent: Color
    let tapStyle: TapStyle?

    private var mp4URL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "mp4")
    }

    private var gifURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "gif")
    }

    var body: some View {
        Group {
            if mp4URL != nil {
                LoopingVideoView(resourceName: resourceName)
            } else if let gifURL {
                AnimatedGIFView(url: gifURL)
            } else if let tapStyle {
                TapStylePreview(style: tapStyle, accent: accent)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [accent.opacity(0.24), accent.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    VStack(spacing: 7) {
                        Image(systemName: placeholderSymbol)
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(accent)
                        Text("Preview")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .background(Color.black.opacity(0.04))
        .clipped()
    }
}

private struct AnimatedGIFView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        load(url, into: imageView, coordinator: context.coordinator)
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        guard context.coordinator.currentURL != url else { return }
        load(url, into: imageView, coordinator: context.coordinator)
    }

    private func load(_ url: URL, into imageView: NSImageView, coordinator: Coordinator) {
        imageView.image = NSImage(contentsOf: url)
        coordinator.currentURL = url
    }

    final class Coordinator {
        var currentURL: URL?
    }
}
