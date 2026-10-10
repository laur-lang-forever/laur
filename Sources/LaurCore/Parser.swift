/// A hand-written recursive-descent parser for `.laur` files.
///
/// Milestone 1 grammar:
///
///     file       := (import | component)*
///     import     := "import" name ("." name)*
///     component  := "component" Name ("(" params? ")")? "{" member* "}"
///     param      := name ":" type
///     type       := "[" type "]" "?"?  |  name ("." name)* "?"?
///     member     := "intent" string  |  "view" block  |  "preview" string "{" entry* "}"
///     block      := "{" node* "}"
///     node       := name "(" args? ")" block?
///     args       := arg ("," arg)* ","?
///     arg        := (name ":")? expr
///     expr       := string | number | "true" | "false"
///                 | "." name ("(" args? ")")?
///                 | name ("." name)*
///     entry      := name ":" expr ","?
///
/// Parsing stops at the first error, which is reported with the exact location and,
/// where it helps, where an unclosed block was opened.
public struct Parser {
    private var tokens: [Token]
    private var index = 0

    public init(tokens: [Token]) {
        self.tokens = tokens
    }

    /// Lexes and parses a whole file. Throws a `Diagnostic` on the first syntax error.
    public static func parse(_ source: String) throws -> SourceFile {
        var parser = Parser(tokens: try Lexer.tokenize(source))
        return try parser.parseFile()
    }

    // Keywords from the spec that are designed but not built yet. Using one gives a
    // clear "not supported yet" error instead of a confusing syntax error.
    private static let laterTopLevel: Set<String> = ["screen", "gate", "event", "native"]
    private static let laterMembers: Set<String> = ["state", "derived", "load", "action", "on", "slot", "title"]
    private static let laterNodes: Set<String> = ["if", "when", "switch", "list"]
    private static let memberKeywords: Set<String> = ["view", "preview", "intent"]

    // MARK: - File

    public mutating func parseFile() throws -> SourceFile {
        var file = SourceFile()
        while !check(.endOfFile) {
            let token = current
            guard case .identifier(let word) = token.kind else {
                throw error("expected `component` or `import`, found \(token.kind.display)", at: token.range)
            }
            switch word {
            case "import":
                file.imports.append(try parseImport())
            case "component":
                file.components.append(try parseComponent())
            default:
                if Self.laterTopLevel.contains(word) {
                    throw notYet(word, at: token.range)
                }
                throw error(
                    "expected `component` or `import`, found `\(word)`",
                    at: token.range,
                    help: ["every `.laur` file is a list of `component` declarations"]
                )
            }
        }
        return file
    }

    private mutating func parseImport() throws -> ImportDecl {
        let start = advance().range // `import`
        var path = [try expectIdentifier("a module name after `import`").name]
        var end = previous.range
        while match(.dot) {
            path.append(try expectIdentifier("a name after `.`").name)
            end = previous.range
        }
        return ImportDecl(path: path, range: start.union(end))
    }

    // MARK: - Component

    private mutating func parseComponent() throws -> Component {
        let keyword = advance() // `component`
        let (name, nameRange) = try expectIdentifier("a component name after `component`")
        if let first = name.first, !first.isUppercase {
            throw error(
                "component names start with an uppercase letter",
                at: nameRange,
                help: ["rename it to `\(first.uppercased() + String(name.dropFirst()))`"]
            )
        }

        var params: [Param] = []
        if match(.leftParen) {
            if !check(.rightParen) {
                repeat {
                    if check(.rightParen) { break } // trailing comma
                    params.append(try parseParam())
                } while match(.comma)
            }
            try expect(.rightParen, "`)` to close the parameter list of `\(name)`")
        }

        let open = try expect(.leftBrace, "`{` to start the body of `\(name)`")
        var intent: String?
        var view: [Node]?
        var previews: [PreviewBlock] = []

        while !check(.rightBrace) {
            if check(.endOfFile) {
                throw unclosed("`component \(name)`", openedAt: open.range)
            }
            if case .identifier("component") = current.kind {
                throw unclosed("`component \(name)`", openedAt: open.range, before: "component")
            }
            let token = current
            guard case .identifier(let word) = token.kind else {
                throw error(
                    "expected `view`, `preview` or `intent` inside `\(name)`, found \(token.kind.display)",
                    at: token.range
                )
            }
            switch word {
            case "intent":
                advance()
                guard case .string(let text) = current.kind else {
                    throw error("expected a string after `intent`", at: current.range,
                                help: ["for example: intent \"Show one product with its price\""])
                }
                if intent != nil {
                    throw error("`\(name)` already has an `intent`", at: token.range)
                }
                advance()
                intent = text
            case "view":
                advance()
                if view != nil {
                    throw error("`\(name)` already has a `view`", at: token.range,
                                help: ["a component has exactly one `view` block"])
                }
                view = try parseBlock(owner: "view")
            case "preview":
                let preview = try parsePreview()
                if previews.contains(where: { $0.name == preview.name }) {
                    throw error("`\(name)` already has a preview named \"\(preview.name)\"", at: preview.range)
                }
                previews.append(preview)
            default:
                if Self.laterMembers.contains(word) {
                    throw notYet(word, at: token.range)
                }
                throw error(
                    "unknown member `\(word)` in `\(name)`",
                    at: token.range,
                    help: ["a component contains `view`, `preview` and `intent` blocks"]
                )
            }
        }
        let close = advance() // `}`

        return Component(
            name: name,
            nameRange: nameRange,
            params: params,
            intent: intent,
            view: view,
            previews: previews,
            range: keyword.range.union(close.range)
        )
    }

