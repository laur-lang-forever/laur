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
    /// Draws each component's context over it, for checking position logic at a glance.
    public var showsContext: Bool

    public init(file: SourceFile, theme: Theme = .standard, samples: SampleData = SampleData(), showsContext: Bool = false) {
        self.file = file
        self.theme = theme
        self.samples = samples
        self.showsContext = showsContext
    }

    /// Renders one named preview of a component.
    public func render(_ component: Component, preview: PreviewBlock) -> AnyView {
        let resolved = Resolver(file: file, samples: samples).resolve(component, preview: preview)
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
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    view(for: child)
                }
            }
        )
    }

    private func build(_ element: Element, scope: Scope, children: [ResolvedNode]) throws -> AnyView {
        switch element.name {
        case "stack": return try stack(element, children: children)
        case "list":
            let spacing = try length(element.argument("spacing"), in: theme.spacing) ?? 0
            if element.argument("axis")?.value.tokenName == "horizontal" {
                return AnyView(
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: spacing) {
                            ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                                view(for: child)
                            }
                        }
                    }
                )
            }
            return column(children, spacing: spacing)
        case "text": return try text(element, scope: scope)
        case "image": return try image(element, scope: scope)
        case "badge": return try badge(element, scope: scope)
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
        let items = Array(children.enumerated())

        let content: AnyView
        if horizontal {
            let vertical: VerticalAlignment = alignment == "leading" ? .top : alignment == "trailing" ? .bottom : .center
            content = AnyView(HStack(alignment: vertical, spacing: spacing) {
                ForEach(items, id: \.offset) { _, child in view(for: child) }
            })
        } else {
            let horizontalAlignment: HorizontalAlignment = alignment == "center" ? .center : alignment == "trailing" ? .trailing : .leading
            content = AnyView(VStack(alignment: horizontalAlignment, spacing: spacing) {
                ForEach(items, id: \.offset) { _, child in view(for: child) }
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

    private func text(_ element: Element, scope: Scope) throws -> AnyView {
        guard let first = element.positional.first else {
            throw RuntimeError("`text` needs a value", at: element.nameRange)
        }
        let value = try Evaluator.evaluate(first.value, in: scope)
        let font = element.argument("style")?.value.tokenName.flatMap { theme.fonts[$0] } ?? theme.fonts["body"] ?? .body
        let color = element.argument("color")?.value.tokenName.flatMap { theme.colors[$0] } ?? .primary
        return AnyView(
            Text(value.description)
                .font(font)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        )
    }

    private func badge(_ element: Element, scope: Scope) throws -> AnyView {
        guard let first = element.positional.first else {
            throw RuntimeError("`badge` needs a label", at: element.nameRange)
        }
        let value = try Evaluator.evaluate(first.value, in: scope)
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

    private func image(_ element: Element, scope: Scope) throws -> AnyView {
        guard let first = element.positional.first else {
            throw RuntimeError("`image` needs a URL or a symbol name", at: element.nameRange)
        }
        let source = try Evaluator.evaluate(first.value, in: scope).description
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
