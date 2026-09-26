import Foundation
import SwiftUI
import MacExplorerCore

/// Top-level application state managing tabs and global preferences.
@Observable
final class AppState {
    let windowID = UUID()
    var tabs: [TabState] = []
    var activeTabID: UUID?
    var showPreview: Bool = UserDefaults.standard.object(forKey: "showPreview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPreview, forKey: "showPreview") }
    }
    var showHiddenFiles: Bool = UserDefaults.standard.bool(forKey: "showHiddenFiles") {
        didSet {
            UserDefaults.standard.set(showHiddenFiles, forKey: "showHiddenFiles")
            refreshCurrentTab()
        }
    }
    var searchQuery: String = ""
    var shouldClose: Bool = false
    /// Set by sidebar to request the file list start renaming a newly created folder by name
    var pendingRenameFolder: String?
    /// Set to scroll the file list to a specific item (e.g. after paste)
    var scrollToItemID: String?
    /// Set to scroll the sidebar tree to a specific folder URL (e.g. after rename)
    var sidebarScrollTarget: URL?
    /// Incremented when the sidebar tree should refresh (e.g. after trash/move from file list)
    var sidebarReloadToken: Int = 0

    let fileService = FileSystemService()
    let directoryWatcher = DirectoryWatcher()
    /// Paths the sidebar is currently watching (expanded folders)
    var watchedSidebarPaths: Set<String> = [] {
        didSet { rebuildWatcher() }
    }

    // MARK: - Undo/Redo

    let undoManager = UndoManager()
    var canUndo = false
    var canRedo = false
    var undoActionName: String = ""
    var redoActionName: String = ""
    private var undoObservers: [Any] = []

    var currentTab: TabState? {
        get { tabs.first { $0.id == activeTabID } }
        set {
            if let tab = newValue {
                activeTabID = tab.id
            }
        }
    }

    init() {
        addTab()
        setupUndoObservers()
        rebuildWatcher()
    }

