public enum TokenKind: Equatable, Sendable {
    case identifier(String)
    /// A string without interpolation.
    case string(String)
    /// A string with `\(...)` interpolation, split into text and code.
    case interpolated([StringPart])
    case number(Double)
    /// An operator: `==` `!=` `!` `&&` `||` `<` `<=` `>` `>=` `+` `-` `*` `/` `%`,
    /// or an assignment: `=` `+=` `-=`
    case symbol(String)
    case leftParen, rightParen
    case leftBrace, rightBrace
    case leftBracket, rightBracket
    case comma, colon, dot, question, arrow
    /// A character Laur doesn't use, like `@`. The parser reports it, so a
    /// keyword earlier on the line (like `state`) gets the clearer error first.
    case unknown(Character)
    case endOfFile

    /// How the token reads in an error message.
    public var display: String {
        switch self {
        case .identifier(let name): return "`\(name)`"
        case .string, .interpolated: return "a string"
        case .number: return "a number"
        case .symbol(let op): return "`\(op)`"
        case .leftParen: return "`(`"
        case .rightParen: return "`)`"
        case .leftBrace: return "`{`"
        case .rightBrace: return "`}`"
        case .leftBracket: return "`[`"
        case .rightBracket: return "`]`"
        case .comma: return "`,`"
        case .colon: return "`:`"
        case .dot: return "`.`"
        case .question: return "`?`"
        case .arrow: return "`->`"
        case .unknown(let c): return "`\(c)`"
        case .endOfFile: return "the end of the file"
        }
    }
}

/// A piece of an interpolated string literal.
public enum StringPart: Equatable, Sendable {
    case text(String)
    /// The source inside `\( ... )`, and where it starts, so errors point at the right place.
    case code(String, start: SourceLocation)
}

public struct Token: Equatable, Sendable {
    public var kind: TokenKind
    public var range: SourceRange

    public init(kind: TokenKind, range: SourceRange) {
        self.kind = kind
        self.range = range
    }
}

/// Splits `.laur` source into tokens. Newlines and `//` comments are skipped;
/// the grammar never depends on line breaks.
public struct Lexer {
    private let chars: [Character]
    private var index = 0
    private var line: Int
    private var column: Int
    private let baseOffset: Int

    /// - Parameter start: where this source begins in the file. Used to lex the code
    ///   inside string interpolation with correct positions.
    public init(_ source: String, startingAt start: SourceLocation = .start) {
        // Treat Windows line endings like plain newlines so line numbers stay right.
        self.chars = Array(source).map { $0 == "\r\n" ? "\n" : $0 }
        self.line = start.line
        self.column = start.column
        self.baseOffset = start.offset
    }

    public static func tokenize(_ source: String, startingAt start: SourceLocation = .start) throws -> [Token] {
        var lexer = Lexer(source, startingAt: start)
        return try lexer.tokenize()
    }

    private static let twoCharacterSymbols: Set<String> = ["==", "!=", "&&", "||", "<=", ">=", "+=", "-="]
    private static let oneCharacterSymbols: Set<Character> = ["!", "<", ">", "+", "-", "*", "/", "%", "="]

    public mutating func tokenize() throws -> [Token] {
        var tokens: [Token] = []
        while true {
            skipTrivia()
            let start = location
            guard let c = peek() else {
                tokens.append(Token(kind: .endOfFile, range: SourceRange(start)))
                return tokens
            }

            let kind: TokenKind
            let pair = peek(1).map { String([c, $0]) } ?? ""
            switch c {
            case "(": advance(); kind = .leftParen
            case ")": advance(); kind = .rightParen
            case "{": advance(); kind = .leftBrace
            case "}": advance(); kind = .rightBrace
            case "[": advance(); kind = .leftBracket
            case "]": advance(); kind = .rightBracket
            case ",": advance(); kind = .comma
            case ":": advance(); kind = .colon
            case "?": advance(); kind = .question
            case ".": advance(); kind = .dot
            case "-" where peek(1) == ">":
                advance(); advance()
                kind = .arrow
            case "\"":
                kind = try lexString()
            case _ where Self.twoCharacterSymbols.contains(pair):
                advance(); advance()
                kind = .symbol(pair)
            case _ where Self.oneCharacterSymbols.contains(c):
                advance()
                kind = .symbol(String(c))
            case _ where c.isDigit:
                kind = .number(lexNumber())
            case _ where c.isLetter || c == "_":
                kind = .identifier(lexIdentifier())
            default:
                advance()
                kind = .unknown(c)
            }
            tokens.append(Token(kind: kind, range: SourceRange(start: start, end: location)))
        }
    }

