import AppKit

@MainActor
enum PaletteFiles {
    static func folder(_ title: String, initial: URL? = nil, root: URL? = nil) -> URL? {
        var directory = initial ?? FileManager.default.homeDirectoryForCurrentUser
        func allowed(_ url: URL) -> Bool {
            guard let root else { return true }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            let base = root.resolvingSymlinksInPath().standardizedFileURL.path
            return path == base || path.hasPrefix(base + "/")
        }
        while true {
            let children = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                         options: [.skipsHiddenFiles])) ?? [])
                .filter { allowed($0) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            var choices = [PaletteDialog.Choice(id: "select", title: "Choose This Folder", subtitle: directory.path, icon: "checkmark")]
            let parent = directory.deletingLastPathComponent()
            if parent != directory, allowed(parent) {
                choices.append(.init(id: "parent", title: "Parent Folder", subtitle: parent.path, icon: "arrow.up"))
            }
            choices.append(.init(id: "path", title: "Go to Folder…", icon: "folder"))
            choices.append(.init(id: "new", title: "New Folder…", icon: "folder.badge.plus"))
            choices += children.enumerated().map { .init(id: "folder.\($0.offset)", title: $0.element.lastPathComponent, icon: "folder") }
            guard let choice = PaletteDialog.choose(title, detail: directory.path, choices: choices) else { return nil }
            switch choice {
            case "select": return directory.standardizedFileURL
            case "parent": directory = parent
            case "path":
                guard let path = PaletteDialog.input("Go to Folder", initial: directory.path, button: "Go") else { continue }
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard allowed(url), FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    PaletteDialog.message("Choose an existing folder", detail: root == nil ? path : "The folder must be inside \((root?.path ?? "")).")
                    continue
                }
                directory = url
            case "new":
                guard let name = PaletteDialog.input("New Folder", placeholder: "Folder name", button: "Create"), validName(name) else { continue }
                let url = directory.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                    directory = url
                } catch { PaletteDialog.error(error) }
            default:
                if let index = Int(choice.dropFirst("folder.".count)), children.indices.contains(index) { directory = children[index] }
            }
        }
    }

    static func save(_ title: String, name: String, directory: URL) -> URL? {
        guard let folder = folder(title, initial: directory),
              let name = PaletteDialog.input(title, initial: name, placeholder: "File name", button: "Save"), validName(name) else { return nil }
        let url = folder.appendingPathComponent(name).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) || SpaceFolders.isLink(url) {
            guard PaletteDialog.choose("Replace “\(name)”?", choices: [
                .init(id: "replace", title: "Replace", icon: "doc.on.doc"),
                .init(id: "cancel", title: "Cancel", icon: "xmark"),
            ]) == "replace" else { return nil }
        }
        return url
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
