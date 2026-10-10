import XCTest
import LaurCore
@testable import LaurRuntime

final class EvaluatorTests: XCTestCase {
    func testArithmetic() throws {
        XCTAssertEqual(try eval("1 + 2 * 3"), .number(7))
        XCTAssertEqual(try eval("(1 + 2) * 3"), .number(9))
        XCTAssertEqual(try eval("7 % 3"), .number(1))
        XCTAssertEqual(try eval("10 - 4 - 3"), .number(3))
        XCTAssertEqual(try eval("-n + 1", ["n": .number(5)]), .number(-4))
    }

    func testComparisonAndLogic() throws {
        XCTAssertEqual(try eval("1 < 2 && 2 <= 2"), .bool(true))
        XCTAssertEqual(try eval("!(1 == 1) || \"a\" != \"b\""), .bool(true))
        XCTAssertEqual(try eval("\"apple\" < \"banana\""), .bool(true))
    }

    func testAndOrStopEarly() throws {
        // The right side would fail (`missing` isn't defined) if it were evaluated.
        XCTAssertEqual(try eval("false && missing"), .bool(false))
        XCTAssertEqual(try eval("true || missing"), .bool(true))
    }

    func testStringsJoinWithPlusAndInterpolation() throws {
        XCTAssertEqual(try eval("\"#\" + 3"), .string("#3"))
        XCTAssertEqual(try eval("\"\\(a) and \\(b + 1)\"", ["a": .string("x"), "b": .number(1)]), .string("x and 2"))
    }

    func testPropertiesOfRecords() throws {
        let scope: Scope = ["product": .record(["name": .string("Tote")])]
        XCTAssertEqual(try eval("product.name", scope), .string("Tote"))
        XCTAssertThrowsError(try eval("product.nam", scope)) { error in
            XCTAssertEqual((error as? RuntimeError)?.message, "the sample has no field `nam` (it has `name`)")
        }
    }

    func testErrors() {
        XCTAssertThrowsError(try eval("1 / 0")) { error in
            XCTAssertEqual((error as? RuntimeError)?.message, "division by zero")
        }
        XCTAssertThrowsError(try eval("!3")) { error in
            XCTAssertEqual((error as? RuntimeError)?.message, "expected true or false, but got `3`")
        }
        XCTAssertThrowsError(try eval("1 < \"a\""))
    }

    private func eval(_ source: String, _ scope: Scope = [:]) throws -> Value {
        var parser = Parser(tokens: try Lexer.tokenize(source))
        return try Evaluator.evaluate(try parser.parseExpr(), in: scope)
    }
}
