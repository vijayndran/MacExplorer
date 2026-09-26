import SwiftUI

/// Observable state for an in-flight copy/paste operation, surfaced as a
/// progress sheet. Lives on the main actor because the UI observes it; the
/// actual byte copying happens on a background queue (see `CopyEngine`).
@MainActor
@Observable
final class CopyProgress {
    /// Whether a copy is currently running (drives sheet presentation).
    var isActive = false
    /// Name of the file currently being copied.
    var currentFileName = ""
    /// 1-based index of the file being copied, for "3 of 12" display.
    var currentIndex = 0
    /// Total number of top-level items in this paste.
    var totalCount = 0
    /// Bytes copied so far across all files.
    var bytesCompleted: Int64 = 0
    /// Total bytes to copy across all files (0 if unknown).
    var bytesTotal: Int64 = 0

    /// Cancellation flag shared with the background copy loop.
    private(set) var cancelFlag = CancelFlag()

    /// Nonisolated so `AppState` (a nonisolated @Observable) can construct it in
    /// a stored-property initializer. All stored defaults are trivial values.
    nonisolated init() {}

    /// Determinate fraction 0...1, or nil when total is unknown (shows a bar we
    /// can't fill — fall back to indeterminate in the view).
    var fraction: Double? {
        guard bytesTotal > 0 else { return nil }
        return min(1.0, Double(bytesCompleted) / Double(bytesTotal))
    }

    func begin(totalCount: Int, bytesTotal: Int64) {
        cancelFlag = CancelFlag()
        self.totalCount = totalCount
        self.bytesTotal = bytesTotal
        bytesCompleted = 0
        currentIndex = 0
        currentFileName = ""
        isActive = true
    }

    func finish() {
        isActive = false
    }

    func requestCancel() {
        cancelFlag.cancel()
    }
}
