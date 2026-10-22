import XCTest
@testable import Typewright

final class LanguageServerWriterTests: XCTestCase {
    func testClosedPipeReportsFailure() async throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        let failed = expectation(description: "Broken pipe reported")
        let writer = LanguageServerWriter(handle: pipe.fileHandleForWriting) { failed.fulfill() }
        writer.send(Data("message".utf8))
        await fulfillment(of: [failed], timeout: 2)
    }

    @MainActor
    func testUnresponsiveLanguageServerDoesNotBlockChangesOrShutdown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("server")
        let response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"
        try """
        #!/bin/sh
        printf 'Content-Length: \(response.utf8.count)\\r\\n\\r\\n\(response)'
        exec /bin/sleep 30
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let client = try XCTUnwrap(LanguageClient(binary: binary, root: root, fontPaths: []))
        defer { client.stop() }
        let file = root.appendingPathComponent("main.typ")
        let text = String(repeating: "A", count: 262_144)
        client.open(file, text: text)
        // Let initialize complete, then overflow the pipe of a server that never reads stdin.
        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        for _ in 0..<20 { client.change(file, text: text) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        client.stop()
        for _ in 0..<100 where client.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(client.isRunning)
    }

    @MainActor
    func testBlockedServerCoalescesChangesAndPreservesRequestOrder() async throws {
        let pipe = Pipe()
        let writer = LanguageServerWriter(handle: pipe.fileHandleForWriting) {
            XCTFail("Unexpected pipe write failure")
        }
        let large = Data(repeating: 65, count: 1_048_576)
        writer.send(large)
        // Reading one byte proves the writer started, while the rest still fills the pipe.
        let first = try await Task.detached { try pipe.fileHandleForReading.read(upToCount: 1) }.value
        XCTAssertEqual(first, Data([65]))

        let start = Date()
        for version in 0..<100 {
            writer.send(Data("a\(version)".utf8), document: "a.typ")
            writer.send(Data("b\(version)".utf8), document: "b.typ")
        }
        writer.send(Data("request".utf8))
        writer.send(Data("later".utf8), document: "a.typ")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)

        let suffix = Data("a99b99requestlater".utf8)
        let expected = large.dropFirst() + suffix
        let received = try await Task.detached {
            var data = Data()
            while data.count < expected.count {
                guard let chunk = try pipe.fileHandleForReading.read(upToCount: expected.count - data.count), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            return data
        }.value
        XCTAssertEqual(received, expected)
        writer.stop()
    }
}
