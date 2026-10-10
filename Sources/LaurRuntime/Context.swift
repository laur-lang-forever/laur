import LaurCore

/// Where one component instance sits on screen: what `context` reads inside it.
///
/// Indices are assigned while the screen is resolved, in reading order. Counts for
/// `reading` and `level` are filled in once the whole screen is known, which is why
/// they can be shown but can't decide an `if`.
public final class ContextInfo: Equatable, CustomStringConvertible {
    /// The component's name, like `ProductRow`.
    public let type: String

    public internal(set) var siblingIndex: Int
    public internal(set) var siblingCount: Int

    public internal(set) var readingIndex: Int
    public internal(set) var readingCount: Int?

    /// 0 for the previewed component, 1 for components inside it, and so on.
    public internal(set) var depth: Int
    public internal(set) var levelIndex: Int
    public internal(set) var levelCount: Int?

    /// The containing component's name, or "" for the previewed component.
    public let parentType: String
    /// Every component from the root down, with sibling positions:
    /// `ProductList/ProductRow[2]`. Logging will attach this to every event.
    public let path: String

    init(type: String, siblingIndex: Int, siblingCount: Int, readingIndex: Int, depth: Int, levelIndex: Int, parentType: String, path: String) {
        self.type = type
        self.siblingIndex = siblingIndex
        self.siblingCount = siblingCount
        self.readingIndex = readingIndex
        self.depth = depth
        self.levelIndex = levelIndex
        self.parentType = parentType
        self.path = path
    }

    public static func == (lhs: ContextInfo, rhs: ContextInfo) -> Bool { lhs === rhs }

    public var description: String {
        let reading = readingCount.map { "\(readingIndex)/\($0)" } ?? "\(readingIndex)/?"
        let level = levelCount.map { "\(levelIndex)/\($0)" } ?? "\(levelIndex)/?"
        return "siblings \(siblingIndex)/\(siblingCount) · reading \(reading) · depth \(depth) level \(level)"
    }

    /// Reads `context.<group>.<field>`.
    func value(group: String, field: String, at range: SourceRange?) throws -> Value {
        switch (group, field) {
        case ("siblings", "index"): return .number(Double(siblingIndex))
        case ("siblings", "count"): return .number(Double(siblingCount))
        case ("siblings", "isFirst"): return .bool(siblingIndex == 0)
        case ("siblings", "isLast"): return .bool(siblingIndex == siblingCount - 1)
        case ("reading", "index"): return .number(Double(readingIndex))
        case ("reading", "isFirst"): return .bool(readingIndex == 0)
        case ("reading", "count"):
            guard let readingCount else { throw notYetKnown("reading.count", at: range) }
            return .number(Double(readingCount))
        case ("level", "depth"): return .number(Double(depth))
        case ("level", "index"): return .number(Double(levelIndex))
        case ("level", "count"):
            guard let levelCount else { throw notYetKnown("level.count", at: range) }
            return .number(Double(levelCount))
        case ("parent", "type"): return .string(parentType)
        case ("parent", "path"):
            let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
            return .string(parentPath)
        default:
            throw RuntimeError("`context.\(group)` has no field `\(field)`", at: range)
        }
    }

    private func notYetKnown(_ field: String, at range: SourceRange?) -> RuntimeError {
        RuntimeError("`context.\(field)` isn't known until the whole screen is laid out, so it can't be used in `if`", at: range)
    }
}
