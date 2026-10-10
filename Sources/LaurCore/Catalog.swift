/// The design tokens Laur understands. Values (points, fonts, colors) live in the
/// runtime's theme; the names live here so the checker can validate them without UI code.
public enum TokenCategory: String, CaseIterable, Sendable {
    case axis
    case spacing
    case alignment
    case textStyle = "text style"
    case color
    case corner
    case aspect
    case imageSize = "image size"

    public var names: [String] {
        switch self {
        case .axis: return ["vertical", "horizontal"]
        case .spacing: return ["none", "xs", "sm", "md", "lg", "xl"]
        case .alignment: return ["leading", "center", "trailing"]
        case .textStyle: return ["largeTitle", "title", "headline", "body", "callout", "caption", "footnote"]
        case .color: return ["primary", "secondary", "tertiary", "accent", "error", "success", "surface"]
        case .corner: return ["none", "sm", "md", "lg", "full"]
        case .aspect: return ["square", "wide", "tall", "fit"]
        case .imageSize: return ["thumbnail", "small", "medium", "large"]
        }
    }
}

/// What an argument accepts.
public enum ArgumentKind: Equatable, Sendable {
    /// Any value: a string, a number or a property like `product.name`.
    case value
    /// One of a token category's names.
    case token(TokenCategory)
    /// A token, or a raw number that the checker flags with a warning.
    case tokenOrNumber(TokenCategory)
}

/// The built-in elements a `view` can use.
public struct Primitive {
    public var name: String
    /// What each unlabeled argument accepts, in order.
    public var positional: [ArgumentKind]
    /// How many unlabeled arguments are required.
    public var requiredPositional: Int
    public var labeled: [(label: String, kind: ArgumentKind)]
    public var allowsChildren: Bool
    public var summary: String

    public func kind(forLabel label: String) -> ArgumentKind? {
        labeled.first { $0.label == label }?.kind
    }

    public static let all: [Primitive] = [
        Primitive(
            name: "stack",
            positional: [.token(.axis)],
            requiredPositional: 0,
            labeled: [
                ("spacing", .tokenOrNumber(.spacing)),
                ("padding", .tokenOrNumber(.spacing)),
                ("alignment", .token(.alignment)),
                ("background", .token(.color)),
                ("corner", .tokenOrNumber(.corner)),
            ],
            allowsChildren: true,
            summary: "lays out its children vertically or horizontally"
        ),
        Primitive(
            name: "text",
            positional: [.value],
            requiredPositional: 1,
            labeled: [
                ("style", .token(.textStyle)),
                ("color", .token(.color)),
            ],
            allowsChildren: false,
            summary: "shows a line of text"
        ),
        Primitive(
            name: "image",
            positional: [.value],
            requiredPositional: 1,
            labeled: [
                ("aspect", .token(.aspect)),
                ("corner", .tokenOrNumber(.corner)),
                ("size", .token(.imageSize)),
            ],
            allowsChildren: false,
            summary: "shows an image from a URL or a system symbol name"
        ),
        Primitive(
            name: "spacer",
            positional: [],
            requiredPositional: 0,
            labeled: [],
            allowsChildren: false,
            summary: "takes up the remaining space in a stack"
        ),
        Primitive(
            name: "divider",
            positional: [],
            requiredPositional: 0,
            labeled: [],
            allowsChildren: false,
            summary: "draws a thin separating line"
        ),
    ]

    public static func named(_ name: String) -> Primitive? {
        all.first { $0.name == name }
    }
}
