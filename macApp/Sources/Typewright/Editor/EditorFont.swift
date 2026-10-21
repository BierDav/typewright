import AppKit

enum EditorFont {
    private static let registered: Void = {
        for name in ["JetBrainsMono-Regular", "JetBrainsMono-Bold"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    static func register() { _ = registered }

    static var families: [String] {
        register()
        return NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func font(name: String, size: CGFloat) -> NSFont {
        register()
        if !name.isEmpty, let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
