/// Checks a parsed file for mistakes the grammar can't catch: unknown elements, wrong
/// argument labels, tokens that don't exist, undefined names, invalid `context` fields
/// and missing previews.
/// Unlike the parser, it reports every problem it finds, not just the first.
public struct Checker {
    private let file: SourceFile
    private var diagnostics: [Diagnostic] = []

    public init(file: SourceFile) {
        self.file = file
    }

    public static func check(_ file: SourceFile) -> [Diagnostic] {
        var checker = Checker(file: file)
        return checker.run()
    }

    public mutating func run() -> [Diagnostic] {
        diagnostics = []
        var seen: Set<String> = []
        for component in file.components {
            if !seen.insert(component.name).inserted {
                report("there's already a component named `\(component.name)` in this file", at: component.nameRange)
            }
            checkComponent(component)
        }
        return diagnostics.sorted { $0.range.start.offset < $1.range.start.offset }
    }

    // MARK: - Components

    private mutating func checkComponent(_ component: Component) {
        // `context` is always in scope: every component knows where it sits.
        let scope = checkMembers(component, base: Set(component.params.map(\.name) + ["context"]))

        if let view = component.view {
            if view.isEmpty {
                report("the `view` of `\(component.name)` is empty", at: component.nameRange,
                       help: ["add an element, like `text(\"Hello\")`"])
            }
            checkNodes(view, in: component, scope: scope)
        } else {
            report("`\(component.name)` has no `view`", at: component.nameRange,
                   help: ["add `view { ... }` describing what it shows"])
        }

        if component.previews.isEmpty {
            report(
                "`\(component.name)` needs at least one `preview`",
                at: component.nameRange,
                help: [
                    "previews render the component on its own and double as its tests",
                    "add `preview \"default\" { \(component.params.map { "\($0.name): .sample" }.joined(separator: ", ")) }`",
                ]
            )
        }
        for preview in component.previews {
            checkPreview(preview, of: component)
        }
    }

    /// Checks `state`, `derived` and `action` declarations, and returns every name the
    /// view can use.
    private mutating func checkMembers(_ component: Component, base: Set<String>) -> Set<String> {
        var scope = base
        var declared: Set<String> = Set(component.params.map(\.name))

        for state in component.states {
            if !declared.insert(state.name).inserted {
                report("`\(state.name)` is already declared in `\(component.name)`", at: state.nameRange)
            }
            if case .named(let path) = state.type, path.count == 1, StateTypes.all.contains(path[0]) {
                if let mismatch = literalMismatch(state.initial, expected: path[0]) {
                    report("`\(state.name)` is a \(path[0]), but starts as \(mismatch)", at: state.initial.range)
                }
            } else {
                report(
                    "state can be \(StateTypes.all.map { "`\($0)`" }.joined(separator: ", ")) for now",
                    at: state.nameRange,
                    help: ["`\(state.type)` state comes in a later milestone"]
                )
            }
            checkExpr(state.initial, argument: "the starting value of `\(state.name)`", scope: scope, component: component)
            scope.insert(state.name)
        }

        for derived in component.derived {
            if !declared.insert(derived.name).inserted {
                report("`\(derived.name)` is already declared in `\(component.name)`", at: derived.nameRange)
            }
            checkExpr(derived.value, argument: "`\(derived.name)`", scope: scope, component: component)
            scope.insert(derived.name)
        }

        var actionNames: Set<String> = []
        for action in component.actions {
            if !actionNames.insert(action.name).inserted {
                report("there's already an action named `\(action.name)`", at: action.nameRange)
            }
            checkStatements(action.body, in: component, scope: scope)
        }
        return scope
    }

    /// Describes a literal whose type plainly doesn't match, like a string for a `Number`.
    private func literalMismatch(_ expr: Expr, expected: String) -> String? {
        switch (expr.kind, expected) {
        case (.string, "String"), (.interpolation, "String"), (.number, "Number"), (.bool, "Bool"): return nil
        case (.unary("-", _), "Number"), (.unary("!", _), "Bool"): return nil
        case (.string, _), (.interpolation, _): return "a string"
        case (.number, _): return "a number"
        case (.bool, _): return "`true` or `false`"
        default: return nil
        }
    }

    // MARK: - Actions

