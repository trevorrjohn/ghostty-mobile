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
                    NavigationLink {
                        TrustedHostsView()
                    } label: {
                        LabeledContent("Trusted hosts", value: "\(model.trustedHosts.count)")
                    }
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
            .onAppear { model.reloadTrustedHosts() }
        }
    }
}

private struct TrustedHostsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingRemoval: TrustedHost?

    var body: some View {
        List {
            if model.trustedHosts.isEmpty {
                ContentUnavailableView(
                    "No Trusted Hosts",
                    systemImage: "lock.shield",
                    description: Text("Hosts appear here after you approve their SSH fingerprint.")
                )
            } else {
                ForEach(model.trustedHosts) { trustedHost in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(trustedHost.destination)
                            .font(.headline)
                        Text(trustedHost.algorithm ?? "Invalid record")
                            .font(.caption)
                            .foregroundStyle(trustedHost.error == nil ? Color.ghosttySecondary : Color.red)
                        if let fingerprint = trustedHost.fingerprint {
                            Text(fingerprint)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if let error = trustedHost.error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Color.red)
                        }
                        Button("Remove Trust", role: .destructive) {
                            pendingRemoval = trustedHost
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Trusted Hosts")
        .onAppear { model.reloadTrustedHosts() }
        .alert("Remove trusted host?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                guard let trustedHost = pendingRemoval else { return }
                pendingRemoval = nil
                model.forget(trustedHost: trustedHost)
            }
        } message: {
            Text("The next connection to \(pendingRemoval?.destination ?? "this host") will require fingerprint approval again.")
        }
    }
}
