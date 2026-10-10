import SwiftUI
import LaurCore

/// Turns a parsed `.laur` component into live SwiftUI views.
///
/// This is the dev-mode interpreter: it's what makes previews reload instantly. It works
/// in two steps: the `Resolver` decides what's on screen and where each component sits,
/// then this draws the result. Release builds will compile the same tree to Swift, and a
/// shared test suite will check that both paths render every preview the same way.
public struct Renderer {
    public var file: SourceFile
    public var theme: Theme
    public var samples: SampleData
    /// Where `state` lives. Fields, toggles and buttons write to it.
    public var state: StateStore
    /// Draws each component's context over it, for checking position logic at a glance.
    public var showsContext: Bool

    public init(
        file: SourceFile,
        theme: Theme = .standard,
        samples: SampleData = SampleData(),
        state: StateStore = StateStore(),
        showsContext: Bool = false
    ) {
        self.file = file
        self.theme = theme
        self.samples = samples
        self.state = state
        self.showsContext = showsContext
    }

    /// Renders one named preview of a component.
    public func render(_ component: Component, preview: PreviewBlock) -> AnyView {
        let resolved = Resolver(file: file, samples: samples, state: state).resolve(component, preview: preview)
        return view(for: resolved)
    }

    // MARK: - Tree

    private func view(for node: ResolvedNode) -> AnyView {
        switch node {
        case .failure(let error):
            return AnyView(RenderErrorView(error: error))

        case .component(_, let context, let children):
            let body = column(children, spacing: 0)
            guard showsContext else { return body }
            return AnyView(
                body
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.purple.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    .overlay(alignment: .topTrailing) {
                        ContextBadge(context: context)
                    }
            )

        case .element(let element, let scope, let children):
            do {
                return try build(element, scope: scope, children: children)
            } catch {
                return AnyView(RenderErrorView(error: error))
            }
        }
    }

