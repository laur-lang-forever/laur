import Foundation
import XCTest
import LaurCore
@testable import LaurRuntime

/// What each component knows about its position once a screen is resolved.
final class ResolverTests: XCTestCase {
    let samples = SampleData(types: [
        "Product": ["Canvas Tote", "Trail Runner", "Desk Lamp", "Wool Beanie", "Water Bottle"].map {
            .record(["name": .string($0), "price": .string("$10"), "photo": .string("bag")])
        },
    ])

    // MARK: - The ProductList example

    func testListItemsKnowTheirPosition() throws {
        let (file, list) = try loadExample("ProductList")
        let root = Resolver(file: file, samples: samples).resolve(list, preview: try preview(list, "three items"))

        let contexts = componentContexts(in: root)
        XCTAssertEqual(contexts.map(\.type), ["ProductList", "ProductRow", "ProductRow", "ProductRow"])

        let rows = Array(contexts.dropFirst())
        XCTAssertEqual(rows.map(\.siblingIndex), [0, 1, 2])
        XCTAssertEqual(rows.map(\.siblingCount), [3, 3, 3])
        XCTAssertEqual(rows.map(\.readingIndex), [1, 2, 3])
        XCTAssertEqual(rows.map(\.readingCount), [4, 4, 4])
        XCTAssertEqual(rows.map(\.depth), [1, 1, 1])
        XCTAssertEqual(rows.map(\.levelIndex), [0, 1, 2])
        XCTAssertEqual(rows.map(\.levelCount), [3, 3, 3])
        XCTAssertEqual(rows.map(\.parentType), ["ProductList", "ProductList", "ProductList"])
        XCTAssertEqual(rows.map(\.path), ["ProductList/ProductRow[0]", "ProductList/ProductRow[1]", "ProductList/ProductRow[2]"])
    }

    func testOnlyTheFirstRowHasABadgeAndOnlyTheLastHasNoDivider() throws {
        let (file, list) = try loadExample("ProductList")
        let root = Resolver(file: file, samples: samples).resolve(list, preview: try preview(list, "three items"))
        let rows = componentNodes(in: root).dropFirst()

        XCTAssertEqual(rows.map { elementNames(in: $0).contains("badge") }, [true, false, false])
        XCTAssertEqual(rows.map { elementNames(in: $0).contains("divider") }, [true, true, false])
    }

    func testPreviewContextPlacesTheRow() throws {
        let (file, _) = try loadExample("ProductList")
        let row = try XCTUnwrap(file.component(named: "ProductRow"))
        let resolver = Resolver(file: file, samples: samples)

        let middle = resolver.resolve(row, preview: try preview(row, "middle"))
        XCTAssertEqual(componentContexts(in: middle).first?.siblingIndex, 2)
        XCTAssertEqual(componentContexts(in: middle).first?.siblingCount, 5)
        XCTAssertEqual(texts(in: middle).last, "#3 of 5")
        XCTAssertFalse(elementNames(in: middle).contains("badge"))

        let first = resolver.resolve(row, preview: try preview(row, "first"))
        XCTAssertTrue(elementNames(in: first).contains("badge"))
        XCTAssertEqual(texts(in: first).last, "#1 of 5")

        let last = resolver.resolve(row, preview: try preview(row, "last"))
        XCTAssertFalse(elementNames(in: last).contains("divider"))
    }

    // MARK: - Siblings, reading order and levels

    func testSiblingsCountWhatTheIfsLeftOnScreen() throws {
        let file = try Parser.parse("""
            component Tag {
              view { text("\\(context.siblings.index) of \\(context.siblings.count)") }
              preview "p" {}
            }
            component Screen(show: Bool) {
              view {
                stack(.vertical) {
                  text("header")
                  if show { text("optional") }
                  Tag()
                }
              }
              preview "hidden" { show: false }
              preview "shown" { show: true }
            }
            """)
        let screen = try XCTUnwrap(file.component(named: "Screen"))
        let resolver = Resolver(file: file)

        let hidden = resolver.resolve(screen, preview: try preview(screen, "hidden"))
        XCTAssertEqual(componentContexts(in: hidden).last.map { "\($0.siblingIndex)/\($0.siblingCount)" }, "1/2")
        let shown = resolver.resolve(screen, preview: try preview(screen, "shown"))
        XCTAssertEqual(componentContexts(in: shown).last.map { "\($0.siblingIndex)/\($0.siblingCount)" }, "2/3")
    }

