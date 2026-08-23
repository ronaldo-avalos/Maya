import CoreGraphics
import Foundation
import SwiftUI

enum DeviceFrameKind: String, Hashable, Sendable {
    case physical    // Real device with a PNG asset.
    case generic     // Drawn placeholder phone (no specific brand/model look).
    case none        // No frame — video is shown bare at its own aspect ratio.
}

struct DeviceColor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Exact asset name in the catalog.
    let imageName: String
    /// Swatch tint shown in the picker.
    let swatchHex: String
}

struct DeviceModel: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    /// Width / height of the rasterized PNG (all currently-supported Pro models share these).
    let frameAspectRatio: CGFloat
    /// Screen rect relative to the PNG, in normalized coords (top-left origin).
    let screenRectNormalized: CGRect
    let screenCornerRadiusNormalized: CGFloat
    let colors: [DeviceColor]
    let kind: DeviceFrameKind
    /// SF Symbol used in the picker chip when there is no color swatch.
    let symbol: String

    var defaultColor: DeviceColor { colors.first! }

    func color(id: String) -> DeviceColor? {
        colors.first { $0.id == id }
    }

    func frame(for color: DeviceColor) -> DeviceFrame {
        DeviceFrame(
            id: "\(id).\(color.id)",
            displayName: kind == .physical ? "\(displayName) – \(color.name)" : displayName,
            imageName: color.imageName,
            frameAspectRatio: frameAspectRatio,
            screenRectNormalized: screenRectNormalized,
            screenCornerRadiusNormalized: screenCornerRadiusNormalized,
            kind: kind
        )
    }
}

extension DeviceModel {
    /// iPhone 16 Pro and 17 Pro share rasterization: 450×920 frame, 402×874
    /// screen at (24, 23), ~60pt screen radius (relative to the PNG's 450 width).
    private static let pro16_17Geometry = (
        aspect: CGFloat(450.0 / 920.0),
        screenRect: CGRect(
            x: 24.0 / 450.0,
            y: 23.0 / 920.0,
            width: 402.0 / 450.0,
            height: 874.0 / 920.0
        ),
        cornerRadius: CGFloat(60.0 / 450.0)
    )

    /// iPhone 15 Pro: 473×932 frame, 393×852 screen (centered → 40pt inset on
    /// every edge). Corner radius kept proportional to the older render so the
    /// visual mask still matches Apple's screen radius.
    private static let pro15Geometry = (
        aspect: CGFloat(473.0 / 932.0),
        screenRect: CGRect(
            x: 40.0 / 473.0,
            y: 40.0 / 932.0,
            width: 393.0 / 473.0,
            height: 852.0 / 932.0
        ),
        cornerRadius: CGFloat(60.0 / 473.0)
    )

    /// Sentinel "color" used by non-physical models so callers can keep using
    /// `model.frame(for:)` without special-casing.
    private static let voidColor = DeviceColor(
        id: "default",
        name: "Default",
        imageName: "",
        swatchHex: "#000000"
    )

    static let none = DeviceModel(
        id: "no-frame",
        displayName: "No frame",
        // Aspect is irrelevant when kind == .none — the renderer falls back to
        // the source video's natural aspect. We seed a reasonable iPhone-ish
        // aspect for the brief moment before the video loads.
        frameAspectRatio: 9.0 / 19.5,
        screenRectNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
        screenCornerRadiusNormalized: 0.04,
        colors: [voidColor],
        kind: .none,
        symbol: "rectangle.dashed"
    )

    static let generic = DeviceModel(
        id: "generic-phone",
        displayName: "Generic",
        // Aspect/cornerRadius are seeded reasonably for the first frame; the
        // renderer overrides both at runtime: aspect = source video, corner =
        // user-controlled `Project.bareCornerRadius`. The screen rect fills
        // the entire phone box so the bezel can grow *outward* around it.
        frameAspectRatio: 9.0 / 19.5,
        screenRectNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
        screenCornerRadiusNormalized: 0.06,
        colors: [voidColor],
        kind: .generic,
        symbol: "iphone"
    )

    static let iPhone15Pro = DeviceModel(
        id: "iphone-15-pro",
        displayName: "iPhone 15 Pro",
        frameAspectRatio: pro15Geometry.aspect,
        screenRectNormalized: pro15Geometry.screenRect,
        screenCornerRadiusNormalized: pro15Geometry.cornerRadius,
        colors: [
            DeviceColor(id: "natural-titanium", name: "Natural Titanium",
                        imageName: "iPhone 15 Pro - Natural Titanium", swatchHex: "#8B8378"),
            DeviceColor(id: "black-titanium",   name: "Black Titanium",
                        imageName: "iPhone 15 Pro - Black Titanium",   swatchHex: "#3A3A3C"),
            DeviceColor(id: "white-titanium",   name: "White Titanium",
                        imageName: "iPhone 15 Pro - White Titanium",   swatchHex: "#E3E0DA")
        ],
        kind: .physical,
        symbol: "iphone"
    )

