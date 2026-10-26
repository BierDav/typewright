import Foundation
import TypstBridge

enum TypewrightCLI {
    struct Options {
        let command: String
        var input: String?
        var output: String?
        var root: String?
        var format = "pdf"
        var dark = false
        var json = false

        init(_ arguments: [String]) throws {
            command = arguments.first ?? "help"
            guard ["help", "--help", "-h", "--version", "info", "check", "compile"].contains(command) else {
                throw Usage("Unknown command: \(command)")
            }
            var args = Array(arguments.dropFirst())
            var positional: [String] = []
            var format: String?
            while !args.isEmpty {
                let arg = args.removeFirst()
                switch arg {
                case "--root", "--format":
                    guard !args.isEmpty else { throw Usage("\(arg) requires a value") }
                    let value = args.removeFirst()
                    if arg == "--root" { root = value } else { format = value }
                case "--dark", "--dark-mode": dark = true
                case "--json": json = true
                case "--": positional += args; args = []
                case "--help", "-h": throw Help()
                default:
                    guard !arg.hasPrefix("-") else { throw Usage("Unknown option: \(arg)") }
                    positional.append(arg)
                }
            }
            let count = command == "compile" ? 2 : command == "check" ? 1 : 0
            if command == "info" {
                guard positional.count <= 1 else { throw Usage("info accepts at most one input file") }
            } else if positional.count != count {
                throw Usage("\(command) requires \(count) path argument(s)")
            }
            input = positional.first
            output = positional.dropFirst().first
            self.format = format ?? (output.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } == "html" ? "html" : "pdf")
            guard ["pdf", "html"].contains(self.format) else { throw Usage("Format must be pdf or html") }
            guard !dark || self.format == "html" else { throw Usage("--dark requires HTML output (--format html)") }
        }

        static let help = """
        Usage: typewright <command> [options]
          compile INPUT OUTPUT   Compile to PDF or HTML (inferred from OUTPUT's extension).
          check INPUT            Compile and report diagnostics without writing output.
          info [INPUT]           Show the bundled compiler, project root and font search paths.
          --version              Show Typewright and bundled Typst versions.

        Options:
          --root DIR             Project root (defaults to the containing library space, or input's folder).
          --format pdf|html      Select the output/check target (default: pdf).
          --dark                 Force dark browser appearance in exported HTML, regardless of OS theme.
          --json                 Emit a JSON result, including diagnostics, on stdout.

        Uses Typewright's bundled compiler, package cache and configured font folders.
        Reads saved files from disk; save in the app before checking. External compiler selection is ignored.
        Dark appearance activates adaptive CSS; document styles can still specify fixed colors.
        Exit codes: 0 success, 1 compilation/I/O failure, 2 invalid command or options.
        """
    }

    struct Usage: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct Help: Error {}

    static func run(_ arguments: [String]) -> Int32 {
        do {
            let options = try Options(arguments)
            if ["help", "--help", "-h"].contains(options.command) { print(Options.help); return 0 }
            if options.command == "--version" {
                print("Typewright \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") (Typst \(String(cString: tw_version())))")
                return 0
            }
            return try execute(options)
        } catch is Help {
            print(Options.help)
            return 0
        } catch let error as Usage {
            writeError(error.message)
            return 2
        } catch {
            writeError(error.localizedDescription)
            return 1
        }
    }

    static func projectRoot(for input: URL) -> URL {
        var folder = input.deletingLastPathComponent()
        while folder.path != "/" {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".jj/typewright").path) {
                let relative = String(input.path.dropFirst(folder.path.count + 1))
                if relative.contains("/"), let space = relative.split(separator: "/").first {
                    return folder.appendingPathComponent(String(space), isDirectory: true)
                }
                return folder
            }
            folder.deleteLastPathComponent()
        }
        return input.deletingLastPathComponent()
    }

    private static func execute(_ options: Options) throws -> Int32 {
        let input = options.input.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
        let root = options.root.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath() }
            ?? input.map(projectRoot) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let paths = FontSearch.directories(FontSearch.loadSettings(), from: input?.deletingLastPathComponent() ?? root)
        var report: [String: Any] = [
            "compiler": "builtin", "version": String(cString: tw_version()), "root": root.path,
            "fontPaths": paths.map(\.path), "source": "disk", "format": options.format,
        ]
        if let input { report["input"] = input.path }
        if options.command == "info" {
            if options.json {
                try printJSON(report)
            } else {
                print("Bundled Typst \(String(cString: tw_version()))\nRoot: \(root.path)\nSource: saved files on disk\nFonts:")
                paths.forEach { print("  \($0.path)") }
            }
            return 0
        }
        guard let input else { throw Usage("An input file is required") }
        guard input.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { throw Usage("Input is outside --root") }
        let main = String(input.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
        let output = options.output.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
        guard output != input else { throw Usage("Output must not overwrite the input document") }

        let world = tw_world_new(root.path)
        defer { tw_world_free(world) }
        tw_world_set_main(world, main)
        let strings = paths.map { strdup($0.path)! }
        defer { strings.forEach { free($0) } }
        strings.map { UnsafePointer($0) }.withUnsafeBufferPointer {
            _ = tw_world_set_font_paths(world, $0.baseAddress, $0.count)
        }
        let format = options.format == "html" ? TWFormatHTML : options.command == "check" ? TWFormatCheck : TWFormatPDF
        let result = tw_world_compile(world, format)
        defer { tw_result_free(result) }
        let diagnostics = try JSONSerialization.jsonObject(with: Data(String(cString: result.diagnostics).utf8))
        report["diagnostics"] = diagnostics
        report["success"] = result.data != nil
        if !options.json, let diagnostics = diagnostics as? [[String: Any]] {
            for entry in diagnostics {
                let path = entry["path"] as? String ?? ""
                let location = path.isEmpty ? "" : "\(path):\(entry["line"] ?? 1):\(entry["column"] ?? 1): "
                writeError("\(location)\(entry["severity"] ?? "error"): \(entry["message"] ?? "")")
            }
        }
        if let bytes = result.data, let output {
            do {
                var data = Data(bytes: bytes, count: result.len)
                if options.format == "html" {
                    data = Data(try HTMLExport.document(String(decoding: data, as: UTF8.self), root: root,
                                                        fontDirectories: paths, dark: options.dark).utf8)
                }
                try data.write(to: output, options: .atomic)
                report["output"] = output.path
            } catch {
                report["success"] = false
                report["error"] = error.localizedDescription
                if !options.json { writeError(error.localizedDescription) }
            }
        }
        if options.json { try printJSON(report) }
        return report["success"] as? Bool == true ? 0 : 1
    }

    private static func printJSON(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
