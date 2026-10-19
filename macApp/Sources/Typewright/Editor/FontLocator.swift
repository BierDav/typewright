import CoreText
import Foundation

/// Finds the file behind a font family name, so it can be opened like a source file.
enum FontLocator {
    private static let extensions: Set<String> = ["ttf", "otf", "ttc", "otc", "woff", "woff2"]

    /// Searches `folders` first, like typst does, then the fonts installed on the Mac.
    static func file(for family: String, in folders: [URL]) -> URL? {
        let wanted = family.lowercased()
        guard !wanted.isEmpty else { return nil }
        for folder in folders {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = files?.nextObject() as? URL {
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                if families(of: url).contains(wanted) { return url.standardizedFileURL }
            }
        }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor] ?? []
        return matches.lazy
            .compactMap { CTFontDescriptorCopyAttribute($0, kCTFontURLAttribute) as? URL }
            .first
    }

    private static func families(of url: URL) -> Set<String> {
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        return Set(descriptors.compactMap { (CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String)?.lowercased() })
    }
}
