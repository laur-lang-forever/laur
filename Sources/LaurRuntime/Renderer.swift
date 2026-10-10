import SwiftUI
import LaurCore

/// Turns a parsed `.laur` component into live SwiftUI views by walking its syntax tree.
///
/// This is the dev-mode interpreter: it's what makes previews reload instantly. Release
/// builds will compile the same tree to Swift instead, and a shared test suite will check
/// that both paths render every preview the same way.
public struct Renderer {
    public var file: SourceFile
    public var theme: Theme
    public var samples: SampleData

    public init(file: SourceFile, theme: Theme = .standard, samples: SampleData = SampleData()) {
        self.file = file
        self.theme = theme
        self.samples = samples
    }

    /// Renders one named preview of a component.
    public func render(_ component: Component, preview: PreviewBlock) -> AnyView {
        do {
            var scope: [String: Value] = [:]
            for param in component.params {
                if let entry = preview.entry(param.name) {
                    scope[param.name] = try samples.resolve(entry.value, type: param.type)
                } else {
                    scope[param.name] = .null
                }
            }
            return try body(of: component, scope: scope, depth: 0)
        } catch {
            return AnyView(RenderErrorView(error: error))
        }
    }

    // MARK: - Tree walking

    private func body(of component: Component, scope: [String: Value], depth: Int) throws -> AnyView {
        guard depth < 64 else {
            throw RuntimeError("components are nested more than 64 levels deep; is one containing itself?", at: component.nameRange)
        }
        let nodes = component.view ?? []
        if nodes.count == 1 {
            return view(for: nodes[0], scope: scope, depth: depth)
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                    view(for: node, scope: scope, depth: depth)
                }
            }
        )
    }

    /// Renders a node, showing an inline error in place of anything that fails so one
    /// mistake doesn't blank the whole preview.
    private func view(for node: Node, scope: [String: Value], depth: Int) -> AnyView {
        do {
            return try build(node, scope: scope, depth: depth)
        } catch {
            return AnyView(RenderErrorView(error: error))
        }
    }

    private func build(_ node: Node, scope: [String: Value], depth: Int) throws -> AnyView {
        switch node.name {
        case "stack": return try stack(node, scope: scope, depth: depth)
        case "text": return try text(node, scope: scope)
        case "image": return try image(node, scope: scope)
        case "spacer": return AnyView(Spacer(minLength: 0))
        case "divider": return AnyView(Divider())
        default:
            guard let target = file.component(named: node.name) else {
                throw RuntimeError("unknown element `\(node.name)`", at: node.nameRange)
            }
            var inner: [String: Value] = [:]
            for param in target.params {
                if let argument = node.argument(param.name) {
                    inner[param.name] = try evaluate(argument.value, scope: scope)
                } else {
                    inner[param.name] = .null
                }
            }
            return try body(of: target, scope: inner, depth: depth + 1)
        }
    }

    // MARK: - Primitives

    private func stack(_ node: Node, scope: [String: Value], depth: Int) throws -> AnyView {
        let horizontal = node.positional.first?.value.tokenName == "horizontal"
        let spacing = try length(node.argument("spacing"), in: theme.spacing) ?? theme.spacing["sm"] ?? 8
        let alignment = node.argument("alignment")?.value.tokenName
        let children = Array((node.children ?? []).enumerated())

        let content: AnyView
        if horizontal {
            let vertical: VerticalAlignment = alignment == "leading" ? .top : alignment == "trailing" ? .bottom : .center
            content = AnyView(HStack(alignment: vertical, spacing: spacing) {
                ForEach(children, id: \.offset) { _, child in view(for: child, scope: scope, depth: depth) }
            })
        } else {
            let horizontalAlignment: HorizontalAlignment = alignment == "center" ? .center : alignment == "trailing" ? .trailing : .leading
            content = AnyView(VStack(alignment: horizontalAlignment, spacing: spacing) {
                ForEach(children, id: \.offset) { _, child in view(for: child, scope: scope, depth: depth) }
            })
        }

        var result = content
        if let padding = try length(node.argument("padding"), in: theme.spacing) {
            result = AnyView(result.padding(padding))
        }
        if let name = node.argument("background")?.value.tokenName, let color = theme.colors[name] {
            result = AnyView(result.background(color))
        }
        if let radius = try length(node.argument("corner"), in: theme.corners) {
            result = AnyView(result.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
        }
        return result
    }

    private func text(_ node: Node, scope: [String: Value]) throws -> AnyView {
        guard let first = node.positional.first else {
            throw RuntimeError("`text` needs a value", at: node.nameRange)
        }
        let value = try evaluate(first.value, scope: scope)
        let font = node.argument("style")?.value.tokenName.flatMap { theme.fonts[$0] } ?? theme.fonts["body"] ?? .body
        let color = node.argument("color")?.value.tokenName.flatMap { theme.colors[$0] } ?? .primary
        return AnyView(
            Text(value.description)
                .font(font)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        )
    }

    private func image(_ node: Node, scope: [String: Value]) throws -> AnyView {
        guard let first = node.positional.first else {
            throw RuntimeError("`image` needs a URL or a symbol name", at: node.nameRange)
        }
        let source = try evaluate(first.value, scope: scope).description
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

        let size = node.argument("size")?.value.tokenName.flatMap { theme.imageSizes[$0] }
        var ratio: CGFloat?
        switch node.argument("aspect")?.value.tokenName {
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
        if let radius = try length(node.argument("corner"), in: theme.corners) {
            result = AnyView(result.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
        }
        return result
    }

    // MARK: - Values

    private func evaluate(_ expr: Expr, scope: [String: Value]) throws -> Value {
        switch expr.kind {
        case .string(let s): return .string(s)
        case .number(let n): return .number(n)
        case .bool(let b): return .bool(b)
        case .token(let name, _): return .token(name)
        case .path(let path):
            guard var value = scope[path[0]] else {
                throw RuntimeError("`\(path[0])` isn't defined", at: expr.range)
            }
            for field in path.dropFirst() {
                guard case .record(let fields) = value else {
                    throw RuntimeError("`\(field)` can't be read from \(value == .null ? "an empty value" : "`\(value)`")", at: expr.range)
                }
                guard let next = fields[field] else {
                    let known = fields.keys.sorted().map { "`\($0)`" }.joined(separator: ", ")
                    throw RuntimeError("the sample has no field `\(field)` (it has \(known))", at: expr.range)
                }
                value = next
            }
            return value
        }
    }

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