    static let iPhone16Pro = DeviceModel(
        id: "iphone-16-pro",
        displayName: "iPhone 16 Pro",
        frameAspectRatio: pro16_17Geometry.aspect,
        screenRectNormalized: pro16_17Geometry.screenRect,
        screenCornerRadiusNormalized: pro16_17Geometry.cornerRadius,
        colors: [
            DeviceColor(id: "natural-titanium", name: "Natural Titanium",
                        imageName: "iPhone 16 Pro - Natural Titanium ", swatchHex: "#BFB4A1"),
            DeviceColor(id: "black-titanium",   name: "Black Titanium",
                        imageName: "iPhone 16 Pro - Black Titanium",    swatchHex: "#3A3A3C"),
            DeviceColor(id: "white-titanium",   name: "White Titanium",
                        imageName: "iPhone 16 Pro - White Titanium",    swatchHex: "#E3E0DA"),
            DeviceColor(id: "gold-titanium",    name: "Desert Titanium",
                        imageName: "iPhone 16 Pro - Gold Titanium",     swatchHex: "#C9A77F")
        ],
        kind: .physical,
        symbol: "iphone"
    )

    static let iPhone17Pro = DeviceModel(
        id: "iphone-17-pro",
        displayName: "iPhone 17 Pro",
        frameAspectRatio: pro16_17Geometry.aspect,
        screenRectNormalized: pro16_17Geometry.screenRect,
        screenCornerRadiusNormalized: pro16_17Geometry.cornerRadius,
        colors: [
            DeviceColor(id: "cosmic-orange", name: "Cosmic Orange",
                        imageName: "iPhone 17 Pro - Cosmic Orange", swatchHex: "#E96A2C"),
            DeviceColor(id: "deep-blue",     name: "Deep Blue",
                        imageName: "iPhone 17 Pro - Deep Blue",     swatchHex: "#3F5476"),
            DeviceColor(id: "silver",        name: "Silver",
                        imageName: "iPhone 17 Pro - Silver",        swatchHex: "#C9CCD0")
        ],
        kind: .physical,
        symbol: "iphone"
    )

    /// MacBook Pro 14": 1216×735 PNG. The transparent screen hole is 966×628
    /// at (125, 18) but its edge has a 1px anti-aliased gradient, so we bleed
    /// the video rect 3px outward on every side (→ 972×634 at (122, 15)). The
    /// frame PNG sits on top of the video in the ZStack and hides the bleed,
    /// while killing the background sliver that used to peek through.
    static let macBookPro14 = DeviceModel(
        id: "macbook-pro-14",
        displayName: "MacBook Pro 14",
        frameAspectRatio: 1216.0 / 735.0,
        screenRectNormalized: CGRect(
            x: 122.0 / 1216.0,
            y: 15.0 / 735.0,
            width: 972.0 / 1216.0,
            height: 634.0 / 735.0
        ),
        screenCornerRadiusNormalized: 10.0 / 1216.0,
        colors: [
            DeviceColor(id: "silver", name: "Silver",
                        imageName: "MacBook Pro 14", swatchHex: "#C9CCD0")
        ],
        kind: .physical,
        symbol: "laptopcomputer"
    )

    /// iPad Pro 11" (M4), landscape: 1320×940 PNG. The transparent screen hole
    /// measures exactly 1210×834 at (55, 53) — the device's point resolution —
    /// with a ~1px anti-aliased edge and a 32px screen corner radius. As with
    /// the MacBook, we bleed the video rect 3px outward on every side
    /// (→ 1216×840 at (52, 50), corner 35px) so no background sliver shows
    /// through that soft edge; the frame PNG draws on top and hides the bleed.
    static let iPadPro11 = DeviceModel(
        id: "ipad-pro-11",
        displayName: "iPad Pro 11",
        frameAspectRatio: 1320.0 / 940.0,
        screenRectNormalized: CGRect(
            x: 52.0 / 1320.0,
            y: 50.0 / 940.0,
            width: 1216.0 / 1320.0,
            height: 840.0 / 940.0
        ),
        screenCornerRadiusNormalized: 35.0 / 1320.0,
        colors: [
            DeviceColor(id: "silver", name: "Silver",
                        imageName: "iPad Pro 11", swatchHex: "#C9CCD0")
        ],
        kind: .physical,
        symbol: "ipad.landscape"
    )

    static let all: [DeviceModel] = [
        .none, .generic, .iPhone17Pro, .iPhone16Pro, .iPhone15Pro, .iPadPro11, .macBookPro14
    ]

    static func model(id: String) -> DeviceModel? {
        all.first { $0.id == id }
    }
}

struct DeviceFrame: Hashable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let imageName: String
    let frameAspectRatio: CGFloat
    let screenRectNormalized: CGRect
    let screenCornerRadiusNormalized: CGFloat
    let kind: DeviceFrameKind

    static let iPhone15Pro = DeviceModel.iPhone15Pro.frame(for: DeviceModel.iPhone15Pro.defaultColor)

    func screenRect(in frameSize: CGSize) -> CGRect {
        CGRect(
            x: screenRectNormalized.minX * frameSize.width,
            y: screenRectNormalized.minY * frameSize.height,
            width: screenRectNormalized.width * frameSize.width,
            height: screenRectNormalized.height * frameSize.height
        )
    }

    func screenCornerRadius(in frameSize: CGSize) -> CGFloat {
        screenCornerRadiusNormalized * frameSize.width
    }
}
