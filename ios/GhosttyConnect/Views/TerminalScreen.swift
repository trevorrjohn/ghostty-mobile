import SwiftUI

struct TerminalScreen: View {
    let host: Host
    @EnvironmentObject private var model: AppModel
    @Environment(\.displayScale) private var displayScale
    @StateObject private var session = TerminalSessionModel()
    @State private var secret = ""
    @State private var showingCredential = false
    @State private var keyboardFocused = false

    var body: some View {
        let theme = TerminalTheme.theme(id: model.settings.themeID)
        VStack(spacing: 0) {
            statusBar
            if let snapshot = session.snapshot {
                GeometryReader { proxy in
                    TerminalGridView(snapshot: snapshot, fontSize: model.settings.fontSize)
                        .contentShape(Rectangle())
                        .onTapGesture { keyboardFocused = true }
                        .onAppear { resize(to: proxy.size) }
                        .onChange(of: proxy.size) { _, size in resize(to: size) }
                }
            } else {
                Spacer()
            }
            HStack(spacing: 10) {
                ForEach(TerminalKey.allCases) { key in
                    Button(key.label) { session.send(key.sequence) }
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .foregroundStyle(Color.ghosttyAccent)
            .background(Color.ghosttyRaised)
            HStack(spacing: 8) {
                Image(systemName: keyboardFocused ? "keyboard.fill" : "keyboard")
                Text(keyboardFocused ? "Typing directly into terminal" : "Tap terminal to type")
                    .font(.caption)
                Spacer()
                Button(keyboardFocused ? "Hide" : "Show") { keyboardFocused.toggle() }
            }
            .padding(10)
            .foregroundStyle(Color.ghosttySecondary)
            .background(Color.ghosttyRaised)
            TerminalKeyboardCapture(isFocused: $keyboardFocused, onInput: session.send)
                .frame(width: 1, height: 1)
                .opacity(0.01)
        }
        .background(theme.background)
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button("Disconnect") { Task { await session.disconnect() } }
                Button("Forget Host Key", role: .destructive) { model.forgetHostKey(for: host) }
                    .disabled(!canForgetHostKey)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .onAppear {
            if host.authenticationType == .password {
                showingCredential = true
            } else {
                let key = selectedKey
                if key?.requiresPassphrase == true {
                    showingCredential = true
                } else {
                    Task { await session.connect(to: host, secret: nil, key: key) }
                }
            }
        }
        .onDisappear {
            secret = ""
            keyboardFocused = false
            Task { await session.disconnect() }
        }
        .onChange(of: session.state) { _, state in
            if state == .connected { keyboardFocused = true }
        }
        .alert(host.authenticationType == .password ? "Password" : "Key passphrase", isPresented: $showingCredential) {
            SecureField("Not saved", text: $secret)
            Button("Connect") {
                let credential = secret
                secret = ""
                Task { await session.connect(to: host, secret: credential, key: selectedKey) }
            }
            Button("Cancel", role: .cancel) { secret = "" }
        } message: {
            Text("Enter the credential for \(host.destination). It remains in memory only for this connection.")
        }
        .sheet(item: hostTrustBinding) { request in
            HostTrustView(
                request: request,
                reject: { session.answerHostTrust(requestID: request.id, accepted: false) },
                accept: { session.answerHostTrust(requestID: request.id, accepted: true) }
            )
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.state == .connected ? Color.green : Color.ghosttySecondary)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .foregroundStyle(Color.ghosttySecondary)
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(Color.ghosttyRaised)
    }

    private var selectedKey: StoredKey? {
        model.keys.first { $0.name == host.keyName }
    }

    private var statusText: String {
        switch session.state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting to \(host.destination)..."
        case .verifyingHost: "Waiting for host key approval..."
        case .authenticating: "Authenticating..."
        case .connected: "Connected to \(host.destination)"
        case .failed(let message): message
        }
    }

    private var hostTrustBinding: Binding<HostTrustRequest?> {
        Binding(
            get: { session.pendingHostTrust },
            set: { request in
                if request == nil && session.pendingHostTrust != nil {
                    let requestID = session.pendingHostTrust?.id
                    if let requestID {
                        session.answerHostTrust(requestID: requestID, accepted: false)
                    }
                }
            }
        )
    }

    private var canForgetHostKey: Bool {
        switch session.state {
        case .disconnected, .failed: true
        case .connecting, .verifyingHost, .authenticating, .connected: false
        }
    }

    private func resize(to size: CGSize) {
        let dimensions = TerminalDimensions.fit(
            size: size,
            fontSize: model.settings.fontSize,
            displayScale: displayScale
        )
        session.resize(
            columns: dimensions.columns,
            rows: dimensions.rows,
            pixelWidth: dimensions.pixelWidth,
            pixelHeight: dimensions.pixelHeight
        )
    }
}

private struct HostTrustView: View {
    let request: HostTrustRequest
    let reject: () -> Void
    let accept: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label(
                    request.status == .changed ? "Host key changed" : "Unknown host",
                    systemImage: request.status == .changed ? "exclamationmark.triangle.fill" : "lock.shield"
                )
                .font(.title2.bold())
                .foregroundStyle(request.status == .changed ? Color.red : Color.primary)

