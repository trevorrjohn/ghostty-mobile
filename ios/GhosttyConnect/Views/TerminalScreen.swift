import SwiftUI

struct TerminalScreen: View {
    let host: Host
    @EnvironmentObject private var model: AppModel
    @State private var secret = ""
    @State private var showingCredential = false

    var body: some View {
        let theme = TerminalTheme.theme(id: model.settings.themeID)
        VStack(spacing: 0) {
            ScrollView {
                Text("Ghostty Connect iOS\n\nNative SSH and libghostty-vt are not linked in this source checkout. Build the pinned Ghostty XCFramework and provide an SSHTransport implementation before connecting to \(host.destination).")
                    .font(.system(size: model.settings.fontSize, design: .monospaced))
                    .foregroundStyle(theme.foreground)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding()
            }
            .background(theme.background)
            HStack(spacing: 18) {
                ForEach(["esc", "ctrl", "alt", "tab", "↑", "↓", "←", "→"], id: \.self) { key in
                    Text(key.uppercased()).font(.system(.caption2, design: .monospaced).weight(.semibold))
                }
            }
            .padding(.horizontal)
            .frame(height: 44)
            .foregroundStyle(Color.ghosttyAccent)
            .background(Color.ghosttyRaised)
        }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            showingCredential = host.authenticationType == .password || model.keys.first(where: { $0.name == host.keyName })?.requiresPassphrase == true
        }
        .onDisappear { secret = "" }
        .alert(host.authenticationType == .password ? "Password" : "Key passphrase", isPresented: $showingCredential) {
            SecureField("Not saved", text: $secret)
            Button("Continue") { secret = ""; model.alertMessage = "SSH transport is not linked yet." }
            Button("Cancel", role: .cancel) { secret = "" }
        } message: {
            Text("Enter the credential for \(host.destination). It remains in memory only for this connection.")
        }
    }
}

struct TerminalPreview: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let theme = TerminalTheme.theme(id: model.settings.themeID)
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ghostty renderer preview").foregroundStyle(theme.cursor).bold()
                Text("$ printf 'Hello from iOS\\n'")
                Text("Hello from iOS")
                HStack(spacing: 0) {
                    Text("ANSI ").foregroundStyle(.red)
                    Text("truecolor ").foregroundStyle(.green)
                    Text("Unicode: λ 日本語")
                }
                Text("█").foregroundStyle(theme.cursor)
                Spacer()
            }
            .font(.system(size: model.settings.fontSize, design: .monospaced))
            .foregroundStyle(theme.foreground)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Renderer preview")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
