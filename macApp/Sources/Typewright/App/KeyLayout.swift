import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key with the modifiers held along with it.
struct Shortcut: Equatable {
    let key: Key
    let modifiers: SwiftUI.EventModifiers

    /// Like "⇧⌘F", for the command palette and hints.
    var display: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + key.display
    }

    /// Matches the physical key, so shifted digits find theirs on German and other layouts too.
    func matches(_ event: NSEvent) -> Bool {
        key.keyCodes.contains(event.keyCode) && event.modifierFlags.intersection(Self.mask) == modifiers.nsFlags
    }

    private static let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
}

extension Shortcut: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let token = try container.decode(String.self, forKey: .key)
        guard let key = Key(token: token) else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: container, debugDescription: "Unknown key “\(token)”.")
        }
        self.init(key: key, modifiers: SwiftUI.EventModifiers(names: try container.decode([String].self, forKey: .modifiers)))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key.token, forKey: .key)
        try container.encode(modifiers.names, forKey: .modifiers)
    }

    private enum CodingKeys: String, CodingKey {
        case key, modifiers
    }
}

enum Key: Equatable {
    case character(Character)
    case leftArrow, rightArrow, upArrow, downArrow
    case `return`, delete, space
    case function(Int)

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .character(let character): return KeyEquivalent(character)
        case .leftArrow: return .leftArrow
        case .rightArrow: return .rightArrow
        case .upArrow: return .upArrow
        case .downArrow: return .downArrow
        case .return: return .return
        case .delete: return .delete
        case .space: return .space
        case .function(let number): return KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey + number - 1)!))
        }
    }

    var keyCodes: [UInt16] {
        switch self {
        case .character(let character):
            guard let code = Self.codes[character] else { return [] }
            return [code]
        case .leftArrow: return [UInt16(kVK_LeftArrow)]
        case .rightArrow: return [UInt16(kVK_RightArrow)]
        case .upArrow: return [UInt16(kVK_UpArrow)]
        case .downArrow: return [UInt16(kVK_DownArrow)]
        // The keypad's Enter types Return too.
        case .return: return [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)]
        case .delete: return [UInt16(kVK_Delete)]
        case .space: return [UInt16(kVK_Space)]
        case .function(let number):
            guard Self.functionKeyCodes.indices.contains(number - 1) else { return [] }
            return [UInt16(Self.functionKeyCodes[number - 1])]
        }
    }

    var display: String {
        switch self {
        case .character(let character): return character.isLetter ? String(character).uppercased() : String(character)
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .return: return "↩"
        case .delete: return "⌫"
        case .space: return "Space"
        case .function(let number): return "F\(number)"
        }
    }

    var isFunction: Bool {
        if case .function = self { return true }
        return false
    }

    /// How the key is saved; physical codes stay out of the defaults.
    var token: String {
        switch self {
        case .character(let character): return "character:\(character)"
        case .leftArrow: return "left"
        case .rightArrow: return "right"
        case .upArrow: return "up"
        case .downArrow: return "down"
        case .return: return "return"
        case .delete: return "delete"
        case .space: return "space"
        case .function(let number): return "f\(number)"
        }
    }

    init?(token: String) {
        switch token {
        case "left": self = .leftArrow
        case "right": self = .rightArrow
        case "up": self = .upArrow
        case "down": self = .downArrow
        case "return": self = .return
        case "delete": self = .delete
        case "space": self = .space
        default:
            if token.hasPrefix("character:"), let character = token.dropFirst("character:".count).first {
                self = .character(character)
            } else if token.hasPrefix("f"), let number = Int(token.dropFirst()), Self.functionKeyCodes.indices.contains(number - 1) {
                self = .function(number)
            } else {
                return nil
            }
        }
    }

    /// The key a recorded event pressed, by its physical place.
    init?(keyCode: UInt16) {
        if let character = Self.codes.first(where: { $0.value == keyCode })?.key {
            self = .character(character)
            return
        }
        switch Int(keyCode) {
        case kVK_LeftArrow: self = .leftArrow
        case kVK_RightArrow: self = .rightArrow
        case kVK_UpArrow: self = .upArrow
        case kVK_DownArrow: self = .downArrow
        case kVK_Return, kVK_ANSI_KeypadEnter: self = .return
        case kVK_Delete: self = .delete
        case kVK_Space: self = .space
        default:
            guard let index = Self.functionKeyCodes.firstIndex(of: Int(keyCode)) else { return nil }
            self = .function(index + 1)
        }
    }

    private static let functionKeyCodes = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
        kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ]

    private static let codes: [Character: UInt16] = [
        "a": UInt16(kVK_ANSI_A), "b": UInt16(kVK_ANSI_B), "c": UInt16(kVK_ANSI_C),
        "d": UInt16(kVK_ANSI_D), "e": UInt16(kVK_ANSI_E), "f": UInt16(kVK_ANSI_F),
        "g": UInt16(kVK_ANSI_G), "h": UInt16(kVK_ANSI_H), "i": UInt16(kVK_ANSI_I),
        "j": UInt16(kVK_ANSI_J), "k": UInt16(kVK_ANSI_K), "l": UInt16(kVK_ANSI_L),
        "m": UInt16(kVK_ANSI_M), "n": UInt16(kVK_ANSI_N), "o": UInt16(kVK_ANSI_O),
        "p": UInt16(kVK_ANSI_P), "q": UInt16(kVK_ANSI_Q), "r": UInt16(kVK_ANSI_R),
        "s": UInt16(kVK_ANSI_S), "t": UInt16(kVK_ANSI_T), "u": UInt16(kVK_ANSI_U),
        "v": UInt16(kVK_ANSI_V), "w": UInt16(kVK_ANSI_W), "x": UInt16(kVK_ANSI_X),
        "y": UInt16(kVK_ANSI_Y), "z": UInt16(kVK_ANSI_Z),
        "0": UInt16(kVK_ANSI_0), "1": UInt16(kVK_ANSI_1), "2": UInt16(kVK_ANSI_2),
        "3": UInt16(kVK_ANSI_3), "4": UInt16(kVK_ANSI_4), "5": UInt16(kVK_ANSI_5),
        "6": UInt16(kVK_ANSI_6), "7": UInt16(kVK_ANSI_7), "8": UInt16(kVK_ANSI_8),
        "9": UInt16(kVK_ANSI_9),
        ",": UInt16(kVK_ANSI_Comma), ".": UInt16(kVK_ANSI_Period),
        "/": UInt16(kVK_ANSI_Slash), "\\": UInt16(kVK_ANSI_Backslash),
        "-": UInt16(kVK_ANSI_Minus), "=": UInt16(kVK_ANSI_Equal),
        ";": UInt16(kVK_ANSI_Semicolon), "'": UInt16(kVK_ANSI_Quote),
        "[": UInt16(kVK_ANSI_LeftBracket), "]": UInt16(kVK_ANSI_RightBracket),
        "`": UInt16(kVK_ANSI_Grave),
    ]
}

