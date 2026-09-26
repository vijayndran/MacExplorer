import SwiftUI

/// App preferences / settings view.
struct SettingsView: View {
    @AppStorage("showHiddenFiles") private var showHiddenFiles = false
    @AppStorage("showPreview") private var showPreview = true
    @State private var openAtLogin = LoginItemManager.isEnabled

    var body: some View {
        Form {
            Toggle("Show Hidden Files", isOn: $showHiddenFiles)
                .onChange(of: showHiddenFiles) {
                    NotificationCenter.default.post(name: .settingsChanged, object: nil)
                }
            Toggle("Show Preview Pane", isOn: $showPreview)
                .onChange(of: showPreview) {
                    NotificationCenter.default.post(name: .settingsChanged, object: nil)
                }
            Toggle("Open at Login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) {
                    let ok = LoginItemManager.setEnabled(openAtLogin)
                    // Reflect the real system state in case registration was refused.
                    if !ok { openAtLogin = LoginItemManager.isEnabled }
                }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 190)
        .navigationTitle("Settings")
        .onAppear { openAtLogin = LoginItemManager.isEnabled }
    }
}
