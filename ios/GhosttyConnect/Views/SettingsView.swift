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
                    NavigationLink {
                        KeyboardBarSettingsView()
                    } label: {
                        LabeledContent(
                            "Keyboard bar",
                            value: model.keyboardBarConfig.enabled ? "\(model.keyboardBarConfig.items.count) keys" : "Off"
                        )
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

private struct KeyboardBarSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editedAction: KeyboardAction?

    private var availableItems: [KeyboardBarItem] {
        let builtIns = KeyboardBarItemID.allCases.map(KeyboardBarItem.builtIn)
        let actions = model.keyboardBarConfig.actions.map { KeyboardBarItem.action($0.id) }
        return (builtIns + actions).filter { !model.keyboardBarConfig.items.contains($0) }
    }

    var body: some View {
        List {
            Section {
                Toggle("Show keyboard bar", isOn: $model.keyboardBarConfig.enabled)
            } footer: {
                Text("The bar appears while terminal keyboard input is active. Modifiers apply once to the next named key or eligible single ASCII letter, number, or space.")
            }

            Section("Controls") {
                if model.keyboardBarConfig.items.isEmpty {
                    Text("No controls configured")
                        .foregroundStyle(Color.ghosttySecondary)
                }
                ForEach(model.keyboardBarConfig.items) { item in
                    Label(label(for: item), systemImage: systemImage(for: item))
                }
                .onMove { source, destination in
                    model.keyboardBarConfig.moveItems(from: source, to: destination)
                }
                .onDelete { offsets in
                    model.keyboardBarConfig.removeItems(at: offsets)
                }
            }

            if !availableItems.isEmpty {
                Section("Add Control") {
                    ForEach(availableItems) { item in
                        Button {
                            model.keyboardBarConfig.append(item)
                        } label: {
                            Label(label(for: item), systemImage: "plus.circle")
                        }
                    }
                }
            }

            Section {
                Button {
                    editedAction = KeyboardAction(label: "", key: .c, modifiers: [.control])
                } label: {
                    Label("Create Custom Action", systemImage: "plus")
                }
                .disabled(model.keyboardBarConfig.actions.count >= KeyboardBarConfig.maximumActions)
                ForEach(model.keyboardBarConfig.actions) { action in
                    Button {
                        editedAction = action
                    } label: {
                        LabeledContent(action.label, value: description(for: action))
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            model.keyboardBarConfig.deleteAction(id: action.id)
                        }
                    }
                }
            } header: {
                Text("Custom Actions")
            } footer: {
                Text("Create up to \(KeyboardBarConfig.maximumActions) actions from a key and Ctrl, Alt, or Shift.")
            }

            Section {
                Button("Reset to Defaults") {
                    model.keyboardBarConfig = .defaults
                }
            }
        }
        .navigationTitle("Keyboard Bar")
        .toolbar { EditButton() }
        .sheet(item: $editedAction) { action in
            KeyboardActionEditor(action: action) { savedAction in
                let isNew = model.keyboardBarConfig.action(id: savedAction.id) == nil
                return model.keyboardBarConfig.saveAction(savedAction, addToBar: isNew)
            }
        }
    }

    private func label(for item: KeyboardBarItem) -> String {
        switch item {
        case .builtIn(let item): item.accessibilityLabel
        case .action(let id): model.keyboardBarConfig.action(id: id)?.label ?? "Custom action"
        }
    }

    private func systemImage(for item: KeyboardBarItem) -> String {
        switch item {
        case .builtIn(let item): item.modifier == nil ? "keyboard" : "option"
        case .action: "command"
        }
    }

    private func description(for action: KeyboardAction) -> String {
        let modifiers = KeyboardModifier.allCases
            .filter(action.modifiers.contains)
            .map(\.label)
        return (modifiers + [action.key.label]).joined(separator: "+")
    }
}

private struct KeyboardActionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var action: KeyboardAction
    let onSave: (KeyboardAction) -> Bool

    init(action: KeyboardAction, onSave: @escaping (KeyboardAction) -> Bool) {
        _action = State(initialValue: action)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Action") {
                    TextField("Label", text: $action.label)
                        .textInputAutocapitalization(.characters)
                    Picker("Key", selection: $action.key) {
                        ForEach(KeyboardActionKey.allCases) { key in
                            Text(key.label).tag(key)
                        }
                    }
                }
                Section("Modifiers") {
                    ForEach(KeyboardModifier.allCases, id: \.self) { modifier in
                        Toggle(modifier.label, isOn: modifierBinding(modifier))
                    }
                }
            }
            .navigationTitle("Custom Action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let saved = onSave(KeyboardAction(
                            id: action.id,
                            label: action.label,
                            key: action.key,
                            modifiers: action.modifiers
                        ))
                        if saved { dismiss() }
                    }
                    .disabled(!action.isValid)
                }
            }
        }
    }

    private func modifierBinding(_ modifier: KeyboardModifier) -> Binding<Bool> {
        Binding {
            action.modifiers.contains(modifier)
        } set: { enabled in
            if enabled { action.modifiers.insert(modifier) }
            else { action.modifiers.remove(modifier) }
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
