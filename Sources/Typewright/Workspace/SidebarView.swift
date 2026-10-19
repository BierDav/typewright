import SwiftUI

struct SidebarView: View {
    let workspace: Workspace

    var body: some View {
        List(selection: Binding(
            get: { workspace.selectedFile },
            set: { url in if let url { workspace.select(url) } }
        )) {
            OutlineGroup(workspace.tree, children: \.children) { node in
                row(node)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { workspace.createFile() } label: { Image(systemName: "plus") }
                    .help("New Typst file")
                Spacer()
                Button { workspace.reloadTree() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload files")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    @ViewBuilder
    private func row(_ node: FileNode) -> some View {
        let label = Label {
            Text(node.name)
        } icon: {
            Image(systemName: icon(for: node))
                .foregroundStyle(node.isTypst ? Color.accentColor : .secondary)
        }
        .contextMenu {
            if node.isTypst {
                Button("Set as Main File") { workspace.mainFile = node.url }
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        }

        if node.isEditable {
            label.tag(node.url)
                .fontWeight(node.url == workspace.mainFile ? .semibold : .regular)
        } else {
            label.foregroundStyle(.secondary)
        }
    }

    private func icon(for node: FileNode) -> String {
        if node.children != nil { return "folder" }
        switch node.url.pathExtension.lowercased() {
        case "typ": return "t.square"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        case "bib": return "books.vertical"
        case "pdf": return "doc.richtext"
        default: return "doc.text"
        }
    }
}
