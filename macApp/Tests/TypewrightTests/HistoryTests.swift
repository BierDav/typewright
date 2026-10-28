import XCTest
import TypewrightCore
@testable import Typewright

@MainActor
final class HistoryTests: XCTestCase {
    private func versions(_ json: String) throws -> [FileVersion] {
        try JSONDecoder().decode([FileVersion].self, from: Data(json.utf8))
    }

    private func lines(_ rows: [FileDiffRow]) -> [FileDiffRow.Line] {
        rows.compactMap { if case .line(let line) = $0 { line } else { nil } }
    }

    // MARK: - Diff rows

    func testDiffRowsNumberBothSides() {
        let rows = FileDiffRow.rows(old: "a\nb\nc", new: "a\nB\nc")
        let numbered = lines(rows).map { "\($0.kind) \($0.old.map(String.init) ?? "-") \($0.new.map(String.init) ?? "-") \($0.text)" }
        XCTAssertEqual(numbered, ["same 1 1 a", "removed 2 - b", "added - 2 B", "same 3 3 c"])
    }

    func testLongUnchangedRunsFoldAndExpand() {
        let old = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 15\n", with: "changed\n")
        let rows = FileDiffRow.rows(old: old, new: new, context: 3)
        // The run before the change keeps no head, the run after it no tail; each keeps 3 lines next to the change.
        let folds = rows.compactMap { if case .fold(let id, let count) = $0 { (id, count) } else { nil } }
        XCTAssertEqual(folds.map(\.1), [11, 12])
        XCTAssertEqual(lines(rows).first?.old, 12, "numbering continues after a fold")
        XCTAssertEqual(lines(rows).last?.new, 18)

        let expanded = FileDiffRow.rows(old: old, new: new, context: 3, expanded: [folds[0].0])
        XCTAssertEqual(expanded.filter { if case .fold = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(lines(expanded).first?.old, 1)
        XCTAssertEqual(Set(expanded.map(\.id)).count, expanded.count, "row ids stay unique")
    }

    func testShortRunsDontFold() {
        let rows = FileDiffRow.rows(old: "a\nb\nc\nd\ne", new: "a\nb\nc\nd\nE", context: 3)
        XCTAssertFalse(rows.contains { if case .fold = $0 { true } else { false } })
    }

    // MARK: - Versions

    func testVersionsGroupByDayNewestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let list = try versions("""
        [{"commit": "c", "time": 172800, "description": "", "kind": "modified", "added": 1, "removed": 0},
         {"commit": "b", "time": 90000, "description": "", "kind": "modified", "added": 1, "removed": 1},
         {"commit": "a", "time": 86500, "description": "", "kind": "added", "added": 3, "removed": 0}]
        """)
        let days = FileVersionDay.group(list, calendar: calendar)
        XCTAssertEqual(days.map { $0.versions.map(\.commit) }, [["c"], ["b", "a"]])
        XCTAssertEqual(days[1].day, Date(timeIntervalSince1970: 86400))
    }

    func testPathsFollowRenamesBackwards() throws {
        let list = try versions("""
        [{"commit": "3", "time": 3, "kind": "modified"},
         {"commit": "2", "time": 2, "kind": "renamed", "from": "S/old.typ"},
         {"commit": "1", "time": 1, "kind": "added"}]
        """)
        XCTAssertEqual(FileVersion.paths(of: list, current: "S/new.typ"), ["S/new.typ", "S/new.typ", "S/old.typ"])
    }

    func testModelDiffsSelectionAgainstNowAndItsParent() async throws {
        let list = try versions("""
        [{"commit": "2", "time": 2, "kind": "renamed", "from": "S/old.typ"},
         {"commit": "1", "time": 1, "kind": "added"}]
        """)
        let contents = ["S/new.typ@2": "a\nb\n", "S/old.typ@1": "a\n"]
        var requested: [String] = []
        let model = FileHistoryModel(
            file: URL(fileURLWithPath: "/r/S/new.typ"), path: "S/new.typ",
            source: .init(versions: { list }, content: { path, commit in
                requested.append("\(path)@\(commit)")
                return contents["\(path)@\(commit)"].map(FileContent.text) ?? .missing
            }),
            currentText: { "a\nb\nc\n" }
        )
        await model.load()
        XCTAssertEqual(model.selection, "2", "the newest version is selected")
        try await waitFor { model.hunks != nil }
        XCTAssertEqual(model.hunks?.map(\.kind), [.same, .added], "now adds c to version 2")

        model.comparison = .previous
        try await waitFor { requested.contains("S/old.typ@1") && model.hunks?.last?.lines == ["b"] }
        XCTAssertEqual(model.path(of: list[1]), "S/old.typ")

        model.selection = "1"
        // The first version is compared to nothing, so all of it is new.
        try await waitFor { model.hunks?.map(\.kind) == [.added] }
    }

    func testSelectionHistoryTracksLinesAcrossRenamesAndSkipsUnrelatedChanges() async throws {
        let list = try versions("""
        [{"commit": "4", "time": 4, "kind": "modified"},
         {"commit": "3", "time": 3, "kind": "renamed", "from": "S/old.typ"},
         {"commit": "2", "time": 2, "kind": "modified"},
         {"commit": "1", "time": 1, "kind": "added"}]
        """)
        let contents = ["4": "intro\na\nnew\nz", "3": "a\nnew\nz", "2": "a\nnew\nz", "1": "a\nold\nz"]
        var requested: [String] = []
        let model = FileHistoryModel(
            file: URL(fileURLWithPath: "/r/S/new.typ"), path: "S/new.typ",
            source: .init(versions: { list }, content: { path, commit in
                requested.append("\(path)@\(commit)")
                return .text(contents[commit]!)
            }), currentText: { contents["4"] }, selectedLines: 2..<3
        )
        await model.load()
        XCTAssertEqual(model.visibleVersions.map(\.commit), ["2", "1"])
        XCTAssertEqual(model.selection, "2")
        XCTAssertTrue(requested.contains("S/old.typ@1"))
        try await waitFor { model.rows != nil }
        XCTAssertEqual(model.rows.map { self.lines($0).map(\.text) }, ["old", "new"])
        XCTAssertEqual(model.rows.map { self.lines($0).compactMap(\.new) }, [2])
        model.comparison = .current
        try await waitFor { model.hunks != nil }
        XCTAssertEqual(model.rows.map { self.lines($0).map(\.text) }, ["new"])
    }

    func testSelectionHistoryStopsBeforeSelectedLinesWereAdded() async throws {
        let list = try versions("""
        [{"commit": "2", "time": 2, "kind": "modified"},
         {"commit": "1", "time": 1, "kind": "added"}]
        """)
        let model = FileHistoryModel(
            file: URL(fileURLWithPath: "/r/S/a.typ"), path: "S/a.typ",
            source: .init(versions: { list }, content: { _, commit in
                .text(commit == "2" ? "a\nselected\nz" : "a\nz")
            }), currentText: { "a\nselected\nz" }, selectedLines: 1..<2
        )
        await model.load()
        XCTAssertEqual(model.visibleVersions.map(\.commit), ["2"])
        try await waitFor { model.rows != nil }
        XCTAssertEqual(model.rows.map { self.lines($0).map(\.text) }, ["selected"])
    }

    func testUnsavedNewSelectionHasNoSavedHistory() async throws {
        let list = try versions(#"[{"commit": "1", "time": 1, "kind": "added"}]"#)
        let model = FileHistoryModel(
            file: URL(fileURLWithPath: "/r/S/a.typ"), path: "S/a.typ",
            source: .init(versions: { list }, content: { _, _ in .text("a\nz") }),
            currentText: { "a\nunsaved\nz" }, selectedLines: 1..<2
        )
        await model.load()
        XCTAssertTrue(model.visibleVersions.isEmpty)
        XCTAssertNil(model.selection)
        XCTAssertFalse(model.isLoading)
    }

    func testBinaryVersionsGetNoDiff() async throws {
        let list = try versions(#"[{"commit": "1", "time": 1, "kind": "added"}]"#)
        let model = FileHistoryModel(
            file: URL(fileURLWithPath: "/r/S/logo.png"), path: "S/logo.png",
            source: .init(versions: { list }, content: { _, _ in .data(Data([0x89, 0x50])) }),
            currentText: { XCTFail("Whole-file versions must not read or diff the current text"); return nil }
        )
        await model.load()
        try await waitFor { model.content != nil }
        XCTAssertFalse(model.isText)
        XCTAssertNil(model.rows)
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Conflicts

    func testResolutionNeedsEveryConflict() {
        var resolution = ConflictResolution(.sample)
        XCTAssertEqual(resolution.conflictIndices, [1, 3])
        XCTAssertNil(resolution.text)
        resolution.choices[1] = .side(1)
        XCTAssertEqual(resolution.unresolvedCount, 1)
        resolution.choices[3] = .side(0)
        XCTAssertEqual(resolution.text, "= Thesis\n\nIntro, from the laptop.\n" + (1...12).map { "Line \($0)\n" }.joined() + "== Method\n")
        XCTAssertEqual(resolution.label(of: 0), "This Mac")
        XCTAssertEqual(resolution.label(of: 5), "Side 6")
    }

    func testKeepingBothSidesKeepsLinesApart() {
        let conflict = FileConflict(path: "S/a.typ", binary: false, sides: ["A", "B"],
                                    hunks: [.conflict(base: "x", sides: ["one", "two"])])
        var resolution = ConflictResolution(conflict)
        resolution.choices[0] = .both
        XCTAssertEqual(resolution.text, "one\ntwo")
        resolution.choices[0] = .manual("mine")
        XCTAssertEqual(resolution.text, "mine")
    }

    func testDayTitles() {
        XCTAssertEqual(FileHistoryView.dayTitle(.now), "Today")
        XCTAssertEqual(FileHistoryView.dayTitle(.now.addingTimeInterval(-86_400)), "Yesterday")
    }
}