    private mutating func checkStatements(_ statements: [Statement], in component: Component, scope: Set<String>) {
        for statement in statements {
            switch statement {
            case .assign(let target, let targetRange, let op, let value):
                checkAssignable(target, at: targetRange, in: component, scope: scope)
                checkExpr(value, argument: "the new value of `\(target)`", scope: scope, component: component)
                if op != "=", case .string = value.kind {
                    report("`\(op)` works on numbers", at: value.range,
                           help: ["to change text, assign the whole value: `\(target) = ...`"])
                }
            case .call(let name, let range):
                if component.action(named: name) == nil {
                    var help = suggestion(for: name, in: component.actions.map(\.name))
                    if component.actions.isEmpty {
                        help.append("declare it with `action \(name)() { ... }`")
                    }
                    report("`\(component.name)` has no action `\(name)`", at: range, help: help)
                }
            case .conditional(let branches, let otherwise, _):
                for branch in branches {
                    checkExpr(branch.condition, argument: "an `if` condition", scope: scope, component: component)
                    checkStatements(branch.body, in: component, scope: scope)
                }
                if let otherwise {
                    checkStatements(otherwise, in: component, scope: scope)
                }
            }
        }
    }

    /// Only `state` and `bind` parameters can change.
    private mutating func checkAssignable(_ name: String, at range: SourceRange, in component: Component, scope: Set<String>) {
        if component.state(named: name) != nil { return }
        if let param = component.param(named: name) {
            if param.type.isBinding { return }
            report("`\(name)` is a parameter, so it can't be changed here", at: range,
                   help: ["make it `state`, or declare the parameter as `\(name): bind \(param.type)` so the caller's state changes"])
        } else if component.derived.contains(where: { $0.name == name }) {
            report("`\(name)` is derived from other values, so it can't be assigned", at: range,
                   help: ["change the values it's derived from instead"])
        } else if name == "context" {
            report("`context` is read-only", at: range)
        } else {
            let candidates = component.states.map(\.name) + component.params.filter { $0.type.isBinding }.map(\.name)
            report("`\(name)` isn't a state value in `\(component.name)`", at: range,
                   help: suggestion(for: name, in: candidates) + ["declare it with `state \(name): Number = 0`"])
        }
    }

    /// `bind x` needs `x` to be state or a `bind` parameter.
    private mutating func checkBindTarget(_ name: String, at range: SourceRange, in component: Component, scope: Set<String>) {
        if component.state(named: name) != nil { return }
        if let param = component.param(named: name), param.type.isBinding { return }
        if scope.contains(name) {
            report("`\(name)` can't be bound", at: range,
                   help: ["only `state` values and `bind` parameters can be bound"])
        } else {
            report("`\(name)` isn't defined in `\(component.name)`", at: range,
                   help: suggestion(for: name, in: component.states.map(\.name)))
        }
    }

    private mutating func checkPreview(_ preview: PreviewBlock, of component: Component) {
        let paramNames = component.params.map(\.name)
        for entry in preview.entries {
            if entry.name == "context" {
                checkPreviewContext(entry)
                continue
            }
            guard component.param(named: entry.name) != nil || component.state(named: entry.name) != nil else {
                report(
                    "`\(entry.name)` isn't a parameter or state of `\(component.name)`",
                    at: entry.nameRange,
                    help: suggestion(for: entry.name, in: paramNames + component.states.map(\.name) + ["context"])
                )
                continue
            }
            if !entry.value.paths.isEmpty {
                report("previews take fixed values, not properties", at: entry.value.range,
                       help: ["use a literal like \"Canvas Tote\" or a sample like `.sample`"])
            }
        }
        for param in component.params where !param.type.isOptional && preview.entry(param.name) == nil {
            report(
                "preview \"\(preview.name)\" is missing a value for `\(param.name)`",
                at: preview.range,
                help: ["add `\(param.name): .sample`"]
            )
        }
    }

    /// `context: .siblings(2, of: 5)` places the previewed component as if it were the
    /// third of five items.
    private mutating func checkPreviewContext(_ entry: PreviewEntry) {
        let help = ["for example `context: .siblings(2, of: 5)` or `context: .reading(0, of: 3)`"]
        guard case .token(let name, let arguments) = entry.value.kind,
              name == "siblings" || name == "reading",
              let args = arguments, args.count == 2,
              args[0].label == nil, args[1].label == "of",
              case .number(let index) = args[0].value.kind,
              case .number(let count) = args[1].value.kind else {
            report("a preview's `context` is `.siblings(index, of: count)` or `.reading(index, of: count)`",
                   at: entry.value.range, help: help)
            return
        }
        if index != index.rounded() || count != count.rounded() || index < 0 || count < 1 || index >= count {
            report("`.\(name)(\(formatNumber(index)), of: \(formatNumber(count)))` isn't a valid position",
                   at: entry.value.range,
                   help: ["the index is counted from 0, so it must be a whole number less than the count"])
        }
    }

    // MARK: - Nodes

