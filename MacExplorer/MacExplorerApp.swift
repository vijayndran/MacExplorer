import SwiftUI

@main
struct MacExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ExplorerWindow()
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NotificationCenter.default.post(name: .undoAction, object: nil)
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo") {
                    NotificationCenter.default.post(name: .redoAction, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandGroup(after: .newItem) {
                Button("New Tab") {
                    NotificationCenter.default.post(name: .newTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Tab") {
                    NotificationCenter.default.post(name: .closeTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Copy") {
                    NotificationCenter.default.post(name: .copyFiles, object: nil)
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Paste") {
                    NotificationCenter.default.post(name: .pasteFiles, object: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Toggle Preview") {
                    NotificationCenter.default.post(name: .togglePreview, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            CommandGroup(after: .toolbar) {
                Button("Back") {
                    NotificationCenter.default.post(name: .navigateBack, object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Forward") {
                    NotificationCenter.default.post(name: .navigateForward, object: nil)
                }
                .keyboardShortcut("]", modifiers: .command)

                Button("Move to Trash") {
                    NotificationCenter.default.post(name: .moveToTrash, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

// Notifications for menu commands → active window
extension Notification.Name {
    static let newTab = Notification.Name("MacExplorer.newTab")
    static let closeTab = Notification.Name("MacExplorer.closeTab")
    static let togglePreview = Notification.Name("MacExplorer.togglePreview")
    static let navigateBack = Notification.Name("MacExplorer.navigateBack")
    static let navigateForward = Notification.Name("MacExplorer.navigateForward")
    static let moveToTrash = Notification.Name("MacExplorer.moveToTrash")
    static let copyFiles = Notification.Name("MacExplorer.copyFiles")
    static let pasteFiles = Notification.Name("MacExplorer.pasteFiles")
    static let settingsChanged = Notification.Name("MacExplorer.settingsChanged")
    static let undoAction = Notification.Name("MacExplorer.undo")
    static let redoAction = Notification.Name("MacExplorer.redo")
}

/// Each window gets its own AppState, registered with the global WindowManager.
struct ExplorerWindow: View {
    @State private var appState = AppState()
    @State private var showFullDiskAccessAlert = false
    @State private var hostWindow: NSWindow?

    var body: some View {
        ContentView()
            .environment(appState)
            .background(WindowAccessor(onResolve: setHostWindow))
            .onAppear {
                WindowManager.shared.register(appState)
                checkFullDiskAccess()
                handleLaunchArguments()
            }
            .onDisappear {
                WindowManager.shared.unregister(appState.windowID)
            }
            .onChange(of: appState.shouldClose) {
                if appState.shouldClose {
                    // Close this window if all tabs were dragged out
                    NSApp.keyWindow?.close()
                }
            }
            .modifier(CommandHandlers(appState: appState, isMine: isMyWindowKey))
            .alert("Full Disk Access Required", isPresented: $showFullDiskAccessAlert) {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        let appURL = URL(fileURLWithPath: Bundle.main.executablePath!)
                            .deletingLastPathComponent()
                            .deletingLastPathComponent()
                            .deletingLastPathComponent()
                        NSWorkspace.shared.activateFileViewerSelecting([appURL])
                    }
                }
                Button("Later", role: .cancel) {}
                Button("Don't Ask Again") {
                    UserDefaults.standard.set(true, forKey: "fdaAlertSuppressed")
                }
            } message: {
                Text("MacExplorer needs Full Disk Access to browse all folders.\n\n1. Click \"Open System Settings\" below\n2. Click the + button in Full Disk Access\n3. Select MacExplorer from the Finder window that opens\n\nAlternatively, drag MacExplorer.app into the list.")
            }
            .sheet(isPresented: Binding(
                get: { appState.copyProgress.isActive },
                set: { if !$0 { appState.copyProgress.requestCancel() } }
            )) {
                CopyProgressSheet(progress: appState.copyProgress)
            }
    }

    private func findMyWindow() -> NSWindow? {
        hostWindow
    }

    /// Cheap Bool guard reused by every command handler — pulling this out of
    /// the view body keeps the (already large) modifier chain type-checkable.
    private var isMyWindowKey: Bool {
        hostWindow != nil && NSApp.keyWindow === hostWindow
    }

    private func setHostWindow(_ window: NSWindow?) {
        hostWindow = window
    }

    private func checkFullDiskAccess() {
        // Don't nag if the user already dismissed this or we confirmed access before.
        if UserDefaults.standard.bool(forKey: "fdaAlertSuppressed") { return }

        if Self.hasFullDiskAccess() {
            // Remember success so we never probe-and-prompt again on later launches.
            UserDefaults.standard.set(true, forKey: "fdaAlertSuppressed")
            return
        }
        showFullDiskAccessAlert = true
    }

    /// Real Full Disk Access probe. `isReadableFile` only checks POSIX perms and
    /// is NOT gated by TCC, so it gives false negatives (prompting when access is
    /// actually granted). The reliable signal is whether we can genuinely READ the
    /// CONTENTS of a TCC-protected location — that read is what FDA governs.
    static func hasFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        // TCC-protected locations. We only need ONE to succeed. Try to actually
        // enumerate/read them, not just stat — enumeration is what TCC blocks.
        let protectedDirs = [
            "\(home)/Library/Safari",
            "\(home)/Library/Mail",
            "\(home)/Library/Application Support/com.apple.TCC",
            "/Library/Application Support/com.apple.TCC"
        ]
        for dir in protectedDirs where FileManager.default.fileExists(atPath: dir) {
            if (try? FileManager.default.contentsOfDirectory(atPath: dir)) != nil {
                return true
            }
        }
        // Fallback: try to open the system TCC database for reading (FDA-only).
        let tccDB = "/Library/Application Support/com.apple.TCC/TCC.db"
        if FileManager.default.fileExists(atPath: tccDB),
           let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: tccDB)) {
            try? fh.close()
            return true
        }
        return false
    }

    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        for arg in args.dropFirst() where !arg.hasPrefix("-") {
            let url = URL(fileURLWithPath: arg)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                appState.navigate(to: url)
                return
            }
        }
    }
}

/// Handles folder open events from macOS.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the app icon for the Dock — find it relative to the executable in the .app bundle
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let resourcesURL = execURL
            .deletingLastPathComponent()  // Contents/MacOS
            .deletingLastPathComponent()  // Contents
            .appendingPathComponent("Resources")
            .appendingPathComponent("AppIcon.icns")
        if let icon = NSImage(contentsOf: resourcesURL) {
            NSApp.applicationIconImage = icon
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Open folders in the key window's state, or the first available window
        let targetState = WindowManager.shared.windowStates.values.first
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                targetState?.navigate(to: url)
            }
        }
    }
}

/// Captures the NSWindow hosting this SwiftUI view, so per-window command
/// routing can reliably identify "my" window instead of guessing.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

/// Hosts every menu-command NotificationCenter handler in one modifier so the
/// window's main `body` stays small enough for the Swift type-checker. `isMine`
/// is the "am I the key window" guard, evaluated where the modifier is applied.
private struct CommandHandlers: ViewModifier {
    let appState: AppState
    let isMine: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .newTab)) { _ in
                if isMine { appState.addTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeTab)) { _ in
                if isMine { appState.closeCurrentTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .togglePreview)) { _ in
                if isMine { appState.showPreview.toggle() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateBack)) { _ in
                if isMine {
                    appState.currentTab?.goBack()
                    appState.refreshCurrentTab()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateForward)) { _ in
                if isMine {
                    appState.currentTab?.goForward()
                    appState.refreshCurrentTab()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .moveToTrash)) { _ in
                if isMine { appState.trashSelectedInCurrentTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyFiles)) { _ in
                if isMine { appState.copySelectedInCurrentTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pasteFiles)) { _ in
                if isMine { appState.pasteIntoCurrentTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsChanged)) { _ in
                appState.showPreview = UserDefaults.standard.object(forKey: "showPreview") as? Bool ?? true
                appState.showHiddenFiles = UserDefaults.standard.bool(forKey: "showHiddenFiles")
            }
            .onReceive(NotificationCenter.default.publisher(for: .undoAction)) { _ in
                if isMine, appState.undoManager.canUndo { appState.undoManager.undo() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .redoAction)) { _ in
                if isMine, appState.undoManager.canRedo { appState.undoManager.redo() }
            }
    }
}
