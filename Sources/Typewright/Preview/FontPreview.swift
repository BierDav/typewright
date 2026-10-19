import CoreText
import SwiftUI

private struct FontFace: Identifiable {
    let id: Int
    let font: CTFont

    var family: String { CTFontCopyFamilyName(font) as String }
    var style: String { CTFontCopyName(font, kCTFontStyleNameKey) as String? ?? "" }
    var glyphCount: Int { CTFontGetGlyphCount(font) }

    func sized(_ size: CGFloat) -> Font { Font(CTFontCreateCopyWithAttributes(font, size, nil, nil)) }

    /// Loads every face in the file without registering it, so installed fonts can't shadow it.
    static func load(_ url: URL) -> [FontFace] {
        guard let data = try? Data(contentsOf: url),
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor]
        else { return [] }
        return descriptors.enumerated().map { FontFace(id: $0.offset, font: CTFontCreateWithFontDescriptor($0.element, 32, nil)) }
    }
}

/// Specimen view for font files in the project.
struct FontPreview: View {
    let url: URL
    @State private var faces: [FontFace]?
    @State private var sample = "The quick brown fox jumps over the lazy dog"

    private static let sizes: [CGFloat] = [12, 18, 24, 36, 48, 72]
    private static let glyphs = "ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789 !?&@#%(){}[]$€"

    var body: some View {
        Group {
            if let faces, faces.isEmpty {
                ContentUnavailableView("Unsupported font", systemImage: "textformat",
                                       description: Text("\(url.lastPathComponent) could not be read."))
            } else if let faces {
                ScrollView {
                    VStack(alignment: .leading, spacing: 40) {
                        TextField("Sample text", text: $sample)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 420)
                        ForEach(faces) { face(for: $0, waterfall: faces.count == 1) }
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) { faces = FontFace.load(url) }
    }

    private func face(for face: FontFace, waterfall: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(face.family).font(.title2.bold())
                Text(face.style).font(.title3).foregroundStyle(.secondary)
                Spacer()
                Text("\(face.glyphCount) glyphs").font(.caption).foregroundStyle(.secondary)
            }
            Text(Self.glyphs).font(face.sized(32)).lineSpacing(4)
            if waterfall {
                ForEach(Self.sizes, id: \.self) { size in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text("\(Int(size))").font(.caption).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                        Text(sample).font(face.sized(size)).lineLimit(1)
                    }
                }
            } else {
                Text(sample).font(face.sized(24))
            }
            Divider()
        }
    }
}