    private mutating func checkNodes(_ nodes: [Node], in component: Component, scope: Set<String>) {
        for node in nodes {
            switch node {
            case .element(let element):
                checkElement(element, in: component, scope: scope)
            case .conditional(let conditional):
                for branch in conditional.branches {
                    checkCondition(branch.condition, in: component, scope: scope)
                    checkNodes(branch.body, in: component, scope: scope)
                }
                if let otherwise = conditional.otherwise {
                    checkNodes(otherwise, in: component, scope: scope)
                }
            }
        }
    }

    private mutating func checkElement(_ node: Element, in component: Component, scope: Set<String>) {
        if let primitive = Primitive.named(node.name) {
            checkPrimitive(node, primitive, in: component, scope: scope)
        } else if let target = file.component(named: node.name) {
            checkComponentUse(node, target, in: component, scope: scope)
        } else {
            let candidates = Primitive.all.map(\.name) + file.components.map(\.name)
            var help = suggestion(for: node.name, in: candidates)
            if help.isEmpty {
                help = ["built-in elements are \(Primitive.all.map { "`\($0.name)`" }.joined(separator: ", "))"]
            }
            report("unknown element `\(node.name)`", at: node.nameRange, help: help)
        }

        var childScope = scope
        if node.name == "list" {
            if let binding = node.binding {
                if scope.contains(binding.name) {
                    report("`\(binding.name)` is already defined here", at: binding.range,
                           help: ["pick another name for each item"])
                }
                childScope.insert(binding.name)
            } else if node.children != nil {
                report("`list` needs a name for each item", at: node.nameRange,
                       help: ["write it like `list(products) { product in ... }`"])
            } else {
                report("`list` needs a block to repeat for each item", at: node.nameRange,
                       help: ["write it like `list(products) { product in ProductRow(product: product) }`"])
            }
        } else if let binding = node.binding {
            report("only `list` blocks name their items", at: binding.range,
                   help: ["remove `\(binding.name) in`"])
        }

        if let children = node.children {
            checkNodes(children, in: component, scope: childScope)
        }
    }

    /// An `if` condition: a normal expression, minus the context fields that are only
    /// known after the screen is laid out.
    private mutating func checkCondition(_ expr: Expr, in component: Component, scope: Set<String>) {
        checkExpr(expr, argument: "an `if` condition", scope: scope, component: component)
        for (path, range) in expr.paths where path.count == 3 && path[0] == "context" && scope.contains("context") {
            let field = Array(path[1...])
            if ContextSchema.knownAfterLayout.contains(field) {
                report(
                    "`\(path.joined(separator: "."))` can't be used in an `if`",
                    at: range,
                    help: ["it's only known once the whole screen is laid out, and `if` changes what's laid out; you can still show it with `text`"]
                )
            }
        }
    }

    private mutating func checkPrimitive(_ node: Element, _ primitive: Primitive, in component: Component, scope: Set<String>) {
        let positional = node.positional
        for (i, argument) in positional.enumerated() {
            if i < primitive.positional.count {
                checkValue(argument.value, accepts: primitive.positional[i], argument: "the first argument of `\(primitive.name)`", scope: scope, component: component)
            } else {
                let count = primitive.positional.count
                let takes = count == 0 ? "takes no unlabeled arguments" : "takes \(count) unlabeled argument\(count == 1 ? "" : "s")"
                report("`\(primitive.name)` \(takes)", at: argument.range,
                       help: labelHelp(primitive))
            }
        }
        if positional.count < primitive.requiredPositional {
            report(
                "`\(primitive.name)` needs a value",
                at: node.nameRange,
                help: ["`\(primitive.name)` \(primitive.summary); for example `\(primitive.name)(\"...\")`"]
            )
        }

        var seenLabels: Set<String> = []
        for argument in node.arguments {
            guard let label = argument.label, let labelRange = argument.labelRange else { continue }
            if !seenLabels.insert(label).inserted {
                report("`\(label)` is passed twice", at: labelRange)
                continue
            }
            guard let kind = primitive.kind(forLabel: label) else {
                let valid = primitive.labeled.map(\.label)
                var help = suggestion(for: label, in: valid)
                help += labelHelp(primitive)
                report("`\(primitive.name)` has no argument `\(label)`", at: labelRange, help: help)
                continue
            }
            checkValue(argument.value, accepts: kind, argument: "`\(label)`", scope: scope, component: component)
        }

        for label in primitive.requiredLabels where node.argument(label) == nil {
            report("`\(primitive.name)` needs a `\(label):` argument", at: node.nameRange,
                   help: ["for example `\(primitive.name)(\"Email\", \(label): bind email)`"])
        }
        if primitive.name == "button" {
            if let handler = node.handler {
                checkStatements(handler, in: component, scope: scope)
            } else {
                report("`button` needs a block that says what happens on tap", at: node.nameRange,
                       help: ["for example `button(\"Save\") { save() }`"])
            }
        }

        if node.children != nil && !primitive.allowsChildren {
            report(
                "`\(primitive.name)` can't contain other elements",
                at: node.nameRange,
                help: ["wrap them in a `stack` instead"]
            )
        }
    }

