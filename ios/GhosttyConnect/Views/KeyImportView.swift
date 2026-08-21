import SwiftUI
import UniformTypeIdentifiers

struct KeyImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var keyName = ""
    @State private var keyText = ""
    @State private var generatedName = ""
    @State private var showingImporter = false
    @State private var errorMessage: String?
    private let onImport: (StoredKey) -> Void

    init(onImport: @escaping (StoredKey) -> Void = { _ in }) {
        self.onImport = onImport
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Paste an OpenSSH, PEM, or PKCS#8 private key. Encrypted keys request their passphrase only when connecting.")
                    .font(.subheadline)
                    .foregroundStyle(Color.ghosttySecondary)
                Text("SSH connections currently support OpenSSH Ed25519 and RSA keys.")
                    .font(.caption)
                    .foregroundStyle(Color.ghosttySecondary)
                TextField("Key name", text: $keyName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextEditor(text: $keyText)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.ghosttyRaised, in: RoundedRectangle(cornerRadius: 12))
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                Button("Choose file") { showingImporter = true }
                    .buttonStyle(.bordered)
            }
            .padding()
            .background(Color.ghosttySurface.ignoresSafeArea())
            .navigationTitle("Import key")
            .onChange(of: keyText) { _, value in
                guard let details = try? SSHKeyInspector.inspect(
                    Data(value.utf8),
                    existingNames: model.keys.map(\.name)
                ), keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keyName == generatedName else {
                    return
                }
                generatedName = details.suggestedName
                keyName = generatedName
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Import", action: importText).disabled(keyText.isEmpty) }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data, .plainText]) { result in
                do {
                    let url = try result.get()
                    guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
                    defer { url.stopAccessingSecurityScopedResource() }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 1_048_576 else { throw KeyInspectionError.tooLarge }
                    keyText = String(decoding: try Data(contentsOf: url), as: UTF8.self)
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func importText() {
        do {
            let key = try model.importKey(data: Data(keyText.utf8), name: keyName)
            onImport(key)
            dismiss()
        }
        catch { errorMessage = error.localizedDescription }
    }
}
