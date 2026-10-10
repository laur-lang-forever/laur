import Foundation
import XCTest
@testable import LaurCore

/// The example from the spec, read from the repo so the test and the example never drift.
let exampleURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // LaurCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // repo root
    .appendingPathComponent("Examples/ProductCard/ProductCard.laur")

func loadExample() throws -> String {
    try String(contentsOf: exampleURL, encoding: .utf8)
}

final class ParserTests: XCTestCase {
    func testParsesProductCardExample() throws {
        let file = try Parser.parse(try loadExample())

        XCTAssertEqual(file.imports.map(\.path), [["Models", "Product"]])
        XCTAssertEqual(file.components.count, 1)

        let card = try XCTUnwrap(file.components.first)
        XCTAssertEqual(card.name, "ProductCard")
        XCTAssertEqual(card.params.map(\.name), ["product"])
        XCTAssertEqual(card.params.first?.type, .named(["Product"]))
        XCTAssertEqual(card.intent, "Show one product with its photo, name and price")

        let root = try XCTUnwrap(card.view?.first?.element)
        XCTAssertEqual(card.view?.count, 1)
        XCTAssertEqual(root.name, "stack")
        XCTAssertEqual(root.positional.first?.value.tokenName, "vertical")
        XCTAssertEqual(root.argument("spacing")?.value.tokenName, "md")
        XCTAssertEqual(root.children?.compactMap(\.element).map(\.name), ["image", "text", "text"])

        let image = try XCTUnwrap(root.children?.first?.element)
        XCTAssertEqual(image.positional.first?.value.kind, .path(["product", "photo"]))
        XCTAssertEqual(image.argument("aspect")?.value.tokenName, "square")
        XCTAssertEqual(image.argument("corner")?.value.tokenName, "md")

        XCTAssertEqual(card.previews.map(\.name), ["default", "long name"])
        XCTAssertEqual(card.previews[0].entry("product")?.value.kind, .token("sample", arguments: nil))

        guard case .token("sample", let overrides?)? = card.previews[1].entry("product")?.value.kind else {
            return XCTFail("expected .sample(...) with overrides")
        }
        XCTAssertEqual(overrides.first?.label, "name")
        XCTAssertEqual(overrides.first?.value.kind, .string("An unusually long product name that wraps"))
    }

    func testSourceRangesPointAtTheText() throws {
        let file = try Parser.parse("component A {\n  view {\n    text(\"hi\")\n  }\n  preview \"p\" {}\n}\n")
        let node = try XCTUnwrap(file.components.first?.view?.first?.element)
        XCTAssertEqual(node.nameRange.start, SourceLocation(line: 3, column: 5, offset: 27))
        XCTAssertEqual(node.nameRange.end.column, 9)
    }

    func testCommentsAndTrailingCommasAreAllowed() throws {
        let source = """
            // A card
            component A(title: String,) {
              view {
                text(title, style: .body,) // trailing comma
              }
              preview "p" { title: "Hi", }
            }
            """
        let file = try Parser.parse(source)
        XCTAssertEqual(file.components.first?.params.map(\.name), ["title"])
        XCTAssertEqual(file.components.first?.view?.first?.element?.arguments.count, 2)
    }

    func testParsesOptionalAndArrayTypes() throws {
        let file = try Parser.parse("component A(a: [Models.Item]?, b: String?) { view { spacer() } preview \"p\" {} }")
        let params = try XCTUnwrap(file.components.first?.params)
        XCTAssertEqual(params[0].type, .optional(.array(.named(["Models", "Item"]))))
        XCTAssertEqual(params[0].type.baseName, "Item")
        XCTAssertTrue(params[1].type.isOptional)
    }

    func testWindowsLineEndingsKeepLineNumbers() throws {
        let file = try Parser.parse("component A {\r\n  view {\r\n    text(\"x\")\r\n  }\r\n}\r\n")
        XCTAssertEqual(file.components.first?.view?.first?.element?.nameRange.start.line, 3)
    }

    func testPrinterOutputIsStable() throws {
        let original = try Parser.parse(try loadExample())
        let printed = Printer.print(original)
        let reparsed = try Parser.parse(printed)
        // Printing is idempotent: formatting formatted code changes nothing.
        XCTAssertEqual(Printer.print(reparsed), printed)
        XCTAssertEqual(reparsed.components.first?.previews.map(\.name), ["default", "long name"])
        XCTAssertTrue(printed.contains("    stack(.vertical, spacing: .md) {\n      image(product.photo, aspect: .square, corner: .md)"))
    }
}