    private mutating func checkComponentUse(_ node: Element, _ target: Component, in component: Component, scope: Set<String>) {
        if target.name == component.name {
            report("`\(component.name)` can't contain itself", at: node.nameRange)
            return
        }
        var passed: Set<String> = []
        let paramNames = target.params.map(\.name)
        for argument in node.arguments {
            guard let label = argument.label, let labelRange = argument.labelRange else {
                report(
                    "arguments to components are labeled",
                    at: argument.range,
                    help: target.params.first.map { ["write `\(target.name)(\($0.name): ...)`"] } ?? []
                )
                continue
            }
            guard target.param(named: label) != nil else {
                report("`\(target.name)` has no parameter `\(label)`", at: labelRange,
                       help: suggestion(for: label, in: paramNames))
                continue
            }
            passed.insert(label)
            let isBindParam = target.param(named: label)?.type.isBinding ?? false
            if isBindParam {
                checkValue(argument.value, accepts: .binding, argument: "`\(label)`", scope: scope, component: component)
            } else if case .bind = argument.value.kind {
                report("`\(label)` isn't a `bind` parameter of `\(target.name)`", at: argument.value.range,
                       help: ["pass the value itself, or declare it as `\(label): bind ...` in `\(target.name)`"])
            } else {
                checkValue(argument.value, accepts: .value, argument: "`\(label)`", scope: scope, component: component)
            }
        }
        for param in target.params where !param.type.isOptional && !passed.contains(param.name) {
            report("`\(target.name)` needs a value for `\(param.name)`", at: node.nameRange)
        }
        if node.children != nil {
            report("`\(target.name)` can't contain other elements yet", at: node.nameRange,
                   help: ["slots are planned for a later milestone"])
        }
    }

    // MARK: - Values

    private mutating func checkValue(_ expr: Expr, accepts kind: ArgumentKind, argument: String, scope: Set<String>, component: Component) {
        switch (expr.kind, kind) {
        case (_, .value):
            checkExpr(expr, argument: argument, scope: scope, component: component)

        case (.bind(let name), .binding):
            checkBindTarget(name, at: expr.range, in: component, scope: scope)

        case (_, .binding):
            report("\(argument) takes `bind` and a state name", at: expr.range,
                   help: ["for example `value: bind email`, where `email` is a `state` value"])

        case (.token(let name, let arguments), .token(let category)),
             (.token(let name, let arguments), .tokenOrNumber(let category)):
            if arguments != nil {
                report("`.\(name)` doesn't take arguments here", at: expr.range)
            } else if !category.names.contains(name) {
                var help = suggestion(for: name, in: category.names, prefix: ".")
                help.append("\(category.rawValue) tokens are \(category.names.map { ".\($0)" }.joined(separator: ", "))")
                report("`.\(name)` isn't a \(category.rawValue) token", at: expr.range, help: help)
            }

        case (.number(let value), .tokenOrNumber(let category)):
            report(
                .warning,
                "raw number `\(formatNumber(value))` bypasses the design tokens",
                at: expr.range,
                help: ["use a \(category.rawValue) token like `.\(category.names[min(3, category.names.count - 1)])` so designs stay consistent"]
            )

        case (_, .token(let category)), (_, .tokenOrNumber(let category)):
            report(
                "\(argument) takes a \(category.rawValue) token",
                at: expr.range,
                help: ["for example `.\(category.names[min(1, category.names.count - 1)])`"]
            )
        }
    }

