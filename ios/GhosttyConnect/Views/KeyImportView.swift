import SwiftUI
import UniformTypeIdentifiers

struct KeyImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var keyText = ""
    @State private var showingImporter = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Paste an OpenSSH, PEM, or PKCS#8 private key. Encrypted keys request their passphrase only when connecting.")
                    .font(.subheadline)
                    .foregroundStyle(Color.ghosttySecondary)
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
        do { _ = try model.importKey(data: Data(keyText.utf8)); dismiss() }
        catch { errorMessage = error.localizedDescription }
    }
}
