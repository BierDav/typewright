import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Opens project windows from menus, Finder and the home window.
@MainActor
final class Opener {
    static let shared = Opener()

    private var controllers: [MainWindowController] = []

    /// Focuses the window showing `url`, else loads it into a Home window, else opens a new one.
    func open(_ url: URL) {
        let url = url.standardizedFileURL
        if let existing = controllers.first(where: { $0.state.project == url }) {
            return existing.showWindow(nil)
        }
        let homes = controllers.filter { $0.state.project == nil }
        if let target = homes.first(where: { $0.window?.isKeyWindow == true }) ?? homes.first {
            target.state.project = url
            target.showWindow(nil)
        } else {
            show(MainWindowController(project: url))
        }
    }

    func newWindow() {
        show(MainWindowController(project: nil))
    }

    /// Brings up a Home window, reusing an existing one.
    func showHome() {
        if let home = controllers.first(where: { $0.state.project == nil }) {
            home.showWindow(nil)
        } else {
            newWindow()
        }
    }

    func closeProject() {
        controllers.first { $0.window?.isKeyWindow == true }?.state.project = nil
    }

    /// Reopens the projects from the last session, or Home.
    func restoreSession() {
        guard controllers.isEmpty else { return }
        let paths = UserDefaults.standard.stringArray(forKey: "openProjects") ?? []
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { newWindow() } else { urls.forEach { show(MainWindowController(project: $0)) } }
    }

    func saveSession() {
        let paths = controllers.compactMap { $0.state.project?.path }
        UserDefaults.standard.set(paths, forKey: "openProjects")
    }

    func closed(_ controller: MainWindowController) {
        controllers.removeAll { $0 === controller }
        // Keep the session when quitting closes all windows.
        if !isTerminating { saveSession() }
    }

    var isTerminating = false

    private func show(_ controller: MainWindowController) {
        controllers.append(controller)
        controller.showWindow(nil)
        saveSession()
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "typ") ?? .plainText, .folder]
        panel.message = "Choose a Typst file or project folder"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func newProject(_ template: ProjectTemplate = ProjectTemplate.all[0]) {
        let panel = NSSavePanel()
        panel.title = "New \(template.name) Project"
        panel.nameFieldLabel = "Project:"
        panel.nameFieldStringValue = "Untitled"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try template.body(url.lastPathComponent)
                .write(to: url.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
            open(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Runs `git clone` and returns git's error output on failure.
    func clone(_ remote: String, into parent: URL) async -> String? {
        let name = URL(string: remote)?.deletingPathExtension().lastPathComponent ?? "repository"
        let target = parent.appendingPathComponent(name.isEmpty ? "repository" : name)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["clone", remote, target.path]
        let err = Pipe()
        proc.standardError = err
        do { try proc.run() } catch { return error.localizedDescription }
        let output = await Task.detached {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
        guard proc.terminationStatus == 0 else { return output }
        open(target)
        return nil
    }
}

enum Recents {
    private static let key = "recentProjects"

    static var all: [URL] {
        var seen = Set<String>()
        return (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            .filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
    }

    static func add(_ url: URL) {
        let url = url.resolvingSymlinksInPath()
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(30)), forKey: key)
    }

    static func remove(_ url: URL) {
        let paths = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != url.path }
        UserDefaults.standard.set(paths, forKey: key)
    }

    /// Current git branch of the project, if any.
    static func branch(of url: URL) -> String? {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        var dir = isDir.boolValue ? url : url.deletingLastPathComponent()
        for _ in 0..<6 {
            let head = dir.appendingPathComponent(".git/HEAD")
            if let s = try? String(contentsOf: head, encoding: .utf8) {
                let ref = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return ref.hasPrefix("ref: refs/heads/") ? String(ref.dropFirst(16)) : String(ref.prefix(7))
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    @MainActor static func apply(_ raw: String) {
        switch Appearance(rawValue: raw) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
