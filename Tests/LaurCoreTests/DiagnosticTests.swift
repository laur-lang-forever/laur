import XCTest
@testable import LaurCore

/// The five mistakes people will make most, plus a few more. Each should produce a
/// clear message at the right place rather than a crash or a vague syntax error.
final class DiagnosticTests: XCTestCase {
    // MARK: - Parse errors (stop at the first)

    func testMissingBraceSaysWhichBlockWasLeftOpen() {
        let source = """
            component Card {
              view {
                stack(.vertical) {
                  text("a")
              }
              preview "p" {}
            }
            """
        let error = parseError(source)
        XCTAssertEqual(error?.message, "expected `}` to close `view`, opened on line 2, before `preview`")
        XCTAssertEqual(error?.range.start.line, 2)
        XCTAssertEqual(error?.help, ["add the missing `}` above line 6"])
    }

    func testUnclosedElementBlockPointsAtItsBrace() {
        let source = """
            component Card {
              view {
                stack(.vertical) {
                  text("a")
            """
        let error = parseError(source)
        XCTAssertEqual(error?.message, "expected `}` to close `stack`, opened on line 3")
        XCTAssertEqual(error?.range.start.line, 3)
        XCTAssertEqual(error?.range.start.column, 22)
    }

    func testMissingCommaBetweenArguments() {
        let error = parseError("component A { view { text(\"a\" style: .body) } }")
        XCTAssertEqual(error?.message, "expected `,` or `)` after an argument to `text`, found `style`")
    }

    func testUnterminatedString() {
        let error = parseError("component A { view { text(\"oops) } }")
        XCTAssertEqual(error?.message, "this string is never closed")
    }

    func testFeaturesFromLaterMilestonesSayNotYet() {
        XCTAssertEqual(parseError("component A { state count: Int = 0 }")?.message, "`state` isn't supported yet")
        XCTAssertEqual(parseError("gate enableV3: Bool = false")?.message, "`gate` isn't supported yet")
        XCTAssertEqual(parseError("component A { view { if x { text(\"a\") } } }")?.message, "`if` isn't supported yet")
    }

    func testStrayCharacterIsReportedWhereItAppears() {
        XCTAssertEqual(parseError("component A { view { text(\"a\" = 1) } }")?.message,
                       "expected `,` or `)` after an argument to `text`, found `=`")
        XCTAssertEqual(parseError("component A { view { text(=) } }")?.message,
                       "unexpected character `=`")
    }

    func testLowercaseComponentName() {
        let error = parseError("component card { }")
        XCTAssertEqual(error?.message, "component names start with an uppercase letter")
        XCTAssertEqual(error?.help, ["rename it to `Card`"])
    }

    // MARK: - Checker errors (all reported)

    func testUnknownPrimitiveSuggestsTheClosestOne() {
        let diagnostics = check(card(view: "stak(.vertical) { text(product.name) }"))
        XCTAssertEqual(diagnostics.map(\.message), ["unknown element `stak`"])
        XCTAssertEqual(diagnostics.first?.help, ["did you mean `stack`?"])
    }

    func testWrongArgumentLabelSuggestsTheRightOne() {
        let diagnostics = check(card(view: "text(product.name, colour: .secondary)"))
        XCTAssertEqual(diagnostics.first?.message, "`text` has no argument `colour`")
        XCTAssertEqual(diagnostics.first?.help.first, "did you mean `color`?")
    }

    func testBadTokenListsTheValidOnes() {
        let diagnostics = check(card(view: "stack(.vertical, spacing: .huge) { text(product.name) }"))
        XCTAssertEqual(diagnostics.first?.message, "`.huge` isn't a spacing token")
        XCTAssertEqual(diagnostics.first?.help.last, "spacing tokens are .none, .xs, .sm, .md, .lg, .xl")
    }

    func testTokenTypoGetsASuggestion() {
        let diagnostics = check(card(view: "text(product.name, style: .headlin)"))
        XCTAssertEqual(diagnostics.first?.help.first, "did you mean `.headline`?")
    }

    func testMissingPreviewIsAnError() {
        let source = """
            component Card(product: Product) {
              view { text(product.name) }
            }
            """
        let diagnostics = check(source)
        XCTAssertEqual(diagnostics.map(\.message), ["`Card` needs at least one `preview`"])
        XCTAssertEqual(diagnostics.first?.help.last, "add `preview \"default\" { product: .sample }`")
    }

    func testUndefinedNameSuggestsAParameter() {
        let diagnostics = check(card(view: "text(prodcut.name)"))
        XCTAssertEqual(diagnostics.first?.message, "`prodcut` isn't defined in `Card`")
        XCTAssertEqual(diagnostics.first?.help, ["did you mean `product`?"])
    }

    func testRawNumberIsAWarningNotAnError() {
        let diagnostics = check(card(view: "stack(spacing: 13) { text(product.name) }"))
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.severity, .warning)
        XCTAssertFalse(diagnostics.hasErrors)
    }

    func testTextCannotHaveChildren() {
        let diagnostics = check(card(view: "text(product.name) { spacer() }"))
        XCTAssertEqual(diagnostics.first?.message, "`text` can't contain other elements")
    }

    func testPreviewMustSetRequiredParameters() {
        let source = """
            component Card(product: Product) {
              view { text(product.name) }
              preview "empty" {}
            }
            """
        XCTAssertEqual(check(source).map(\.message), ["preview \"empty\" is missing a value for `product`"])
    }

    func testComponentsCanUseEachOther() {
        let source = """
            component Price(amount: String) {
              view { text(amount, style: .headline) }
              preview "p" { amount: "$5" }
            }
            component Card(product: Product) {
              view { stack(.vertical) { text(product.name) Price(amount: product.price) } }
              preview "p" { product: .sample }
            }
            """
        XCTAssertEqual(check(source), [])
    }

    func testExampleHasNoDiagnostics() throws {
        XCTAssertEqual(check(try loadExample()), [])
    }

    // MARK: - Rendering

    func testRenderedDiagnosticPointsAtTheMistake() {
        let source = card(view: "stak(.vertical) { text(product.name) }")
        let diagnostic = check(source)[0]
        XCTAssertEqual(diagnostic.render(source: source, fileName: "Card.laur"), """
            error: unknown element `stak`
             --> Card.laur:2:10
              |
            2 |   view { stak(.vertical) { text(product.name) } }
              |          ^^^^
              = help: did you mean `stack`?

            """)
    }

    func testEditDistance() {
        XCTAssertEqual(editDistance("stak", "stack"), 1)
        XCTAssertEqual(editDistance("colour", "color"), 1)
        XCTAssertEqual(closest(to: "zzz", in: ["stack", "text"]), nil)
    }

    // MARK: - Helpers

    private func card(view: String) -> String {
        """
        component Card(product: Product) {
          view { \(view) }
          preview "p" { product: .sample }
        }
        """
    }

    private func parseError(_ source: String) -> Diagnostic? {
        do {
            _ = try Parser.parse(source)
            XCTFail("expected a parse error")
            return nil
        } catch {
            return error as? Diagnostic
        }
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