    private mutating func parseParam() throws -> Param {
        let (name, nameRange) = try expectIdentifier("a parameter name")
        try expect(.colon, "`:` and a type after `\(name)`, like `\(name): String`")
        let type = try parseType()
        return Param(name: name, type: type, range: nameRange.union(previous.range))
    }

    private mutating func parseType() throws -> TypeRef {
        var type: TypeRef
        if match(.leftBracket) {
            type = .array(try parseType())
            try expect(.rightBracket, "`]` to close the array type")
        } else {
            var path = [try expectIdentifier("a type name").name]
            while match(.dot) {
                path.append(try expectIdentifier("a type name after `.`").name)
            }
            type = .named(path)
        }
        if match(.question) {
            type = .optional(type)
        }
        return type
    }

    // MARK: - Preview

    private mutating func parsePreview() throws -> PreviewBlock {
        let keyword = advance() // `preview`
        guard case .string(let name) = current.kind else {
            throw error("expected a name in quotes after `preview`", at: current.range,
                        help: ["for example: preview \"default\" { product: .sample }"])
        }
        advance()
        let open = try expect(.leftBrace, "`{` to start preview \"\(name)\"")
        var entries: [PreviewEntry] = []
        while !check(.rightBrace) {
            if check(.endOfFile) {
                throw unclosed("preview \"\(name)\"", openedAt: open.range)
            }
            let (entryName, entryRange) = try expectIdentifier("a parameter name inside preview \"\(name)\"")
            try expect(.colon, "`:` after `\(entryName)`")
            let value = try parseExpr()
            if entries.contains(where: { $0.name == entryName }) {
                throw error("`\(entryName)` is set twice in preview \"\(name)\"", at: entryRange)
            }
            entries.append(PreviewEntry(name: entryName, nameRange: entryRange, value: value))
            match(.comma)
        }
        let close = advance()
        return PreviewBlock(name: name, entries: entries, range: keyword.range.union(close.range))
    }

    // MARK: - View nodes

    private mutating func parseBlock(owner: String) throws -> [Node] {
        let open = try expect(.leftBrace, "`{` to start the `\(owner)` block")
        var nodes: [Node] = []
        while !check(.rightBrace) {
            if check(.endOfFile) {
                throw unclosed("`\(owner)`", openedAt: open.range)
            }
            // A component keyword here almost always means a `}` is missing above it.
            if case .identifier(let word) = current.kind, Self.memberKeywords.contains(word) {
                throw unclosed("`\(owner)`", openedAt: open.range, before: word)
            }
            nodes.append(try parseNode())
        }
        advance()
        return nodes
    }

    private mutating func parseNode() throws -> Node {
        let token = current
        guard case .identifier(let name) = token.kind else {
            throw error("expected an element like `text(...)`, found \(token.kind.display)", at: token.range)
        }
        if Self.laterNodes.contains(name) {
            throw notYet(name, at: token.range)
        }
        advance()
        guard check(.leftParen) else {
            throw error(
                "expected `(` after `\(name)`",
                at: current.range,
                help: ["elements are written like calls, even without arguments: `\(name)()`"]
            )
        }
        let arguments = try parseArguments(owner: name)
        var children: [Node]?
        if check(.leftBrace) {
            children = try parseBlock(owner: name)
        }
        return Node(
            name: name,
            nameRange: token.range,
            arguments: arguments,
            children: children,
            range: token.range.union(previous.range)
        )
    }

