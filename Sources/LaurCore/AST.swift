// The syntax tree every Laur tool reads: the previewer, the checker, and later the
// Swift compiler, the language server, the design bar and AI edits. Every node keeps
// its source range so tools can always point back at the exact text.

public struct SourceFile: Equatable, Sendable {
    public var imports: [ImportDecl]
    public var services: [ServiceDecl]
    public var components: [Component]

    public init(imports: [ImportDecl] = [], services: [ServiceDecl] = [], components: [Component] = []) {
        self.imports = imports
        self.services = services
        self.components = components
    }

    public func component(named name: String) -> Component? {
        components.first { $0.name == name }
    }

    public func service(named name: String) -> ServiceDecl? {
        services.first { $0.name == name }
    }
}

/// Declares Swift functions Laur can call, so the checker knows their names, arguments
/// and results. Previews simulate them with sample data; compiled apps call the real ones.
///
///     service Orders {
///       fetch(userId: String) -> [Order]
///     }
public struct ServiceDecl: Equatable, Sendable {
    public var name: String
    public var nameRange: SourceRange
    public var functions: [ServiceFunction]
    public var range: SourceRange

    public func function(named name: String) -> ServiceFunction? {
        functions.first { $0.name == name }
    }
}

public struct ServiceFunction: Equatable, Sendable {
    public var name: String
    public var nameRange: SourceRange
    public var params: [Param]
    public var returns: TypeRef
    public var range: SourceRange
}

/// `load orders = Orders.fetch(userId: userId)`: starts when the component appears.
/// The view reads it with `when orders { loading {...} failed(e) {...} loaded(x) {...} }`.
public struct LoadDecl: Equatable, Sendable {
    public var name: String
    public var nameRange: SourceRange
    public var call: Expr
    public var range: SourceRange
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
    /// `state email: String = ""`, in declaration order.
    public var states: [StateDecl] = []
    /// `derived canSubmit = ...`, in declaration order (each can use the ones before it).
    public var derived: [DerivedDecl] = []
    /// `load orders = Orders.fetch(...)`
    public var loads: [LoadDecl] = []
    /// `action submit() { ... }`
    public var actions: [ActionDecl] = []
    /// Top-level nodes of the `view { ... }` block, or nil when the component has none.
    public var view: [Node]?
    public var previews: [PreviewBlock]
    public var range: SourceRange

    public func param(named name: String) -> Param? {
        params.first { $0.name == name }
    }

    public func state(named name: String) -> StateDecl? {
        states.first { $0.name == name }
    }

    public func action(named name: String) -> ActionDecl? {
        actions.first { $0.name == name }
    }

    public func load(named name: String) -> LoadDecl? {
        loads.first { $0.name == name }
    }

    public func preview(named name: String) -> PreviewBlock? {
        previews.first { $0.name == name }
    }
}

/// `state email: String = ""`: a value the component owns and its actions can change.
public struct StateDecl: Equatable, Sendable {
    public var name: String
    public var nameRange: SourceRange
    public var type: TypeRef
    public var initial: Expr
    public var range: SourceRange
}

/// `derived canSubmit = email.contains("@") && !submitting`: recomputed from other values.
public struct DerivedDecl: Equatable, Sendable {
    public var name: String
    public var nameRange: SourceRange
    public var value: Expr
    public var range: SourceRange
}

/// `action submit() { ... }`: the only place, besides a button's block, that changes state.
public struct ActionDecl: Equatable, Sendable {
    public var name: String
    public var nameRange: SourceRange
    public var body: [Statement]
    public var range: SourceRange
}

/// One step of an action.
public indirect enum Statement: Equatable, Sendable {
    /// `email = ""`, `count += 1`
    case assign(target: String, targetRange: SourceRange, op: String, value: Expr)
    /// `submit()`
    case call(name: String, range: SourceRange)
    /// `orders.reload()`
    case reload(name: String, range: SourceRange)
    /// `if a { ... } else if b { ... } else { ... }`
    case conditional(branches: [StatementBranch], otherwise: [Statement]?, range: SourceRange)

    public var range: SourceRange {
        switch self {
        case .assign(_, let targetRange, _, let value): return targetRange.union(value.range)
        case .call(_, let range): return range
        case .reload(_, let range): return range
        case .conditional(_, _, let range): return range
        }
    }
}

public struct StatementBranch: Equatable, Sendable {
    public var condition: Expr
    public var body: [Statement]
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
    /// `bind Number`: the caller passes `bind x`, and changes flow back to it.
    case binding(TypeRef)

    public var description: String {
        switch self {
        case .named(let path): return path.joined(separator: ".")
        case .optional(let inner): return "\(inner)?"
        case .array(let inner): return "[\(inner)]"
        case .binding(let inner): return "bind \(inner)"
        }
    }

    /// The last name in the type, ignoring `?`, `[]` and `bind`. `[Models.Product]?` → `Product`.
    public var baseName: String {
        switch self {
        case .named(let path): return path.last ?? ""
        case .optional(let inner), .array(let inner), .binding(let inner): return inner.baseName
        }
    }

    public var isBinding: Bool {
        if case .binding = self { return true }
        return false
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
    case when(When)

    public var range: SourceRange {
        switch self {
        case .element(let element): return element.range
        case .conditional(let conditional): return conditional.range
        case .when(let when): return when.range
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
    /// For `button`, the block is an action to run, not more elements.
    public var handler: [Statement]? = nil
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

/// `when orders { loading { ... } failed(error) { ... } loaded(items) { ... } }`
public struct When: Equatable, Sendable {
    public struct Branch: Equatable, Sendable {
        /// `loading`, `failed` or `loaded`.
        public var kind: String
        public var kindRange: SourceRange
        /// The name in `failed(error)` or `loaded(items)`.
        public var binding: Binding?
        public var body: [Node]
    }

    public var subject: String
    public var subjectRange: SourceRange
    public var branches: [Branch]
    public var range: SourceRange

    public func branch(_ kind: String) -> Branch? {
        branches.first { $0.kind == kind }
    }
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
        /// `bind email`: a reference to state, for fields and `bind` parameters.
        case bind(String)
        /// `email.contains("@")`: a built-in method on a value.
        case method(receiver: Expr, name: String, arguments: [Argument])
        /// `[1, 2, 3]`, `[]`
        case list([Expr])
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
        case .bind(let name): return [([name], range)]
        case .method(let receiver, _, let arguments):
            return receiver.paths + arguments.flatMap { $0.value.paths }
        case .list(let items): return items.flatMap(\.paths)
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
