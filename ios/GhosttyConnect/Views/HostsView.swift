import SwiftUI

struct HostsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessions: TerminalSessionRegistry
    @State private var editedHost: Host?
    @State private var showingKeyImport = false
    @State private var showingPreview = false
    @State private var showingQuickConnect = false
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Seance Shell")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                            Text("Your remote workspace")
                                .font(.subheadline)
                                .foregroundStyle(Color.ghosttySecondary)
                        }
                        Spacer()
                        Menu {
                            NavigationLink("Settings", destination: SettingsView())
                            Button("Import SSH key", systemImage: "key") { showingKeyImport = true }
                            Button("Renderer preview", systemImage: "rectangle.on.rectangle") { showingPreview = true }
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(Color.ghosttySecondary)
                                .frame(width: 48, height: 48)
                                .background(Color.ghosttyRaised, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .accessibilityLabel("App menu")
                    }

                    HStack {
                        Text("Hosts").font(.title3.bold())
                        Spacer()
                        Button { editedHost = Host() } label: {
                            Label("Add host", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background(Color.ghosttyRaised, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }

                    if model.hosts.isEmpty {
                        EmptyHostsView(add: { editedHost = Host() })
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(model.hosts) { host in
                                HostCard(
                                    host: host,
                                    open: { startSession(for: host) },
                                    edit: { editedHost = host },
                                    duplicate: { editedHost = host.duplicated(existingNames: model.hosts.map(\.name)) },
                                    delete: { model.delete(host: host) }
                                )
                            }
                        }
                    }

                    if !sessions.records.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Terminal sessions").font(.title3.bold())
                            ForEach(sessions.records) { record in
                                ActiveSessionCard(
                                    record: record,
                                    savedHost: model.hosts.first { $0.id == record.host.id },
                                    open: { path = [record.id] },
                                    duplicate: { startSession(for: record.host) },
                                    close: { Task { await sessions.close(id: record.id) } }
                                )
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.ghosttySurface.ignoresSafeArea())
            .navigationDestination(for: UUID.self) { sessionID in
                if let record = sessions.record(id: sessionID) {
                    TerminalScreen(record: record, showHosts: { path = [] }) { selectedID in path = [selectedID] }
                        .id(record.id)
                } else {
                    ContentUnavailableView("Session Closed", systemImage: "terminal", description: Text("This session is no longer active."))
                }
            }
            .sheet(item: $editedHost) { HostEditorView(host: $0) }
            .sheet(isPresented: $showingKeyImport) { KeyImportView() }
            .sheet(isPresented: $showingPreview) { TerminalPreview() }
            .confirmationDialog("Quick connect", isPresented: $showingQuickConnect) {
                ForEach(model.hosts) { host in
                    Button("\(host.name) — \(host.destination)") { startSession(for: host) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose a saved host.")
            }
            .onChange(of: model.quickConnectRequest) { _, request in
                guard request != nil else { return }
                switch model.hosts.count {
                case 0: editedHost = Host()
                case 1: startSession(for: model.hosts[0])
                default: showingQuickConnect = true
                }
            }
        }
    }

    private func startSession(for host: Host) {
        path = [sessions.create(for: host)]
    }
}

private struct ActiveSessionCard: View {
    @ObservedObject var record: TerminalSessionRecord
    let savedHost: Host?
    let open: () -> Void
    let duplicate: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(record.host.name).font(.headline)
                        Text(record.shortID)
                            .font(.system(.caption2, design: .monospaced).bold())
                            .foregroundStyle(Color.ghosttyAccent)
                    }
                    Text(record.host.destination)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.ghosttySecondary)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(record.status) · \(duration(record.elapsedSeconds))")
                            .font(.caption)
                            .foregroundStyle(Color.ghosttySecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("Session settings", systemImage: "gearshape") { record.showingSettings = true; open() }
                    Button("Duplicate session", systemImage: "plus.square.on.square", action: duplicate)
                    Button("Disconnect", role: .destructive, action: close)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Color.ghosttySecondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Session actions for \(record.host.name) \(record.shortID)")
            }
            HStack(spacing: 8) {
                Button(action: open) { HostIndexActionLabel(title: "Terminal", icon: "terminal", emphasized: true) }
                if let savedHost {
                    NavigationLink {
                        SFTPBrowserScreen(host: savedHost, initialPath: terminalDirectoryPath(record.session.snapshot?.workingDirectory))
                    } label: { HostIndexActionLabel(title: "Files", icon: "folder", emphasized: false) }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.ghosttyRaised, in: RoundedRectangle(cornerRadius: 18))
    }

    private func duration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct EmptyHostsView: View {
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            VStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(Color.ghosttyAccent)
                Text("Your first connection")
                    .font(.headline)
                Text("Save a host to open its terminal or browse its files.")
                    .font(.subheadline)
                    .foregroundStyle(Color.ghosttySecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(32)
            .background(Color.ghosttyRaised, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

private struct HostCard: View {
    let host: Host
    let open: () -> Void
    let edit: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.name).font(.title3.bold())
                    Text(host.destination).font(.system(.caption, design: .monospaced)).foregroundStyle(Color.ghosttySecondary)
                    Text(host.authenticationType.label).font(.caption).foregroundStyle(Color.ghosttySecondary)
                }
                Spacer()
                Menu {
                    Button("Edit host", systemImage: "pencil", action: edit)
                    Button("Duplicate host", systemImage: "plus.square.on.square", action: duplicate)
                    Button("Delete host", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Color.ghosttySecondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Host actions for \(host.name)")
            }
            HStack(spacing: 8) {
                Button(action: open) { HostIndexActionLabel(title: "Terminal", icon: "terminal", emphasized: true) }
                NavigationLink { SFTPBrowserScreen(host: host) } label: {
                    HostIndexActionLabel(title: "Files", icon: "folder", emphasized: false)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.ghosttyRaised, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct HostIndexActionLabel: View {
    let title: String
    let icon: String
    let emphasized: Bool

    var body: some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(emphasized ? Color.ghosttySurface : Color.primary)
            .background(emphasized ? Color.ghosttyAccent : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
