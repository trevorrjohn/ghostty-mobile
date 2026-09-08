import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host: Host
    @State private var showingKeyImport = false

    init(host: Host) { _host = State(initialValue: host) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Alias (optional)", text: $host.alias)
                    TextField("Hostname or IP", text: $host.hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $host.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $host.port, format: .number)
                        .keyboardType(.numberPad)
                }
                Section("Authentication") {
                    Picker("Method", selection: $host.authenticationType) {
                        ForEach(AuthenticationType.allCases) { Text($0.label).tag($0) }
                    }
                    if host.authenticationType == .sshKey {
                        Picker("Private key", selection: $host.identityID) {
                            Text("Choose a key").tag(UUID?.none)
                            ForEach(model.keys) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        Button("Add SSH key") { showingKeyImport = true }
                    }
                }
                Section("Reconnect") {
                    Toggle("Retry after network loss", isOn: $host.retryEnabled)
                    Stepper(
                        "Maximum attempts: \(host.retryMaxAttempts)",
                        value: $host.retryMaxAttempts,
                        in: 1...10
                    )
                    .disabled(!host.retryEnabled)
                    Picker("Backoff", selection: $host.retryBackoff) {
                        ForEach(RetryBackoff.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!host.retryEnabled)
                    Text("Automatic retry is available only for SSH keys that do not require a passphrase. A reconnect always starts a new shell.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Remote requests") {
                    permissionPicker("Clipboard", selection: $host.remoteClipboard)
                    permissionPicker("Notifications", selection: $host.remoteNotifications)
                }
                Section("Files") {
                    Toggle("Allow remote deletion", isOn: Binding(
                        get: { host.allowSftpDelete == true },
                        set: { host.allowSftpDelete = $0 }
                    ))
                    Text("Deletion still requires confirmation for every file or empty directory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.ghosttySurface)
            .navigationTitle(host.hostname.isEmpty ? "Add host" : "Edit host")
            .onChange(of: host.authenticationType) { _, authenticationType in
                guard authenticationType == .sshKey,
                      host.identityID == nil,
                      model.keys.count == 1 else { return }
                host.identityID = model.keys[0].id
            }
            .sheet(isPresented: $showingKeyImport) {
                KeyImportView { key in host.identityID = key.id }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.save(host: host); dismiss() }
                        .disabled(host.hostname.trimmingCharacters(in: .whitespaces).isEmpty || host.username.trimmingCharacters(in: .whitespaces).isEmpty || !(1...65535).contains(host.port) || (host.authenticationType == .sshKey && host.identityID == nil))
                }
            }
        }
    }

    private func permissionPicker(_ title: String, selection: Binding<RemotePermission>) -> some View {
        Picker(title, selection: selection) {
            ForEach(RemotePermission.allCases) { Text($0.label).tag($0) }
        }
    }
}
