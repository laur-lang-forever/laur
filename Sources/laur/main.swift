import Foundation
import LaurCore

let usage = """
    laur — tools for the Laur UI language

    Usage:
      laur preview <file.laur>   Open a live preview window that reloads when you save
      laur check <file.laur>     Report errors and warnings
      laur fmt <file.laur>       Print the file in canonical formatting
      laur help                  Show this message

    Sample data for previews is read from samples.json next to the .laur file.
    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func readFile(_ path: String) -> (url: URL, text: String) {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        fail("laur: can't read \(path)")
    }
    return (url, text)
}

/// Parses and checks a file, printing every diagnostic. Returns nil if there were errors.
func parseAndReport(_ url: URL, _ text: String) -> SourceFile? {
    let name = url.lastPathComponent
    do {
        let file = try Parser.parse(text)
        let diagnostics = Checker.check(file)
        for diagnostic in diagnostics {
            print(diagnostic.render(source: text, fileName: name))
        }
        return diagnostics.hasErrors ? nil : file
    } catch let diagnostic as Diagnostic {
        print(diagnostic.render(source: text, fileName: name))
        return nil
    } catch {
        print("error: \(error)")
        return nil
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"

switch command {
case "check":
    guard arguments.count == 2 else { fail("usage: laur check <file.laur>", code: 2) }
    let (url, text) = readFile(arguments[1])
    if let file = parseAndReport(url, text) {
        let count = file.components.count
        print("\(url.lastPathComponent): \(count) component\(count == 1 ? "" : "s"), no errors")
    } else {
        exit(1)
    }

case "fmt":
    guard arguments.count == 2 else { fail("usage: laur fmt <file.laur>", code: 2) }
    let (url, text) = readFile(arguments[1])
    do {
        print(Printer.print(try Parser.parse(text)), terminator: "")
    } catch let diagnostic as Diagnostic {
        fail(diagnostic.render(source: text, fileName: url.lastPathComponent))
    } catch {
        fail("error: \(error)")
    }

case "preview":
    guard arguments.count == 2 else { fail("usage: laur preview <file.laur>", code: 2) }
    let (url, _) = readFile(arguments[1])
    PreviewerApp.fileURL = url
    // The process is on the main thread here; start the SwiftUI app on the main actor.
    MainActor.assumeIsolated {
        PreviewerApp.main()
    }

case "help", "-h", "--help":
    print(usage)

default:
    fail("laur: unknown command `\(command)`\n\n\(usage)", code: 2)
}
