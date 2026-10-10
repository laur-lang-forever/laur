import SwiftUI
import LaurCore
import LaurRuntime
#if canImport(AppKit)
import AppKit
#endif

/// The window `laur preview` opens: every component's previews in a sidebar, the
/// selected one rendered live, and errors shown inline as you edit.
struct PreviewerApp: App {
    /// Set by `main.swift` before the app starts.
    static var fileURL = URL(fileURLWithPath: "")

    @StateObject private var workspace = Workspace(fileURL: PreviewerApp.fileURL)

    var body: some Scene {
        WindowGroup("Laur Preview — \(PreviewerApp.fileURL.lastPathComponent)") {
            PreviewerView(workspace: workspace)
                .frame(minWidth: 760, minHeight: 760)
                .onAppear {
                    #if canImport(AppKit)
                    // A command-line process starts as a background app; bring the window forward.
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    #endif
                }
        }
    }
}

struct PreviewerView: View {
    @ObservedObject var workspace: Workspace
    @AppStorage("showsContext") private var showsContext = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        // Each preview starts fresh. Editing the file keeps state, so you don't lose
        // what you typed on every save.
        .onChange(of: workspace.selection) { _, _ in
            workspace.state.reset()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $workspace.selection) {
            if let file = workspace.lastGood {
                ForEach(file.components, id: \.name) { component in
                    Section(component.name) {
                        ForEach(component.previews, id: \.name) { preview in
                            Label(preview.name, systemImage: "rectangle.portrait")
                                .tag(PreviewID(component: component.name, preview: preview.name))
                        }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                // In the window itself rather than the toolbar, which a command-line app's
                // window doesn't always show.
                Toggle("Show context", isOn: $showsContext)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Outline each component and show its siblings, reading order and depth")
                HStack(spacing: 6) {
                    Circle()
                        .fill(workspace.hasErrors ? Color.red : Color.green)
                        .frame(width: 8, height: 8)
                    Text(workspace.hasErrors ? "Errors" : "Up to date")
                    Spacer()
                    Text(workspace.lastReload, style: .time)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .padding(10)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            if !workspace.diagnostics.isEmpty || workspace.samplesError != nil {
                problems
            }
            ScrollView {
                VStack(spacing: 16) {
                    if let intent = selectedComponent?.intent {
                        Text(intent)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 390, alignment: .leading)
                    }
                    phone
                    StateBar(state: workspace.state)
                        .frame(width: 390)
                }
                .padding(32)
                .frame(maxWidth: .infinity)
            }
            .opacity(workspace.hasErrors ? 0.5 : 1)
        }
        .background(Color.gray.opacity(0.08))
    }

    private var phone: some View {
        Group {
            if let file = workspace.lastGood,
               let selection = workspace.selection,
               let component = file.component(named: selection.component),
               let preview = component.preview(named: selection.preview) {
                PhoneScreen(
                    file: file,
                    component: component,
                    preview: preview,
                    samples: workspace.samples,
                    showsContext: showsContext,
                    state: workspace.state
                )
                .padding(16)
                    .frame(width: 390, alignment: .topLeading)
                    .frame(minHeight: 200, alignment: .top)
            } else {
                Text("Nothing to preview yet")
                    .foregroundStyle(.secondary)
                    .frame(width: 390, height: 200)
            }
        }
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.black.opacity(0.1)))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }

    private var problems: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(workspace.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    Text(diagnostic.render(source: workspace.source, fileName: workspace.fileURL.lastPathComponent))
                        .foregroundStyle(diagnostic.severity == .error ? Color.red : Color.orange)
                }
                if let samplesError = workspace.samplesError {
                    Text(samplesError).foregroundStyle(.red)
                }
            }
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(maxHeight: 260)
        .background(Color.red.opacity(0.05))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var selectedComponent: Component? {
        guard let selection = workspace.selection else { return nil }
        return workspace.lastGood?.component(named: selection.component)
    }
}

/// The rendered preview. Watches the state so typing and tapping redraw it.
struct PhoneScreen: View {
    let file: SourceFile
    let component: Component
    let preview: PreviewBlock
    let samples: SampleData
    let showsContext: Bool
    @ObservedObject var state: StateStore

    var body: some View {
        Renderer(file: file, samples: samples, state: state, showsContext: showsContext)
            .render(component, preview: preview)
    }
}

/// Under the preview: what went wrong in the last action, and a way to start over.
struct StateBar: View {
    @ObservedObject var state: StateStore

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let error = state.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Reset state") { state.reset() }
                .controlSize(.small)
                .help("Put every state value back to where the preview starts")
        }
    }
}