    /// Any value expression: literals, properties, operators and interpolation.
    private mutating func checkExpr(_ expr: Expr, argument: String, scope: Set<String>, component: Component) {
        switch expr.kind {
        case .string, .number, .bool:
            break
        case .path(let path):
            checkPath(path, at: expr.range, scope: scope, component: component)
        case .token(let name, _):
            report("\(argument) expects a value, not the token `.\(name)`", at: expr.range)
        case .unary(_, let operand):
            checkExpr(operand, argument: argument, scope: scope, component: component)
        case .binary(_, let left, let right):
            checkExpr(left, argument: argument, scope: scope, component: component)
            checkExpr(right, argument: argument, scope: scope, component: component)
        case .interpolation(let parts):
            for case .expr(let inner) in parts {
                checkExpr(inner, argument: argument, scope: scope, component: component)
            }
        case .bind:
            report("`bind` passes state to a field, a toggle or a `bind` parameter", at: expr.range,
                   help: ["to read the value here, drop `bind`"])
        case .method(let receiver, let name, let arguments):
            checkExpr(receiver, argument: argument, scope: scope, component: component)
            if let arity = BuiltIns.methods[name] {
                if arguments.count != arity {
                    report("`\(name)` takes \(arity == 0 ? "no arguments" : "\(arity) argument\(arity == 1 ? "" : "s")")", at: expr.range)
                }
            } else {
                var help = suggestion(for: name, in: Array(BuiltIns.methods.keys))
                help.append("built-in methods are \(BuiltIns.methods.keys.sorted().map { "`\($0)`" }.joined(separator: ", "))")
                report("there's no built-in method `\(name)`", at: expr.range, help: help)
            }
            for argument in arguments where argument.label != nil {
                report("built-in methods take unlabeled arguments", at: argument.range)
            }
            for argument in arguments {
                checkExpr(argument.value, argument: "an argument to `\(name)`", scope: scope, component: component)
            }
        }
    }

    private mutating func checkPath(_ path: [String], at range: SourceRange, scope: Set<String>, component: Component) {
        let root = path[0]
        guard scope.contains(root) else {
            report("`\(root)` isn't defined in `\(component.name)`", at: range,
                   help: suggestion(for: root, in: scope.sorted()))
            return
        }
        guard root == "context" else { return }

        let groupNames = ContextSchema.groups.map(\.name)
        let groupList = groupNames.map { "`context.\($0)`" }.joined(separator: ", ")
        guard path.count >= 2 else {
            report("`context` on its own isn't a value", at: range,
                   help: ["use a field, like `context.siblings.index`", "groups are \(groupList)"])
            return
        }
        let groupName = path[1]
        if let later = ContextSchema.laterGroups[groupName] {
            report("`context.\(groupName)` isn't supported yet", at: range, help: [later])
            return
        }
        guard let group = ContextSchema.group(named: groupName) else {
            var help = suggestion(for: groupName, in: groupNames, prefix: "context.")
            help.append("groups are \(groupList)")
            report("`context` has no group `\(groupName)`", at: range, help: help)
            return
        }
        let fieldList = group.fields.map { "`\($0)`" }.joined(separator: ", ")
        guard path.count >= 3 else {
            report("`context.\(groupName)` on its own isn't a value", at: range,
                   help: ["its fields are \(fieldList)"])
            return
        }
        let field = path[2]
        guard group.fields.contains(field) else {
            var help = suggestion(for: field, in: group.fields)
            help.append("`context.\(groupName)` has \(fieldList)")
            report("`context.\(groupName)` has no field `\(field)`", at: range, help: help)
            return
        }
        if path.count > 3 {
            report("`context.\(groupName).\(field)` has no fields", at: range)
        }
    }

    // MARK: - Helpers

    private func labelHelp(_ primitive: Primitive) -> [String] {
        if primitive.labeled.isEmpty { return ["`\(primitive.name)` takes no labeled arguments"] }
        return ["`\(primitive.name)` accepts \(primitive.labeled.map { "`\($0.label):`" }.joined(separator: ", "))"]
    }

    private mutating func report(_ message: String, at range: SourceRange, help: [String] = []) {
        diagnostics.append(Diagnostic(.error, message, at: range, help: help))
    }

    private mutating func report(_ severity: Diagnostic.Severity, _ message: String, at range: SourceRange, help: [String] = []) {
        diagnostics.append(Diagnostic(severity, message, at: range, help: help))
    }

    private func suggestion(for name: String, in candidates: [String], prefix: String = "") -> [String] {
        guard let best = closest(to: name, in: candidates) else { return [] }
        return ["did you mean `\(prefix)\(best)`?"]
    }

    private func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// The candidate within a small edit distance of `name`, if there is one.
func closest(to name: String, in candidates: [String]) -> String? {
    let limit = name.count <= 3 ? 1 : 2
    var best: (word: String, distance: Int)?
    for candidate in candidates where candidate != name {
        let d = editDistance(name.lowercased(), candidate.lowercased())
        if d <= limit && d < (best?.distance ?? Int.max) {
            best = (candidate, d)
        }
    }
    return best?.word
}

func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    for i in 1...a.count {
        var row = [i] + Array(repeating: 0, count: b.count)
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + cost)
        }
        previous = row
    }
    return previous[b.count]
}
