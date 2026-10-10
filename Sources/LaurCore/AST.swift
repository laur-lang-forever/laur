// The syntax tree every Laur tool reads: the previewer, the checker, and later the
// Swift compiler, the language server, the design bar and AI edits. Every node keeps
// its source range so tools can always point back at the exact text.

public struct SourceFile: Equatable, Sendable {
    public var imports: [ImportDecl]
    public var components: [Component]

    public init(imports: [ImportDecl] = [], components: [Component] = []) {
        self.imports = imports
        self.components = components
    }

    public func component(named name: String) -> Component? {
        components.first { $0.name == name }
    }
}

/// `import Models.Product`
public struct ImportDecl: Equatable, Sendable {
    public var path: [String]
    public var range: SourceRange
}

/// `component ProductCard(product: Product) { ... }`
public struct Component: Equatable, Sendable {
    public var name: String
    public var nameRange: SourceRange
    public var params: [Param]
    /// The plain-language purpose, from `intent "..."`.
    public var intent: String?
    /// Top-level nodes of the `view { ... }` block, or nil when the component has none.
    public var view: [Node]?
    public var previews: [PreviewBlock]
    public var range: SourceRange

    public func param(named name: String) -> Param? {
        params.first { $0.name == name }
    }

    public func preview(named name: String) -> PreviewBlock? {
        previews.first { $0.name == name }
    }
}

/// `product: Product`
public struct Param: Equatable, Sendable {
    public var name: String
    public var type: TypeRef
    public var range: SourceRange
}

public indirect enum TypeRef: Equatable, Sendable, CustomStringConvertible {
    /// `Product`, `Models.Product`
    case named([String])
    /// `Product?`
    case optional(TypeRef)
    /// `[Product]`
    case array(TypeRef)

    public var description: String {
        switch self {
        case .named(let path): return path.joined(separator: ".")
        case .optional(let inner): return "\(inner)?"
        case .array(let inner): return "[\(inner)]"
        }
    }

    /// The last name in the type, ignoring `?` and `[]`. `[Models.Product]?` → `Product`.
    public var baseName: String {
        switch self {
        case .named(let path): return path.last ?? ""
        case .optional(let inner), .array(let inner): return inner.baseName
        }
    }

    public var isOptional: Bool {
        if case .optional = self { return true }
        return false
    }
}

/// One entry in a view block: an element like `text(...)`, or an `if`.
public indirect enum Node: Equatable, Sendable {
    case element(Element)
    case conditional(Conditional)

    public var range: SourceRange {
        switch self {
        case .element(let element): return element.range
        case .conditional(let conditional): return conditional.range
        }
    }

    /// The element, when this node is one.
    public var element: Element? {
        if case .element(let element) = self { return element }
        return nil
    }
}

/// A call in a view: `text(product.name, style: .headline)`, `stack(.vertical) { ... }`
/// or `list(products) { product in ... }`. The name is a primitive or another component.
public struct Element: Equatable, Sendable {
    public var name: String
    public var nameRange: SourceRange
    public var arguments: [Argument]
    /// The item name in `{ product in ... }`, for `list`.
    public var binding: Binding?
    /// The `{ ... }` block after the call, or nil when there isn't one.
    public var children: [Node]?
    public var range: SourceRange

    /// Arguments without a label, in order.
    public var positional: [Argument] { arguments.filter { $0.label == nil } }

    public func argument(_ label: String) -> Argument? {
        arguments.first { $0.label == label }
    }
}

/// `product in`, at the start of a `list` block.
public struct Binding: Equatable, Sendable {
    public var name: String
    public var range: SourceRange
}

/// `if a { ... } else if b { ... } else { ... }`
public struct Conditional: Equatable, Sendable {
    public struct Branch: Equatable, Sendable {
        public var condition: Expr
        public var body: [Node]
    }

    public var branches: [Branch]
    public var otherwise: [Node]?
    public var range: SourceRange
}

/// `style: .headline` or an unlabeled `product.name`.
public struct Argument: Equatable, Sendable {
    public var label: String?
    public var labelRange: SourceRange?
    public var value: Expr
    public var range: SourceRange
}

public struct Expr: Equatable, Sendable {
    public indirect enum Kind: Equatable, Sendable {
        /// `"Top pick"`
        case string(String)
        /// `8`, `0.5`
        case number(Double)
        /// `true`, `false`
        case bool(Bool)
        /// `.headline`, or `.sample(name: "x")` when it has arguments.
        case token(String, arguments: [Argument]?)
        /// `product.name`, `context.siblings.index`
        case path([String])
        /// `!isLast`, `-offset`
        case unary(String, Expr)
        /// `index + 1`, `a && b`, `count == 0`
        case binary(String, Expr, Expr)
        /// `"#\(index + 1) of \(count)"`
        case interpolation([InterpolationPart])
    }

    public enum InterpolationPart: Equatable, Sendable {
        case text(String)
        case expr(Expr)
    }

    public var kind: Kind
    public var range: SourceRange

    public init(_ kind: Kind, range: SourceRange) {
        self.kind = kind
        self.range = range
    }

    /// The token name when this is a token like `.md`.
    public var tokenName: String? {
        if case .token(let name, _) = kind { return name }
        return nil
    }

    /// Every property path used anywhere in this expression, with its range.
    public var paths: [(path: [String], range: SourceRange)] {
        switch kind {
        case .path(let path): return [(path, range)]
        case .unary(_, let operand): return operand.paths
        case .binary(_, let left, let right): return left.paths + right.paths
        case .interpolation(let parts):
            return parts.flatMap { part -> [(path: [String], range: SourceRange)] in
                if case .expr(let e) = part { return e.paths }
                return []
            }
        case .token(_, let arguments): return (arguments ?? []).flatMap { $0.value.paths }
        case .string, .number, .bool: return []
        }
    }
}

/// `preview "long name" { product: .sample(name: "...") }`
public struct PreviewBlock: Equatable, Sendable {
    public var name: String
    public var entries: [PreviewEntry]
    public var range: SourceRange

    public func entry(_ name: String) -> PreviewEntry? {
        entries.first { $0.name == name }
    }
}

public struct PreviewEntry: Equatable, Sendable {
    public var name: String
    public var nameRange: SourceRange
    public var value: Expr
}
