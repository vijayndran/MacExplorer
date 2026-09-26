import Foundation

/// Background file copier that reports byte-level progress and supports
/// cancellation. Used instead of a bare `FileManager.copyItem` (which blocks
/// the caller for the whole transfer with no progress and no cancel — the cause
/// of the "Not Responding" hang when pasting onto a slow ExFAT USB volume).
///
/// Not main-actor isolated: every method is meant to run on a background queue.
enum CopyEngine {

    /// Aggregate the on-disk size of the given top-level URLs, recursing into
    /// directories. Best-effort: unreadable entries contribute 0.
    static func totalSize(of urls: [URL]) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let child as URL in en {
                        let vals = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        if vals?.isRegularFile == true { total += Int64(vals?.fileSize ?? 0) }
                    }
                }
            } else {
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey])
                total += Int64(vals?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Copy `source` to `destination`, streaming file contents in chunks so
    /// progress can be reported and the operation cancelled between chunks.
    /// Recurses into directories. Throws on I/O error or when cancelled.
    ///
    /// - Parameters:
    ///   - onBytes: called (on the copy queue) after each chunk with the number
    ///     of bytes just written — accumulate for a progress bar.
    ///   - isCancelled: polled between chunks and directory entries.
    static func copy(
        from source: URL,
        to destination: URL,
        chunkSize: Int = 1 << 20, // 1 MiB
        isCancelled: () -> Bool,
        onBytes: (Int64) -> Void
    ) throws {
        if isCancelled() { throw CancellationError() }
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw CocoaError(.fileNoSuchFile)
        }

        if isDir.boolValue {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let entries = try fm.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: []
            )
            for entry in entries {
                if isCancelled() { throw CancellationError() }
                let target = destination.appendingPathComponent(entry.lastPathComponent)
                try copy(from: entry, to: target, chunkSize: chunkSize,
                         isCancelled: isCancelled, onBytes: onBytes)
            }
            return
        }

        // Regular file: stream it in chunks.
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        fm.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        while true {
            if isCancelled() { throw CancellationError() }
            let data = try input.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            onBytes(Int64(data.count))
        }

        // Best-effort: preserve modification date & POSIX perms (ExFAT ignores
        // perms, which is fine — this is a no-op there rather than an error).
        let attrs = try? fm.attributesOfItem(atPath: source.path)
        if let attrs {
            var toApply: [FileAttributeKey: Any] = [:]
            if let d = attrs[.modificationDate] { toApply[.modificationDate] = d }
            if let p = attrs[.posixPermissions] { toApply[.posixPermissions] = p }
            try? fm.setAttributes(toApply, ofItemAtPath: destination.path)
        }
    }
}