    // MARK: - Pieces

    private mutating func lexIdentifier() -> String {
        var text = ""
        while let c = peek(), c.isLetter || c.isNumber || c == "_" {
            text.append(c)
            advance()
        }
        return text
    }

    /// Negative numbers are a unary minus applied to a number, so `index-1` reads as subtraction.
    private mutating func lexNumber() -> Double {
        var text = ""
        while let c = peek(), c.isDigit {
            text.append(c)
            advance()
        }
        // A dot only belongs to the number when a digit follows (so `8.` stays two tokens).
        if peek() == ".", let next = peek(1), next.isDigit {
            text.append(".")
            advance()
            while let c = peek(), c.isDigit {
                text.append(c)
                advance()
            }
        }
        return Double(text) ?? 0
    }

    private mutating func lexString() throws -> TokenKind {
        let start = location
        advance() // opening quote
        var parts: [StringPart] = []
        var text = ""
        while true {
            guard let c = peek(), c != "\n" else {
                throw Diagnostic(
                    .error,
                    "this string is never closed",
                    at: SourceRange(start: start, end: location),
                    help: ["add a `\"` before the end of the line"]
                )
            }
            if c == "\"" {
                advance()
                if parts.isEmpty { return .string(text) }
                if !text.isEmpty { parts.append(.text(text)) }
                return .interpolated(parts)
            }
            if c == "\\" {
                let escapeStart = location
                advance()
                guard let e = peek() else { continue }
                advance()
                switch e {
                case "n": text.append("\n")
                case "t": text.append("\t")
                case "\"": text.append("\"")
                case "\\": text.append("\\")
                case "(":
                    if !text.isEmpty { parts.append(.text(text)) }
                    text = ""
                    parts.append(try lexInterpolation(openedAt: escapeStart))
                default:
                    throw Diagnostic(
                        .error,
                        "unknown escape `\\\(e)`",
                        at: SourceRange(start: escapeStart, end: location),
                        help: ["supported escapes are \\n, \\t, \\\", \\\\ and \\( ... ) for interpolation"]
                    )
                }
                continue
            }
            text.append(c)
            advance()
        }
    }

    /// Reads the code inside `\( ... )`, up to the matching `)`. The opening `\(` is consumed.
    private mutating func lexInterpolation(openedAt open: SourceLocation) throws -> StringPart {
        let codeStart = location
        var code = ""
        var depth = 1
        while true {
            guard let c = peek(), c != "\n" else {
                throw Diagnostic(
                    .error,
                    "this interpolation is never closed",
                    at: SourceRange(start: open, end: location),
                    help: ["add a `)` to end the `\\(`"]
                )
            }
            if c == "(" { depth += 1 }
            if c == ")" {
                depth -= 1
                if depth == 0 {
                    advance()
                    return .code(code, start: codeStart)
                }
            }
            if c == "\"" {
                // A string inside the interpolation: copy it whole so its parentheses don't count.
                code.append(c)
                advance()
                while let s = peek(), s != "\"", s != "\n" {
                    code.append(s)
                    advance()
                    if s == "\\", let escaped = peek() {
                        code.append(escaped)
                        advance()
                    }
                }
                if peek() == "\"" {
                    code.append("\"")
                    advance()
                }
                continue
            }
            code.append(c)
            advance()
        }
    }

    private mutating func skipTrivia() {
        while let c = peek() {
            if c.isWhitespace {
                advance()
            } else if c == "/" && peek(1) == "/" {
                while let c = peek(), c != "\n" { advance() }
            } else {
                return
            }
        }
    }

    // MARK: - Cursor

    private var location: SourceLocation {
        SourceLocation(line: line, column: column, offset: baseOffset + index)
    }

    private func peek(_ ahead: Int = 0) -> Character? {
        let i = index + ahead
        return i < chars.count ? chars[i] : nil
    }

    private mutating func advance() {
        guard index < chars.count else { return }
        if chars[index] == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        index += 1
    }
}

private extension Character {
    var isDigit: Bool { isASCII && isNumber }
}