extension SwiftUI.EventModifiers {
    /// The same modifiers as AppKit's, for matching key events.
    var nsFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        if contains(.shift) { flags.insert(.shift) }
        return flags
    }

    /// The four modifiers kept with a shortcut; Caps Lock and the function flag come along from the keyboard.
    init(nsFlags: NSEvent.ModifierFlags) {
        self = []
        if nsFlags.contains(.command) { insert(.command) }
        if nsFlags.contains(.option) { insert(.option) }
        if nsFlags.contains(.control) { insert(.control) }
        if nsFlags.contains(.shift) { insert(.shift) }
    }

    /// How the modifiers are saved.
    var names: [String] {
        var names: [String] = []
        if contains(.command) { names.append("command") }
        if contains(.option) { names.append("option") }
        if contains(.control) { names.append("control") }
        if contains(.shift) { names.append("shift") }
        return names
    }

    init(names: [String]) {
        self = []
        for name in names {
            switch name {
            case "command": insert(.command)
            case "option": insert(.option)
            case "control": insert(.control)
            case "shift": insert(.shift)
            default: break
            }
        }
    }
}

/// One command's keys; the first is the one menus and hints show, the rest work too.
struct KeyBinding: Equatable {
    var primary: Shortcut
    var alternates: [Shortcut] = []

    init(_ key: Key, _ modifiers: SwiftUI.EventModifiers) {
        primary = Shortcut(key: key, modifiers: modifiers)
    }

    init(primary: Shortcut, alternates: [Shortcut] = []) {
        self.primary = primary
        self.alternates = alternates
    }

    var display: String { primary.display }

