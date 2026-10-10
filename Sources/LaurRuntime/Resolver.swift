import LaurCore

/// A screen after `if`s are decided, lists are expanded, and every component instance
/// has its context. Rendering only draws this tree; it never makes layout decisions.
public indirect enum ResolvedNode {
    /// A primitive like `stack` or `text`, with the scope its arguments are read in.
    case element(Element, scope: InstanceScope, children: [ResolvedNode])
    /// An instance of a component, with its context and its resolved body.
    case component(Component, context: ContextInfo, children: [ResolvedNode])
    /// Something that couldn't be resolved, shown inline in place of the element.
    case failure(RuntimeError)
}

/// Resolves a component preview into a `ResolvedNode` tree.
///
/// The work happens in one depth-first pass, in reading order. That order is what makes
/// context safe to use in `if`:
///
/// - `siblings` comes from the container, whose `if`s are decided first.
/// - `reading.index` and `level.index` only depend on components earlier in reading
///   order, which are already resolved.
/// - `reading.count` and `level.count` depend on the whole screen, so they're filled
///   in at the end and can't be used in `if` (the checker reports it; so does this).
public final class Resolver {
    public let file: SourceFile
    public let samples: SampleData
    public let state: StateStore

    private var readingCounter = 0
    private var levelCounters: [Int: Int] = [:]
    private var contexts: [ContextInfo] = []

    public init(file: SourceFile, samples: SampleData = SampleData(), state: StateStore = StateStore()) {
        self.file = file
        self.samples = samples
        self.state = state
    }

    public func resolve(_ component: Component, preview: PreviewBlock) -> ResolvedNode {
        readingCounter = 0
        levelCounters = [:]
        contexts = []

        var params: Scope = [:]
        var startingState: Scope = [:]
        var siblings = (index: 0, count: 1)
        var readingCountOverride = 0
        do {
            for param in component.params {
                if let entry = preview.entry(param.name) {
                    params[param.name] = try samples.resolve(entry.value, type: param.type)
                } else {
                    params[param.name] = .null
                }
            }
            // A preview can start the component in a particular state.
            for state in component.states {
                if let entry = preview.entry(state.name) {
                    startingState[state.name] = try samples.resolve(entry.value, type: state.type)
                }
            }
            if let entry = preview.entry("context") {
                let (kind, index, count) = try Self.previewPosition(entry.value)
                if kind == "siblings" {
                    siblings = (index, count)
                } else {
                    readingCounter = index
                    readingCountOverride = count
                }
            }
        } catch {
            return .failure(error as? RuntimeError ?? RuntimeError("\(error)"))
        }

        let root = resolveComponent(component, params: params, bound: [:], startingState: startingState,
                                    siblings: siblings, parent: nil, depth: 0)

        for context in contexts {
            context.readingCount = max(readingCounter, readingCountOverride)
            context.levelCount = levelCounters[context.depth] ?? 0
        }
        return root
    }

    // MARK: - Components

    private func resolveComponent(
        _ component: Component,
        params: Scope,
        bound: [String: String],
        startingState: Scope,
        siblings: (index: Int, count: Int),
        parent: ContextInfo?,
        depth: Int
    ) -> ResolvedNode {
        guard depth < 64 else {
            return .failure(RuntimeError("components are nested more than 64 levels deep; is one containing itself?", at: component.nameRange))
        }
        let position = siblings.count > 1 ? "[\(siblings.index)]" : ""
        let path = (parent.map { $0.path + "/" } ?? "") + component.name + position

        let context = ContextInfo(
            type: component.name,
            siblingIndex: siblings.index,
            siblingCount: siblings.count,
            readingIndex: readingCounter,
            depth: depth,
            levelIndex: levelCounters[depth] ?? 0,
            parentType: parent?.type ?? "",
            path: path
        )
        readingCounter += 1
        levelCounters[depth, default: 0] += 1
        contexts.append(context)

        var scope = InstanceScope(values: params, stateKeys: [:], component: component)
        scope.values["context"] = .context(context)
        do {
            // `bind` parameters read and write the caller's state. When nothing is bound
            // (a preview of this component alone), they get state of their own.
            for param in component.params where param.type.isBinding {
                let key = bound[param.name] ?? "\(path)#\(param.name)"
                state.initialize(key, params[param.name] ?? .null)
                scope.stateKeys[param.name] = key
                scope.values[param.name] = state.value(key) ?? .null
            }
            for declaration in component.states {
                let key = "\(path)#\(declaration.name)"
                if state.value(key) == nil {
                    let initial = try startingState[declaration.name] ?? Evaluator.evaluate(declaration.initial, in: scope.values)
                    state.initialize(key, initial)
                }
                scope.stateKeys[declaration.name] = key
                scope.values[declaration.name] = state.value(key) ?? .null
            }
            try scope.recomputeDerived()
        } catch {
            return .component(component, context: context, children: [.failure(error as? RuntimeError ?? RuntimeError("\(error)"))])
        }

        let children = resolveNodes(component.view ?? [], scope: scope, owner: context, depth: depth, position: nil)
        return .component(component, context: context, children: children)
    }

