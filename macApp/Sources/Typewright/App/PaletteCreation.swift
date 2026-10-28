import SwiftUI
import TypewrightCore

@MainActor extension PalettePage {
    static func newFolder(in workspace: Workspace, folder: URL, onCreate: @escaping () -> Void = {}) -> PalettePage {
        PalettePage(title: "New Folder in \(workspace.displayName(of: folder))", placeholder: "Folder name",
                    kind: .input(initial: "") { name in
            withAnimation(.smooth(duration: 0.25)) {
                if folder != workspace.root { workspace.expanded.insert(folder) }
                workspace.createFolder(in: folder, named: name)
                onCreate()
            }
        })
    }

    static func newFile(in workspace: Workspace, folder: URL, onCreate: @escaping () -> Void = {}) -> PalettePage {
        let initial = folder == workspace.root ? "" : workspace.relativePath(of: folder) + "/"
        return PalettePage(title: "New File", placeholder: "Path relative to \(workspace.name)",
                           kind: .input(initial: initial) { path in
            withAnimation(.smooth(duration: 0.25)) {
                if workspace.createFile(named: path) != nil { onCreate() }
            }
        }, suggestions: { query in
            let folders = Workspace.flatten(workspace.tree).filter { $0.children != nil }
                .map { workspace.relativePath(of: $0.url) }
            return fileFolderSuggestions(input: query, folders: folders)
        }, inputHint: { query in
            newFilePath(input: query)?.addsTypExtension == true ? ".typ will be added" : nil
        }, inputTitle: { newFilePath(input: $0)?.path })
    }
}