    /// Every key that triggers the command, like "⇧⌘A / ⌘K".
    var allDisplay: String {
        var seen = Set<String>()
        return ([primary] + alternates).map(\.display).filter { seen.insert($0).inserted }.joined(separator: " / ")
    }

    func matches(_ event: NSEvent) -> Bool {
        primary.matches(event) || alternates.contains { $0.matches(event) }
    }

    func contains(_ shortcut: Shortcut) -> Bool {
        primary == shortcut || alternates.contains(shortcut)
    }
}

/// The shortcuts of a layout; each one is used by the menus, the editor and the palette's hints.
struct Shortcuts: Equatable {
    var settings = KeyBinding(.character(","), .command)
    var newWindow = KeyBinding(.character("n"), .command)
    var openSpace = KeyBinding(.character("o"), .command)
    var moveFile = KeyBinding(.character("i"), [.command, .option])
    var closeSpace = KeyBinding(.character("w"), [.command, .control])
    var togglePreview = KeyBinding(.character("-"), .command)
    var previewCurrentFile = KeyBinding(.character("-"), [.command, .shift])
    var findInSpace = KeyBinding(.character("f"), [.command, .shift])
    var palette = KeyBinding(.character("k"), .command)
    var showSpaces = KeyBinding(.character("s"), [.command, .option])
    var sidebar = KeyBinding(.character("s"), .command)
    var back = KeyBinding(.leftArrow, [.command, .control])
    var forward = KeyBinding(.rightArrow, [.command, .control])

    var find = KeyBinding(.character("f"), .command)
    var replace = KeyBinding(.character("f"), [.command, .option])
    var findNext = KeyBinding(.character("g"), .command)
    var findPrevious = KeyBinding(.character("g"), [.command, .shift])

    var definition = KeyBinding(.character("b"), .command)
    var format = KeyBinding(.character("l"), [.command, .option])
    var rename = KeyBinding(.function(6), .shift)
    var extractVariable = KeyBinding(.character("v"), [.command, .option])
    var inlineVariable = KeyBinding(.character("n"), [.command, .option])
    var extractFunction = KeyBinding(.character("m"), [.command, .option])
    var extractFunctionToScope = KeyBinding(.character("m"), [.command, .option, .shift])
    var contextActions = KeyBinding(.return, .option)
    var duplicateLine = KeyBinding(.character("d"), .command)
    var deleteLine = KeyBinding(.delete, .command)
    var commentLine = KeyBinding(.character("/"), .command)
    var commentBlock = KeyBinding(.character("/"), [.command, .option])
    var moveLineUp = KeyBinding(.upArrow, [.option, .shift])
    var moveLineDown = KeyBinding(.downArrow, [.option, .shift])
    var addCaretAbove = KeyBinding(.upArrow, [.control, .shift])
    var addCaretBelow = KeyBinding(.downArrow, [.control, .shift])
    var columnSelection = KeyBinding(.character("8"), [.command, .shift])
    var completions = KeyBinding(.space, .control)
    var documentation = KeyBinding(.function(1), [])
}

