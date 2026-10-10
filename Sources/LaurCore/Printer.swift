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
        if let view = component.view {
            var section = ["  view {"]
            for node in view {
                section += print(node, indent: 2)
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
        let call = "\(node.name)(\(print(node.arguments)))"
        guard let children = node.children else {
            return [pad + call]
        }
        if children.isEmpty {
            return [pad + call + " {}"]
        }
        var lines = [pad + call + " {"]
        for child in children {
            lines += print(child, indent: indent + 1)
        }
        lines.append(pad + "}")
        return lines
    }

    public static func print(_ arguments: [Argument]) -> String {
        arguments.map { argument in
            if let label = argument.label {
                return "\(label): \(print(argument.value))"
            }
            return print(argument.value)
        }.joined(separator: ", ")
    }

    public static func print(_ expr: Expr) -> String {
        switch expr.kind {
        case .string(let s): return quote(s)
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .path(let path): return path.joined(separator: ".")
        case .token(let name, let arguments):
            guard let arguments else { return ".\(name)" }
            return ".\(name)(\(print(arguments)))"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out + "\""
    }
}
