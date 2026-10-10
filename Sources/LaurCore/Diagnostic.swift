/// A position in a `.laur` file. Lines and columns start at 1.
public struct SourceLocation: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var line: Int
    public var column: Int
    /// Offset in characters (not bytes) from the start of the file.
    public var offset: Int

    public init(line: Int, column: Int, offset: Int) {
        self.line = line
        self.column = column
        self.offset = offset
    }

    public static let start = SourceLocation(line: 1, column: 1, offset: 0)

    public var description: String { "\(line):\(column)" }
}

/// A span of source text. `end` is exclusive.
public struct SourceRange: Equatable, Hashable, Sendable {
    public var start: SourceLocation
    public var end: SourceLocation

    public init(start: SourceLocation, end: SourceLocation) {
        self.start = start
        self.end = end
    }

    public init(_ location: SourceLocation) {
        self.start = location
        self.end = location
    }

    /// The smallest range covering both.
    public func union(_ other: SourceRange) -> SourceRange {
        SourceRange(
            start: start.offset <= other.start.offset ? start : other.start,
            end: end.offset >= other.end.offset ? end : other.end
        )
    }
}

/// A message about the source, with enough position information to point at the exact text.
public struct Diagnostic: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public var severity: Severity
    public var message: String
    public var range: SourceRange
    /// Extra hints shown under the source excerpt, such as "did you mean `stack`?".
    public var help: [String]

    public init(_ severity: Severity = .error, _ message: String, at range: SourceRange, help: [String] = []) {
        self.severity = severity
        self.message = message
        self.range = range
        self.help = help
    }

    public var description: String { "\(range.start): \(severity.rawValue): \(message)" }

    /// Renders the diagnostic the way the compiler and previewer show it:
    ///
    ///     error: unknown element `stak`
    ///      --> ProductCard.laur:6:5
    ///       |
    ///     6 |     stak(.vertical, spacing: .md) {
    ///       |     ^^^^
    ///       = help: did you mean `stack`?
    public func render(source: String, fileName: String) -> String {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let lineNumber = range.start.line
        let gutter = String(repeating: " ", count: String(lineNumber).count)

        var out = "\(severity.rawValue): \(message)\n"
        out += "\(gutter)--> \(fileName):\(range.start.line):\(range.start.column)\n"

        if lineNumber >= 1 && lineNumber <= lines.count {
            let text = String(lines[lineNumber - 1])
            let startColumn = max(range.start.column, 1)
            var width = 1
            if range.end.line == range.start.line {
                width = max(range.end.column - range.start.column, 1)
            }
            // Don't draw carets past the end of the line.
            width = max(1, min(width, max(text.count - startColumn + 1, 1)))
            let pad = String(repeating: " ", count: startColumn - 1)
            out += "\(gutter) |\n"
            out += "\(lineNumber) | \(text)\n"
            out += "\(gutter) | \(pad)\(String(repeating: "^", count: width))\n"
        }
        for hint in help {
            out += "\(gutter) = help: \(hint)\n"
        }
        return out
    }
}

extension Array where Element == Diagnostic {
    public var hasErrors: Bool { contains { $0.severity == .error } }
}
