import Foundation

/// Reads only what was appended to log files since the last read, a bounded number of bytes at a time, and hands back
/// whole lines. A line still being written stays buffered until its newline arrives. A file that shrank or was
/// replaced is read again from the start.
final class AIAgentLogTailer {
    private struct FileState {
        var offset: UInt64 = 0
        var fileNumber: UInt64 = 0
        var pending = Data()
    }

    /// A partial line longer than this is dropped rather than buffered for ever.
    static let maxPendingBytes = AIAgentJSON.maxDecodedLineBytes + 1

    private var files: [String: FileState] = [:]

    /// The lines appended to `path`, reading at most `budget` bytes (which is reduced by what was read).
    /// `hasMore` is true when the file holds more than the budget allowed.
    func readNewLines(path: String, budget: inout Int) -> (lines: [Data], hasMore: Bool) {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            files[path] = nil
            return ([], false)
        }
        let size = UInt64(max(0, info.st_size))
        let fileNumber = UInt64(info.st_ino)
        var state = files[path] ?? FileState()
        if state.fileNumber != fileNumber || size < state.offset {
            state = FileState(fileNumber: fileNumber)
        }
        guard size > state.offset else {
            files[path] = state
            return ([], false)
        }
        guard budget > 0 else {
            files[path] = state
            return ([], true)
        }

        let wanted = min(size - state.offset, UInt64(budget))
        guard let handle = FileHandle(forReadingAtPath: path) else { return ([], false) }
        defer { try? handle.close() }
        let chunk: Data
        do {
            try handle.seek(toOffset: state.offset)
            chunk = try handle.read(upToCount: Int(wanted)) ?? Data()
        } catch {
            return ([], false)
        }
        budget -= chunk.count
        state.offset += UInt64(chunk.count)

        var buffer = state.pending
        buffer.append(chunk)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            start = buffer.index(after: newline)
        }
        state.pending = start < buffer.endIndex ? Data(buffer[start...]) : Data()
        if state.pending.count > Self.maxPendingBytes {
            state.pending = Data()
        }
        files[path] = state
        return (lines, state.offset < size)
    }

    func forget(_ path: String) {
        files[path] = nil
    }

    var trackedPaths: [String] { Array(files.keys) }
}
