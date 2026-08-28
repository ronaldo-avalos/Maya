import CoreGraphics
import Foundation

enum CanvasAspectRatio: String, CaseIterable, Identifiable, Hashable, Sendable {
    case square      // 1:1
    case vertical9x16
    case vertical4x5
    case landscape4x3
    case landscape16x9

    var id: String { rawValue }

    /// width / height
    var ratio: CGFloat {
        switch self {
        case .square:        return 1.0
        case .vertical9x16:  return 9.0 / 16.0
        case .vertical4x5:   return 4.0 / 5.0
        case .landscape4x3:  return 4.0 / 3.0
        case .landscape16x9: return 16.0 / 9.0
        }
    }

    var displayName: String {
        switch self {
        case .square:        return "Square"
        case .vertical9x16:  return "Reels / Story"
        case .vertical4x5:   return "Portrait"
        case .landscape4x3:  return "Landscape"
        case .landscape16x9: return "YouTube / Widescreen"
        }
    }

    var shortLabel: String {
        switch self {
        case .square:        return "1:1"
        case .vertical9x16:  return "9:16"
        case .vertical4x5:   return "4:5"
        case .landscape4x3:  return "4:3"
        case .landscape16x9: return "16:9"
        }
    }

    /// Pixel dimensions used by the export pipeline. Short side stays at 1080
    /// for Reels/Shorts parity; landscape variants keep 1080 tall so HD
    /// (1920×1080) is the default for 16:9.
    var renderSize: CGSize {
        switch self {
        case .square:        return CGSize(width: 1080, height: 1080)
        case .vertical9x16:  return CGSize(width: 1080, height: 1920)
        case .vertical4x5:   return CGSize(width: 1080, height: 1350)
        case .landscape4x3:  return CGSize(width: 1440, height: 1080)
        case .landscape16x9: return CGSize(width: 1920, height: 1080)
        }
    }

    func renderSize(for quality: ExportQuality) -> CGSize {
        let base = renderSize
        return CGSize(
            width: (base.width * quality.dimensionScale).rounded(),
            height: (base.height * quality.dimensionScale).rounded()
        )
    }

    /// SF Symbol matching the aspect — for the sidebar picker chips.
    var symbol: String {
        switch self {
        case .square:        return "square"
        case .vertical9x16:  return "rectangle.portrait"
        case .vertical4x5:   return "rectangle.portrait"
        case .landscape4x3:  return "rectangle"
        case .landscape16x9: return "rectangle"
        }
    }
}
