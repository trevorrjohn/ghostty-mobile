import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host: Host

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
                        Picker("Private key", selection: $host.keyName) {
                            Text("Choose a key").tag(String?.none)
                            ForEach(model.keys) { Text($0.name).tag(String?.some($0.name)) }
                        }
                    }
                }
                Section("Remote requests") {
                    permissionPicker("Clipboard", selection: $host.remoteClipboard)
                    permissionPicker("Notifications", selection: $host.remoteNotifications)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.ghosttySurface)
            .navigationTitle(host.hostname.isEmpty ? "Add host" : "Edit host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.save(host: host); dismiss() }
                        .disabled(host.hostname.trimmingCharacters(in: .whitespaces).isEmpty || host.username.trimmingCharacters(in: .whitespaces).isEmpty || !(1...65535).contains(host.port) || (host.authenticationType == .sshKey && host.keyName == nil))
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