/// A command the layouts bind, as listed in the layout editor.
enum ShortcutCommand: String, CaseIterable, Identifiable {
    case settings, newWindow, openSpace, closeSpace, palette, showSpaces, sidebar
    case moveFile, findInSpace
    case back, forward
    case togglePreview, previewCurrentFile
    case find, replace, findNext, findPrevious
    case definition, format, contextActions, documentation, completions
    case rename, extractVariable, inlineVariable, extractFunction, extractFunctionToScope
    case duplicateLine, deleteLine, commentLine, commentBlock, moveLineUp, moveLineDown
    case addCaretAbove, addCaretBelow, columnSelection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings: return "Settings…"
        case .newWindow: return "New Window"
        case .openSpace: return "Link Folder as Space…"
        case .closeSpace: return "Close Space"
        case .palette: return "Command Palette…"
        case .showSpaces: return "Show Spaces"
        case .sidebar: return "Toggle Sidebar"
        case .moveFile: return "Move File…"
        case .findInSpace: return "Find in Space…"
        case .back: return "Back"
        case .forward: return "Forward"
        case .togglePreview: return "Cycle Preview Mode"
        case .previewCurrentFile: return "Preview Current File"
        case .find: return "Find"
        case .replace: return "Find and Replace"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .definition: return "Go to Definition"
        case .format: return "Format Document"
        case .contextActions: return "Context Actions"
        case .documentation: return "Show Documentation"
        case .completions: return "Show Completions"
        case .rename: return "Rename Symbol"
        case .extractVariable: return "Extract Variable"
        case .inlineVariable: return "Inline Variable"
        case .extractFunction: return "Extract Function"
        case .extractFunctionToScope: return "Extract Function to Scope"
        case .duplicateLine: return "Duplicate Line"
        case .deleteLine: return "Delete Line"
        case .commentLine: return "Comment Line"
        case .commentBlock: return "Comment Block"
        case .moveLineUp: return "Move Line Up"
        case .moveLineDown: return "Move Line Down"
        case .addCaretAbove: return "Add Caret Above"
        case .addCaretBelow: return "Add Caret Below"
        case .columnSelection: return "Column Selection Mode"
        }
    }

    /// The group it's listed under in the layout editor.
    var section: String {
        switch self {
        case .settings, .newWindow, .openSpace, .closeSpace, .palette, .showSpaces, .sidebar: return "App"
        case .moveFile, .findInSpace: return "Files"
        case .back, .forward: return "Navigation"
        case .togglePreview, .previewCurrentFile: return "Preview"
        case .find, .replace, .findNext, .findPrevious: return "Search"
        case .definition, .format, .contextActions, .documentation, .completions: return "Code"
        case .rename, .extractVariable, .inlineVariable, .extractFunction, .extractFunctionToScope: return "Refactor"
        case .duplicateLine, .deleteLine, .commentLine, .commentBlock, .moveLineUp, .moveLineDown, .addCaretAbove, .addCaretBelow,
             .columnSelection: return "Editing"
        }
    }

    /// Where the layout keeps the binding.
    var keyPath: WritableKeyPath<Shortcuts, KeyBinding> {
        switch self {
        case .settings: return \.settings
        case .newWindow: return \.newWindow
        case .openSpace: return \.openSpace
        case .closeSpace: return \.closeSpace
        case .palette: return \.palette
        case .showSpaces: return \.showSpaces
        case .sidebar: return \.sidebar
        case .moveFile: return \.moveFile
        case .findInSpace: return \.findInSpace
        case .back: return \.back
        case .forward: return \.forward
        case .togglePreview: return \.togglePreview
        case .previewCurrentFile: return \.previewCurrentFile
        case .find: return \.find
        case .replace: return \.replace
        case .findNext: return \.findNext
        case .findPrevious: return \.findPrevious
        case .definition: return \.definition
        case .format: return \.format
        case .contextActions: return \.contextActions
        case .documentation: return \.documentation
        case .completions: return \.completions
        case .rename: return \.rename
        case .extractVariable: return \.extractVariable
        case .inlineVariable: return \.inlineVariable
        case .extractFunction: return \.extractFunction
        case .extractFunctionToScope: return \.extractFunctionToScope
        case .duplicateLine: return \.duplicateLine
        case .deleteLine: return \.deleteLine
        case .commentLine: return \.commentLine
        case .commentBlock: return \.commentBlock
        case .moveLineUp: return \.moveLineUp
        case .moveLineDown: return \.moveLineDown
        case .addCaretAbove: return \.addCaretAbove
        case .addCaretBelow: return \.addCaretBelow
        case .columnSelection: return \.columnSelection
        }
    }
}

