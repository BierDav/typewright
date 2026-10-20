import AppKit
import Carbon.HIToolbox

/// A practical subset of Vim for the code editor: normal, insert and visual modes, counted motions,
/// operators with text objects, a register and `.`.
@MainActor
final class VimEngine {
    enum Mode { case normal, insert, visual, visualLine }

    private(set) var mode = Mode.normal
    private unowned let textView: TypstTextView
    /// Keys belong to the completion list while it shows.
    weak var completion: CompletionController?
    /// Gets the mode for the status bar, like "NORMAL" or "NORMAL d2".
    var onModeChange: ((String?) -> Void)? {
        didSet { if reported == nil { DispatchQueue.main.async { [weak self] in self?.report() } } }
    }
    /// Yanks land here too so they paste in other apps; nil keeps them inside (tests).
    var pasteboard: NSPasteboard? = .general

    private var pending: [String] = []
    private var register = (text: "", linewise: false)
    private var pasteboardChange = -1
    private var anchor = 0
    private var head = 0
    /// The column j and k aim for, and where the last vertical move ended so a click resets it.
    private var column: Int?
    private var verticalEnd = -1
    private var lastFind: (kind: String, char: String)?
    private var lastChange: [String] = []
    /// The command that started the running insert, for `.`.
    private var changeKeys: [String]?
    private var insertStart = 0
    private var insertLength = 0
    private var replaying = false
    private var reported: String??

    init(textView: TypstTextView) {
        self.textView = textView
    }

    var blockCaret: Bool { mode == .normal }

    /// Vim leaves the completion list, an inline rename and IME composition alone.
    private var isSuspended: Bool {
        completion?.isVisible == true || textView.isRenaming || textView.hasMarkedText()
    }

    // MARK: Keys

    /// Handles a key press; false lets the text view handle it.
    func handle(_ event: NSEvent) -> Bool {
        guard !isSuspended, let key = Self.key(for: event) else { return false }
        if mode == .insert, key != "<Esc>" { return false }
        feed(key)
        return true
    }

    /// Feeds keys in Vim notation, like `d2w` or `ifoo<Esc>`; text typed in insert mode is inserted.
    func handle(keys: String) {
        var rest = Substring(keys)
        while let first = rest.first {
            if first == "<", let close = rest.firstIndex(of: ">"), rest.distance(from: rest.startIndex, to: close) > 1,
               Self.named.contains(String(rest[...close])) {
                feed(String(rest[...close]))
                rest = rest[rest.index(after: close)...]
            } else {
                feed(String(first))
                rest = rest.dropFirst()
            }
        }
    }

    private static let named: Set = ["<Esc>", "<CR>", "<BS>", "<Del>", "<Tab>", "<Left>", "<Right>", "<Up>", "<Down>",
                                     "<C-r>", "<C-d>", "<C-u>"]