    private func setupUndoObservers() {
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
            .NSUndoManagerCheckpoint
        ]
        for name in names {
            let observer = nc.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                self?.syncUndoState()
            }
            undoObservers.append(observer)
        }
    }

    private func syncUndoState() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
        undoActionName = undoManager.undoActionName
        redoActionName = undoManager.redoActionName
    }

    // MARK: - Directory Watching

    func rebuildWatcher() {
        var paths: Set<String> = []
        if let tab = currentTab {
            paths.insert(tab.currentPath.path)
        }
        paths.formUnion(watchedSidebarPaths)
        directoryWatcher.watch(paths: Array(paths)) { [weak self] changedPaths in
            self?.handleFileSystemChanges(changedPaths)
        }
    }

    private func handleFileSystemChanges(_ changedPaths: [String]) {
        guard let tab = currentTab else { return }
        let currentPath = tab.currentPath.standardizedFileURL.path

        var needsListRefresh = false
        var needsSidebarRefresh = false

        for path in changedPaths {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            if standardized == currentPath {
                needsListRefresh = true
            }
            if watchedSidebarPaths.contains(path) || watchedSidebarPaths.contains(standardized) {
                needsSidebarRefresh = true
            }
        }

        if needsListRefresh {
            refreshCurrentTab()
        }
        if needsSidebarRefresh {
            sidebarReloadToken += 1
        }
    }

    // MARK: - Undo-aware File Operations

    /// Move files to a destination folder with undo support.
    func moveWithUndo(urls: [URL], to destination: URL) {
        // Check for conflicts first
        var conflicting: [String] = []
        for url in urls {
            let target = destination.appendingPathComponent(url.lastPathComponent)
            guard url.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL else { continue }
            if FileManager.default.fileExists(atPath: target.path) {
                conflicting.append(url.lastPathComponent)
            }
        }
        if !conflicting.isEmpty {
            let alert = NSAlert()
            alert.messageText = "File\(conflicting.count == 1 ? "" : "s") Already Exist\(conflicting.count == 1 ? "s" : "")"
            if conflicting.count == 1 {
                alert.informativeText = "\"\(conflicting[0])\" already exists in \"\(destination.lastPathComponent)\". The item was not moved."
            } else {
                let names = conflicting.prefix(5).map { "\"\($0)\"" }.joined(separator: ", ")
                let extra = conflicting.count > 5 ? " and \(conflicting.count - 5) more" : ""
                alert.informativeText = "\(names)\(extra) already exist in \"\(destination.lastPathComponent)\". The items were not moved."
            }
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        var movedPairs: [(from: URL, to: URL)] = []
        for url in urls {
            let target = destination.appendingPathComponent(url.lastPathComponent)
            guard url.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL else { continue }
            do {
                try FileManager.default.moveItem(at: url, to: target)
                movedPairs.append((from: url, to: target))
            } catch {}
        }
        guard !movedPairs.isEmpty else { return }

        undoManager.registerUndo(withTarget: self) { [movedPairs] state in
            for pair in movedPairs {
                try? FileManager.default.moveItem(at: pair.to, to: pair.from)
            }
            state.refreshCurrentTab()
            state.sidebarReloadToken += 1
            state.syncUndoState()
            state.undoManager.registerUndo(withTarget: state) { redoState in
                redoState.moveWithUndo(urls: movedPairs.map(\.from), to: destination)
            }
            state.undoManager.setActionName("Move")
        }
        undoManager.setActionName("Move")
        sidebarReloadToken += 1
        syncUndoState()
    }

    /// Rename a file/folder with undo support. Returns the new URL.
    @discardableResult
    func renameWithUndo(at url: URL, to newName: String) -> URL? {
        let oldName = url.lastPathComponent
        guard !newName.isEmpty, newName != oldName else { return nil }
        let directory = url.deletingLastPathComponent()
        let newURL = directory.appendingPathComponent(newName)

        // Guard against clobbering an existing item at the target name.
        // Decision delegated to GuardLogic (unit-tested); presentation stays here.
        if GuardLogic.renameShouldBlock(oldName: oldName, newName: newName, in: directory) {
            let alert = NSAlert()
            alert.messageText = "Name Already Taken"
            alert.informativeText = "An item named \"\(newName)\" already exists in this folder. \"\(oldName)\" was not renamed."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }

        do {
            try FileManager.default.moveItem(at: url, to: newURL)
        } catch {
            return nil
        }

        undoManager.registerUndo(withTarget: self) { state in
            state.renameWithUndo(at: newURL, to: oldName)
            state.refreshCurrentTab()
        }
        undoManager.setActionName("Rename \"\(oldName)\"")
        sidebarReloadToken += 1
        syncUndoState()
        return newURL
    }

    /// Move files to trash with undo support. Returns true if operation succeeded.
    @discardableResult
    func trashWithUndo(urls: [URL]) -> Bool {
        var trashedPairs: [(original: URL, trash: URL)] = []
        for url in urls {
            do {
                if let trashURL = try fileService.moveToTrash(url) {
                    trashedPairs.append((original: url, trash: trashURL))
                }
            } catch {}
        }
        guard !trashedPairs.isEmpty else { return false }

        undoManager.registerUndo(withTarget: self) { [trashedPairs] state in
            for pair in trashedPairs {
                try? FileManager.default.moveItem(at: pair.trash, to: pair.original)
            }
            state.refreshCurrentTab()
            state.sidebarReloadToken += 1
            state.syncUndoState()
            // Register redo
            state.undoManager.registerUndo(withTarget: state) { redoState in
                redoState.trashWithUndo(urls: trashedPairs.map(\.original))
            }
            state.undoManager.setActionName("Move to Trash")
        }
        undoManager.setActionName("Move to Trash")
        sidebarReloadToken += 1
        syncUndoState()
        return true
    }

    /// Trash the current tab's selected items: computes the next selection,
    /// confirms non-empty folders, trashes with undo, then reselects.
    /// Extracted from the view so the command-handler body stays type-checkable.
    func trashSelectedInCurrentTab() {
        guard let tab = currentTab else { return }
        let items = tab.items.filter { tab.selectedItems.contains($0.id) }
        guard !items.isEmpty else { return }

        let allItems = tab.items
        let deletedIDs = Set(items.map(\.id))
        var nextName: String?
        if let lastIndex = allItems.lastIndex(where: { deletedIDs.contains($0.id) }) {
            if lastIndex + 1 < allItems.count, !deletedIDs.contains(allItems[lastIndex + 1].id) {
                nextName = allItems[lastIndex + 1].name
            } else if let prev = allItems[0...lastIndex].last(where: { !deletedIDs.contains($0.id) }) {
                nextName = prev.name
            }
        }

        // Confirm before trashing non-empty folders (packages excluded).
        let nonEmptyFolders = items.filter { item in
            item.isDirectory
                && !((try? item.url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false)
                && !fileService.isDirectoryEmpty(item.url)
        }
        if !nonEmptyFolders.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Move to Trash?"
            if nonEmptyFolders.count == 1 {
                alert.informativeText = "\"\(nonEmptyFolders[0].name)\" is not empty. Are you sure?"
            } else {
                alert.informativeText = "\(nonEmptyFolders.count) folders are not empty. Are you sure?"
            }
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        trashWithUndo(urls: items.map(\.url))
        refreshCurrentTab()
        // refreshCurrentTab() repopulates tab.items synchronously,
        // so reselect immediately rather than racing a fixed timer.
        if let nextName, let item = tab.items.first(where: { $0.name == nextName }) {
            tab.selectedItems = [item.id]
            scrollToItemID = item.id
        }
    }

    /// Copy the current tab's selected item URLs to the pasteboard.
    func copySelectedInCurrentTab() {
        guard let tab = currentTab else { return }
        let items = tab.items.filter { tab.selectedItems.contains($0.id) }
        guard !items.isEmpty else { return }
        let urls: [NSURL] = items.map { $0.url as NSURL }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls)
    }

    /// Paste file URLs from the pasteboard into the current tab, with undo,
    /// then select the pasted items. Extracted from the view body.
    func pasteIntoCurrentTab() {
        guard let tab = currentTab else { return }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objects = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options),
              let urls = objects as? [URL], !urls.isEmpty else { return }

        let pastedURLs = pasteWithUndo(urls: urls, to: tab.currentPath)
        refreshCurrentTab()
        guard let lastURL = pastedURLs.last else { return }

        let pastedNames: Set<String> = Set(pastedURLs.map { $0.lastPathComponent })
        guard tab.items.contains(where: { $0.name == lastURL.lastPathComponent }) else { return }
        let selectedIDs = tab.items.filter { pastedNames.contains($0.name) }.map { $0.id }
        tab.selectedItems = Set(selectedIDs)
        if let scrollItem = tab.items.first(where: { $0.name == lastURL.lastPathComponent }) {
            scrollToItemID = scrollItem.id
        }
    }

    /// Create a folder with undo support. Returns the created folder URL.
    @discardableResult
    func createFolderWithUndo(at parent: URL, name: String) -> URL? {
        guard (try? fileService.createFolder(at: parent, name: name)) != nil else { return nil }
        let folderURL = parent.appendingPathComponent(name)

        undoManager.registerUndo(withTarget: self) { state in
            try? FileManager.default.removeItem(at: folderURL)
            state.refreshCurrentTab()
            state.sidebarReloadToken += 1
            state.syncUndoState()
            // Register redo
            state.undoManager.registerUndo(withTarget: state) { redoState in
                redoState.createFolderWithUndo(at: parent, name: name)
            }
            state.undoManager.setActionName("New Folder")
        }
        undoManager.setActionName("New Folder")
        sidebarReloadToken += 1
        syncUndoState()
        return folderURL
    }

    /// Paste (copy) files with undo support.
    func pasteWithUndo(urls: [URL], to destination: URL) -> [URL] {
        var pastedURLs: [URL] = []
        for url in urls {
            let target = destination.appendingPathComponent(url.lastPathComponent)
            let finalTarget = uniqueURL(for: target)
            do {
                try FileManager.default.copyItem(at: url, to: finalTarget)
                pastedURLs.append(finalTarget)
            } catch {}
        }
        guard !pastedURLs.isEmpty else { return [] }

        undoManager.registerUndo(withTarget: self) { [pastedURLs] state in
            for url in pastedURLs {
                try? FileManager.default.removeItem(at: url)
            }
            state.refreshCurrentTab()
            state.syncUndoState()
            // Register redo
            state.undoManager.registerUndo(withTarget: state) { redoState in
                _ = redoState.pasteWithUndo(urls: urls, to: destination)
            }
            state.undoManager.setActionName("Paste")
        }
        undoManager.setActionName("Paste")
        syncUndoState()
        return pastedURLs
    }

    /// Returns a unique file URL by appending " copy", " copy 2", etc.
    func uniqueURL(for url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let baseName = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var counter = 0
        while true {
            let suffix = counter == 0 ? " copy" : " copy \(counter + 1)"
            let newName = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
            let candidate = dir.appendingPathComponent(newName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    @discardableResult
    func addTab(path: URL? = nil) -> TabState {
        let tab = TabState(path: path)
        tabs.append(tab)
        activeTabID = tab.id
        refreshCurrentTab()
        return tab
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 0 else { return }
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            let tab = tabs[index]
            tab.cancelSearch()
            tabs.remove(at: index)
            if activeTabID == id {
                let newIndex = min(index, tabs.count - 1)
                activeTabID = tabs.indices.contains(newIndex) ? tabs[newIndex].id : nil
            }
        }
    }

    func closeCurrentTab() {
        guard let id = activeTabID else { return }
        closeTab(id)
    }

    func refreshCurrentTab() {
        guard let tab = currentTab else { return }
        if tab.isSearchTab { return }
        tab.items = fileService.contentsOfDirectory(
            at: tab.currentPath,
            showHidden: showHiddenFiles
        )
    }

    /// Create a search tab and start async search with streaming results.
    func performSearch(query: String, from path: URL) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let tab = TabState(searchQuery: trimmed, rootPath: path)
        tabs.append(tab)
        activeTabID = tab.id

        let cancelFlag = CancelFlag()
        let service = self.fileService
        let showHidden = self.showHiddenFiles

        let task = Task.detached {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    var didResume = false
                    service.searchFiles(
                        in: path,
                        query: trimmed,
                        showHidden: showHidden,
                        isCancelled: { cancelFlag.isCancelled },
                        onProgress: { newItems, scanned, isComplete in
                            if !newItems.isEmpty {
                                tab.items.append(contentsOf: newItems)
                            }
                            tab.filesScanned = scanned
                            if isComplete {
                                tab.isSearching = false
                                if !didResume {
                                    didResume = true
                                    cont.resume()
                                }
                            }
                        }
                    )
                }
            } onCancel: {
                cancelFlag.cancel()
            }
        }
        tab.searchTask = task
    }

    func navigate(to url: URL) {
        guard let tab = currentTab else { return }
        tab.navigate(to: url)
        // Defer filesystem read to next run loop so UI updates instantly
        DispatchQueue.main.async { [self] in
            refreshCurrentTab()
            rebuildWatcher()
        }
    }
}

/// Thread-safe cancellation flag for bridging Task cancellation to GCD.
final class CancelFlag: @unchecked Sendable {
    private var _cancelled = false
    private let lock = NSLock()

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        lock.unlock()
    }
}
