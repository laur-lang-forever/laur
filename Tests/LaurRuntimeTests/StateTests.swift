import Foundation
import XCTest
import LaurCore
@testable import LaurRuntime

/// Interactive previews without a screen: resolve, "tap" a button by running its
/// block, and resolve again to see what changed.
final class StateTests: XCTestCase {
    var file: SourceFile!
    var store: StateStore!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/SignUp/SignUp.laur")
        file = try Parser.parse(try String(contentsOf: url, encoding: .utf8))
        store = StateStore()
    }

    func testPreviewsSetStartingStateAndDerivedValuesFollow() throws {
        let root = try resolve("SignUpForm", "ready")
        let submit = try XCTUnwrap(element("button", labeled: "Create account", in: root))
        XCTAssertEqual(try value(of: submit, "enabled"), .bool(true))

        // Switching previews starts fresh, as the preview window does.
        store.reset()
        let empty = try resolve("SignUpForm", "empty")
        let disabled = try XCTUnwrap(element("button", labeled: "Create account", in: empty))
        XCTAssertEqual(try value(of: disabled, "enabled"), .bool(false))
    }

    func testTappingAButtonRunsItsAction() throws {
        var root = try resolve("SignUpForm", "ready")
        try tap("Create account", in: root)
        XCTAssertEqual(store.value("SignUpForm#submitted"), .bool(true))

        root = try resolve("SignUpForm", "ready")
        XCTAssertTrue(texts(in: root).contains("Welcome!"))
        XCTAssertTrue(texts(in: root).contains("We sent a confirmation to laur@example.com."))

        try tap("Start over", in: root)
        XCTAssertEqual(store.value("SignUpForm#email"), .string(""))
        XCTAssertEqual(store.value("SignUpForm#submitted"), .bool(false))
    }

    func testTypingUpdatesWhatDependsOnIt() throws {
        _ = try resolve("SignUpForm", "empty")
        // What a field does on each keystroke.
        store.set("SignUpForm#password", .string("abc"))
        let root = try resolve("SignUpForm", "empty")
        XCTAssertTrue(texts(in: root).contains("Too short: 5 more to go"))
    }

    func testPasswordStrengthPreviewsShowWhatTheyAreNamedFor() throws {
        let expected = [
            "empty": "Use 8 or more characters",
            "short": "Too short: 5 more to go",
            "good": "Good",
            "strong": "Strong",
        ]
        for (preview, text) in expected {
            XCTAssertEqual(texts(in: try resolve("PasswordStrength", preview)), [text], preview)
        }
    }

    func testBindParametersChangeTheCallersState() throws {
        var root = try resolve("QuantityPicker", "one")
        for _ in 0..<9 {
            try tap("+", in: root)
            root = try resolve("QuantityPicker", "one")
        }
        XCTAssertEqual(store.value("QuantityPicker#quantity"), .number(10))
        XCTAssertTrue(texts(in: root).contains("Bulk orders ship separately"))
        // The stepper has no state of its own; it wrote through to the picker.
        XCTAssertNil(store.snapshot.keys.first { $0.hasSuffix("Stepper#value") })
    }

    func testBindParameterPreviewedAloneGetsItsOwnState() throws {
        let root = try resolve("Stepper", "three")
        try tap("−", in: root)
        XCTAssertEqual(store.value("Stepper#value"), .number(2))
    }

    func testStateSurvivesReResolvingButNotReset() throws {
        _ = try resolve("SignUpForm", "empty")
        store.set("SignUpForm#email", .string("kept@example.com"))
        _ = try resolve("SignUpForm", "empty")
        XCTAssertEqual(store.value("SignUpForm#email"), .string("kept@example.com"))
        store.reset()
        _ = try resolve("SignUpForm", "empty")
        XCTAssertEqual(store.value("SignUpForm#email"), .string(""))
    }

    func testActionErrorsAreReportedNotThrown() throws {
        let file = try Parser.parse("""
            component A {
              state label: String = "x"
              view { button("Break") { label += 1 } }
              preview "p" {}
            }
            """)
        let a = try XCTUnwrap(file.component(named: "A"))
        let root = Resolver(file: file, state: store).resolve(a, preview: try XCTUnwrap(a.preview(named: "p")))
        try tap("Break", in: root)
        XCTAssertEqual(store.lastError, "line 3: `+=` needs numbers")
    }

    // MARK: - Helpers

    private func resolve(_ name: String, _ preview: String) throws -> ResolvedNode {
        let component = try XCTUnwrap(file.component(named: name))
        return Resolver(file: file, state: store).resolve(component, preview: try XCTUnwrap(component.preview(named: preview)))
    }

    private func tap(_ label: String, in root: ResolvedNode) throws {
        let found = try XCTUnwrap(element("button", labeled: label, in: root), "no button \(label)")
        ActionRunner.run(found.0.handler ?? [], in: found.1, store: store)
    }

    private func value(of found: (Element, InstanceScope), _ label: String) throws -> Value {
        let argument = try XCTUnwrap(found.0.argument(label))
        return try Evaluator.evaluate(argument.value, in: found.1.values)
    }

    private func element(_ name: String, labeled label: String, in node: ResolvedNode) -> (Element, InstanceScope)? {
        switch node {
        case .component(_, _, let children):
            return children.lazy.compactMap { self.element(name, labeled: label, in: $0) }.first
        case .element(let element, let scope, let children):
            if element.name == name, let first = element.positional.first,
               (try? Evaluator.evaluate(first.value, in: scope.values)) == .string(label) {
                return (element, scope)
            }
            return children.lazy.compactMap { self.element(name, labeled: label, in: $0) }.first
        case .failure:
            return nil
        }
    }

    private func texts(in node: ResolvedNode) -> [String] {
        switch node {
        case .component(_, _, let children):
            return children.flatMap { texts(in: $0) }
        case .element(let element, let scope, let children):
            var result: [String] = []
            if element.name == "text", let first = element.positional.first,
               let value = try? Evaluator.evaluate(first.value, in: scope.values) {
                result.append(value.description)
            }
            return result + children.flatMap { texts(in: $0) }
        case .failure(let error):
            return ["error: \(error.message)"]
        }
    }
}