    private static func key(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command) { return nil }
        let plain = flags.subtracting(.shift).isEmpty
        switch Int(event.keyCode) {
        case kVK_Escape: return flags.isEmpty ? "<Esc>" : nil
        case kVK_Return, kVK_ANSI_KeypadEnter: return plain ? "<CR>" : nil
        case kVK_Delete: return flags.isEmpty ? "<BS>" : nil
        case kVK_ForwardDelete: return flags.isEmpty ? "<Del>" : nil
        case kVK_Tab: return plain ? "<Tab>" : nil
        case kVK_LeftArrow: return flags.isEmpty ? "<Left>" : nil
        case kVK_RightArrow: return flags.isEmpty ? "<Right>" : nil
        case kVK_UpArrow: return flags.isEmpty ? "<Up>" : nil
        case kVK_DownArrow: return flags.isEmpty ? "<Down>" : nil
        default: break
        }
        if flags.contains(.control) {
            if event.keyCode == UInt16(kVK_ANSI_LeftBracket) { return "<Esc>" }
            switch event.charactersIgnoringModifiers {
            case "[": return "<Esc>"
            case "r": return "<C-r>"
            case "d": return "<C-d>"
            case "u": return "<C-u>"
            default: return nil
            }
        }
        var chars = event.characters ?? ""
        // Dead keys like ^ and ~ on German layouts type nothing until the next key.
        if chars.isEmpty { chars = deadKeyCharacter(event) }
        guard chars.count == 1, let scalar = chars.unicodeScalars.first, scalar.value >= 0x20,
              !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
        return chars
    }

    private static func deadKeyCharacter(_ event: NSEvent) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var modifiers = 0
        if event.modifierFlags.contains(.shift) { modifiers |= shiftKey }
        if event.modifierFlags.contains(.option) { modifiers |= optionKey }
        var deadState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, event.keyCode, UInt16(kUCKeyActionDown), UInt32(modifiers >> 8) & 0xFF,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                  &deadState, chars.count, &length, &chars)
        }
        return status == noErr ? String(utf16CodeUnits: chars, count: length) : ""
    }

    private func feed(_ key: String) {
        if mode == .insert {
            if key == "<Esc>" {
                leaveInsert()
            } else {
                textView.insertText(key == "<CR>" ? "\n" : key, replacementRange: textView.selectedRange())
            }
        } else {
            if pending.isEmpty { adoptSelection(before: key) }
            pending.append(key)
            switch parse(pending) {
            case .incomplete: break
            case .invalid: pending = []
            case .command(let command):
                let keys = pending
                pending = []
                if mode == .normal { runNormal(command, keys: keys) } else { runVisual(command) }
            }
        }
        report()
    }

    /// Selections made with the mouse or by find: operators act on them, anything else collapses them.
    private func adoptSelection(before key: String) {
        let sel = textView.selectedRange()
        switch mode {
        case .normal where sel.length > 0:
            if ["d", "c", "y", "x", "s", ">", "<", "~", "p", "P", "<Del>"].contains(key) {
                mode = .visual
                anchor = sel.location
                head = max(sel.location, NSMaxRange(sel) - 1)
            } else {
                setCursor(clamp(sel.location))
            }
        case .visual, .visualLine:
            guard sel != visualRange else { return }
            if sel.length == 0 {
                mode = .normal
                setCursor(clamp(sel.location))
            } else {
                mode = .visual
                anchor = sel.location
                head = max(sel.location, NSMaxRange(sel) - 1)
            }
        default: break
        }
    }

    private func report() {
        let name = switch mode {
        case .normal: "NORMAL"
        case .insert: "INSERT"
        case .visual: "VISUAL"
        case .visualLine: "VISUAL LINE"
        }
        let label = pending.isEmpty ? name : name + " " + pending.joined()
        guard reported != .some(label) else { return }
        reported = label
        onModeChange?(label)
        textView.refreshCaret()
    }

    // MARK: Parsing

    private struct Motion {
        var key: String
        var arg: String?
        var count: Int?
    }

    private struct Command {
        var name: String
        var count: Int?
        var motion: Motion?
        var arg: String?
    }

    private enum Parsed {
        case incomplete, invalid
        case command(Command)
    }

    private static let motions: Set = ["h", "j", "k", "l", "w", "b", "e", "W", "B", "E", "0", "^", "$", "G", "{", "}",
                                       ";", ",", "%", "<CR>", "<BS>", " ", "<Left>", "<Right>", "<Up>", "<Down>",
                                       "<C-d>", "<C-u>", "+", "-", "_"]
    private static let vertical: Set = ["j", "k", "<Up>", "<Down>", "<C-d>", "<C-u>"]
    private static let operators: Set = ["d", "c", "y", ">", "<"]
    private static let normalCommands: Set = ["x", "X", "s", "S", "D", "C", "Y", "p", "P", "J", "u", "<C-r>", "i", "a",
                                              "I", "A", "o", "O", "v", "V", ".", "~", "n", "N", "/", "?", ":", "<Esc>",
                                              "<Del>", "<Tab>"]
    private static let visualCommands: Set = ["d", "x", "<Del>", "c", "s", "y", ">", "<", "~", "u", "U", "J", "p", "P",
                                              "o", "O", "v", "V", "D", "X", "Y", "C", "S", "R", ":", "<Esc>", "<Tab>"]

    private func parse(_ k: [String]) -> Parsed {
        var i = 0
        let count = parseCount(k, &i)
        guard i < k.count else { return .incomplete }
        let key = k[i]
        if mode == .normal, Self.operators.contains(key) {
            var j = i + 1
            let inner = parseCount(k, &j)
            guard j < k.count else { return .incomplete }
            let total = count.map { $0 * (inner ?? 1) } ?? inner
            if k[j] == key {
                return j + 1 == k.count ? .command(Command(name: key, count: total, motion: Motion(key: "line", count: total))) : .invalid
            }
            return parseMotion(k, j, count: total, objects: true).map { Command(name: key, count: total, motion: $0) }
        }
        if key == "r" {
            guard i + 1 < k.count else { return .incomplete }
            let arg = k[i + 1]
            return arg.count == 1 || arg == "<CR>" ? .command(Command(name: "r", count: count, arg: arg)) : .invalid
        }
        if (mode == .normal ? Self.normalCommands : Self.visualCommands).contains(key) {
            return i + 1 == k.count ? .command(Command(name: key, count: count)) : .invalid
        }
        return parseMotion(k, i, count: count, objects: mode != .normal).map { Command(name: "move", count: count, motion: $0) }
    }

    private func parseMotion(_ k: [String], _ i: Int, count: Int?, objects: Bool) -> MotionParse {
        guard i < k.count else { return .incomplete }
        let key = k[i]
        if Self.motions.contains(key) { return i + 1 == k.count ? .motion(Motion(key: key, count: count)) : .invalid }
        guard ["f", "F", "t", "T", "g"].contains(key) || objects && (key == "i" || key == "a") else { return .invalid }
        guard i + 1 < k.count else { return .incomplete }
        let arg = k[i + 1]
        guard i + 2 == k.count, arg.count == 1 else { return .invalid }
        if key == "g" { return arg == "g" ? .motion(Motion(key: "gg", count: count)) : .invalid }
        return .motion(Motion(key: key, arg: arg, count: count))
    }

    private enum MotionParse {
        case incomplete, invalid
        case motion(Motion)

        func map(_ make: (Motion) -> Command) -> Parsed {
            switch self {
            case .incomplete: .incomplete
            case .invalid: .invalid
            case .motion(let m): .command(make(m))
            }
        }
    }

    private func parseCount(_ k: [String], _ i: inout Int) -> Int? {
        var n: Int?
        while i < k.count, k[i].count == 1, let d = Int(k[i]), d > 0 || n != nil {
            n = min((n ?? 0) * 10 + d, 99_999)
            i += 1
        }
        return n
    }

    // MARK: Normal mode

    private func runNormal(_ c: Command, keys: [String]) {
        let p = clamp(textView.selectedRange().location)
        let n = c.count ?? 1
        let isChange = !["move", "y", "Y", "u", "<C-r>", ".", "n", "N", "/", "?", ":", "<Esc>", "<Tab>", "v", "V"].contains(c.name)
        if isChange, !replaying { lastChange = keys }
        switch c.name {
        case "move":
            guard let m = c.motion else { return }
            move(m, from: p) { setCursor(clamp($0)) }
        case "d", "c", "y", ">", "<":
            guard let m = c.motion else { return }
            operate(c.name, m, from: p, keys: keys)
        case "x", "<Del>": operate("d", Motion(key: "l", count: c.count), from: p, keys: keys)
        case "X": operate("d", Motion(key: "h", count: c.count), from: p, keys: keys)
        case "s": operate("c", Motion(key: "l", count: c.count), from: p, keys: keys)
        case "S": operate("c", Motion(key: "line", count: c.count), from: p, keys: keys)
        case "D": operate("d", Motion(key: "$", count: c.count), from: p, keys: keys)
        case "C": operate("c", Motion(key: "$", count: c.count), from: p, keys: keys)
        case "Y": operate("y", Motion(key: "line", count: c.count), from: p, keys: keys)
        case "p", "P": put(after: c.name == "p", count: n, at: p)
        case "J": join(from: p, lines: max(n, 2))
        case "r": replaceChars(at: p, count: n, with: c.arg ?? "")
        case "~": toggleCase(at: p, count: n)
        case "i": enterInsert(at: p, keys: keys)
        case "a": enterInsert(at: p < lineEnd(p) ? nextChar(p) : p, keys: keys)
        case "I": enterInsert(at: firstNonBlank(lineStart(p)), keys: keys)
        case "A": enterInsert(at: lineEnd(p), keys: keys)
        case "o", "O": openLine(below: c.name == "o", at: p, keys: keys)
        case "v", "V":
            mode = c.name == "v" ? .visual : .visualLine
            anchor = p
            head = p
            showVisual()
        case "u", "<C-r>":
            for _ in 0..<n {
                if c.name == "u" { textView.undo(nil) } else { textView.redo(nil) }
            }
            setCursor(clamp(textView.selectedRange().location))
        case ".": repeatChange(count: c.count)
        case "n", "N": textView.onFindStep?(c.name == "n" ? 1 : -1)
        case "/", "?": textView.onFind?(false)
        default: break
        }
    }

    /// Runs a motion, keeping the column j and k aim for.
    private func move(_ m: Motion, from p: Int, to apply: (Int) -> Void) {
        let isVertical = Self.vertical.contains(m.key)
        if isVertical, column == nil || p != verticalEnd { column = p - lineStart(p) }
        guard let t = target(m, from: p, op: false) else { return }
        if isVertical || m.key == "$" {
            if m.key == "$" { column = .max }
            verticalEnd = mode == .normal ? clamp(t.pos) : t.pos
        } else {
            column = nil
        }
        apply(t.pos)
    }

    private func operate(_ op: String, _ m: Motion, from p: Int, keys: [String]) {
        guard let (range, linewise) = operatorRange(op, m, from: p) else { return }
        apply(op, range: range, linewise: linewise, cursor: p, keys: keys, count: 1)
    }

    private func operatorRange(_ op: String, _ m: Motion, from p: Int) -> (NSRange, Bool)? {
        let length = text.length
        if m.key == "line" {
            let first = lineStart(p)
            var last = first
            for _ in 1..<max(m.count ?? 1, 1) {
                guard let next = lineDown(last) else { break }
                last = next
            }
            return (linesRange(first, last), true)
        }
        if m.key == "i" || m.key == "a" {
            return textObject(inner: m.key == "i", m.arg ?? "", at: p).map { ($0, false) }
        }
        // cw changes to the end of the word, like ce.
        if op == "c", m.key == "w" || m.key == "W", p < length, !isBlank(p) {
            let big = m.key == "W"
            var end = p
            while end + 1 < length, cls(end + 1, big) == cls(p, big) { end += 1 }
            for _ in 1..<max(m.count ?? 1, 1) { end = nextWordEnd(end, big) }
            return (NSRange(location: p, length: nextChar(end) - p), false)
        }
        guard let t = target(m, from: p, op: true) else { return nil }
        let lo = min(p, t.pos), hi = max(p, t.pos)
        switch t.kind {
        case .linewise: return (linesRange(lineStart(lo), lineStart(hi)), true)
        case .inclusive: return (NSRange(location: lo, length: min(hi < length ? nextChar(hi) : hi, length) - lo), false)
        case .exclusive: return (NSRange(location: lo, length: hi - lo), false)
        }
    }

    private func apply(_ op: String, range: NSRange, linewise: Bool, cursor p: Int, keys: [String], count: Int) {
        switch op {
        case "y":
            yank(range, linewise: linewise)
            setCursor(linewise && lineStart(p) == range.location ? p : range.location)
        case "d":
            yank(range, linewise: linewise)
            var r = range
            // The last line takes the break before it, so no empty line is left behind.
            if linewise, NSMaxRange(r) == text.length, r.location > 0, r.length == 0 || char(NSMaxRange(r) - 1) != 10 {
                r.location -= 1
                r.length += 1
            }
            guard replace(r, with: "", action: "Delete") else { return }
            setCursor(linewise ? firstNonBlank(lineStart(min(range.location, text.length))) : clamp(r.location))
        case "c":
            yank(range, linewise: linewise)
            if linewise {
                var content = range
                if content.length > 0, char(NSMaxRange(content) - 1) == 10 { content.length -= 1 }
                let indent = leadingWhitespace(range.location)
                guard replace(content, with: indent, action: "Change") else { return }
                enterInsert(at: range.location + (indent as NSString).length, keys: keys)
            } else {
                guard replace(range, with: "", action: "Change") else { return }
                enterInsert(at: range.location, keys: keys)
            }
        case ">", "<":
            indent(range, outdent: op == "<", times: count)
        default: break
        }
    }

    private func enterInsert(at p: Int, keys: [String]) {
        mode = .insert
        setCursor(p)
        textView.breakUndoCoalescing()
        changeKeys = replaying ? nil : keys
        insertStart = p
        insertLength = text.length
    }

    private func leaveInsert() {
        textView.breakUndoCoalescing()
        let p = textView.selectedRange().location
        if let keys = changeKeys {
            // What was typed, for `.`; anything moving around outside the insert repeats only the command.
            let delta = text.length - insertLength
            var typed: [String] = []
            if delta > 0, insertStart + delta <= text.length, p >= insertStart, p <= insertStart + delta {
                typed = [text.substring(with: NSRange(location: insertStart, length: delta))]
            }
            if delta >= 0 { lastChange = keys + typed + ["<Esc>"] }
            changeKeys = nil
        }
        mode = .normal
        setCursor(p > lineStart(p) ? prevChar(p) : p)
    }

    private func repeatChange(count: Int?) {
        guard !lastChange.isEmpty else { return }
        var keys = lastChange
        if let count {
            var i = 0
            _ = parseCount(keys, &i)
            keys = String(count).map(String.init) + keys[i...]
        }
        replaying = true
        defer { replaying = false }
        for key in keys { feed(key) }
    }

    private func put(after: Bool, count: Int, at p: Int) {
        let reg = currentRegister
        guard !reg.text.isEmpty else { return }
        let body = String(repeating: reg.text, count: count)
        if reg.linewise {
            if after {
                let line = lineRange(p)
                let end = NSMaxRange(line)
                if end > line.location, char(end - 1) == 10 {
                    guard replace(NSRange(location: end, length: 0), with: body, action: "Paste") else { return }
                    setCursor(firstNonBlank(end))
                } else {
                    guard replace(NSRange(location: end, length: 0), with: "\n" + body.dropLast(), action: "Paste") else { return }
                    setCursor(firstNonBlank(end + 1))
                }
            } else {
                let start = lineStart(p)
                guard replace(NSRange(location: start, length: 0), with: body, action: "Paste") else { return }
                setCursor(firstNonBlank(start))
            }
        } else {
            let at = after && p < lineEnd(p) ? nextChar(p) : p
            guard replace(NSRange(location: at, length: 0), with: body, action: "Paste") else { return }
            setCursor(body.contains("\n") ? at : clamp(at + (body as NSString).length - 1))
        }
    }

    private func join(from p: Int, lines count: Int) {
        let start = lineStart(p)
        var last = start
        for _ in 1..<count {
            guard let next = lineDown(last) else { break }
            last = next
        }
        guard last > start else { return }
        let range = NSRange(location: start, length: lineEnd(last) - start)
        let lines = text.substring(with: range).components(separatedBy: "\n")
        var joined = lines[0]
        var cursor = 0
        for line in lines.dropFirst() {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            cursor = (joined as NSString).length
            if !trimmed.isEmpty, !joined.isEmpty, !joined.hasSuffix(" "), !joined.hasSuffix("\t"), !trimmed.hasPrefix(")") {
                joined += " "
            }
            joined += trimmed
        }
        guard replace(range, with: joined, action: "Join Lines") else { return }
        setCursor(clamp(start + cursor))
    }

    private func replaceChars(at p: Int, count: Int, with arg: String) {
        let end = lineEnd(p)
        var e = p
        for _ in 0..<count where e < end { e = nextChar(e) }
        guard p < end, e > p, count == 1 || e - p >= count else { return }
        let newline = arg == "<CR>"
        let s = newline ? "\n" : String(repeating: arg, count: count)
        guard replace(NSRange(location: p, length: e - p), with: s, action: "Replace") else { return }
        setCursor(newline ? p + 1 : clamp(p + (s as NSString).length - (arg as NSString).length))
    }

    private func toggleCase(at p: Int, count: Int) {
        let end = lineEnd(p)
        guard p < end else { return }
        var e = p
        for _ in 0..<count where e < end { e = nextChar(e) }
        let range = NSRange(location: p, length: e - p)
        guard changeCase(range, to: nil) else { return }
        setCursor(clamp(e))
    }

    @discardableResult
    private func changeCase(_ range: NSRange, to upper: Bool?) -> Bool {
        let s = text.substring(with: range)
        let changed = s.map { ch -> String in
            switch upper {
            case true?: ch.uppercased()
            case false?: ch.lowercased()
            case nil: ch.isUppercase ? ch.lowercased() : ch.uppercased()
            }
        }.joined()
        return replace(range, with: changed, action: "Change Case")
    }

    private func openLine(below: Bool, at p: Int, keys: [String]) {
        let indent = leadingWhitespace(lineStart(p))
        let indentLength = (indent as NSString).length
        if below {
            let end = lineEnd(p)
            guard replace(NSRange(location: end, length: 0), with: "\n" + indent, action: "Open Line") else { return }
            enterInsert(at: end + 1 + indentLength, keys: keys)
        } else {
            let start = lineStart(p)
            guard replace(NSRange(location: start, length: 0), with: indent + "\n", action: "Open Line") else { return }
            enterInsert(at: start + indentLength, keys: keys)
        }
    }

    /// Two spaces per level, like Tab in the editor.
    private func indent(_ range: NSRange, outdent: Bool, times: Int) {
        let lines = text.lineRange(for: NSRange(location: range.location,
                                                length: max(0, range.length - (range.length > 0 && char(NSMaxRange(range) - 1) == 10 ? 1 : 0))))
        var content = lines
        if content.length > 0, char(NSMaxRange(content) - 1) == 10 { content.length -= 1 }
        let block = text.substring(with: content).components(separatedBy: "\n").map { line -> String in
            if outdent {
                var rest = Substring(line)
                for _ in 0..<times * 2 where rest.first == " " { rest = rest.dropFirst() }
                if rest.count == line.count, rest.first == "\t" { rest = rest.dropFirst() }
                return String(rest)
            }
            return line.isEmpty ? line : String(repeating: "  ", count: times) + line
        }.joined(separator: "\n")
        guard replace(content, with: block, action: outdent ? "Outdent" : "Indent") else { return }
        setCursor(firstNonBlank(lines.location))
    }

    // MARK: Visual mode

    private var visualRange: NSRange {
        let lo = min(anchor, head), hi = max(anchor, head)
        if mode == .visualLine { return linesRange(lineStart(lo), lineStart(hi)) }
        return NSRange(location: lo, length: (hi < text.length ? nextChar(hi) : hi) - lo)
    }

    private func showVisual() {
        textView.setSelectedRange(visualRange)
        textView.scrollRangeToVisible(NSRange(location: min(head, text.length), length: 0))
    }

    private func runVisual(_ c: Command) {
        let range = visualRange
        let linewise = mode == .visualLine
        let n = c.count ?? 1
        let lines = linesRange(lineStart(range.location), lineStart(max(range.location, NSMaxRange(range) - 1)))
        func done(_ cursor: Int) {
            mode = .normal
            setCursor(clamp(cursor))
        }
        switch c.name {
        case "move":
            guard let m = c.motion else { return }
            if m.key == "i" || m.key == "a" {
                guard let object = textObject(inner: m.key == "i", m.arg ?? "", at: head), object.length > 0 else { return }
                mode = .visual
                anchor = object.location
                head = NSMaxRange(object) - 1
                return showVisual()
            }
            move(m, from: head) { head = min($0, text.length) }
            showVisual()
        case "o", "O":
            swap(&anchor, &head)
            showVisual()
        case "v", "V":
            let target: Mode = c.name == "v" ? .visual : .visualLine
            if mode == target { done(head) } else {
                mode = target
                showVisual()
            }
        case "<Esc>": done(head)
        case "d", "x", "<Del>", "c", "s", "y", "D", "X", "C", "S", "R", "Y":
            let op = ["d", "x", "<Del>", "D", "X"].contains(c.name) ? "d" : ["y", "Y"].contains(c.name) ? "y" : "c"
            let whole = linewise || ["D", "X", "C", "S", "R", "Y"].contains(c.name)
            mode = .normal
            apply(op, range: whole ? lines : range, linewise: whole, cursor: range.location, keys: [], count: 1)
        case ">", "<":
            mode = .normal
            indent(lines, outdent: c.name == "<", times: n)
        case "~", "u", "U":
            mode = .normal
            changeCase(range, to: c.name == "~" ? nil : c.name == "U")
            done(range.location)
        case "J":
            let count = text.substring(with: lines).filter { $0 == "\n" }.count
            mode = .normal
            join(from: range.location, lines: max(2, count))
        case "r":
            let arg = c.arg == "<CR>" ? "\n" : c.arg ?? ""
            let replaced = text.substring(with: range).map { $0 == "\n" ? "\n" : arg }.joined()
            mode = .normal
            if replace(range, with: replaced, action: "Replace") { done(range.location) }
        case "p", "P":
            let reg = currentRegister
            let old = text.substring(with: range)
            var body = reg.text
            if linewise, !reg.linewise { body += "\n" } else if !linewise, reg.linewise { body = "\n" + body }
            mode = .normal
            guard replace(range, with: body, action: "Paste") else { return }
            if c.name == "p" { setRegister(old, linewise: linewise) }
            done(linewise ? firstNonBlank(range.location) : range.location + max((body as NSString).length - 1, 0))
        default: break
        }
    }

    // MARK: Motions

    private enum Kind { case exclusive, inclusive, linewise }

    private func target(_ m: Motion, from p: Int, op: Bool) -> (pos: Int, kind: Kind)? {
        let n = max(m.count ?? 1, 1)
        let length = text.length
        let start = lineStart(p), end = lineEnd(p)
        switch m.key {
        case "h", "<Left>", "<BS>":
            guard p > start else { return nil }
            var q = p
            for _ in 0..<n where q > start { q = prevChar(q) }
            return (q, .exclusive)
        case "l", "<Right>", " ":
            let limit = op || mode != .normal ? end : max(start, end > start ? prevChar(end) : start)
            guard p < limit else { return nil }
            var q = p
            for _ in 0..<n where q < limit { q = nextChar(q) }
            return (q, .exclusive)
        case "j", "k", "<Up>", "<Down>", "<C-d>", "<C-u>", "+", "-", "_", "<CR>":
            let down = ["j", "<Down>", "<C-d>", "+", "_", "<CR>"].contains(m.key)
            var steps = m.key == "_" ? n - 1 : n
            if m.key == "<C-d>" || m.key == "<C-u>" { steps = halfPage }
            var line = start
            var moved = 0
            for _ in 0..<steps {
                guard let next = down ? lineDown(line) : lineUp(line) else { break }
                line = next
                moved += 1
            }
            guard moved > 0 || m.key == "_" else { return nil }
            if ["+", "-", "_", "<CR>"].contains(m.key) { return (firstNonBlank(line), .linewise) }
            let width = lineEnd(line) - line
            return (line + min(column ?? (p - start), width), .linewise)
        case "w", "W":
            let big = m.key == "W"
            var q = p
            for i in 0..<n {
                let next = nextWordStart(q, big)
                // An operator stops at the end of the line the last word is on.
                if op, i == n - 1, next > lineEnd(q) { q = max(lineEnd(q), q) } else { q = next }
            }
            return q == p ? nil : (min(q, length), .exclusive)
        case "b", "B":
            var q = p
            for _ in 0..<n { q = prevWordStart(q, m.key == "B") }
            return q == p ? nil : (q, .exclusive)
        case "e", "E":
            var q = p
            for _ in 0..<n { q = nextWordEnd(q, m.key == "E") }
            return q == p ? nil : (q, .inclusive)
        case "0": return (start, .exclusive)
        case "^": return (firstNonBlank(start), .exclusive)
        case "$":
            var line = start
            for _ in 1..<n {
                guard let next = lineDown(line) else { break }
                line = next
            }
            let e = lineEnd(line)
            return e == line ? (e, .exclusive) : (prevChar(e), .inclusive)
        case "gg", "G":
            let target = m.count ?? (m.key == "gg" ? 1 : .max)
            var line = 0
            var number = 1
            while number < target, let next = lineDown(line) {
                line = next
                number += 1
            }
            return (firstNonBlank(line), .linewise)
        case "{", "}":
            var line = start
            for _ in 0..<n {
                guard let next = paragraph(from: line, down: m.key == "}") else {
                    return m.key == "}" ? (op ? length : clamp(length), .exclusive) : (0, .exclusive)
                }
                line = next
            }
            return (line, .exclusive)
        case "f", "F", "t", "T":
            guard let arg = m.arg else { return nil }
            lastFind = (m.key, arg)
            return find(m.key, arg, from: p, count: n, repeating: false)
        case ";", ",":
            guard let last = lastFind else { return nil }
            let reversed = ["f": "F", "F": "f", "t": "T", "T": "t"][last.kind] ?? last.kind
            return find(m.key == ";" ? last.kind : reversed, last.char, from: p, count: n, repeating: true)
        case "%":
            return matchBracket(from: p).map { ($0, .inclusive) }
        default:
            return nil
        }
    }

    private var halfPage: Int {
        let height = textView.enclosingScrollView?.contentView.bounds.height ?? 400
        let line = textView.font.flatMap { textView.layoutManager?.defaultLineHeight(for: $0) } ?? 16
        return max(1, Int(height / max(line, 1)) / 2)
    }

    private func paragraph(from line: Int, down: Bool) -> Int? {
        func step(_ l: Int) -> Int? { down ? lineDown(l) : lineUp(l) }
        var line = line
        while lineEnd(line) == line, let next = step(line) { line = next }
        while let next = step(line) {
            line = next
            if lineEnd(line) == line { return line }
        }
        return nil
    }

    private func find(_ kind: String, _ arg: String, from p: Int, count: Int, repeating: Bool) -> (pos: Int, kind: Kind)? {
        guard arg.utf16.count == 1, let target = arg.utf16.first else { return nil }
        let start = lineStart(p), end = lineEnd(p)
        let forward = kind == "f" || kind == "t"
        var q = p
        for i in 0..<count {
            var j = forward ? q + 1 : q - 1
            // Repeating t skips the match right next to the caret.
            if repeating, i == 0, kind == "t" { j += 1 }
            if repeating, i == 0, kind == "T" { j -= 1 }
            while j >= start, j < end, char(j) != target { j += forward ? 1 : -1 }
            guard j >= start, j < end else { return nil }
            q = j
        }
        switch kind {
        case "f": return (q, .inclusive)
        case "t": return (q - 1, .inclusive)
        case "F": return (q, .exclusive)
        default: return (q + 1, .exclusive)
        }
    }

    private func matchBracket(from p: Int) -> Int? {
        let pairs: [unichar: (unichar, Bool)] = [40: (41, true), 91: (93, true), 123: (125, true),
                                                 41: (40, false), 93: (91, false), 125: (123, false)]
        let end = lineEnd(p)
        var q = p
        while q < end, pairs[char(q)] == nil { q += 1 }
        guard q < end, let (partner, forward) = pairs[char(q)] else { return nil }
        let own = char(q)
        var depth = 0
        var j = q
        while true {
            j += forward ? 1 : -1
            guard j >= 0, j < text.length else { return nil }
            let c = char(j)
            if c == own { depth += 1 } else if c == partner {
                if depth == 0 { return j }
                depth -= 1
            }
        }
    }

    // MARK: Text objects

    private func textObject(inner: Bool, _ kind: String, at p: Int) -> NSRange? {
        switch kind {
        case "w", "W": return word(inner: inner, big: kind == "W", at: p)
        case "\"", "'", "`": return quoted(inner: inner, kind.utf16.first!, at: p)
        case "(", ")", "b": return bracketed(inner: inner, open: 40, close: 41, at: p)
        case "[", "]": return bracketed(inner: inner, open: 91, close: 93, at: p)
        case "{", "}", "B": return bracketed(inner: inner, open: 123, close: 125, at: p)
        case "<", ">": return bracketed(inner: inner, open: 60, close: 62, at: p)
        default: return nil
        }
    }

    private func word(inner: Bool, big: Bool, at p: Int) -> NSRange? {
        guard p < text.length, char(p) != 10 else { return nil }
        let start = lineStart(p), end = lineEnd(p), c = cls(p, big)
        var s = p, e = p + 1
        while s > start, cls(s - 1, big) == c { s -= 1 }
        while e < end, cls(e, big) == c { e += 1 }
        if !inner {
            if c != 0 {
                let wordEnd = e
                while e < end, isBlank(e) { e += 1 }
                if e == wordEnd { while s > start, isBlank(s - 1) { s -= 1 } }
            } else if e < end {
                let next = cls(e, big)
                while e < end, cls(e, big) == next { e += 1 }
            }
        }
        return NSRange(location: s, length: e - s)
    }

    private func quoted(inner: Bool, _ quote: unichar, at p: Int) -> NSRange? {
        let start = lineStart(p), end = lineEnd(p)
        var quotes: [Int] = []
        var i = start
        while i < end {
            if char(i) == 92 { i += 2; continue }
            if char(i) == quote { quotes.append(i) }
            i += 1
        }
        var pair: (Int, Int)?
        for k in stride(from: 0, to: quotes.count - 1, by: 2) where p <= quotes[k + 1] {
            pair = (quotes[k], quotes[k + 1])
            break
        }
        guard let (a, b) = pair else { return nil }
        if inner { return NSRange(location: a + 1, length: b - a - 1) }
        var e = b + 1
        while e < end, isBlank(e) { e += 1 }
        return NSRange(location: a, length: e - a)
    }

    private func bracketed(inner: Bool, open: unichar, close: unichar, at p: Int) -> NSRange? {
        let length = text.length
        var s: Int?
        if p < length, char(p) == open { s = p } else {
            var depth = 0
            var i = p - 1
            while i >= 0 {
                let c = char(i)
                if c == close { depth += 1 } else if c == open {
                    if depth == 0 { s = i; break }
                    depth -= 1
                }
                i -= 1
            }
        }
        guard let s else { return nil }
        var depth = 0
        var e = s + 1
        while e < length {
            let c = char(e)
            if c == open { depth += 1 } else if c == close {
                if depth == 0 { break }
                depth -= 1
            }
            e += 1
        }
        guard e < length else { return nil }
        guard inner else { return NSRange(location: s, length: e - s + 1) }
        var lo = s + 1, hi = e
        // A block on its own lines keeps the lines with its brackets.
        if lo < hi, char(lo) == 10, firstNonBlank(lineStart(hi)) == hi, lineStart(hi) > lo {
            lo += 1
            hi = lineStart(hi) - 1
        }
        return NSRange(location: lo, length: max(hi - lo, 0))
    }

    // MARK: Text

    private var text: NSString { textView.textStorage?.mutableString ?? (textView.string as NSString) }

    private func char(_ i: Int) -> unichar { text.character(at: i) }

    private func isBlank(_ i: Int) -> Bool {
        let c = char(i)
        return c == 32 || c == 9
    }

    /// 0 for blanks, 1 for word characters, 2 for punctuation; big words only know blanks and the rest.
    private func cls(_ i: Int, _ big: Bool) -> Int {
        let c = char(i)
        if c == 32 || c == 9 || c == 10 || c == 13 { return 0 }
        if big || c == 95 { return 1 }
        guard let scalar = Unicode.Scalar(c) else { return 1 }
        return CharacterSet.alphanumerics.contains(scalar) ? 1 : 2
    }

    private func nextChar(_ i: Int) -> Int {
        i < text.length ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: i)) : i
    }

    private func prevChar(_ i: Int) -> Int {
        i > 0 ? text.rangeOfComposedCharacterSequence(at: i - 1).location : 0
    }

    private func lineRange(_ p: Int) -> NSRange { text.lineRange(for: NSRange(location: min(p, text.length), length: 0)) }

    private func lineStart(_ p: Int) -> Int { lineRange(p).location }

    /// Where the line's content ends, before its break.
    private func lineEnd(_ p: Int) -> Int {
        let r = lineRange(p)
        let e = NSMaxRange(r)
        return e > r.location && char(e - 1) == 10 ? e - 1 : e
    }

    /// The next line's start; the empty spot after a final break doesn't count as a line, like in Vim.
    private func lineDown(_ start: Int) -> Int? {
        let r = lineRange(start)
        let e = NSMaxRange(r)
        guard e > r.location, char(e - 1) == 10, e < text.length else { return nil }
        return e
    }

    private func lineUp(_ start: Int) -> Int? { start == 0 ? nil : lineStart(start - 1) }

    private func linesRange(_ first: Int, _ last: Int) -> NSRange {
        NSRange(location: first, length: NSMaxRange(lineRange(last)) - first)
    }

    private func firstNonBlank(_ start: Int) -> Int {
        let end = lineEnd(start)
        var i = start
        while i < end, isBlank(i) { i += 1 }
        return i
    }

    private func leadingWhitespace(_ start: Int) -> String {
        text.substring(with: NSRange(location: start, length: firstNonBlank(start) - start))
    }

    /// Normal mode keeps the caret on a character, not after a line's last one.
    private func clamp(_ p: Int) -> Int {
        let p = min(max(p, 0), text.length)
        let start = lineStart(p), end = lineEnd(p)
        return end > start ? min(p, prevChar(end)) : start
    }

    private func nextWordStart(_ p: Int, _ big: Bool) -> Int {
        let length = text.length
        guard p < length else { return length }
        var i = p
        let c = cls(i, big)
        if c != 0 { while i < length, cls(i, big) == c { i += 1 } }
        while i < length, cls(i, big) == 0 {
            // Empty lines count as words.
            if char(i) == 10, i + 1 < length, char(i + 1) == 10 { return i + 1 }
            i += 1
        }
        return i
    }

    private func nextWordEnd(_ p: Int, _ big: Bool) -> Int {
        let length = text.length
        var i = nextChar(p)
        while i < length, cls(i, big) == 0 { i += 1 }
        guard i < length else { return max(min(p, length - 1), 0) }
        let c = cls(i, big)
        while i + 1 < length, cls(i + 1, big) == c { i += 1 }
        return i
    }

    private func prevWordStart(_ p: Int, _ big: Bool) -> Int {
        guard p > 0 else { return 0 }
        var i = p - 1
        while i > 0, cls(i, big) == 0 {
            if char(i) == 10, char(i - 1) == 10 { return i }
            i -= 1
        }
        if cls(i, big) == 0 { return i }
        let c = cls(i, big)
        while i > 0, cls(i - 1, big) == c { i -= 1 }
        return i
    }

    // MARK: Editing

    private var currentRegister: (text: String, linewise: Bool) {
        // Something copied elsewhere since the last yank wins.
        if let pasteboard, pasteboard.changeCount != pasteboardChange, let s = pasteboard.string(forType: .string) {
            return (s, s.hasSuffix("\n"))
        }
        return register
    }

    private func yank(_ range: NSRange, linewise: Bool) {
        setRegister(text.substring(with: range), linewise: linewise)
    }

    private func setRegister(_ s: String, linewise: Bool) {
        let s = linewise && !s.hasSuffix("\n") ? s + "\n" : s
        register = (s, linewise)
        guard let pasteboard else { return }
        pasteboard.clearContents()
        pasteboard.setString(s, forType: .string)
        pasteboardChange = pasteboard.changeCount
    }

    /// Goes through shouldChangeText like typing, so undo, autosave and live editing see it.
    @discardableResult
    private func replace(_ range: NSRange, with string: String, action: String) -> Bool {
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: string) else { return false }
        textView.replaceCharacters(in: range, with: string)
        textView.didChangeText()
        textView.undoManager?.setActionName(action)
        // The edit came from a key press, which the completion list takes for typing.
        completion?.hide()
        return true
    }

    private func setCursor(_ p: Int) {
        let range = NSRange(location: min(max(p, 0), text.length), length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }
}

extension TypstTextView {
    /// Turns the Vim bindings on or off; `onModeChange` gets nil once they're off.
    func configureVim(_ enabled: Bool, completion: CompletionController?, onModeChange: ((String?) -> Void)?) {
        if enabled, vim == nil {
            vim = VimEngine(textView: self)
        } else if !enabled, vim != nil {
            vim = nil
            DispatchQueue.main.async { onModeChange?(nil) }
        }
        vim?.completion = completion
        vim?.onModeChange = onModeChange
    }

    /// Normal mode's block caret covers the character under it.
    func vimBlockRect(_ caret: NSRect, at location: Int) -> NSRect {
        let font = font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        var width = (" " as NSString).size(withAttributes: [.font: font]).width
        let s = textStorage?.mutableString ?? (string as NSString)
        if location < s.length, s.character(at: location) != 10, let lm = layoutManager, let container = textContainer {
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
            let glyphWidth = lm.boundingRect(forGlyphRange: glyphs, in: container).width
            if glyphWidth > 0 { width = glyphWidth }
        }
        return NSRect(x: caret.minX + 1, y: caret.minY, width: ceil(width), height: caret.height)
    }
}
