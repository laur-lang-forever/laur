import SwiftUI

/// Maps design token names (`.md`, `.headline`, `.secondary`) to concrete values.
/// This is the single place a design system plugs in; components only ever name tokens.
public struct Theme {
    public var spacing: [String: CGFloat]
    public var corners: [String: CGFloat]
    public var fonts: [String: Font]
    public var colors: [String: Color]
    public var imageSizes: [String: CGFloat]

    public static let standard = Theme(
        spacing: ["none": 0, "xs": 4, "sm": 8, "md": 12, "lg": 20, "xl": 32],
        corners: ["none": 0, "sm": 6, "md": 12, "lg": 20, "full": 999],
        fonts: [
            "largeTitle": .largeTitle.weight(.bold),
            "title": .title2.weight(.semibold),
            "headline": .headline,
            "body": .body,
            "callout": .callout,
            "caption": .caption,
            "footnote": .footnote,
        ],
        colors: [
            "primary": .primary,
            "secondary": .secondary,
            "tertiary": Color.secondary.opacity(0.6),
            "accent": .accentColor,
            "error": .red,
            "success": .green,
            "surface": Color.gray.opacity(0.12),
        ],
        imageSizes: ["thumbnail": 56, "small": 96, "medium": 160, "large": 260]
    )
}