    private func column(_ children: [ResolvedNode], spacing: CGFloat) -> AnyView {
        if children.count == 1 {
            return view(for: children[0])
        }
        return AnyView(
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(identified(children), id: \.id) { item in
                    view(for: item.node)
                }
            }
        )
    }

    /// Gives each child an identity from its place in the source, not its position, so a
    /// field keeps its focus when an `if` above it shows or hides something.
    private func identified(_ children: [ResolvedNode]) -> [(id: String, node: ResolvedNode)] {
        var seen: [String: Int] = [:]
        return children.enumerated().map { index, node in
            let base: String
            switch node {
            case .element(let element, _, _): base = "e\(element.range.start.offset)"
            case .component(_, let context, _): base = "c\(context.path)"
            case .failure: base = "f\(index)"
            }
            let occurrence = seen[base, default: 0]
            seen[base] = occurrence + 1
            return (id: "\(base)#\(occurrence)", node: node)
        }
    }

    private func build(_ element: Element, scope: InstanceScope, children: [ResolvedNode]) throws -> AnyView {
        switch element.name {
        case "stack": return try stack(element, children: children)
        case "list":
            let spacing = try length(element.argument("spacing"), in: theme.spacing) ?? 0
            if element.argument("axis")?.value.tokenName == "horizontal" {
                return AnyView(
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: spacing) {
                            ForEach(identified(children), id: \.id) { item in
                                view(for: item.node)
                            }
                        }
                    }
                )
            }
            return column(children, spacing: spacing)
        case "text": return try text(element, scope: scope)
        case "image": return try image(element, scope: scope)
        case "badge": return try badge(element, scope: scope)
        case "field": return try field(element, scope: scope)
        case "toggle": return try toggle(element, scope: scope)
        case "button": return try button(element, scope: scope)
        case "spacer": return AnyView(Spacer(minLength: 0))
        case "divider": return AnyView(Divider())
        default:
            throw RuntimeError("unknown element `\(element.name)`", at: element.nameRange)
        }
    }

    // MARK: - Primitives

    private func stack(_ element: Element, children: [ResolvedNode]) throws -> AnyView {
        let horizontal = element.positional.first?.value.tokenName == "horizontal"
        let spacing = try length(element.argument("spacing"), in: theme.spacing) ?? theme.spacing["sm"] ?? 8
        let alignment = element.argument("alignment")?.value.tokenName
        let items = identified(children)

        let content: AnyView
        if horizontal {
            let vertical: VerticalAlignment = alignment == "leading" ? .top : alignment == "trailing" ? .bottom : .center
            content = AnyView(HStack(alignment: vertical, spacing: spacing) {
                ForEach(items, id: \.id) { item in view(for: item.node) }
            })
        } else {
            let horizontalAlignment: HorizontalAlignment = alignment == "center" ? .center : alignment == "trailing" ? .trailing : .leading
            content = AnyView(VStack(alignment: horizontalAlignment, spacing: spacing) {
                ForEach(items, id: \.id) { item in view(for: item.node) }
            })
        }

        var result = content
        if let padding = try length(element.argument("padding"), in: theme.spacing) {
            result = AnyView(result.padding(padding))
        }
        if let name = element.argument("background")?.value.tokenName, let color = theme.colors[name] {
            result = AnyView(result.background(color))
        }
        if let radius = try length(element.argument("corner"), in: theme.corners) {
            result = AnyView(result.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
        }
        return result
    }

    private func text(_ element: Element, scope: InstanceScope) throws -> AnyView {
        guard let first = element.positional.first else {
            throw RuntimeError("`text` needs a value", at: element.nameRange)
        }
        let value = try Evaluator.evaluate(first.value, in: scope.values)
        let font = element.argument("style")?.value.tokenName.flatMap { theme.fonts[$0] } ?? theme.fonts["body"] ?? .body
        let color = element.argument("color")?.value.tokenName.flatMap { theme.colors[$0] } ?? .primary
        return AnyView(
            Text(value.description)
                .font(font)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        )
    }

    private func badge(_ element: Element, scope: InstanceScope) throws -> AnyView {
        guard let first = element.positional.first else {
            throw RuntimeError("`badge` needs a label", at: element.nameRange)
        }
        let value = try Evaluator.evaluate(first.value, in: scope.values)
        let color = element.argument("color")?.value.tokenName.flatMap { theme.colors[$0] } ?? theme.colors["accent"] ?? .accentColor
        return AnyView(
            Text(value.description)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.14), in: Capsule())
        )
    }

    private func image(_ element: Element, scope: InstanceScope) throws -> AnyView {
        guard let first = element.positional.first else {
            throw RuntimeError("`image` needs a URL or a symbol name", at: element.nameRange)
        }
        let source = try Evaluator.evaluate(first.value, in: scope.values).description
        let surface = theme.colors["surface"] ?? Color.gray.opacity(0.12)

        let picture: AnyView
        if source.hasPrefix("http://") || source.hasPrefix("https://"), let url = URL(string: source) {
            picture = AnyView(AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else if phase.error != nil {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            })
        } else {
            picture = AnyView(
                Image(systemName: source.isEmpty ? "photo" : source)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
                    .foregroundStyle(.secondary)
            )
        }

        let size = element.argument("size")?.value.tokenName.flatMap { theme.imageSizes[$0] }
        var ratio: CGFloat?
        switch element.argument("aspect")?.value.tokenName {
        case "square": ratio = 1
        case "wide": ratio = 16.0 / 9.0
        case "tall": ratio = 3.0 / 4.0
        case "fit": ratio = nil
        default: ratio = size == nil ? 4.0 / 3.0 : 1
        }

        var result: AnyView
        if let ratio {
            result = AnyView(
                surface
                    .aspectRatio(ratio, contentMode: .fit)
                    .overlay(picture)
                    .clipped()
            )
        } else {
            result = AnyView(picture.background(surface))
        }
        if let size {
            result = AnyView(result.frame(width: size))
        }
        if let radius = try length(element.argument("corner"), in: theme.corners) {
            result = AnyView(result.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
        }
        return result
    }

    // MARK: - Interactive elements

    /// The state key behind `value: bind x`.
    private func boundKey(_ element: Element, scope: InstanceScope) throws -> String {
        guard let argument = element.argument("value") else {
            throw RuntimeError("`\(element.name)` needs `value: bind ...`", at: element.nameRange)
        }
        guard case .bind(let name) = argument.value.kind, let key = scope.stateKeys[name] else {
            throw RuntimeError("`value` needs `bind` and a state name", at: argument.value.range)
        }
        return key
    }

    private func label(_ element: Element, scope: InstanceScope) throws -> String {
        guard let first = element.positional.first else {
            throw RuntimeError("`\(element.name)` needs a label", at: element.nameRange)
        }
        return try Evaluator.evaluate(first.value, in: scope.values).description
    }

    private func field(_ element: Element, scope: InstanceScope) throws -> AnyView {
        let title = try label(element, scope: scope)
        let key = try boundKey(element, scope: scope)
        let store = state
        let text = Binding<String>(
            get: { store.value(key)?.description ?? "" },
            set: { store.set(key, .string($0)) }
        )
        let secure = try element.argument("secure").map {
            try Evaluator.truth(Evaluator.evaluate($0.value, in: scope.values), at: $0.value.range)
        } ?? false

        var result: AnyView
        if secure {
            result = AnyView(SecureField(title, text: text))
        } else {
            result = AnyView(TextField(title, text: text))
        }
        result = AnyView(result.textFieldStyle(.roundedBorder))
        #if canImport(UIKit)
        switch element.argument("keyboard")?.value.tokenName {
        case "email": result = AnyView(result.keyboardType(.emailAddress).textInputAutocapitalization(.never))
        case "number": result = AnyView(result.keyboardType(.decimalPad))
        case "phone": result = AnyView(result.keyboardType(.phonePad))
        case "url": result = AnyView(result.keyboardType(.URL).textInputAutocapitalization(.never))
        default: break
        }
        #endif
        return result
    }

    private func toggle(_ element: Element, scope: InstanceScope) throws -> AnyView {
        let title = try label(element, scope: scope)
        let key = try boundKey(element, scope: scope)
        let store = state
        let isOn = Binding<Bool>(
            get: { store.value(key) == .bool(true) },
            set: { store.set(key, .bool($0)) }
        )
        return AnyView(Toggle(title, isOn: isOn))
    }

    private func button(_ element: Element, scope: InstanceScope) throws -> AnyView {
        let title = try label(element, scope: scope)
        let enabled = try element.argument("enabled").map {
            try Evaluator.truth(Evaluator.evaluate($0.value, in: scope.values), at: $0.value.range)
        } ?? true
        let handler = element.handler ?? []
        let store = state
        let style = element.argument("style")?.value.tokenName ?? "primary"
        let base = Button(role: style == "destructive" ? .destructive : nil) {
            ActionRunner.run(handler, in: scope, store: store)
        } label: {
            Text(title)
        }

        let styled: AnyView
        switch style {
        case "secondary", "destructive": styled = AnyView(base.buttonStyle(.bordered))
        case "plain": styled = AnyView(base.buttonStyle(.plain).foregroundStyle(Color.accentColor))
        default: styled = AnyView(base.buttonStyle(.borderedProminent))
        }
        return AnyView(styled.disabled(!enabled))
    }

    // MARK: - Values

    /// A token from `table`, or a raw number of points.
    private func length(_ argument: Argument?, in table: [String: CGFloat]) throws -> CGFloat? {
        guard let argument else { return nil }
        switch argument.value.kind {
        case .number(let n): return CGFloat(n)
        case .token(let name, _):
            guard let value = table[name] else {
                throw RuntimeError("unknown token `.\(name)`", at: argument.value.range)
            }
            return value
        default:
            throw RuntimeError("expected a token like `.md`", at: argument.value.range)
        }
    }
}

/// The label drawn on each component when "Show context" is on.
struct ContextBadge: View {
    let context: ContextInfo

    var body: some View {
        let reading = context.readingCount.map { "\(context.readingIndex + 1)/\($0)" } ?? "\(context.readingIndex + 1)"
        Text("\(context.type)  sib \(context.siblingIndex + 1)/\(context.siblingCount) · read \(reading) · d\(context.depth)")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
            .offset(y: -8)
            .help(context.path)
    }
}

/// Shown in place of an element that couldn't be rendered.
struct RenderErrorView: View {
    var error: Error

    var body: some View {
        let message: String
        if let runtime = error as? RuntimeError {
            if let range = runtime.range {
                message = "line \(range.start.line): \(runtime.message)"
            } else {
                message = runtime.message
            }
        } else {
            message = String(describing: error)
        }
        return Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption.monospaced())
            .foregroundStyle(.red)
            .padding(8)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
