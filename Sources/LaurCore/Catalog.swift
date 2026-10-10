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
    case keyboard
    case buttonStyle = "button style"

    public var names: [String] {
        switch self {
        case .axis: return ["vertical", "horizontal"]
        case .spacing: return ["none", "xs", "sm", "md", "lg", "xl"]
        case .alignment: return ["leading", "center", "trailing"]
        case .textStyle: return ["largeTitle", "title", "headline", "body", "callout", "caption", "footnote"]
        case .color: return ["primary", "secondary", "tertiary", "accent", "error", "success", "warning", "surface", "inverse"]
        case .corner: return ["none", "sm", "md", "lg", "full"]
        case .aspect: return ["square", "wide", "tall", "fit"]
        case .imageSize: return ["thumbnail", "small", "medium", "large"]
        case .keyboard: return ["text", "email", "number", "phone", "url"]
        case .buttonStyle: return ["primary", "secondary", "plain", "destructive"]
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
    /// `bind someState`: a two-way reference the element reads and writes.
    case binding
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
    /// Labeled arguments that must be passed, like `value:` on a `field`.
    public var requiredLabels: [String] = []

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
            name: "list",
            positional: [.value],
            requiredPositional: 1,
            labeled: [
                ("axis", .token(.axis)),
                ("spacing", .tokenOrNumber(.spacing)),
            ],
            allowsChildren: true,
            summary: "repeats its block once for each item in a collection"
        ),
        Primitive(
            name: "badge",
            positional: [.value],
            requiredPositional: 1,
            labeled: [
                ("color", .token(.color)),
            ],
            allowsChildren: false,
            summary: "shows a short label in a pill"
        ),
        Primitive(
            name: "field",
            positional: [.value],
            requiredPositional: 1,
            labeled: [
                ("value", .binding),
                ("secure", .value),
                ("keyboard", .token(.keyboard)),
            ],
            allowsChildren: false,
            summary: "lets the user type text into a `state` value",
            requiredLabels: ["value"]
        ),
        Primitive(
            name: "toggle",
            positional: [.value],
            requiredPositional: 1,
            labeled: [
                ("value", .binding),
            ],
            allowsChildren: false,
            summary: "switches a `Bool` state value on and off",
            requiredLabels: ["value"]
        ),
        Primitive(
            name: "button",
            positional: [.value],
            requiredPositional: 1,
            labeled: [
                ("style", .token(.buttonStyle)),
                ("enabled", .value),
            ],
            allowsChildren: false,
            summary: "runs its block when tapped"
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

/// What `context` offers inside a component. Each group answers one question about
/// where the component sits, with its own `index` and `count` so they never get mixed up.
public enum ContextSchema {
    public struct Group {
        public var name: String
        public var fields: [String]
        public var summary: String
    }

    public static let groups: [Group] = [
        Group(name: "siblings", fields: ["index", "count", "isFirst", "isLast"],
              summary: "position among the items next to it in the nearest container"),
        Group(name: "reading", fields: ["index", "count", "isFirst"],
              summary: "position in reading order across the whole screen (depth-first)"),
        Group(name: "level", fields: ["depth", "index", "count"],
              summary: "nesting depth, and position among components at the same depth (breadth-first)"),
        Group(name: "parent", fields: ["type", "path"],
              summary: "the component that contains this one"),
    ]

    /// Designed, but arriving with a later milestone.
    public static let laterGroups: [String: String] = [
        "screen": "geometric context (visibility, position on screen) arrives with `on appear` events",
    ]

    /// Fields only known once the whole screen is laid out. Because `if` decides what's
    /// laid out, these can be shown but can't be used in an `if` condition.
    public static let knownAfterLayout: Set<[String]> = [
        ["reading", "count"],
        ["level", "count"],
    ]

    public static func group(named name: String) -> Group? {
        groups.first { $0.name == name }
    }
}

/// Types a `state` value can have so far.
public enum StateTypes {
    public static let all: [String] = ["String", "Number", "Bool"]
}

/// Built-in properties and methods on values, like `email.count` or `email.contains("@")`.
public enum BuiltIns {
    /// Properties available on strings and lists.
    public static let properties: [String] = ["count", "isEmpty"]

    /// Method name → number of arguments.
    public static let methods: [String: Int] = [
        "contains": 1,
        "hasPrefix": 1,
        "hasSuffix": 1,
        "lowercased": 0,
        "uppercased": 0,
        "trimmed": 0,
    ]
}
