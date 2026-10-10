import XCTest
@testable import LaurCore

/// Milestone 3: `state`, `derived`, `action`, `bind`, and the rules about what can change.
final class StateCheckTests: XCTestCase {
    func testParsesMembersOfTheSignUpExample() throws {
        let url = exampleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SignUp/SignUp.laur")
        let file = try Parser.parse(try String(contentsOf: url, encoding: .utf8))
        let form = try XCTUnwrap(file.component(named: "SignUpForm"))
        XCTAssertEqual(form.states.map(\.name), ["email", "password", "agreed", "submitted"])
        XCTAssertEqual(form.derived.map(\.name), ["validEmail", "longEnough", "canSubmit"])
        XCTAssertEqual(form.actions.map(\.name), ["submit", "startOver"])
        XCTAssertEqual(file.component(named: "Stepper")?.params.first?.type, .binding(.named(["Number"])))
    }

    func testDerivedValuesCantBeAssigned() {
        let diagnostics = check(component("""
              state n: Number = 0
              derived double = n * 2
              view { button("Go") { double = 4 } }
            """))
        XCTAssertEqual(diagnostics.map(\.message), ["`double` is derived from other values, so it can't be assigned"])
    }

    func testPlainParametersCantBeAssigned() {
        let source = """
            component A(title: String) {
              view { button("Go") { title = "x" } }
              preview "p" { title: "a" }
            }
            """
        let diagnostics = check(source)
        XCTAssertEqual(diagnostics.first?.message, "`title` is a parameter, so it can't be changed here")
        XCTAssertEqual(diagnostics.first?.help.first, "make it `state`, or declare the parameter as `title: bind String` so the caller's state changes")
    }

    func testOnlyStateCanBeBound() {
        let diagnostics = check(component("""
              state n: Number = 0
              derived label = "x"
              view { field("Name", value: bind label) }
            """))
        XCTAssertEqual(diagnostics.map(\.message), ["`label` can't be bound"])
    }

    func testFieldNeedsABinding() {
        XCTAssertEqual(check(component("""
              view { field("Name") }
            """)).map(\.message), ["`field` needs a `value:` argument"])
        XCTAssertEqual(check(component("""
              state name: String = ""
              view { field("Name", value: name) }
            """)).map(\.message), ["`value` takes `bind` and a state name"])
    }

    func testBindOnlyBelongsInBindings() {
        XCTAssertEqual(check(component("""
              state name: String = ""
              view { text(bind name) }
            """)).map(\.message), ["`bind` passes state to a field, a toggle or a `bind` parameter"])
    }

    func testUnknownActionGetsASuggestion() {
        let diagnostics = check(component("""
              state n: Number = 0
              view { button("Go") { submti() } }
              action submit() { n = 1 }
            """))
        XCTAssertEqual(diagnostics.first?.message, "`A` has no action `submti`")
        XCTAssertEqual(diagnostics.first?.help, ["did you mean `submit`?"])
    }

    func testButtonNeedsABlock() {
        XCTAssertEqual(check(component("""
              view { button("Go") }
            """)).map(\.message), ["`button` needs a block that says what happens on tap"])
    }

    func testBuiltInMethods() {
        XCTAssertEqual(check(component("""
              state s: String = ""
              view { if s.contains("@") && !s.trimmed().hasPrefix(" ") && s.count > 2 { spacer() } }
            """)), [])
        let diagnostics = check(component("""
              state s: String = ""
              view { if s.contain("@") { spacer() } }
            """))
        XCTAssertEqual(diagnostics.first?.message, "there's no built-in method `contain`")
        XCTAssertEqual(diagnostics.first?.help.first, "did you mean `contains`?")
        XCTAssertEqual(check(component("""
              state s: String = ""
              view { text(s.uppercased(1)) }
            """)).map(\.message), ["`uppercased` takes no arguments"])
    }

    func testStateTypesAndStartingValues() {
        XCTAssertEqual(check(component("""
              state n: Number = "zero"
              view { spacer() }
            """)).map(\.message), ["`n` is a Number, but starts as a string"])
        XCTAssertEqual(check(component("""
              state items: [String] = 0
              view { spacer() }
            """)).map(\.message), ["state can be `String`, `Number`, `Bool` for now"])
    }

    func testBindParametersNeedBind() {
        let source = """
            component Stepper(value: bind Number) {
              view { button("+") { value += 1 } }
              preview "p" { value: 1 }
            }
            component A {
              state n: Number = 0
              view { stack(.vertical) { Stepper(value: bind n) Stepper(value: n) } }
              preview "p" {}
            }
            """
        XCTAssertEqual(check(source).map(\.message), ["`value` takes `bind` and a state name"])
    }

    func testPreviewsCanSetState() {
        XCTAssertEqual(check("""
            component A {
              state n: Number = 0
              view { text("\\(n)") }
              preview "p" { n: 5 }
              preview "q" { m: 5 }
            }
            """).map(\.message), ["`m` isn't a parameter or state of `A`"])
    }

    func testNavigationInActionsIsNotSupportedYet() {
        XCTAssertThrowsError(try Parser.parse("component A { action go() { navigate Home } }")) { error in
            XCTAssertEqual((error as? Diagnostic)?.message, "`navigate` isn't supported yet")
        }
    }

    func testStatementsPrint() throws {
        let source = """
            component A {
              state n: Number = 0

              view {
                button("+") { n += 1 }
              }

              action reset() {
                if n > 10 {
                  n = 10
                } else {
                  n = 0
                }
              }

              preview "p" {}
            }
            """
        XCTAssertEqual(Printer.print(try Parser.parse(source)), source + "\n")
    }

    // MARK: - Helpers

    private func component(_ body: String) -> String {
        """
        component A {
        \(body)
          preview "p" {}
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
