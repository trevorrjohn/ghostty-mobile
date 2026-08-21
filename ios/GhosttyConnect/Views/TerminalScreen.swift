import SwiftUI
import UIKit

struct TerminalScreen: View {
    let host: Host
    @EnvironmentObject private var model: AppModel
    @Environment(\.displayScale) private var displayScale
    @StateObject private var session = TerminalSessionModel()
    @State private var secret = ""
    @State private var showingCredential = false
    @State private var keyboardFocused = false
    @State private var pendingReconnect = false
    @State private var hasRequestedConnection = false
    @State private var keyboardBarState = KeyboardBarRuntimeState()
    @State private var pastePrompt: PastePrompt?

    var body: some View {
        let theme = TerminalTheme.theme(id: model.settings.themeID)
        VStack(spacing: 0) {
            statusBar
            if let snapshot = session.snapshot {
                GeometryReader { proxy in
                    ZStack(alignment: .bottomTrailing) {
                        TerminalGridView(
                            snapshot: snapshot,
                            fontSize: model.settings.fontSize,
                            onTap: { keyboardFocused = true },
                            onScrollRows: session.scrollViewport(byRows:),
                            onSelectWord: session.selectWord(column:row:)
                        )
                        .accessibilityAction(named: "Scroll backward") {
                            session.scrollViewport(byRows: -max(1, snapshot.rows - 1))
                        }
                        .accessibilityAction(named: "Scroll forward") {
                            session.scrollViewport(byRows: max(1, snapshot.rows - 1))
                        }

                        if !snapshot.viewport.isAtBottom {
                            Button {
                                session.scrollToBottom()
                            } label: {
                                Label("Live", systemImage: "arrow.down")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            .padding(12)
                        }
                    }
                    .onAppear { resize(to: proxy.size) }
                    .onChange(of: proxy.size) { _, size in resize(to: size) }
                }
            } else {
                Spacer()
            }
            if model.keyboardBarConfig.enabled && keyboardFocused {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.keyboardBarConfig.items) { item in
                            HStack(spacing: 4) {
                                Text(keyboardBarLabel(item))
                                if isLocked(item) {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 9, weight: .bold))
                                }
                            }
                                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                .padding(.horizontal, 9)
                                .frame(minWidth: 44, minHeight: 44)
                                .foregroundStyle(isActive(item) ? Color.ghosttySurface : Color.ghosttyAccent)
                                .background(
                                    isActive(item) ? Color.ghosttyAccent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                                .contentShape(Rectangle())
                                .gesture(
                                    LongPressGesture(minimumDuration: 0.5)
                                        .exclusively(before: TapGesture())
                                        .onEnded { result in
                                            switch result {
                                            case .first(true):
                                                if resolvedModifier(item) != nil { lockKeyboardBarItem(item) }
                                                else { activateKeyboardBarItem(item) }
                                            case .second: activateKeyboardBarItem(item)
                                            default: break
                                            }
                                        }
                                )
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { activateKeyboardBarItem(item) }
                                .accessibilityLabel(keyboardBarAccessibilityLabel(item))
                                .accessibilityHint(keyboardBarAccessibilityHint(item))
                                .accessibilityValue(keyboardBarAccessibilityValue(item))
                                .accessibilityAddTraits(isActive(item) ? .isSelected : [])
                                .accessibilityActions {
                                    if resolvedModifier(item) != nil {
                                        Button("Lock modifier") { lockKeyboardBarItem(item) }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: 44)
                .background(Color.ghosttyRaised)
                .opacity(session.snapshot?.viewport.isAtBottom == false ? 0 : 1)
                .allowsHitTesting(session.snapshot?.viewport.isAtBottom != false)
            }
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
            TerminalKeyboardCapture(
                isFocused: $keyboardFocused,
                onInput: handleInput,
                canCopy: session.snapshot?.hasSelection == true,
                onCopy: copySelection,
                onPaste: requestPaste
            )
                .frame(width: 1, height: 1)
                .opacity(0.01)
        }
        .background(theme.background)
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button("Paste", systemImage: "doc.on.clipboard") { requestPaste() }
                if session.snapshot?.hasSelection == true {
                    Button("Copy Selection", systemImage: "doc.on.doc") { copySelection() }
                    Button("Clear Selection", systemImage: "xmark") { session.clearSelection() }
                }
                Divider()
                Button("Disconnect") { Task { await session.disconnect() } }
                Button("Forget Host Key", role: .destructive) { model.forgetHostKey(for: host) }
                    .disabled(!canForgetHostKey)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .onAppear {
            requestConnection(isReconnect: false)
        }
        .onDisappear {
            secret = ""
            keyboardFocused = false
            keyboardBarState.reset()
            Task { await session.disconnect() }
        }
        .onChange(of: session.state) { _, state in
            if state == .connected { keyboardFocused = true }
            else { keyboardBarState.reset() }
        }
        .onChange(of: keyboardFocused) { _, focused in
            if !focused { keyboardBarState.consumeOneShot() }
        }
        .alert(host.authenticationType == .password ? "Password" : "Key passphrase", isPresented: $showingCredential) {
            SecureField("Not saved", text: $secret)
            Button(pendingReconnect ? (session.hasConnectedShell ? "Reconnect" : "Retry") : "Connect") {
                let credential = secret
                secret = ""
                let reconnect = session.hasConnectedShell
                Task {
                    await session.connect(
                        to: host,
                        secret: credential,
                        key: selectedKey,
                        isReconnect: reconnect
                    )
                }
            }
            Button("Cancel", role: .cancel) { secret = "" }
        } message: {
            Text("Enter the credential for \(host.destination). It remains in memory only for this connection.")
        }
        .alert(item: $pastePrompt) { prompt in
            switch prompt {
            case .empty:
                Alert(
                    title: Text("Clipboard Empty"),
                    message: Text("The clipboard does not contain text."),
                    dismissButton: .default(Text("OK"))
                )
            case .unsafe(_, let text):
                Alert(
                    title: Text("Paste multiple lines?"),
                    message: Text("This paste contains a newline or terminal control sequence."),
                    primaryButton: .cancel(),
                    secondaryButton: .default(Text("Paste")) { session.paste(text) }
                )
            }
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
            if canReconnect {
                Button(session.hasConnectedShell ? "Reconnect" : "Retry") {
                    requestConnection(isReconnect: true)
                }
                .font(.caption.bold())
            }
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
        case .failed(let failure): failure.message
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

    private var canReconnect: Bool {
        switch session.state {
        case .failed(let failure): failure.canRetry
        case .disconnected: hasRequestedConnection
        case .connecting, .verifyingHost, .authenticating, .connected: false
        }
    }

    private func requestConnection(isReconnect: Bool) {
        hasRequestedConnection = true
        pendingReconnect = isReconnect
        if host.authenticationType == .password || selectedKey?.requiresPassphrase == true {
            showingCredential = true
        } else {
            Task {
                await session.connect(
                    to: host,
                    secret: nil,
                    key: selectedKey,
                    isReconnect: session.hasConnectedShell
                )
            }
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

    private func activateKeyboardBarItem(_ item: KeyboardBarItem) {
        if let modifier = resolvedModifier(item) {
            keyboardBarState.toggle(modifier)
            return
        }
        switch item {
        case .builtIn(let builtIn):
            if builtIn == .lastAction {
                guard let action = resolvedAction(item) else { return }
                send(action)
                return
            }
            guard let key = builtIn.key else { return }
            session.send(.key(key, modifiers: TerminalKeyModifiers(keyboardBarState.activeModifiers)))
            keyboardBarState.consumeOneShot()
        case .action(let id):
            guard let action = model.keyboardBarConfig.action(id: id) else { return }
            send(action)
        }
    }

    private func send(_ action: KeyboardAction) {
        keyboardBarState.recordAction(id: action.id)
        session.send(action.event.adding(TerminalKeyModifiers(keyboardBarState.activeModifiers)))
        keyboardBarState.consumeOneShot()
    }

    private func lockKeyboardBarItem(_ item: KeyboardBarItem) {
        guard let modifier = resolvedModifier(item) else { return }
        keyboardBarState.lock(modifier)
    }

    private func handleInput(_ event: TerminalInputEvent) {
        let modifiers = TerminalKeyModifiers(keyboardBarState.activeModifiers)
        guard !modifiers.isEmpty else {
            session.send(event)
            return
        }
        switch event {
        case .key:
            session.send(event.adding(modifiers))
            keyboardBarState.consumeOneShot()
        case .text(let text, let eventModifiers):
            guard TerminalKey.fromCommittedText(text) != nil else {
                session.send(event)
                return
            }
            let output = TerminalKey.fromCommittedText(text)?
                .generatedText(shifted: modifiers.contains(.shift)) ?? text
            session.send(.text(output, modifiers: eventModifiers.union(modifiers)))
            keyboardBarState.consumeOneShot()
        }
    }

    private func requestPaste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            pastePrompt = .empty(UUID())
            return
        }
        if session.isPasteSafe(text) {
            session.paste(text)
        } else {
            pastePrompt = .unsafe(UUID(), text)
        }
    }

    private func copySelection() {
        let text = session.copySelection()
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    private func isActive(_ item: KeyboardBarItem) -> Bool {
        resolvedModifier(item).map(keyboardBarState.activeModifiers.contains) == true
    }

    private func isLocked(_ item: KeyboardBarItem) -> Bool {
        resolvedModifier(item).map(keyboardBarState.lockedModifiers.contains) == true
    }

    private func resolvedModifier(_ item: KeyboardBarItem) -> KeyboardModifier? {
        guard case .builtIn(let builtIn) = item else { return nil }
        return builtIn == .lastModifier ? keyboardBarState.lastUsedModifier : builtIn.modifier
    }

    private func resolvedAction(_ item: KeyboardBarItem) -> KeyboardAction? {
        switch item {
        case .action(let id): return model.keyboardBarConfig.action(id: id)
        case .builtIn(.lastAction):
            return keyboardBarState.lastUsedActionID.flatMap(model.keyboardBarConfig.action(id:))
        case .builtIn: return nil
        }
    }

    private func keyboardBarLabel(_ item: KeyboardBarItem) -> String {
        switch item {
        case .builtIn(.lastModifier): keyboardBarState.lastUsedModifier?.label.uppercased() ?? "LAST MOD"
        case .builtIn(.lastAction): resolvedAction(item)?.label ?? "LAST ACTION"
        case .builtIn(let item): item.label
        case .action(let id): model.keyboardBarConfig.action(id: id)?.label ?? "ACTION"
        }
    }

    private func keyboardBarAccessibilityLabel(_ item: KeyboardBarItem) -> String {
        switch item {
        case .builtIn(.lastModifier):
            keyboardBarState.lastUsedModifier.map { "Last used modifier, \($0.label)" } ?? "Last used modifier"
        case .builtIn(.lastAction):
            resolvedAction(item).map { "Last used custom action, \($0.label)" } ?? "Last used custom action"
        case .builtIn(let item): item.accessibilityLabel
        case .action(let id): model.keyboardBarConfig.action(id: id)?.label ?? "Custom action"
        }
    }

    private func keyboardBarAccessibilityHint(_ item: KeyboardBarItem) -> String {
        if let modifier = resolvedModifier(item) {
            return keyboardBarState.lockedModifiers.contains(modifier)
                ? "Locked. Tap to turn off."
                : "Tap for one use or hold to lock."
        }
        guard let action = resolvedAction(item) else { return "" }
        let modifiers = KeyboardModifier.allCases
            .filter(action.modifiers.contains)
            .map(\.label)
        return "Sends \((modifiers + [action.key.label]).joined(separator: " plus "))"
    }

    private func keyboardBarAccessibilityValue(_ item: KeyboardBarItem) -> String {
        if isLocked(item) { return "Locked" }
        if isActive(item) { return "One use" }
        return ""
    }
}

private enum PastePrompt: Identifiable {
    case empty(UUID)
    case unsafe(UUID, String)

    var id: UUID {
        switch self {
        case .empty(let id), .unsafe(let id, _): id
        }
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
