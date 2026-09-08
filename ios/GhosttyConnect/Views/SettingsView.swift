import SwiftUI
import UniformTypeIdentifiers

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
                    NavigationLink {
                        IdentitiesView()
                    } label: {
                        LabeledContent("Imported keys", value: "\(model.keys.count)")
                    }
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
                    LabeledContent("Version", value: appVersion)
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

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (\(build))"
    }
}

private struct IdentitiesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var renamedKey: StoredKey?
    @State private var pendingDeletion: StoredKey?
    @State private var name = ""

    var body: some View {
        List {
            if model.keys.isEmpty {
                ContentUnavailableView("No SSH Keys", systemImage: "key", description: Text("Import a key while editing a host."))
            } else {
                ForEach(model.keys) { key in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(key.name).font(.headline)
                        Text(key.algorithm ?? "Private key")
                            .font(.caption)
                            .foregroundStyle(Color.ghosttySecondary)
                        if let fingerprint = key.fingerprint {
                            Text(fingerprint)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if key.requiresPassphrase {
                            Label("Passphrase required", systemImage: "lock")
                                .font(.caption)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { pendingDeletion = key }
                        Button("Rename") { name = key.name; renamedKey = key }
                            .tint(.blue)
                    }
                    .contextMenu {
                        Button("Rename") { name = key.name; renamedKey = key }
                        if let publicKey = key.publicKey {
                            ShareLink(item: publicKey) { Label("Share Public Key", systemImage: "square.and.arrow.up") }
                        }
                        Button("Delete", role: .destructive) { pendingDeletion = key }
                    }
                }
            }
        }
        .navigationTitle("SSH Keys")
        .alert("Rename SSH key", isPresented: Binding(
            get: { renamedKey != nil },
            set: { if !$0 { renamedKey = nil } }
        )) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { renamedKey = nil }
            Button("Rename") {
                guard let key = renamedKey else { return }
                if model.rename(key: key, to: name) { renamedKey = nil }
            }
        } message: {
            Text("Saved hosts continue using this identity after it is renamed.")
        }
        .alert("Delete SSH key?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                guard let key = pendingDeletion else { return }
                pendingDeletion = nil
                model.delete(key: key)
            }
        } message: {
            let affected = pendingDeletion.map(model.hosts(using:)) ?? []
            if affected.isEmpty {
                Text("The private key will be permanently removed from this device.")
            } else {
                Text("The private key will be removed. These hosts will require another identity: \(affected.map(\.name).joined(separator: ", ")).")
            }
        }
    }
}

private struct KeyboardBarSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editedAction: KeyboardAction?
    @State private var draggedItem: KeyboardBarItem?

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
                Text("Tap a modifier for one use or hold it to lock. Locked modifiers remain active until tapped again.")
            }

            Section("Controls") {
                if model.keyboardBarConfig.items.isEmpty {
                    Text("No controls configured")
                        .foregroundStyle(Color.ghosttySecondary)
                }
                ForEach(model.keyboardBarConfig.items) { item in
                    HStack {
                        Label(label(for: item), systemImage: systemImage(for: item))
                        Spacer()
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(Color.ghosttySecondary)
                            .accessibilityLabel("Drag to reorder")
                    }
                    .contentShape(Rectangle())
                    .onDrag {
                        draggedItem = item
                        return NSItemProvider(object: item.id as NSString)
                    }
                    .onDrop(
                        of: [UTType.text],
                        delegate: KeyboardBarDropDelegate(
                            destination: item,
                            draggedItem: $draggedItem,
                            config: $model.keyboardBarConfig
                        )
                    )
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
                Text("Create up to \(KeyboardBarConfig.maximumActions) actions with \(KeyboardAction.maximumSteps) ordered key events.")
            }

            Section {
                Button("Reset to Defaults") {
                    model.keyboardBarConfig = .defaults
                }
            }
        }
        .navigationTitle("Keyboard Bar")
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
        action.steps.map(\.description).joined(separator: ", then ")
    }
}

private struct KeyboardBarDropDelegate: DropDelegate {
    let destination: KeyboardBarItem
    @Binding var draggedItem: KeyboardBarItem?
    @Binding var config: KeyboardBarConfig

    func dropEntered(info: DropInfo) {
        guard let draggedItem,
              draggedItem != destination,
              let from = config.items.firstIndex(of: draggedItem),
              let to = config.items.firstIndex(of: destination)
        else { return }
        config.moveItems(
            from: IndexSet(integer: from),
            to: to > from ? to + 1 : to
        )
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
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
                }
                Section("Events") {
                    ForEach(action.steps.indices, id: \.self) { index in
                        NavigationLink {
                            KeyboardActionStepEditor(step: $action.steps[index], requiresModifier: index == 0)
                        } label: {
                            LabeledContent("Event \(index + 1)", value: action.steps[index].description)
                        }
                    }
                    .onDelete(perform: deleteSteps)
                    .onMove { source, destination in
                        action.steps.move(fromOffsets: source, toOffset: destination)
                    }
                    Button("Add Event", systemImage: "plus") {
                        action.steps.append(KeyboardActionStep(key: .n, modifiers: []))
                    }
                    .disabled(action.steps.count >= KeyboardAction.maximumSteps)
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
                        let saved = onSave(action)
                        if saved { dismiss() }
                    }
                    .disabled(!action.isValid)
                }
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
    }

    private func deleteSteps(at offsets: IndexSet) {
        guard action.steps.count - offsets.count >= 1 else { return }
        action.steps.remove(atOffsets: offsets)
    }
}

private struct KeyboardActionStepEditor: View {
    @Binding var step: KeyboardActionStep
    let requiresModifier: Bool

    var body: some View {
        Form {
            Picker("Key", selection: $step.key) {
                ForEach(KeyboardActionKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
            Section {
                ForEach(KeyboardModifier.allCases, id: \.self) { modifier in
                    Toggle(modifier.label, isOn: modifierBinding(modifier))
                }
            } header: {
                Text("Modifiers")
            } footer: {
                Text(requiresModifier ? "The first event requires at least one modifier." : "Modifiers are optional for this event.")
            }
        }
        .navigationTitle("Key Event")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modifierBinding(_ modifier: KeyboardModifier) -> Binding<Bool> {
        Binding {
            step.modifiers.contains(modifier)
        } set: { enabled in
            if enabled { step.modifiers.insert(modifier) }
            else { step.modifiers.remove(modifier) }
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