    func testReadingIsDepthFirstAndLevelIsBreadthFirst() throws {
        // Screen
        // ├── Section A
        // │   ├── Item
        // │   └── Item
        // └── Section B
        //     └── Item
        let file = try Parser.parse("""
            component Item { view { spacer() } preview "p" {} }
            component Section(n: Number) {
              view {
                stack(.vertical) {
                  Item()
                  if n > 1 { Item() }
                }
              }
              preview "p" { n: 1 }
            }
            component Screen {
              view {
                stack(.vertical) {
                  Section(n: 2)
                  Section(n: 1)
                }
              }
              preview "p" {}
            }
            """)
        let screen = try XCTUnwrap(file.component(named: "Screen"))
        let root = Resolver(file: file).resolve(screen, preview: try preview(screen, "p"))
        let contexts = componentContexts(in: root)

        XCTAssertEqual(contexts.map(\.type), ["Screen", "Section", "Item", "Item", "Section", "Item"])
        XCTAssertEqual(contexts.map(\.readingIndex), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(contexts.map(\.depth), [0, 1, 2, 2, 1, 2])
        XCTAssertEqual(contexts.map(\.levelIndex), [0, 0, 0, 1, 1, 2])
        XCTAssertEqual(contexts.map(\.levelCount), [1, 2, 3, 3, 2, 3])
        XCTAssertEqual(contexts.last?.path, "Screen/Section[1]/Item")
    }

    func testCountsAreNotAvailableToIf() throws {
        // The checker rejects this; the runtime must still fail safely if it gets through.
        let file = try Parser.parse("""
            component A {
              view { if context.reading.count > 1 { spacer() } }
              preview "p" {}
            }
            """)
        let a = try XCTUnwrap(file.component(named: "A"))
        let root = Resolver(file: file).resolve(a, preview: try preview(a, "p"))
        guard case .component(_, _, let children) = root, case .failure(let error)? = children.first else {
            return XCTFail("expected the if to fail")
        }
        XCTAssertTrue(error.message.contains("isn't known until the whole screen is laid out"))
    }

    // MARK: - Helpers

    private func loadExample(_ name: String) throws -> (SourceFile, Component) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/\(name)/\(name).laur")
        let file = try Parser.parse(try String(contentsOf: url, encoding: .utf8))
        return (file, try XCTUnwrap(file.component(named: name)))
    }

    private func preview(_ component: Component, _ name: String) throws -> PreviewBlock {
        try XCTUnwrap(component.preview(named: name))
    }

    /// Component nodes in reading order.
    private func componentNodes(in node: ResolvedNode) -> [ResolvedNode] {
        switch node {
        case .component(_, _, let children):
            return [node] + children.flatMap(componentNodes)
        case .element(_, _, let children):
            return children.flatMap(componentNodes)
        case .failure:
            return []
        }
    }

    private func componentContexts(in node: ResolvedNode) -> [ContextInfo] {
        componentNodes(in: node).compactMap {
            if case .component(_, let context, _) = $0 { return context }
            return nil
        }
    }

    /// Names of primitives directly inside this component (not inside nested components).
    private func elementNames(in node: ResolvedNode) -> [String] {
        func walk(_ node: ResolvedNode, isRoot: Bool) -> [String] {
            switch node {
            case .component(_, _, let children):
                return isRoot ? children.flatMap { walk($0, isRoot: false) } : []
            case .element(let element, _, let children):
                return [element.name] + children.flatMap { walk($0, isRoot: false) }
            case .failure:
                return []
            }
        }
        return walk(node, isRoot: true)
    }

    /// Every `text` value, evaluated the way the renderer would.
    private func texts(in node: ResolvedNode) -> [String] {
        switch node {
        case .component(_, _, let children):
            return children.flatMap(texts)
        case .element(let element, let scope, let children):
            var result: [String] = []
            if element.name == "text", let argument = element.positional.first,
               let value = try? Evaluator.evaluate(argument.value, in: scope.values) {
                result.append(value.description)
            }
            return result + children.flatMap(texts)
        case .failure:
            return []
        }
    }
}
