import XCTest
@testable import LaurCore

/// Milestone 2 syntax: operators, interpolation, `if`, and `list` blocks.
final class ExpressionTests: XCTestCase {
    func testOperatorPrecedence() throws {
        let expr = try parseExpr("a + b * c == d && !e || f")
        guard case .binary("||", let left, _) = expr.kind,
              case .binary("&&", let comparison, let negation) = left.kind,
              case .binary("==", let sum, _) = comparison.kind,
              case .binary("+", _, let product) = sum.kind,
              case .binary("*", _, _) = product.kind,
              case .unary("!", _) = negation.kind else {
            return XCTFail("unexpected tree: \(Printer.print(expr))")
        }
    }

    func testPrinterKeepsNeededParenthesesOnly() throws {
        XCTAssertEqual(Printer.print(try parseExpr("(a + b) * c")), "(a + b) * c")
        XCTAssertEqual(Printer.print(try parseExpr("a + (b * c)")), "a + b * c")
        XCTAssertEqual(Printer.print(try parseExpr("a - (b - c)")), "a - (b - c)")
        XCTAssertEqual(Printer.print(try parseExpr("!(a && b)")), "!(a && b)")
    }

    func testSubtractionIsNotANegativeNumber() throws {
        XCTAssertEqual(Printer.print(try parseExpr("index-1")), "index - 1")
        XCTAssertEqual(Printer.print(try parseExpr("-1")), "-1")
    }

    func testInterpolationSplitsTextAndCode() throws {
        let expr = try parseExpr(##""#\(context.siblings.index + 1) of \(context.siblings.count)""##)
        guard case .interpolation(let parts) = expr.kind else {
            return XCTFail("expected an interpolated string")
        }
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], .text("#"))
        XCTAssertEqual(parts[2], .text(" of "))
        guard case .expr(let count) = parts[3] else { return XCTFail("expected code") }
        XCTAssertEqual(count.kind, .path(["context", "siblings", "count"]))
        XCTAssertEqual(Printer.print(expr), ##""#\(context.siblings.index + 1) of \(context.siblings.count)""##)
    }

    func testErrorsInsideInterpolationPointIntoTheString() {
        let source = """
            component Card(product: Product) {
              view { text("Hi \\(prodcut.name)") }
              preview "p" { product: .sample }
            }
            """
        let diagnostics = check(source)
        XCTAssertEqual(diagnostics.first?.message, "`prodcut` isn't defined in `Card`")
        XCTAssertEqual(diagnostics.first?.range.start.line, 2)
        XCTAssertEqual(diagnostics.first?.range.start.column, 21)
    }

    func testIfElseIfElseParsesAndPrints() throws {
        let source = """
            component A(n: Number) {
              view {
                if n == 0 {
                  text("none")
                } else if n == 1 {
                  text("one")
                } else {
                  text("many")
                }
              }

              preview "p" { n: 2 }
            }
            """
        let file = try Parser.parse(source)
        guard case .conditional(let conditional) = file.components[0].view?.first else {
            return XCTFail("expected an if")
        }
        XCTAssertEqual(conditional.branches.count, 2)
        XCTAssertEqual(conditional.otherwise?.count, 1)
        XCTAssertEqual(Printer.print(file), source + "\n")
    }

    func testListBlockNamesItsItems() throws {
        let file = try Parser.parse("component A(xs: [Item]) { view { list(xs) { x in text(x.name) } } preview \"p\" { xs: .samples(2) } }")
        let list = try XCTUnwrap(file.components[0].view?.first?.element)
        XCTAssertEqual(list.binding?.name, "x")
        XCTAssertEqual(list.children?.count, 1)
        XCTAssertEqual(check(Printer.print(file)), [])
    }

    func testOnlyListsNameTheirItems() {
        XCTAssertEqual(
            check(card(view: "stack(.vertical) { x in text(product.name) }")).first?.message,
            "only `list` blocks name their items"
        )
    }

    func testListNeedsAName() {
        let source = "component A(xs: [Item]) { view { list(xs) { text(\"a\") } } preview \"p\" { xs: .samples(2) } }"
        XCTAssertEqual(check(source).first?.message, "`list` needs a name for each item")
    }

    func testListItemIsOnlyInScopeInsideTheList() {
        let source = """
            component A(xs: [Item]) {
              view {
                stack(.vertical) {
                  list(xs) { x in text(x.name) }
                  text(x.name)
                }
              }
              preview "p" { xs: .samples(2) }
            }
            """
        XCTAssertEqual(check(source).map(\.message), ["`x` isn't defined in `A`"])
    }

    func testElseWithoutIf() throws {
        XCTAssertThrowsError(try Parser.parse("component A { view { else { } } }")) { error in
            XCTAssertEqual((error as? Diagnostic)?.message, "`else` without an `if` before it")
        }
    }

    // MARK: - Helpers

    private func parseExpr(_ text: String) throws -> Expr {
        var parser = Parser(tokens: try Lexer.tokenize(text))
        return try parser.parseExpr()
    }

    private func card(view: String) -> String {
        """
        component Card(product: Product) {
          view { \(view) }
          preview "p" { product: .sample }
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
