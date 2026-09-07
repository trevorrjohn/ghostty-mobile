import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SFTPBrowserScreen: View {
    let host: Host
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = SFTPBrowserModel()
    @State private var secret = ""
    @State private var showingCredential = false
    @State private var showingImporter = false
    @State private var showingNewFolder = false
    @State private var showingLocations = false
    @State private var newFolderName = ""
    @State private var selectedEntry: SFTPEntry?
    @State private var exportItem: SFTPExportItem?
    @State private var previewURL: URL?
    @State private var showingTerminal = false
    @State private var pendingUpload: SFTPPendingUpload?

    private var selectedKey: StoredKey? { app.key(for: host) }
    private var hostTrustBinding: Binding<HostTrustRequest?> {
        Binding(
            get: { browser.pendingHostTrust },
            set: { request in
                if request == nil, let pending = browser.pendingHostTrust {
                    browser.answerHostTrust(requestID: pending.id, accepted: false)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            statusView
            if let transfer = browser.transfer { transferView(transfer) }
            fileList
        }
        .background(Color.ghosttySurface.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(.hidden)
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { gesture in
            guard gesture.startLocation.x <= 28,
                  gesture.translation.width >= 72,
                  abs(gesture.translation.width) > abs(gesture.translation.height) else { return }
            if browser.canNavigateBack { Task { await browser.navigateBack() } }
            else { dismiss() }
        })
        .onAppear { requestConnection() }
        .onDisappear {
            secret = ""
            if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
            if let exportItem { try? FileManager.default.removeItem(at: exportItem.url) }
            previewURL = nil
            exportItem = nil
            Task { await browser.disconnect() }
        }
        .alert(host.authenticationType == .password ? "Password" : "Key passphrase", isPresented: $showingCredential) {
            SecureField("Not saved", text: $secret)
            Button("Connect") {
                let credential = secret
                secret = ""
                Task { await browser.connect(to: host, secret: credential, key: selectedKey) }
            }
            Button("Cancel", role: .cancel) { secret = "" }
        } message: {
            Text("Enter the credential for \(host.destination). It remains in memory only for this connection.")
        }
        .alert("New folder", isPresented: $showingNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await browser.createDirectory(named: name) }
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("File browser", isPresented: Binding(
            get: { browser.errorMessage != nil },
            set: { if !$0 { browser.errorMessage = nil } }
        )) {
            Button("OK") { browser.errorMessage = nil }
        } message: { Text(browser.errorMessage ?? "") }
        .sheet(item: $selectedEntry) { entry in
            SFTPEntryDetails(
                entry: entry,
                allowDelete: host.allowSftpDelete == true,
                open: { open(entry) },
                download: { download(entry, preview: false) },
                rename: { name in Task { await browser.rename(entry, to: name) } },
                delete: { Task { await browser.delete(entry) } }
            )
        }
        .sheet(isPresented: $showingLocations) {
            SFTPLocationsView(
                currentPath: browser.path,
                favorites: browser.favorites,
                recent: browser.recentPaths,
                toggleFavorite: browser.toggleCurrentFavorite,
                navigate: { path in Task { await browser.navigate(to: path) } },
                clearRecent: browser.clearRecentPaths
            )
        }
        .sheet(item: hostTrustBinding) { request in
            HostTrustView(
                request: request,
                reject: { browser.answerHostTrust(requestID: request.id, accepted: false) },
                accept: { browser.answerHostTrust(requestID: request.id, accepted: true) }
            )
        }
        .sheet(item: $exportItem) { item in
            SFTPDocumentExporter(url: item.url) {
                try? FileManager.default.removeItem(at: item.url)
                exportItem = nil
            }
        }
        .sheet(isPresented: $showingTerminal) {
            NavigationStack { TerminalScreen(host: host) }
        }
        .sheet(item: $pendingUpload) { upload in
            SFTPUploadNameView(
                upload: upload,
                existingNames: Set(browser.entries.map(\.name))
            ) { name in
                pendingUpload = nil
                Task { await browser.upload(from: upload.url, as: name) }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): pendingUpload = SFTPPendingUpload(url: url)
            case .failure(let error): browser.errorMessage = error.localizedDescription
            }
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { previous, current in
            if current == nil, let previous { try? FileManager.default.removeItem(at: previous) }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            TextField("Current directory or search", text: Binding(
                get: { browser.addressText },
                set: browser.updateAddress
            ))
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit { Task { await browser.submitAddress() } }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color.ghosttyRaised, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHint("Enter a path to navigate, or text to filter this directory")
            browserMenu
                .frame(width: 42, height: 42)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var statusView: some View {
        switch browser.status {
        case .failed(let message):
            VStack(spacing: 8) {
                status(message)
                Button("Retry") { requestConnection() }.buttonStyle(.bordered)
            }
            .padding(.bottom, 10)
        case .disconnected, .connecting, .verifyingHost, .loading, .ready: EmptyView()
        }
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.ghosttySecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
    }

    private var fileList: some View {
        List(browser.visibleEntries) { entry in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon(entry.kind))
                    .foregroundStyle(entry.kind == .directory ? Color.ghosttyAccent : Color.ghosttySecondary)
                    .frame(width: 28)
                Text(entry.name)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if entry.kind == .directory { Task { await browser.open(entry) } }
                else if entry.kind == .file { open(entry) }
            }
            .onLongPressGesture { selectedEntry = entry }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(entry.kind.rawValue), \(entry.name)")
            .accessibilityHint("Double tap to open. Long press for details and actions.")
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if browser.connected && browser.visibleEntries.isEmpty {
                ContentUnavailableView(
                    browser.entries.isEmpty ? "Empty directory" : "No matching files",
                    systemImage: "folder"
                )
            }
        }
        .refreshable { await browser.refresh() }
    }

    private var browserMenu: some View {
        Menu {
            Button("Upload document", systemImage: "square.and.arrow.up") { showingImporter = true }
                .disabled(!browser.connected || browser.transfer != nil)
            Button("New folder", systemImage: "folder.badge.plus") { showingNewFolder = true }
                .disabled(!browser.connected || browser.transfer != nil)
            Button("Locations", systemImage: "star") { showingLocations = true }
                .disabled(!browser.connected)
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await browser.refresh() } }
                .disabled(!browser.connected || browser.transfer != nil)
            Menu("Sort", systemImage: "arrow.up.arrow.down") {
                ForEach(SFTPSort.allCases) { option in
                    Button {
                        browser.sort = option
                    } label: {
                        if browser.sort == option { Label(option.label, systemImage: "checkmark") }
                        else { Text(option.label) }
                    }
                }
            }
            Toggle("Show hidden files", isOn: $browser.showHidden)
            Divider()
            Button("Open terminal", systemImage: "terminal") { showingTerminal = true }
            Button("Disconnect", role: .destructive) {
                Task { await browser.disconnect(); dismiss() }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("File browser menu")
    }

    private func transferView(_ transfer: SFTPTransfer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(transfer.direction == .upload ? "Uploading \(transfer.name)" : "Downloading \(transfer.name)")
                    .font(.caption.bold())
                    .lineLimit(2)
                Spacer()
                Button("Cancel") { Task { await browser.cancelTransfer() } }.font(.caption)
            }
            if let total = transfer.total, total > 0 {
                ProgressView(value: Double(transfer.completed), total: Double(total))
            } else { ProgressView() }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func requestConnection() {
        switch browser.status {
        case .disconnected, .failed: break
        default: return
        }
        if host.authenticationType == .password || selectedKey?.requiresPassphrase == true {
            showingCredential = true
        } else {
            Task { await browser.connect(to: host, secret: nil, key: selectedKey) }
        }
    }

    private func open(_ entry: SFTPEntry) { download(entry, preview: true) }

    private func download(_ entry: SFTPEntry, preview: Bool) {
        let maximumBytes: UInt64 = preview ? 25 * 1024 * 1024 : 2 * 1024 * 1024 * 1024
        if let size = entry.size, size > maximumBytes {
            browser.errorMessage = preview
                ? "This file is too large to preview. Download it instead."
                : SFTPBrowserError.tooLarge.localizedDescription
            return
        }
        selectedEntry = nil
        Task {
            do {
                let url = try await browser.download(entry, maxBytes: maximumBytes)
                if preview { previewURL = url } else { exportItem = SFTPExportItem(url: url) }
            } catch {}
        }
    }

    private func icon(_ kind: SFTPEntryKind) -> String {
        switch kind {
        case .file: "doc"
        case .directory: "folder.fill"
        case .symbolicLink: "link"
        case .unsupported: "questionmark.square.dashed"
        }
    }
}

private struct SFTPEntryDetails: View {
    let entry: SFTPEntry
    let allowDelete: Bool
    let open: () -> Void
    let download: () -> Void
    let rename: (String) -> Void
    let delete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingRename = false
    @State private var showingDelete = false
    @State private var renamedValue = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(entry.name).font(.headline).textSelection(.enabled)
                    detail("Type", entry.kind.rawValue)
                    if let size = entry.size {
                        let formatted = size <= UInt64(Int64.max)
                            ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                            : "Remote size"
                        detail("Size", "\(formatted) (\(size) bytes)")
                    }
                    if let date = entry.modifiedAt { detail("Updated", date.formatted()) }
                    if let date = entry.accessedAt { detail("Accessed", date.formatted()) }
                    if let permissions = entry.permissions { detail("Permissions", String(format: "%04o", permissions & 0o7777)) }
                }
                if entry.isSupported {
                    Section("Actions") {
                        if entry.kind == .file || entry.kind == .directory {
                            Button("Open", action: { dismiss(); open() })
                        }
                        if entry.kind == .file { Button("Download", action: { dismiss(); download() }) }
                        Button("Rename") { renamedValue = entry.name; showingRename = true }
                        if allowDelete {
                            Button(entry.kind == .symbolicLink ? "Delete link" : "Delete", role: .destructive) {
                                showingDelete = true
                            }
                        }
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
            .alert("Rename", isPresented: $showingRename) {
                TextField("Name", text: $renamedValue)
                Button("Rename") { dismiss(); rename(renamedValue) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete \(entry.name)?", isPresented: $showingDelete) {
                Button("Delete", role: .destructive) { dismiss(); delete() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This cannot be undone.") }
        }
        .presentationDetents([.medium, .large])
    }

    private func detail(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).textSelection(.enabled).multilineTextAlignment(.trailing) }
    }
}

private struct SFTPLocationsView: View {
    let currentPath: String
    let favorites: [String]
    let recent: [String]
    let toggleFavorite: () -> Void
    let navigate: (String) -> Void
    let clearRecent: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Current directory") {
                    Text(currentPath).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button(favorites.contains(currentPath) ? "Remove favorite" : "Add favorite") {
                        toggleFavorite()
                    }
                }
                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites, id: \.self) { path in
                            Button(path) { dismiss(); navigate(path) }
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent.filter { $0 != currentPath }, id: \.self) { path in
                            Button(path) { dismiss(); navigate(path) }
                                .font(.system(.body, design: .monospaced))
                        }
                        Button("Clear recent directories", role: .destructive) { clearRecent() }
                    }
                }
            }
            .navigationTitle("Locations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
    }
}

private struct SFTPExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct SFTPPendingUpload: Identifiable {
    let id = UUID()
    let url: URL
}

private struct SFTPUploadNameView: View {
    let upload: SFTPPendingUpload
    let existingNames: Set<String>
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(upload: SFTPPendingUpload, existingNames: Set<String>, submit: @escaping (String) -> Void) {
        self.upload = upload
        self.existingNames = existingNames
        self.submit = submit
        _name = State(initialValue: upload.url.lastPathComponent)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Remote name") {
                    TextField("File name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if existingNames.contains(name) {
                        Text("An entry with this name already exists. Choose another name.")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Upload document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") { submit(name) }
                        .disabled(!validRemoteChildName(name) || existingNames.contains(name))
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct SFTPDocumentExporter: UIViewControllerRepresentable {
    let url: URL
    let completion: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: () -> Void
        init(completion: @escaping () -> Void) { self.completion = completion }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion() }
    }
}
