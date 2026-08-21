import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Terminal") {
                    Picker("Theme", selection: $model.settings.themeID) {
                        ForEach(TerminalTheme.all) { Text($0.name).tag($0.id) }
                    }
                    VStack(alignment: .leading) {
                        HStack { Text("Font size"); Spacer(); Text("\(Int(model.settings.fontSize)) pt").foregroundStyle(Color.ghosttySecondary) }
                        Slider(value: $model.settings.fontSize, in: 9...30, step: 1).tint(.ghosttyAccent)
                    }
                }
                Section("Security") {
                    LabeledContent("Saved hosts", value: "\(model.hosts.count)")
                    LabeledContent("Imported keys", value: "\(model.keys.count)")
                    Text("Profiles and private keys are stored in the device-only Keychain. Passwords and passphrases are never saved.")
                        .font(.caption)
                        .foregroundStyle(Color.ghosttySecondary)
                }
                Section("About") {
                    LabeledContent("Version", value: "0.1.0")
                    LabeledContent("Terminal engine", value: TerminalEngineFactory.isAvailable ? "Ghostty VT" : "Unavailable")
                    LabeledContent("SSH transport", value: "Citadel")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.ghosttySurface)
            .navigationTitle("Settings")
        }
    }
}