                Text(request.status == .changed
                     ? "The saved key does not match. Verify the new fingerprint before replacing trust."
                     : "Verify this fingerprint with the server administrator before trusting it.")

                trustField("Destination", request.destination)
                trustField("Algorithm", request.algorithm)
                trustField("Fingerprint", request.fingerprint)
                if let previousFingerprint = request.previousFingerprint {
                    trustField("Previously trusted", previousFingerprint)
                }
                Spacer()
                Button("Reject", role: .cancel, action: reject)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button(request.status == .changed ? "Replace Saved Key" : "Trust Host", action: accept)
                    .buttonStyle(.borderedProminent)
                    .tint(request.status == .changed ? .red : .accentColor)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("Verify SSH Host")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
        .presentationDetents([.large])
    }

    private func trustField(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
}

private enum TerminalKey: String, CaseIterable, Identifiable {
    case escape
    case controlC
    case tab
    case up
    case down
    case left
    case right

    var id: Self { self }
    var label: String {
        switch self {
        case .escape: "ESC"
        case .controlC: "CTRL-C"
        case .tab: "TAB"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        }
    }
    var sequence: String {
        switch self {
        case .escape: "\u{1b}"
        case .controlC: "\u{03}"
        case .tab: "\t"
        case .up: "\u{1b}[A"
        case .down: "\u{1b}[B"
        case .left: "\u{1b}[D"
        case .right: "\u{1b}[C"
        }
    }
}

struct TerminalPreview: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: TerminalSnapshot?
    @State private var errorMessage: String?

    var body: some View {
        let theme = TerminalTheme.theme(id: model.settings.themeID)
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ghostty VT preview").foregroundStyle(theme.cursor).bold()
                if let snapshot {
                    TerminalGridView(snapshot: snapshot, fontSize: model.settings.fontSize)
                } else {
                    Text(errorMessage ?? "Loading Ghostty VT preview...")
                    Spacer()
                }
            }
            .font(.system(size: model.settings.fontSize, design: .monospaced))
            .foregroundStyle(theme.foreground)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Renderer preview")
            .toolbar { Button("Done") { dismiss() } }
            .task { renderPreview() }
        }
    }

    private func renderPreview() {
        do {
            let engine = try TerminalEngineFactory.make(columns: 48, rows: 8)
            engine.feed(Data("$ printf 'Hello from iOS\\n'\r\nHello from \u{1b}[1;32miOS\u{1b}[0m\r\n\u{1b}[38;2;255;121;198mTruecolor\u{1b}[0m · \u{1b}[4munderline\u{1b}[0m\r\nUnicode: λ 日本語\r\n".utf8))
            snapshot = try engine.snapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