/// The layouts that come with Typewright; custom ones patch them.
enum BuiltinLayout: String, CaseIterable, Identifiable {
    case standard
    case intellij

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .intellij: return "IntelliJ IDEA"
        }
    }

    var summary: String {
        let keys = shortcuts
        switch self {
        case .standard:
            return "Typewright's usual shortcuts, plus \(keys.togglePreview.display) to cycle the preview mode "
                + "and \(keys.previewCurrentFile.display) to preview the selected file."
        case .intellij:
            return "IntelliJ IDEA's keys: \(keys.palette.allDisplay) opens the command palette, \(keys.replace.display) replaces, "
                + "\(keys.moveFile.display) moves files, \(keys.back.display) and \(keys.forward.display) navigate, and "
                + "\(keys.commentLine.display) comments lines and \(keys.commentBlock.display) blocks in the code editor. "
                + "\(keys.commentLine.display) still switches to the seventh space outside the editor, "
                + "and \(keys.togglePreview.display) and \(keys.previewCurrentFile.display) stay on the preview."
        }
    }

    var shortcuts: Shortcuts {
        switch self {
        case .standard: return Self.standardShortcuts
        case .intellij: return Self.intellijShortcuts
        }
    }

    private static let standardShortcuts = Shortcuts()

    private static let intellijShortcuts: Shortcuts = {
        var shortcuts = Shortcuts()
        // ⌘K opens the palette as it does in IntelliJ, next to Typewright's own ⇧⌘A.
        shortcuts.palette = KeyBinding(.character("a"), [.command, .shift])
        shortcuts.palette.alternates = [Shortcut(key: .character("k"), modifiers: .command)]
        shortcuts.replace = KeyBinding(.character("r"), .command)
        shortcuts.moveFile = KeyBinding(.function(6), [])
        shortcuts.back = KeyBinding(.leftArrow, [.command, .option])
        shortcuts.forward = KeyBinding(.rightArrow, [.command, .option])
        // ⌘7 and ⇧⌘7 replace ⌘/ and ⌥⌘/, which need Shift+7 on German keyboards.
        shortcuts.commentLine = KeyBinding(.character("7"), .command)
        shortcuts.commentBlock = KeyBinding(.character("7"), [.command, .shift])
        return shortcuts
    }()
}

/// A layout to pick: a built-in one, or a fork that patches its built-in.
struct KeyLayout: Identifiable, Equatable {
    /// The selected layout's id.
    static let defaultsKey = "keyLayout"
    static let customsKey = "customKeyLayouts"
    /// Set while the layout editor waits for keys, so the window shortcuts let them through.
    static var isRecordingShortcut = false

    let id: String
    var name: String
    let base: BuiltinLayout
    /// Only the bindings that differ from the base; everything else follows it.
    var overrides: [ShortcutCommand: Shortcut] = [:]
    let isBuiltIn: Bool

    init(builtIn: BuiltinLayout) {
        id = builtIn.rawValue
        name = builtIn.title
        base = builtIn
        isBuiltIn = true
    }

    init(id: String, name: String, base: BuiltinLayout, overrides: [ShortcutCommand: Shortcut]) {
        self.id = id
        self.name = name
        self.base = base
        self.overrides = overrides
        isBuiltIn = false
    }

    /// The base's keys with the fork's changes laid over them, so base updates reach forks.
    var shortcuts: Shortcuts {
        var shortcuts = base.shortcuts
        for (command, shortcut) in overrides {
            shortcuts[keyPath: command.keyPath].primary = shortcut
        }
        return shortcuts
    }

    var summary: String {
        guard !isBuiltIn else { return base.summary }
        let changed = overrides.count
        guard changed > 0 else { return "A fork of \(base.title) that follows it until you change a shortcut." }
        return "A fork of \(base.title) with \(changed) changed shortcut\(changed == 1 ? "" : "s")."
    }

    static var all: [KeyLayout] {
        KeyLayoutStore.shared.all
    }

    /// The layout picked in Settings, read fresh so menus and events follow a change.
    static var current: KeyLayout {
        let id = UserDefaults.standard.string(forKey: defaultsKey) ?? BuiltinLayout.standard.rawValue
        return all.first { $0.id == id } ?? KeyLayout(builtIn: .standard)
    }

    /// SwiftUI builds its menus once, so a layout picked later updates their key equivalents here.
    static func updateMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let keys = current.shortcuts
        let items: [(title: String, binding: KeyBinding)] = [
            ("Settings…", keys.settings),
            ("New Window", keys.newWindow),
            ("Link Folder as Space…", keys.openSpace),
            ("Move File…", keys.moveFile),
            ("Close Space", keys.closeSpace),
            ("Find in Space…", keys.findInSpace),
            ("Back", keys.back),
            ("Forward", keys.forward),
            ("Command Palette…", keys.palette),
            ("Show Spaces", keys.showSpaces),
            ("Toggle Sidebar", keys.sidebar),
            ("Cycle Preview Mode", keys.togglePreview),
            ("Preview Current File", keys.previewCurrentFile),
        ]
        for (title, binding) in items {
            guard let item = menuItem(titled: title, in: mainMenu) else { continue }
            item.keyEquivalent = String(binding.primary.key.keyEquivalent.character)
            item.keyEquivalentModifierMask = binding.primary.modifiers.nsFlags
        }
    }

    private static func menuItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu, let found = menuItem(titled: title, in: submenu) { return found }
        }
        return nil
    }
}

