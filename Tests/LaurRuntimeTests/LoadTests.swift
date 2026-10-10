import Foundation
import XCTest
import LaurCore
@testable import LaurRuntime

/// Simulated loads: what a preview shows while loading, after it finishes, when it's
/// pinned to an outcome, and after `reload()`.
final class LoadTests: XCTestCase {
    var file: SourceFile!
    var samples: SampleData!
    var store: StateStore!

    override func setUpWithError() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/OrderHistory")
        file = try Parser.parse(try String(contentsOf: folder.appendingPathComponent("OrderHistory.laur"), encoding: .utf8))
        samples = try SampleData(jsonData: try Data(contentsOf: folder.appendingPathComponent("samples.json")))
        store = StateStore()
        store.completesLoadsAutomatically = false
    }

    func testLiveLoadShowsLoadingThenSamples() throws {
        XCTAssertTrue(try texts("live").contains("Loading your orders…"))
        XCTAssertTrue(store.hasPendingLoads)

        store.completePendingLoads()
        XCTAssertFalse(store.hasPendingLoads)
        let loaded = try texts("live")
        XCTAssertTrue(loaded.contains("4 orders"))
        XCTAssertTrue(loaded.contains("Weekend Duffel"))
    }

    func testPinnedFailureAndRetry() throws {
        let offline = try texts("offline")
        XCTAssertTrue(offline.contains("You're offline"))
        XCTAssertTrue(offline.contains("The Internet connection appears to be offline."))
        XCTAssertFalse(store.hasPendingLoads, "a pinned state doesn't start loading")

        try tap("Try again", in: resolve("offline"))
        XCTAssertTrue(try texts("offline").contains("Loading your orders…"))
        store.completePendingLoads()
        XCTAssertTrue(try texts("offline").contains("4 orders"))
    }

    func testPinnedFailureMessageAndKind() throws {
        let server = try texts("server")
        XCTAssertTrue(server.contains("Couldn't load your orders"))
        XCTAssertTrue(server.contains("Our servers are having a moment."))
    }

    func testPinnedLoadedValues() throws {
        XCTAssertTrue(try texts("loaded").contains("3 orders"))
        store.reset()
        XCTAssertTrue(try texts("empty").contains("No orders yet"))
    }

    func testMissingSampleDataExplainsWhatToAdd() throws {
        samples = SampleData()
        _ = try texts("live")
        store.completePendingLoads()
        let failed = try texts("live")
        XCTAssertTrue(failed.contains("Couldn't load your orders"))
        XCTAssertTrue(failed.contains("No sample data for `Order`. Add a \"Order\" entry to samples.json."))
    }

    func testResetStartsTheLoadAgain() throws {
        _ = try texts("live")
        store.completePendingLoads()
        store.reset()
        XCTAssertTrue(try texts("live").contains("Loading your orders…"))
    }

    // MARK: - Helpers

    private func resolve(_ preview: String) throws -> ResolvedNode {
        let history = try XCTUnwrap(file.component(named: "OrderHistory"))
        return Resolver(file: file, samples: samples, state: store)
            .resolve(history, preview: try XCTUnwrap(history.preview(named: preview)))
    }

    private func texts(_ preview: String) throws -> [String] {
        collectTexts(in: try resolve(preview))
    }

    private func tap(_ label: String, in root: ResolvedNode) throws {
        let found = try XCTUnwrap(findButton(label, in: root), "no button \(label)")
        ActionRunner.run(found.0.handler ?? [], in: found.1, store: store)
    }
}

/// Every `text` value, evaluated the way the renderer would.
func collectTexts(in node: ResolvedNode) -> [String] {
    switch node {
    case .component(_, _, let children):
        return children.flatMap { collectTexts(in: $0) }
    case .element(let element, let scope, let children):
        var result: [String] = []
        if element.name == "text", let first = element.positional.first,
           let value = try? Evaluator.evaluate(first.value, in: scope.values) {
            result.append(value.description)
        }
        return result + children.flatMap { collectTexts(in: $0) }
    case .failure(let error):
        return ["error: \(error.message)"]
    }
}

/// The button with this label, and the scope its block runs in.
func findButton(_ label: String, in node: ResolvedNode) -> (Element, InstanceScope)? {
    switch node {
    case .component(_, _, let children):
        return children.lazy.compactMap { findButton(label, in: $0) }.first
    case .element(let element, let scope, let children):
        if element.name == "button", let first = element.positional.first,
           (try? Evaluator.evaluate(first.value, in: scope.values)) == .string(label) {
            return (element, scope)
        }
        return children.lazy.compactMap { findButton(label, in: $0) }.first
    case .failure:
        return nil
    }
}
