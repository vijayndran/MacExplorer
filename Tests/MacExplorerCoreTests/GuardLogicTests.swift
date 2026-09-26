import XCTest
@testable import MacExplorerCore

/// Regression tests for the four audit-fix guards in the MacExplorer fork.
/// Each test exercises the pure decision logic the fixed code runs, against a
/// real temporary directory — no NSAlert/runModal (which would hang headless).
final class GuardLogicTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExplorerGuardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Fix 2 — rename collision guard

    func testRenameBlockedWhenTargetNameExists() throws {
        // "existing.txt" is already present; renaming onto it must be blocked.
        let existing = tmp.appendingPathComponent("existing.txt")
        try "beta".write(to: existing, atomically: true, encoding: .utf8)

        XCTAssertTrue(
            GuardLogic.renameShouldBlock(oldName: "rename-me.txt", newName: "existing.txt", in: tmp),
            "Renaming onto an existing name must be blocked, not silently fail."
        )
    }

    func testRenameAllowedWhenTargetNameFree() throws {
        XCTAssertFalse(
            GuardLogic.renameShouldBlock(oldName: "rename-me.txt", newName: "brand-new.txt", in: tmp),
            "A free target name must be allowed."
        )
    }

    func testRenameBlockedOnEmptyOrNoOpName() {
        XCTAssertTrue(GuardLogic.renameShouldBlock(oldName: "a.txt", newName: "", in: tmp),
                      "Empty new name must be blocked.")
        XCTAssertTrue(GuardLogic.renameShouldBlock(oldName: "a.txt", newName: "a.txt", in: tmp),
                      "No-op rename (same name) must be blocked.")
    }

    // MARK: Fix 1 — trash error surfacing (no swallowed try?)

    func testTrashCollectsFailuresInsteadOfSwallowing() {
        struct TrashError: Error {}
        let ok = tmp.appendingPathComponent("ok.txt")
        let bad = tmp.appendingPathComponent("locked.txt")

        // Simulate: ok.txt trashes fine, locked.txt throws (e.g. permission denied).
        let outcome = GuardLogic.trashBatch([ok, bad]) { url in
            if url.lastPathComponent == "locked.txt" { throw TrashError() }
        }

        XCTAssertTrue(outcome.hasFailures, "A throwing trash op must be recorded, not swallowed.")
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(outcome.failures.first?.name, "locked.txt")
        XCTAssertTrue(outcome.madeProgress, "One of two moved, so the op made progress.")
    }

    func testTrashAllFailuresMeansNoProgress() {
        struct TrashError: Error {}
        let a = tmp.appendingPathComponent("a.txt")
        let b = tmp.appendingPathComponent("b.txt")

        let outcome = GuardLogic.trashBatch([a, b]) { _ in throw TrashError() }

        XCTAssertEqual(outcome.failures.count, 2)
        XCTAssertFalse(outcome.madeProgress, "No item moved, so madeProgress must be false.")
    }

    func testTrashAllSucceedMeansNoFailures() {
        let a = tmp.appendingPathComponent("a.txt")
        let outcome = GuardLogic.trashBatch([a]) { _ in /* succeeds */ }
        XCTAssertFalse(outcome.hasFailures)
        XCTAssertTrue(outcome.madeProgress)
    }

    // MARK: Fix (bonus) — package exclusion in non-empty-folder confirmation

    func testNonEmptyFolderNeedsConfirmation() {
        XCTAssertTrue(
            GuardLogic.needsNonEmptyConfirmation(isDirectory: true, isPackage: false, isEmpty: false),
            "A non-empty, non-package folder must prompt for confirmation."
        )
    }

    func testPackageBundleIsExcludedFromConfirmation() {
        // A .app bundle is a non-empty directory but must NOT nag on ⌘⌫.
        XCTAssertFalse(
            GuardLogic.needsNonEmptyConfirmation(isDirectory: true, isPackage: true, isEmpty: false),
            "A package (.app) must be excluded from the non-empty confirmation."
        )
    }

    func testEmptyFolderAndFileSkipConfirmation() {
        XCTAssertFalse(GuardLogic.needsNonEmptyConfirmation(isDirectory: true, isPackage: false, isEmpty: true),
                       "An empty folder needs no confirmation.")
        XCTAssertFalse(GuardLogic.needsNonEmptyConfirmation(isDirectory: false, isPackage: false, isEmpty: false),
                       "A plain file needs no confirmation.")
    }
}
