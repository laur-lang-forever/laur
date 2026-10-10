/// A hand-written recursive-descent parser for `.laur` files.
///
/// Grammar so far:
///
///     file        := (import | component)*
///     import      := "import" name ("." name)*
///     component   := "component" Name ("(" params? ")")? "{" member* "}"
///     param       := name ":" type
///     type        := "bind" type  |  "[" type "]" "?"?  |  name ("." name)* "?"?
///     member      := "intent" string  |  "view" block  |  "preview" string "{" entry* "}"
///                  | "state" name ":" type "=" expr  |  "derived" name "=" expr
///                  | "action" name "()" "{" statement* "}"
///     statement   := name ("=" | "+=" | "-=") expr  |  name "()"
///                  | "if" expr "{" statement* "}" ("else" ...)?
///     block       := "{" (name "in")? node* "}"
///     node        := element | conditional
///     element     := name "(" args? ")" block?        (a `button`'s block holds statements)
///     conditional := "if" expr block ("else" "if" expr block)* ("else" block)?
///     args        := arg ("," arg)* ","?
///     arg         := (name ":")? expr
///     expr        := unary (binop unary)*          precedence: || && (== !=) (< <= > >=) (+ -) (* / %)
///     unary       := ("!" | "-") unary | primary
///     primary     := string | number | "true" | "false" | "(" expr ")"
///                  | "." name ("(" args? ")")?
///                  | "bind" name  |  name ("." name)*  |  name ("." name)+ "(" args? ")"
///     entry       := name ":" expr ","?
///
/// Strings can contain `\( expr )`. Parsing stops at the first error, which is reported
/// with the exact location and, where it helps, where an unclosed block was opened.
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
    private static let laterMembers: Set<String> = ["load", "on", "slot", "title"]
    private static let laterStatements: Set<String> = ["try", "await", "defer", "navigate", "present", "dismiss", "back", "log", "toast"]
    private static let laterNodes: Set<String> = ["when", "switch"]
    private static let memberKeywords: Set<String> = ["view", "preview", "intent", "state", "derived", "action"]

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
        var states: [StateDecl] = []
        var derived: [DerivedDecl] = []
        var actions: [ActionDecl] = []

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
                    "expected a member like `view` or `state` inside `\(name)`, found \(token.kind.display)",
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
            case "state":
                states.append(try parseState())
            case "derived":
                derived.append(try parseDerived())
            case "action":
                actions.append(try parseAction())
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
                    help: ["a component contains `state`, `derived`, `action`, `view`, `preview` and `intent`"]
                )
            }
        }
        let close = advance() // `}`

        return Component(
            name: name,
            nameRange: nameRange,
            params: params,
            intent: intent,
            states: states,
            derived: derived,
            actions: actions,
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
        if case .identifier("bind") = current.kind, case .identifier = peekKind(1) {
            advance()
            return .binding(try parseType())
        }
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

    // MARK: - State, derived values and actions

    /// `state email: String = ""`
    private mutating func parseState() throws -> StateDecl {
        let keyword = advance() // `state`
        let (name, nameRange) = try expectIdentifier("a name after `state`")
        try expect(.colon, "`:` and a type after `\(name)`, like `state \(name): String = \"\"`")
        let type = try parseType()
        guard case .symbol("=") = current.kind else {
            throw error("expected `=` and a starting value for `\(name)`", at: current.range,
                        help: ["state always starts with a value, like `state \(name): \(type) = ...`"])
        }
        advance()
        let initial = try parseExpr()
        return StateDecl(name: name, nameRange: nameRange, type: type, initial: initial, range: keyword.range.union(initial.range))
    }

    /// `derived canSubmit = ...`
    private mutating func parseDerived() throws -> DerivedDecl {
        let keyword = advance() // `derived`
        let (name, nameRange) = try expectIdentifier("a name after `derived`")
        guard case .symbol("=") = current.kind else {
            throw error("expected `=` after `\(name)`", at: current.range,
                        help: ["for example `derived \(name) = items.count > 0`"])
        }
        advance()
        let value = try parseExpr()
        return DerivedDecl(name: name, nameRange: nameRange, value: value, range: keyword.range.union(value.range))
    }

    /// `action submit() { ... }`
    private mutating func parseAction() throws -> ActionDecl {
        let keyword = advance() // `action`
        let (name, nameRange) = try expectIdentifier("a name after `action`")
        try expect(.leftParen, "`()` after `\(name)`")
        guard check(.rightParen) else {
            throw error("actions don't take parameters yet", at: current.range)
        }
        advance()
        if case .identifier("async") = current.kind {
            throw notYet("async", at: current.range)
        }
        let body = try parseStatementBlock(owner: "action \(name)")
        return ActionDecl(name: name, nameRange: nameRange, body: body, range: keyword.range.union(previous.range))
    }

    /// `{ statement* }`
    private mutating func parseStatementBlock(owner: String) throws -> [Statement] {
        let open = try expect(.leftBrace, "`{` to start the `\(owner)` block")
        var statements: [Statement] = []
        while !check(.rightBrace) {
            if check(.endOfFile) {
                throw unclosed("`\(owner)`", openedAt: open.range)
            }
            if case .identifier(let word) = current.kind, Self.memberKeywords.contains(word) {
                throw unclosed("`\(owner)`", openedAt: open.range, before: word)
            }
            statements.append(try parseStatement())
        }
        advance()
        return statements
    }

    private mutating func parseStatement() throws -> Statement {
        let token = current
        guard case .identifier(let name) = token.kind else {
            throw error("expected a statement like `count += 1` or `submit()`, found \(token.kind.display)", at: token.range)
        }
        if name == "if" {
            advance()
            var branches: [StatementBranch] = []
            var otherwise: [Statement]?
            while true {
                let condition = try parseExpr()
                branches.append(StatementBranch(condition: condition, body: try parseStatementBlock(owner: "if")))
                guard case .identifier("else") = current.kind else { break }
                advance()
                if case .identifier("if") = current.kind {
                    advance()
                    continue
                }
                otherwise = try parseStatementBlock(owner: "else")
                break
            }
            return .conditional(branches: branches, otherwise: otherwise, range: token.range.union(previous.range))
        }
        if Self.laterStatements.contains(name) {
            throw notYet(name, at: token.range)
        }
        advance()
        if check(.leftParen) {
            advance()
            guard check(.rightParen) else {
                throw error("actions don't take arguments yet", at: current.range)
            }
            let close = advance()
            return .call(name: name, range: token.range.union(close.range))
        }
        if case .symbol(let op) = current.kind, op == "=" || op == "+=" || op == "-=" {
            advance()
            let value = try parseExpr()
            return .assign(target: name, targetRange: token.range, op: op, value: value)
        }
        if check(.dot) {
            throw error("only whole state values can be assigned", at: current.range,
                        help: ["assign `\(name)` itself; changing one field of a value comes later"])
        }
        throw error(
            "expected `=`, `+=`, `-=` or `()` after `\(name)`, found \(current.kind.display)",
            at: current.range,
            help: ["a statement changes state (`\(name) = ...`) or runs an action (`\(name)()`)"]
        )
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
        let (binding, nodes) = try parseBlockBody(owner: owner)
        if let binding {
            throw error(
                "only `list` blocks name their items",
                at: binding.range,
                help: ["remove `\(binding.name) in`"]
            )
        }
        return nodes
    }

    /// Parses `{ ... }`, including an optional `name in` at the start.
    private mutating func parseBlockBody(owner: String) throws -> (Binding?, [Node]) {
        let open = try expect(.leftBrace, "`{` to start the `\(owner)` block")
        var binding: Binding?
        if case .identifier(let name) = current.kind, peekKind(1) == .identifier("in") {
            binding = Binding(name: name, range: current.range)
            advance()
            advance()
        }
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
        return (binding, nodes)
    }

    private mutating func parseNode() throws -> Node {
        let token = current
        guard case .identifier(let name) = token.kind else {
            throw error("expected an element like `text(...)`, found \(token.kind.display)", at: token.range)
        }
        if name == "if" {
            return .conditional(try parseConditional())
        }
        if name == "else" {
            throw error("`else` without an `if` before it", at: token.range)
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
        if name == "button" {
            // A button's block is what happens on tap: statements, not elements.
            var handler: [Statement]?
            if check(.leftBrace) {
                handler = try parseStatementBlock(owner: "button")
            }
            return .element(Element(
                name: name,
                nameRange: token.range,
                arguments: arguments,
                binding: nil,
                children: nil,
                handler: handler,
                range: token.range.union(previous.range)
            ))
        }
        var binding: Binding?
        var children: [Node]?
        if check(.leftBrace) {
            let body = try parseBlockBody(owner: name)
            binding = body.0
            children = body.1
        }
        return .element(Element(
            name: name,
            nameRange: token.range,
            arguments: arguments,
            binding: binding,
            children: children,
            range: token.range.union(previous.range)
        ))
    }

    private mutating func parseConditional() throws -> Conditional {
        let start = advance() // `if`
        var branches: [Conditional.Branch] = []
        var otherwise: [Node]?
        while true {
            let condition = try parseExpr()
            let body = try parseBlock(owner: "if")
            branches.append(Conditional.Branch(condition: condition, body: body))
            guard case .identifier("else") = current.kind else { break }
            advance()
            if case .identifier("if") = current.kind {
                advance()
                continue
            }
            otherwise = try parseBlock(owner: "else")
            break
        }
        return Conditional(branches: branches, otherwise: otherwise, range: start.range.union(previous.range))
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

    /// Binary operators, loosest first. Operators on the same line bind equally and
    /// group left to right.
    private static let precedence: [String: Int] = [
        "||": 1,
        "&&": 2,
        "==": 3, "!=": 3,
        "<": 4, "<=": 4, ">": 4, ">=": 4,
        "+": 5, "-": 5,
        "*": 6, "/": 6, "%": 6,
    ]

    public mutating func parseExpr() throws -> Expr {
        try parseBinary(minimumPrecedence: 1)
    }

    private mutating func parseBinary(minimumPrecedence: Int) throws -> Expr {
        var left = try parseUnary()
        while case .symbol(let op) = current.kind,
              let precedence = Self.precedence[op],
              precedence >= minimumPrecedence {
            advance()
            let right = try parseBinary(minimumPrecedence: precedence + 1)
            left = Expr(.binary(op, left, right), range: left.range.union(right.range))
        }
        return left
    }

    private mutating func parseUnary() throws -> Expr {
        if case .symbol(let op) = current.kind, op == "!" || op == "-" {
            let start = advance()
            let operand = try parseUnary()
            return Expr(.unary(op, operand), range: start.range.union(operand.range))
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> Expr {
        let token = current
        switch token.kind {
        case .string(let text):
            advance()
            return Expr(.string(text), range: token.range)
        case .interpolated(let parts):
            advance()
            var result: [Expr.InterpolationPart] = []
            for part in parts {
                switch part {
                case .text(let text):
                    result.append(.text(text))
                case .code(let code, let start):
                    result.append(.expr(try Self.parseInterpolation(code, start: start, in: token.range)))
                }
            }
            return Expr(.interpolation(result), range: token.range)
        case .number(let value):
            advance()
            return Expr(.number(value), range: token.range)
        case .leftParen:
            advance()
            var inner = try parseExpr()
            let close = try expect(.rightParen, "`)` to close the parenthesis")
            inner.range = token.range.union(close.range)
            return inner
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
            if name == "bind", case .identifier(let target) = current.kind {
                let targetToken = advance()
                if check(.dot) {
                    throw error("`bind` takes a whole state value, not a field", at: current.range)
                }
                return Expr(.bind(target), range: token.range.union(targetToken.range))
            }
            var path = [name]
            var pathEnd = token.range
            while match(.dot) {
                let receiverEnd = pathEnd
                path.append(try expectIdentifier("a property name after `.`").name)
                pathEnd = previous.range
                if check(.leftParen) {
                    // `email.contains("@")`: a method on the value before the last dot.
                    let method = path.removeLast()
                    let receiverRange = token.range.union(receiverEnd)
                    let arguments = try parseArguments(owner: method)
                    var expr = Expr(.method(receiver: Expr(.path(path), range: receiverRange), name: method, arguments: arguments),
                                    range: token.range.union(previous.range))
                    // Allow chains like `name.lowercased().contains("a")`.
                    while match(.dot) {
                        let (next, _) = try expectIdentifier("a method name after `.`")
                        guard check(.leftParen) else {
                            throw error("expected `(` after `\(next)`; properties of method results come later", at: current.range)
                        }
                        let more = try parseArguments(owner: next)
                        expr = Expr(.method(receiver: expr, name: next, arguments: more), range: token.range.union(previous.range))
                    }
                    return expr
                }
            }
            if check(.leftParen) {
                throw error(
                    "`\(name)(...)` can't be called here",
                    at: current.range,
                    help: ["actions run from a button: `button(\"Go\") { \(name)() }`; built-in methods look like `text.contains(\"a\")`"]
                )
            }
            return Expr(.path(path), range: token.range.union(previous.range))
        case .unknown(let c):
            throw error("unexpected character `\(c)`", at: token.range)
        default:
            throw error("expected a value, found \(token.kind.display)", at: token.range)
        }
    }

    /// Parses the code inside `\( ... )` as one expression.
    private static func parseInterpolation(_ code: String, start: SourceLocation, in string: SourceRange) throws -> Expr {
        let tokens = try Lexer.tokenize(code, startingAt: start)
        var parser = Parser(tokens: tokens)
        if parser.check(.endOfFile) {
            throw Diagnostic(.error, "empty interpolation", at: string, help: ["put a value inside `\\( )`, like `\\(product.name)`"])
        }
        let expr = try parser.parseExpr()
        if !parser.check(.endOfFile) {
            throw Diagnostic(.error, "expected `)` to end the interpolation, found \(parser.current.kind.display)", at: parser.current.range)
        }
        return expr
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
