import Foundation
import XCTest
@testable import LaurCore

/// Every `.laur` file under Examples/ must parse, pass the checker with no errors or
/// warnings, and keep the same meaning after formatting.
final class ExampleTests: XCTestCase {
    func testEveryExampleIsClean() throws {
        let examples = exampleURL.deletingLastPathComponent().deletingLastPathComponent()
        let files = try XCTUnwrap(FileManager.default.enumerator(at: examples, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "laur" }
        XCTAssertGreaterThanOrEqual(files.count, 3)

        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            let file: SourceFile
            do {
                file = try Parser.parse(source)
            } catch let diagnostic as Diagnostic {
                XCTFail(diagnostic.render(source: source, fileName: url.lastPathComponent))
                continue
            }
            for diagnostic in Checker.check(file) {
                XCTFail(diagnostic.render(source: source, fileName: url.lastPathComponent))
            }
            let printed = Printer.print(file)
            XCTAssertEqual(Printer.print(try Parser.parse(printed)), printed, url.lastPathComponent)
        }
    }
}
