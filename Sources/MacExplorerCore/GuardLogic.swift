import Foundation

/// Pure, presentation-free decision logic for the four audit-fix guards.
///
/// These functions contain the *decisions* the fixed code makes (should we block
/// a rename? which items failed to trash? did the overall trash op make progress?
/// does a package get excluded from the non-empty-folder confirmation?). They take
/// injectable filesystem probes so they can be unit-tested against a real temp
/// directory with no NSAlert/runModal (which would hang a headless test run) and
/// no @MainActor coupling. The AppKit call sites (TrashHelper, AppState) call
/// these to make the decision, then present the UI.
public enum GuardLogic {

    // MARK: Fix 2 — rename collision guard

    /// Returns true when a rename to `newName` in `directory` must be BLOCKED.
    /// Mirrors `AppState.renameWithUndo`'s guard: block empty names, no-op
    /// renames, and any name already taken by an existing item.
    public static func renameShouldBlock(
        oldName: String,
        newName: String,
        in directory: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        if newName.isEmpty { return true }
        if newName == oldName { return true }
        let target = directory.appendingPathComponent(newName)
        return fileExists(target.path)
    }

    // MARK: Fix 1 — trash error surfacing

    /// The outcome of attempting to trash a batch, computed from a per-URL trash
    /// operation that may throw. Replaces the old bare `try?` which swallowed
    /// every error. `failures` is what the caller surfaces in an alert.
    public struct TrashOutcome {
        public var failures: [(name: String, error: Error)]
        public var attempted: Int
        public init(failures: [(name: String, error: Error)], attempted: Int) {
            self.failures = failures
            self.attempted = attempted
        }
        /// True when at least one item moved — mirrors the function's return.
        public var madeProgress: Bool { failures.count < attempted }
        public var hasFailures: Bool { !failures.isEmpty }
    }

    public static func trashBatch(
        _ urls: [URL],
        moveOne: (URL) throws -> Void
    ) -> TrashOutcome {
        var failures: [(name: String, error: Error)] = []
        for url in urls {
            do {
                try moveOne(url)
            } catch {
                failures.append((name: url.lastPathComponent, error: error))
            }
        }
        return TrashOutcome(failures: failures, attempted: urls.count)
    }

    // MARK: Fix (bonus) — package exclusion in the non-empty-folder confirmation

    /// Whether a URL needs the "folder is not empty" confirmation before trashing.
    /// A package (.app bundle) is excluded even though it is a non-empty directory,
    /// matching TrashHelper's `isDir && !isPackage && !isEmpty` rule. This is the
    /// exclusion the ⌘⌫ shortcut path was missing before the AppState extraction.
    public static func needsNonEmptyConfirmation(
        isDirectory: Bool,
        isPackage: Bool,
        isEmpty: Bool
    ) -> Bool {
        isDirectory && !isPackage && !isEmpty
    }
}
