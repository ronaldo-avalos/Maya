import CoreGraphics
import Foundation

enum ExportQuality: String, CaseIterable, Identifiable, Hashable, Sendable {
    case compact
    case hd
    case fourK

    nonisolated var id: String { rawValue }

    nonisolated var resolutionLabel: String {
        switch self {
        case .compact: "720p"
        case .hd: "1080p"
        case .fourK: "4K"
        }
    }

    /// Scales the existing 1080-class canvas dimensions without changing its ratio.
    nonisolated var dimensionScale: CGFloat {
        switch self {
        case .compact: 2.0 / 3.0
        case .hd: 1
        case .fourK: 2
        }
    }

    /// Used by the manual HEVC-with-alpha writer. Standard MP4 exports use
    /// AVAssetExportPresetHighestQuality at the selected output dimensions.
    nonisolated var transparentEncoderQuality: Double {
        switch self {
        case .compact: 0.68
        case .hd: 0.85
        case .fourK: 0.95
        }
    }

    nonisolated var audioBitRate: Int {
        switch self {
        case .compact: 96_000
        case .hd: 128_000
        case .fourK: 192_000
        }
    }
}
