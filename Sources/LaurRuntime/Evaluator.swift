import LaurCore

/// Names visible while evaluating: parameters, list items, and `context`.
public typealias Scope = [String: Value]

/// Evaluates expressions: literals, properties, `context` fields, operators and interpolation.
public enum Evaluator {
    public static func evaluate(_ expr: Expr, in scope: Scope) throws -> Value {
        switch expr.kind {
        case .string(let s): return .string(s)
        case .number(let n): return .number(n)
        case .bool(let b): return .bool(b)
        case .token(let name, _): return .token(name)

        case .path(let path):
            return try lookup(path, in: scope, at: expr.range)

        case .interpolation(let parts):
            var text = ""
            for part in parts {
                switch part {
                case .text(let s): text += s
                case .expr(let inner): text += try evaluate(inner, in: scope).description
                }
            }
            return .string(text)

        case .unary(let op, let operand):
            let value = try evaluate(operand, in: scope)
            switch op {
            case "!":
                return .bool(!(try truth(value, at: operand.range)))
            case "-":
                guard case .number(let n) = value else {
                    throw RuntimeError("`-` needs a number, not `\(value)`", at: expr.range)
                }
                return .number(-n)
            default:
                throw RuntimeError("unknown operator `\(op)`", at: expr.range)
            }

        case .binary(let op, let leftExpr, let rightExpr):
            // `&&` and `||` stop early, so `a != nil && a.x` style checks work.
            if op == "&&" {
                return .bool(try truth(evaluate(leftExpr, in: scope), at: leftExpr.range)
                             && truth(evaluate(rightExpr, in: scope), at: rightExpr.range))
            }
            if op == "||" {
                return .bool(try truth(evaluate(leftExpr, in: scope), at: leftExpr.range)
                             || truth(evaluate(rightExpr, in: scope), at: rightExpr.range))
            }
            let left = try evaluate(leftExpr, in: scope)
            let right = try evaluate(rightExpr, in: scope)
            return try apply(op, left, right, at: expr.range)
        }
    }

    /// The truth of a condition. Only booleans count; an empty value counts as false.
    public static func truth(_ value: Value, at range: SourceRange?) throws -> Bool {
        switch value {
        case .bool(let b): return b
        case .null: return false
        default: throw RuntimeError("expected true or false, but got `\(value)`", at: range)
        }
    }

    private static func lookup(_ path: [String], in scope: Scope, at range: SourceRange) throws -> Value {
        guard var value = scope[path[0]] else {
            throw RuntimeError("`\(path[0])` isn't defined", at: range)
        }
        if case .context(let context) = value {
            guard path.count == 3 else {
                throw RuntimeError("use a `context` field like `context.siblings.index`", at: range)
            }
            return try context.value(group: path[1], field: path[2], at: range)
        }
        for field in path.dropFirst() {
            guard case .record(let fields) = value else {
                throw RuntimeError("`\(field)` can't be read from \(value == .null ? "an empty value" : "`\(value)`")", at: range)
            }
            guard let next = fields[field] else {
                let known = fields.keys.sorted().map { "`\($0)`" }.joined(separator: ", ")
                throw RuntimeError("the sample has no field `\(field)` (it has \(known))", at: range)
            }
            value = next
        }
        return value
    }

    private static func apply(_ op: String, _ left: Value, _ right: Value, at range: SourceRange) throws -> Value {
        switch op {
        case "==": return .bool(left == right)
        case "!=": return .bool(left != right)
        case "+":
            if case .number(let a) = left, case .number(let b) = right { return .number(a + b) }
            if case .string = left { return .string(left.description + right.description) }
            if case .string = right { return .string(left.description + right.description) }
            throw RuntimeError("`+` needs two numbers or a string, not `\(left)` and `\(right)`", at: range)
        case "<", "<=", ">", ">=":
            let ordered: Bool
            switch (left, right) {
            case (.number(let a), .number(let b)):
                ordered = op == "<" ? a < b : op == "<=" ? a <= b : op == ">" ? a > b : a >= b
            case (.string(let a), .string(let b)):
                ordered = op == "<" ? a < b : op == "<=" ? a <= b : op == ">" ? a > b : a >= b
            default:
                throw RuntimeError("`\(op)` compares two numbers or two strings, not `\(left)` and `\(right)`", at: range)
            }
            return .bool(ordered)
        case "-", "*", "/", "%":
            guard case .number(let a) = left, case .number(let b) = right else {
                throw RuntimeError("`\(op)` needs two numbers, not `\(left)` and `\(right)`", at: range)
            }
            switch op {
            case "-": return .number(a - b)
            case "*": return .number(a * b)
            default:
                guard b != 0 else { throw RuntimeError("division by zero", at: range) }
                return .number(op == "/" ? a / b : a.truncatingRemainder(dividingBy: b))
            }
        default:
            throw RuntimeError("unknown operator `\(op)`", at: range)
        }
    }
}