    // MARK: - Nodes

    /// One entry of a container after its `if`s are decided.
    private enum Placed {
        case element(Element)
        case failure(RuntimeError)
    }

    /// Resolves the contents of one container. Children are numbered as siblings in the
    /// order they appear after `if`s are decided, unless `position` says they all belong
    /// to one list item.
    private func resolveNodes(
        _ nodes: [Node],
        scope: InstanceScope,
        owner: ContextInfo,
        depth: Int,
        position: (index: Int, count: Int)?
    ) -> [ResolvedNode] {
        let placed = place(nodes, scope: scope)
        return placed.enumerated().map { i, item -> ResolvedNode in
            switch item {
            case .failure(let error):
                return .failure(error)
            case .element(let element):
                let siblings = position ?? (i, placed.count)
                return resolveElement(element, scope: scope, siblings: siblings, owner: owner, depth: depth)
            }
        }
    }

    /// Flattens `if`s into the elements they choose.
    private func place(_ nodes: [Node], scope: InstanceScope) -> [Placed] {
        var placed: [Placed] = []
        for node in nodes {
            switch node {
            case .element(let element):
                placed.append(.element(element))
            case .conditional(let conditional):
                do {
                    var chosen: [Node]? = conditional.otherwise
                    for branch in conditional.branches {
                        let value = try Evaluator.evaluate(branch.condition, in: scope.values)
                        if try Evaluator.truth(value, at: branch.condition.range) {
                            chosen = branch.body
                            break
                        }
                    }
                    placed += place(chosen ?? [], scope: scope)
                } catch {
                    placed.append(.failure(error as? RuntimeError ?? RuntimeError("\(error)")))
                }
            }
        }
        return placed
    }

    private func resolveElement(
        _ element: Element,
        scope: InstanceScope,
        siblings: (index: Int, count: Int),
        owner: ContextInfo,
        depth: Int
    ) -> ResolvedNode {
        do {
            if element.name == "list" {
                return try resolveList(element, scope: scope, owner: owner, depth: depth)
            }
            if Primitive.named(element.name) != nil {
                let children = resolveNodes(element.children ?? [], scope: scope, owner: owner, depth: depth, position: nil)
                return .element(element, scope: scope, children: children)
            }
            guard let target = file.component(named: element.name) else {
                throw RuntimeError("unknown element `\(element.name)`", at: element.nameRange)
            }
            var params: Scope = [:]
            var bound: [String: String] = [:]
            for param in target.params {
                guard let argument = element.argument(param.name) else {
                    params[param.name] = .null
                    continue
                }
                if param.type.isBinding {
                    guard case .bind(let name) = argument.value.kind, let key = scope.stateKeys[name] else {
                        throw RuntimeError("`\(param.name)` needs `bind` and a state value", at: argument.value.range)
                    }
                    bound[param.name] = key
                } else {
                    params[param.name] = try Evaluator.evaluate(argument.value, in: scope.values)
                }
            }
            return resolveComponent(target, params: params, bound: bound, startingState: [:],
                                    siblings: siblings, parent: owner, depth: depth + 1)
        } catch {
            return .failure(error as? RuntimeError ?? RuntimeError("\(error)"))
        }
    }

    /// Repeats the list's block for each item. Everything one item produces shares that
    /// item's position, so a row is "2 of 5" even if its block has several elements.
    private func resolveList(_ element: Element, scope: InstanceScope, owner: ContextInfo, depth: Int) throws -> ResolvedNode {
        guard let source = element.positional.first else {
            throw RuntimeError("`list` needs a collection, like `list(products)`", at: element.nameRange)
        }
        let items: [Value]
        switch try Evaluator.evaluate(source.value, in: scope.values) {
        case .list(let values): items = values
        case .null: items = []
        case let other:
            throw RuntimeError("`list` needs a collection, but got `\(other)`", at: source.value.range)
        }
        let name = element.binding?.name ?? "item"
        var children: [ResolvedNode] = []
        for (i, item) in items.enumerated() {
            var itemScope = scope
            itemScope.values[name] = item
            children += resolveNodes(element.children ?? [], scope: itemScope, owner: owner, depth: depth, position: (i, items.count))
        }
        return .element(element, scope: scope, children: children)
    }

    // MARK: - Previews

    /// Reads `.siblings(2, of: 5)` or `.reading(0, of: 3)` from a preview.
    private static func previewPosition(_ expr: Expr) throws -> (kind: String, index: Int, count: Int) {
        guard case .token(let kind, let arguments) = expr.kind,
              kind == "siblings" || kind == "reading",
              let args = arguments, args.count == 2,
              case .number(let index) = args[0].value.kind,
              case .number(let count) = args[1].value.kind,
              index >= 0, index < count else {
            throw RuntimeError("a preview's `context` is `.siblings(index, of: count)` or `.reading(index, of: count)`", at: expr.range)
        }
        return (kind, Int(index), Int(count))
    }
}
