public enum TokenKind: Equatable, Sendable {
    case identifier(String)
    case string(String)
    case number(Double)
    case leftParen, rightParen
    case leftBrace, rightBrace
    case leftBracket, rightBracket
    case comma, colon, dot, question, arrow
    /// A character Laur doesn't use yet, like `=`. The parser reports it, so a
    /// keyword earlier on the line (like `state`) gets the clearer error first.
    case unknown(Character)
    case endOfFile

    /// How the token reads in an error message.
    public var display: String {
        switch self {
        case .identifier(let name): return "`\(name)`"
        case .string: return "a string"
        case .number: return "a number"
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
    private var line = 1
    private var column = 1

    public init(_ source: String) {
        // Treat Windows line endings like plain newlines so line numbers stay right.
        self.chars = Array(source).map { $0 == "\r\n" ? "\n" : $0 }
    }

    public static func tokenize(_ source: String) throws -> [Token] {
        var lexer = Lexer(source)
        return try lexer.tokenize()
    }

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
            case ".":
                advance()
                kind = .dot
            case "-" where peek(1) == ">":
                advance(); advance()
                kind = .arrow
            case "\"":
                kind = .string(try lexString())
            case _ where c.isDigit || (c == "-" && (peek(1)?.isDigit ?? false)):
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

    private mutating func lexNumber() -> Double {
        var text = ""
        if peek() == "-" {
            text.append("-")
            advance()
        }
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

    private mutating func lexString() throws -> String {
        let start = location
        advance() // opening quote
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
                return text
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
                    throw Diagnostic(
                        .error,
                        "string interpolation isn't supported yet",
                        at: SourceRange(start: escapeStart, end: location),
                        help: ["it's planned for a later milestone; pass the value as its own argument for now"]
                    )
                default:
                    throw Diagnostic(
                        .error,
                        "unknown escape `\\\(e)`",
                        at: SourceRange(start: escapeStart, end: location),
                        help: ["supported escapes are \\n, \\t, \\\" and \\\\"]
                    )
                }
                continue
            }
            text.append(c)
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
        SourceLocation(line: line, column: column, offset: index)
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
