import Darwin
import Foundation

/// A slow server must never hold up the editor or accumulate every intermediate buffer.
final class LanguageServerWriter: @unchecked Sendable {
    private struct Message {
        let data: Data
        let document: String?
    }

    private let handle: FileHandle
    private let queue = DispatchQueue(label: "dev.bierdav.Typewright.lsp-input", qos: .userInitiated)
    private let lock = NSLock()
    private var messages: [Message] = []
    private var writing = false
    private var stopped = false
    private let onFailure: @Sendable () -> Void

    init(handle: FileHandle, onFailure: @escaping @Sendable () -> Void) {
        self.handle = handle
        self.onFailure = onFailure
        // A server exiting mid-write must report EPIPE instead of terminating the app.
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func send(_ data: Data, document: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        if let document {
            // Requests and lifecycle messages are barriers: their preceding edits must arrive first.
            for index in messages.indices.reversed() {
                guard messages[index].document != nil else { break }
                if messages[index].document == document {
                    messages.remove(at: index)
                    break
                }
            }
        }
        messages.append(Message(data: data, document: document))
        guard !writing else { return }
        writing = true
        queue.async { self.drain() }
    }

    func stop() {
        lock.lock()
        stopped = true
        messages.removeAll()
        lock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            guard !stopped, !messages.isEmpty else {
                writing = false
                lock.unlock()
                return
            }
            let message = messages.removeFirst()
            lock.unlock()
            do {
                try handle.write(contentsOf: message.data)
            } catch {
                stop()
                onFailure()
                return
            }
        }
    }
}