    /// Parses `( ... )`, starting at the `(`.
    private mutating func parseArguments(owner: String) throws -> [Argument] {
        let open = try expect(.leftParen, "`(`")
        var arguments: [Argument] = []
        while !check(.rightParen) {
            if check(.endOfFile) {
                throw unclosed("the arguments of `\(owner)`", openedAt: open.range, closer: ")")
            }
            arguments.append(try parseArgument())
            if match(.comma) { continue }
            if check(.rightParen) { break }
            throw error(
                "expected `,` or `)` after an argument to `\(owner)`, found \(current.kind.display)",
                at: current.range
            )
        }
        advance()
        return arguments
    }

    private mutating func parseArgument() throws -> Argument {
        var label: String?
        var labelRange: SourceRange?
        if case .identifier(let name) = current.kind, peekKind(1) == .colon {
            label = name
            labelRange = current.range
            advance()
            advance()
        }
        let value = try parseExpr()
        let start = labelRange ?? value.range
        return Argument(label: label, labelRange: labelRange, value: value, range: start.union(value.range))
    }

    // MARK: - Expressions

    private mutating func parseExpr() throws -> Expr {
        let token = current
        switch token.kind {
        case .string(let text):
            advance()
            return Expr(.string(text), range: token.range)
        case .number(let value):
            advance()
            return Expr(.number(value), range: token.range)
        case .dot:
            advance()
            let (name, nameRange) = try expectIdentifier("a token name after `.`, like `.md`")
            var arguments: [Argument]?
            if check(.leftParen) {
                arguments = try parseArguments(owner: ".\(name)")
            }
            return Expr(.token(name, arguments: arguments), range: token.range.union(arguments == nil ? nameRange : previous.range))
        case .identifier(let name):
            advance()
            if name == "true" { return Expr(.bool(true), range: token.range) }
            if name == "false" { return Expr(.bool(false), range: token.range) }
            var path = [name]
            while match(.dot) {
                path.append(try expectIdentifier("a property name after `.`").name)
            }
            if check(.leftParen) {
                throw error(
                    "calling functions isn't supported yet",
                    at: current.range,
                    help: ["milestone 1 supports values, properties like `product.name`, and tokens like `.md`"]
                )
            }
            return Expr(.path(path), range: token.range.union(previous.range))
        case .unknown(let c):
            throw error("unexpected character `\(c)`", at: token.range)
        default:
            throw error("expected a value, found \(token.kind.display)", at: token.range)
        }
    }

    // MARK: - Token helpers

    private var current: Token { tokens[index] }
    private var previous: Token { tokens[max(index - 1, 0)] }

    private func check(_ kind: TokenKind) -> Bool { current.kind == kind }

    private func peekKind(_ ahead: Int) -> TokenKind {
        let i = min(index + ahead, tokens.count - 1)
        return tokens[i].kind
    }

    @discardableResult
    private mutating func advance() -> Token {
        let token = tokens[index]
        if index < tokens.count - 1 { index += 1 }
        return token
    }

    @discardableResult
    private mutating func match(_ kind: TokenKind) -> Bool {
        guard check(kind) else { return false }
        advance()
        return true
    }

    @discardableResult
    private mutating func expect(_ kind: TokenKind, _ what: String) throws -> Token {
        guard check(kind) else {
            throw error("expected \(what), found \(current.kind.display)", at: current.range)
        }
        return advance()
    }

    private mutating func expectIdentifier(_ what: String) throws -> (name: String, range: SourceRange) {
        guard case .identifier(let name) = current.kind else {
            throw error("expected \(what), found \(current.kind.display)", at: current.range)
        }
        let range = advance().range
        return (name, range)
    }

    // MARK: - Errors

    private func error(_ message: String, at range: SourceRange, help: [String] = []) -> Diagnostic {
        Diagnostic(.error, message, at: range, help: help)
    }

    private func unclosed(_ what: String, openedAt open: SourceRange, closer: String = "}", before word: String? = nil) -> Diagnostic {
        if let word {
            return Diagnostic(
                .error,
                "expected `\(closer)` to close \(what), opened on line \(open.start.line), before `\(word)`",
                at: open,
                help: ["add the missing `\(closer)` above line \(current.range.start.line)"]
            )
        }
        return Diagnostic(
            .error,
            "expected `\(closer)` to close \(what), opened on line \(open.start.line)",
            at: open,
            help: ["the file ended before the matching `\(closer)`"]
        )
    }

    private func notYet(_ keyword: String, at range: SourceRange) -> Diagnostic {
        Diagnostic(
            .error,
            "`\(keyword)` isn't supported yet",
            at: range,
            help: ["it's in the spec, but milestone 1 only covers static components"]
        )
    }
}
