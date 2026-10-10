import Foundation
import LaurCore

/// A value while a component is being rendered.
public indirect enum Value: Equatable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case token(String)
    /// A record with named fields, such as a sample `Product`.
    case record([String: Value])
    case list([Value])
    case null

    /// How the value reads when shown with `text(...)`.
    public var description: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .token(let t): return ".\(t)"
        case .record(let fields): return "{" + fields.keys.sorted().joined(separator: ", ") + "}"
        case .list(let items): return "[\(items.count) items]"
        case .null: return ""
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Converts parsed JSON (from `samples.json`) into a value.
    public init(json: Any) {
        switch json {
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            // JSONSerialization uses NSNumber for both booleans and numbers.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let dict as [String: Any]:
            self = .record(dict.mapValues { Value(json: $0) })
        case let array as [Any]:
            self = .list(array.map { Value(json: $0) })
        default:
            self = .null
        }
    }
}

public struct RuntimeError: Error, CustomStringConvertible {
    public var message: String
    public var range: SourceRange?

    public init(_ message: String, at range: SourceRange? = nil) {
        self.message = message
        self.range = range
    }

    public var description: String {
        if let range { return "\(range.start): \(message)" }
        return message
    }
}

/// Sample data for previews, keyed by type name.
///
/// Loaded from a `samples.json` next to the `.laur` file:
///
///     {
///       "Product": {
///         "name": "Canvas Tote",
///         "price": "$48.00",
///         "photo": "bag.fill"
///       }
///     }
///
/// A preview writes `product: .sample` to use it, or `.sample(name: "...")` to
/// override fields. A list of objects gives `.sample` the first and
/// `.samples(n)` the first n.
public struct SampleData {
    public var types: [String: [Value]]

    public init(types: [String: [Value]] = [:]) {
        self.types = types
    }

    public init(jsonData: Data) throws {
        let json = try JSONSerialization.jsonObject(with: jsonData)
        guard let root = json as? [String: Any] else {
            throw RuntimeError("samples.json must be an object whose keys are type names")
        }
        var types: [String: [Value]] = [:]
        for (typeName, entry) in root {
            switch Value(json: entry) {
            case .list(let items): types[typeName] = items
            case let single: types[typeName] = [single]
            }
        }
        self.types = types
    }

    /// Resolves a preview value like `.sample` or `.sample(name: "x")` for a parameter of the given type.
    public func resolve(_ expr: Expr, type: TypeRef) throws -> Value {
        switch expr.kind {
        case .string(let s): return .string(s)
        case .number(let n): return .number(n)
        case .bool(let b): return .bool(b)
        case .path:
            throw RuntimeError("previews take fixed values, not properties", at: expr.range)
        case .token(let name, let arguments):
            let typeName = type.baseName
            switch name {
            case "sample":
                guard let base = types[typeName]?.first else {
                    throw RuntimeError("no sample data for `\(typeName)`; add a \"\(typeName)\" entry to samples.json", at: expr.range)
                }
                return try override(base, with: arguments ?? [])
            case "samples":
                guard let all = types[typeName], !all.isEmpty else {
                    throw RuntimeError("no sample data for `\(typeName)`; add a \"\(typeName)\" list to samples.json", at: expr.range)
                }
                var count = all.count
                if let first = arguments?.first, case .number(let n) = first.value.kind {
                    count = Int(n)
                }
                return .list((0..<count).map { all[$0 % all.count] })
            case "none", "nil":
                return .null
            default:
                return .token(name)
            }
        }
    }

    private func override(_ base: Value, with arguments: [Argument]) throws -> Value {
        guard !arguments.isEmpty else { return base }
        guard case .record(var fields) = base else {
            throw RuntimeError("only records can have fields overridden")
        }
        for argument in arguments {
            guard let label = argument.label else {
                throw RuntimeError("overrides are labeled, like `.sample(name: \"...\")`", at: argument.range)
            }
            fields[label] = try resolve(argument.value, type: .named(["_"]))
        }
        return .record(fields)
    }
}
