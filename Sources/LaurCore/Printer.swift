/// Prints a syntax tree back out as canonical `.laur` source: two-space indents, one
/// element per line, arguments in a fixed order. This is the start of `laur fmt`, and
/// it's how tools that edit the tree (the design bar, AI edits) turn it back into text.
/// Comments aren't kept in the tree yet, so they don't survive printing.
public enum Printer {
    public static func print(_ file: SourceFile) -> String {
        var parts: [String] = []
        if !file.imports.isEmpty {
            parts.append(file.imports.map { "import \($0.path.joined(separator: "."))" }.joined(separator: "\n"))
        }
        parts += file.components.map { Printer.print($0) }
        return parts.joined(separator: "\n\n") + "\n"
    }

    public static func print(_ component: Component) -> String {
        var lines: [String] = []
        var header = "component \(component.name)"
        if !component.params.isEmpty {
            header += "(" + component.params.map { "\($0.name): \($0.type)" }.joined(separator: ", ") + ")"
        }
        lines.append(header + " {")

        var sections: [[String]] = []
        if let intent = component.intent {
            sections.append(["  intent \(quote(intent))"])
        }
        if !component.states.isEmpty || !component.derived.isEmpty {
            var section: [String] = component.states.map {
                "  state \($0.name): \($0.type) = \(print($0.initial))"
            }
            section += component.derived.map { "  derived \($0.name) = \(print($0.value))" }
            sections.append(section)
        }
        if let view = component.view {
            var section = ["  view {"]
            for node in view {
                section += print(node, indent: 2)
            }
            section.append("  }")
            sections.append(section)
        }
        for action in component.actions {
            var section = ["  action \(action.name)() {"]
            for statement in action.body {
                section += print(statement, indent: 2)
            }
            section.append("  }")
            sections.append(section)
        }
        if !component.previews.isEmpty {
            sections.append(component.previews.map { preview in
                let entries = preview.entries.map { "\($0.name): \(print($0.value))" }.joined(separator: ", ")
                return entries.isEmpty
                    ? "  preview \(quote(preview.name)) {}"
                    : "  preview \(quote(preview.name)) { \(entries) }"
            })
        }
        for (i, section) in sections.enumerated() {
            if i > 0 { lines.append("") }
            lines += section
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    public static func print(_ node: Node, indent: Int) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        switch node {
        case .element(let element):
            let call = "\(element.name)(\(print(element.arguments)))"
            if let handler = element.handler {
                return block(pad + call + " {", handler.flatMap { print($0, indent: indent + 1) }, close: pad + "}")
            }
            guard let children = element.children else {
                return [pad + call]
            }
            let binding = element.binding.map { " \($0.name) in" } ?? ""
            if children.isEmpty {
                return [pad + call + " {" + binding + " }"]
            }
            var lines = [pad + call + " {" + binding]
            for child in children {
                lines += print(child, indent: indent + 1)
            }
            lines.append(pad + "}")
            return lines

        case .conditional(let conditional):
            var lines: [String] = []
            for (i, branch) in conditional.branches.enumerated() {
                let keyword = i == 0 ? pad + "if" : pad + "} else if"
                lines.append("\(keyword) \(print(branch.condition)) {")
                for child in branch.body {
                    lines += print(child, indent: indent + 1)
                }
            }
            if let otherwise = conditional.otherwise {
                lines.append(pad + "} else {")
                for child in otherwise {
                    lines += print(child, indent: indent + 1)
                }
            }
            lines.append(pad + "}")
            return lines
        }
    }

    public static func print(_ statement: Statement, indent: Int) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        switch statement {
        case .assign(let target, _, let op, let value):
            return [pad + "\(target) \(op) \(print(value))"]
        case .call(let name, _):
            return [pad + "\(name)()"]
        case .conditional(let branches, let otherwise, _):
            var lines: [String] = []
            for (i, branch) in branches.enumerated() {
                lines.append(pad + (i == 0 ? "if " : "} else if ") + print(branch.condition) + " {")
                lines += branch.body.flatMap { print($0, indent: indent + 1) }
            }
            if let otherwise {
                lines.append(pad + "} else {")
                lines += otherwise.flatMap { print($0, indent: indent + 1) }
            }
            lines.append(pad + "}")
            return lines
        }
    }

    /// One short statement stays on the opening line, like `button("+") { count += 1 }`.
    private static func block(_ open: String, _ body: [String], close: String) -> [String] {
        if body.isEmpty { return [open + " }"] }
        if body.count == 1 { return [open + " " + body[0].trimmingLeadingSpaces() + " }"] }
        return [open] + body + [close]
    }

    public static func print(_ arguments: [Argument]) -> String {
        arguments.map { argument in
            if let label = argument.label {
                return "\(label): \(print(argument.value))"
            }
            return print(argument.value)
        }.joined(separator: ", ")
    }

    private static let precedence: [String: Int] = [
        "||": 1, "&&": 2, "==": 3, "!=": 3, "<": 4, "<=": 4, ">": 4, ">=": 4,
        "+": 5, "-": 5, "*": 6, "/": 6, "%": 6,
    ]

    public static func print(_ expr: Expr) -> String {
        switch expr.kind {
        case .string(let s): return quote(s)
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .path(let path): return path.joined(separator: ".")
        case .token(let name, let arguments):
            guard let arguments else { return ".\(name)" }
            return ".\(name)(\(print(arguments)))"
        case .unary(let op, let operand):
            if case .binary = operand.kind { return "\(op)(\(print(operand)))" }
            return op + print(operand)
        case .binary(let op, let left, let right):
            let mine = precedence[op] ?? 0
            // Parenthesize a side only when it binds looser than this operator (or equally,
            // on the right, since operators group left to right).
            func side(_ e: Expr, right: Bool) -> String {
                let text = Printer.print(e)
                guard case .binary(let inner, _, _) = e.kind else { return text }
                let theirs = Printer.precedence[inner] ?? 0
                return theirs < mine || (right && theirs == mine) ? "(\(text))" : text
            }
            return "\(side(left, right: false)) \(op) \(side(right, right: true))"
        case .bind(let name):
            return "bind \(name)"
        case .method(let receiver, let name, let arguments):
            var target = print(receiver)
            if case .binary = receiver.kind { target = "(\(target))" }
            if case .unary = receiver.kind { target = "(\(target))" }
            return "\(target).\(name)(\(print(arguments)))"
        case .interpolation(let parts):
            var out = "\""
            for part in parts {
                switch part {
                case .text(let text): out += escape(text)
                case .expr(let e): out += "\\(" + print(e) + ")"
                }
            }
            return out + "\""
        }
    }

    static func quote(_ s: String) -> String {
        "\"" + escape(s) + "\""
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out
    }
}

private extension String {
    func trimmingLeadingSpaces() -> String {
        String(drop { $0 == " " })
    }
}