/// The forks of the built-in layouts, saved as their changes.
final class KeyLayoutStore: ObservableObject {
    static let shared = KeyLayoutStore()

    @Published private(set) var custom: [KeyLayout] = []

    /// The built-in layouts followed by the forks, in the order Settings lists them.
    var all: [KeyLayout] { BuiltinLayout.allCases.map { KeyLayout(builtIn: $0) } + custom }

    private init() {
        custom = Self.load()
        // A stored id for a fork that no longer exists falls back to the standard layout.
        let selected = UserDefaults.standard.string(forKey: KeyLayout.defaultsKey) ?? BuiltinLayout.standard.rawValue
        if !all.contains(where: { $0.id == selected }) {
            // Deferred: the defaults notification reads the store back.
            DispatchQueue.main.async {
                UserDefaults.standard.set(BuiltinLayout.standard.rawValue, forKey: KeyLayout.defaultsKey)
            }
        }
    }

    /// A copy of `layout` that starts out following it; forking a built-in is the usual case.
    func fork(_ layout: KeyLayout, named name: String) -> KeyLayout {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "\(layout.name) Copy" }
        let fork = KeyLayout(id: UUID().uuidString, name: name, base: layout.base,
                             overrides: layout.isBuiltIn ? [:] : layout.overrides)
        custom.append(fork)
        save()
        return fork
    }

    func rename(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = custom.firstIndex(where: { $0.id == id }) else { return }
        custom[index].name = name
        save()
    }

    func setShortcut(_ shortcut: Shortcut, for command: ShortcutCommand, in id: String) {
        guard let index = custom.firstIndex(where: { $0.id == id }) else { return }
        custom[index].overrides[command] = shortcut
        save()
    }

    func reset(_ command: ShortcutCommand, in id: String) {
        guard let index = custom.firstIndex(where: { $0.id == id }) else { return }
        custom[index].overrides[command] = nil
        save()
    }

    func resetAll(in id: String) {
        guard let index = custom.firstIndex(where: { $0.id == id }) else { return }
        custom[index].overrides.removeAll()
        save()
    }

    func delete(_ id: String) {
        if let layout = custom.first(where: { $0.id == id }),
           UserDefaults.standard.string(forKey: KeyLayout.defaultsKey) == id {
            UserDefaults.standard.set(layout.base.rawValue, forKey: KeyLayout.defaultsKey)
        }
        custom.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(custom.map(StoredKeyLayout.init)) else { return }
        UserDefaults.standard.set(data, forKey: KeyLayout.customsKey)
    }

    private static func load() -> [KeyLayout] {
        guard let data = UserDefaults.standard.data(forKey: KeyLayout.customsKey),
              let stored = try? JSONDecoder().decode([StoredKeyLayout].self, from: data) else { return [] }
        return stored.compactMap(\.layout)
    }
}

/// How a fork is saved: its changes, never the keys it inherits.
private struct StoredKeyLayout: Codable {
    var id: String
    var name: String
    var base: String
    var overrides: [String: Shortcut]

    init(_ layout: KeyLayout) {
        id = layout.id
        name = layout.name
        base = layout.base.rawValue
        overrides = Dictionary(uniqueKeysWithValues: layout.overrides.map { ($0.key.rawValue, $0.value) })
    }

    var layout: KeyLayout? {
        guard let base = BuiltinLayout(rawValue: base) else { return nil }
        let commands = Dictionary(uniqueKeysWithValues: overrides.compactMap { key, shortcut in
            ShortcutCommand(rawValue: key).map { ($0, shortcut) }
        })
        return KeyLayout(id: id, name: name, base: base, overrides: commands)
    }
}

extension View {
    /// Applies a layout's shortcut to a menu item or a hidden button.
    func keyboardShortcut(_ binding: KeyBinding) -> some View {
        keyboardShortcut(binding.primary.key.keyEquivalent, modifiers: binding.primary.modifiers)
    }

    func keyboardShortcut(_ shortcut: Shortcut) -> some View {
        keyboardShortcut(shortcut.key.keyEquivalent, modifiers: shortcut.modifiers)
    }
}
