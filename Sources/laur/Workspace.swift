import Foundation
import LaurCore
import LaurRuntime

/// Identifies one preview of one component in the sidebar.
struct PreviewID: Hashable {
    var component: String
    var preview: String
}

/// Watches a `.laur` file (and the `samples.json` beside it), re-parsing and re-checking
/// whenever either changes on disk.
@MainActor
final class Workspace: ObservableObject {
    let fileURL: URL
    var samplesURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("samples.json") }

    @Published private(set) var source = ""
    /// The most recent version that parsed and checked without errors. The preview keeps
    /// showing it while the file has errors, so a typo doesn't blank the screen.
    @Published private(set) var lastGood: SourceFile?
    @Published private(set) var diagnostics: [Diagnostic] = []
    @Published private(set) var samples = SampleData()
    @Published private(set) var samplesError: String?
    @Published private(set) var lastReload = Date()
    @Published var selection: PreviewID?
    /// The previewed screen's `state` values. Kept across reloads, reset per preview.
    let state = StateStore()

    private var fileStamp: Date?
    private var samplesStamp: Date?
    private var timer: Timer?

    init(fileURL: URL) {
        self.fileURL = fileURL
        reload(force: true)
        // Polling is simple and survives editors that save by replacing the file.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload(force: false) }
        }
    }

    var hasErrors: Bool { diagnostics.hasErrors }

    func reload(force: Bool) {
        let newFileStamp = modificationDate(fileURL)
        let newSamplesStamp = modificationDate(samplesURL)
        guard force || newFileStamp != fileStamp || newSamplesStamp != samplesStamp else { return }
        fileStamp = newFileStamp
        samplesStamp = newSamplesStamp

        loadSamples()

        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            source = ""
            diagnostics = [Diagnostic(.error, "can't read \(fileURL.path)", at: SourceRange(.start))]
            return
        }
        source = text
        lastReload = Date()

        do {
            let file = try Parser.parse(text)
            diagnostics = Checker.check(file)
            if !diagnostics.hasErrors {
                lastGood = file
            }
        } catch let diagnostic as Diagnostic {
            diagnostics = [diagnostic]
        } catch {
            diagnostics = [Diagnostic(.error, "\(error)", at: SourceRange(.start))]
        }
        keepSelectionValid()
    }

    private func loadSamples() {
        guard FileManager.default.fileExists(atPath: samplesURL.path) else {
            samples = SampleData()
            samplesError = nil
            return
        }
        do {
            samples = try SampleData(jsonData: try Data(contentsOf: samplesURL))
            samplesError = nil
        } catch {
            samplesError = "samples.json: \(error.localizedDescription)"
        }
    }

    private func keepSelectionValid() {
        guard let file = lastGood else { return }
        if let selection,
           let component = file.component(named: selection.component),
           component.preview(named: selection.preview) != nil {
            return
        }
        if let component = file.components.first, let preview = component.previews.first {
            selection = PreviewID(component: component.name, preview: preview.name)
        }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}
