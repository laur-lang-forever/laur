import XCTest
@testable import LaurCore

/// The checker's rules for `context`: which groups and fields exist, which can't be
/// used in `if`, and how previews set a component's position.
final class ContextCheckTests: XCTestCase {
    func testValidContextFieldsPass() {
        let view = """
            stack(.vertical) {
              text("\\(context.siblings.index) \\(context.siblings.count) \\(context.reading.index) \\(context.reading.count)")
              text("\\(context.level.depth) \\(context.level.index) \\(context.level.count)")
              text(context.parent.type)
              text(context.parent.path)
              if context.siblings.isFirst && !context.siblings.isLast && context.reading.isFirst { spacer() }
            }
            """
        XCTAssertEqual(check(card(view: view)), [])
    }

    func testUnknownGroupSuggestsTheRightOne() {
        let diagnostics = check(card(view: "text(\"\\(context.sibling.index)\")"))
        XCTAssertEqual(diagnostics.first?.message, "`context` has no group `sibling`")
        XCTAssertEqual(diagnostics.first?.help.first, "did you mean `context.siblings`?")
    }

    func testUnknownFieldListsTheFields() {
        let diagnostics = check(card(view: "text(\"\\(context.siblings.indx)\")"))
        XCTAssertEqual(diagnostics.first?.message, "`context.siblings` has no field `indx`")
        XCTAssertEqual(diagnostics.first?.help, [
            "did you mean `index`?",
            "`context.siblings` has `index`, `count`, `isFirst`, `isLast`",
        ])
    }

    func testGroupOnItsOwnIsNotAValue() {
        XCTAssertEqual(check(card(view: "text(context.siblings)")).first?.message,
                       "`context.siblings` on its own isn't a value")
        XCTAssertEqual(check(card(view: "text(context)")).first?.message,
                       "`context` on its own isn't a value")
    }

    func testScreenContextIsNotSupportedYet() {
        XCTAssertEqual(check(card(view: "if context.screen.isVisible { spacer() }")).first?.message,
                       "`context.screen` isn't supported yet")
    }

    func testCountsKnownAfterLayoutCantDecideAnIf() {
        let diagnostics = check(card(view: "if context.reading.count > 3 { spacer() }"))
        XCTAssertEqual(diagnostics.map(\.message), ["`context.reading.count` can't be used in an `if`"])
        // ...but showing them is fine.
        XCTAssertEqual(check(card(view: "text(\"\\(context.level.count)\")")), [])
    }

    func testPreviewCanPlaceTheComponent() {
        XCTAssertEqual(check(card(view: "text(product.name)", context: ".siblings(2, of: 5)")), [])
        XCTAssertEqual(check(card(view: "text(product.name)", context: ".reading(0, of: 3)")), [])
    }

    func testPreviewPositionMustBeInRange() {
        XCTAssertEqual(check(card(view: "text(product.name)", context: ".siblings(5, of: 5)")).first?.message,
                       "`.siblings(5, of: 5)` isn't a valid position")
        XCTAssertEqual(check(card(view: "text(product.name)", context: ".first")).first?.message,
                       "a preview's `context` is `.siblings(index, of: count)` or `.reading(index, of: count)`")
    }

    func testProductListExampleHasNoDiagnostics() throws {
        let url = exampleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ProductList/ProductList.laur")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(check(source), [])
    }

    // MARK: - Helpers

    private func card(view: String, context: String? = nil) -> String {
        let contextEntry = context.map { ", context: \($0)" } ?? ""
        return """
            component Card(product: Product) {
              view {
                \(view)
              }
              preview "p" { product: .sample\(contextEntry) }
            }
            """
    }

    private func check(_ source: String) -> [Diagnostic] {
        do {
            return Checker.check(try Parser.parse(source))
        } catch {
            XCTFail("unexpected parse error: \(error)")
            return []
        }
    }
}
