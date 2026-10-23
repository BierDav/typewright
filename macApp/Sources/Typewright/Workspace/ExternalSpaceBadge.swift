import SwiftUI

struct ExternalSpaceBadge: View {
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            Image(systemName: "arrow.up.forward.square")
            Text("External")
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.gray.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(.gray.opacity(0.5), lineWidth: 1))
        .fixedSize()
        .help("Outside the Typewright library. No Typewright history or device sync. Use Import External Spaces… in the command palette to import it.")
    }
}
