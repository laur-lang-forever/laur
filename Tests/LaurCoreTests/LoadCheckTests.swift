import XCTest
@testable import LaurCore

/// Milestone 4: `service`, `load`, `when`, `reload`, and error kinds.
final class LoadCheckTests: XCTestCase {
    func testParsesTheOrderHistoryExample() throws {
        let url = exampleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OrderHistory/OrderHistory.laur")
        let file = try Parser.parse(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(file.services.map(\.name), ["Orders"])
        XCTAssertEqual(file.services.first?.functions.first?.returns, .array(.named(["Order"])))
        let history = try XCTUnwrap(file.component(named: "OrderHistory"))
        XCTAssertEqual(history.loads.map(\.name), ["orders"])
        guard case .element(let stack) = history.view?.first, case .when(let when) = stack.children?[1] else {
            return XCTFail("expected a when inside the stack")
        }
        XCTAssertEqual(when.branches.map(\.kind), ["loading", "failed", "loaded"])
        XCTAssertEqual(when.branch("failed")?.binding?.name, "error")
    }

    func testWhenMustHandleEveryCase() {
        let diagnostics = check(view: """
            when orders {
              loading { spinner() }
              loaded(items) { text("\\(items.count)") }
            }
            """)
        XCTAssertEqual(diagnostics.map(\.message), ["`when orders` needs a `failed` case"])
    }

    func testWhenNeedsALoad() {
        XCTAssertEqual(check(view: """
            when order { loading { spinner() } failed(e) { spinner() } loaded(x) { spinner() } }
            """).first?.message, "`order` isn't a `load` in `A`")
    }

    func testLoadsAreOnlyReadThroughWhen() {
        XCTAssertEqual(check(view: "text(\"\\(orders.count)\")").map(\.message),
                       ["`orders` is loaded, so read it inside `when orders { ... }`"])
    }

    func testServiceCallsAreChecked() {
        XCTAssertEqual(check(load: "Order.fetch(userId: \"u\")").first?.help.first, "did you mean `Orders`?")
        XCTAssertEqual(check(load: "Orders.fetchh(userId: \"u\")").first?.message, "`Orders` has no function `fetchh`")
        XCTAssertEqual(check(load: "Orders.fetch()").map(\.message), ["`Orders.fetch` needs a value for `userId`"])
        XCTAssertTrue(check(load: "Orders.fetch(\"u\")").map(\.message).contains("arguments to `Orders.fetch` are labeled"))
    }

    func testServiceCallsOnlyHappenInLoad() {
        XCTAssertEqual(check(view: "text(Orders.fetch(userId: \"u\"))").map(\.message), ["service calls happen in `load`"])
    }

    func testErrorKindsAreChecked() {
        let diagnostics = check(view: """
            when orders {
              loading { spinner() }
              failed(error) { if error.kind == .netwrok { spinner() } }
              loaded(items) { spinner() }
            }
            """)
        XCTAssertEqual(diagnostics.first?.message, "`.netwrok` isn't an error kind")
        XCTAssertEqual(diagnostics.first?.help.first, "did you mean `.network`?")
    }

    func testPreviewLoadStates() {
        XCTAssertEqual(check(view: "spinner()", preview: "orders: .done").first?.message, "`.done` isn't a load state")
        XCTAssertEqual(check(view: "spinner()", preview: "orders: .failed(.oops)").first?.message, "`.failed` starts with an error kind")
        XCTAssertEqual(check(view: "spinner()", preview: "orders: .failed(.server, \"down\")"), [])
        XCTAssertEqual(check(view: "spinner()", preview: "orders: .loaded([])"), [])
    }

    func testOnlyLoadsReload() {
        XCTAssertEqual(check(view: "button(\"Go\") { userId.reload() }").map(\.message),
                       ["`userId` isn't a `load`, so it can't be reloaded"])
    }

    func testMisspelledCaseIsAParseError() {
        XCTAssertThrowsError(try Parser.parse(source(view: "when orders { loadin { spinner() } }"))) { error in
            XCTAssertEqual((error as? Diagnostic)?.message, "`loadin` isn't a case of `when`")
            XCTAssertEqual((error as? Diagnostic)?.help.first, "did you mean `loading`?")
        }
    }

    // MARK: - Helpers

    private func source(view: String, load: String = "Orders.fetch(userId: userId)", preview: String = "") -> String {
        let extra = preview.isEmpty ? "" : ", \(preview)"
        return """
            service Orders {
              fetch(userId: String) -> [Order]
            }

            component A(userId: String) {
              load orders = \(load)
              view {
                \(view)
              }
              preview "p" { userId: "u"\(extra) }
            }
            """
    }

    private func check(view: String = "spinner()", load: String = "Orders.fetch(userId: userId)", preview: String = "") -> [Diagnostic] {
        do {
            return Checker.check(try Parser.parse(source(view: view, load: load, preview: preview)))
        } catch {
            XCTFail("unexpected parse error: \(error)")
            return []
        }
    }
}
