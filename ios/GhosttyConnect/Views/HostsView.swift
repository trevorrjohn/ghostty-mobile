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
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Seance Shell")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("A fast, native SSH terminal")
                            .foregroundStyle(Color.ghosttySecondary)
                    }

                    if !sessions.records.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Active Sessions")
                                .font(.headline)
                            ForEach(sessions.records) { record in
                                ActiveSessionCard(
                                    record: record,
                                    open: { path = [record.id] },
                                    close: { Task { await sessions.close(id: record.id) } }
                                )
                            }
                        }
                    }

                    if model.hosts.isEmpty {
                        EmptyHostsView(add: { editedHost = Host() })
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(model.hosts) { host in
                                HStack(spacing: 8) {
                                    Button { startSession(for: host) } label: { HostCard(host: host) }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button("Edit") { editedHost = host }
                                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                                editedHost = host.duplicated(existingNames: model.hosts.map(\.name))
                                            }
                                            Button("Delete", role: .destructive) { model.delete(host: host) }
                                        }
                                    NavigationLink {
                                        SFTPBrowserScreen(host: host)
                                    } label: {
                                        Image(systemName: "folder")
                                            .font(.title3.weight(.semibold))
                                            .foregroundStyle(Color.ghosttyAccent)
                                            .frame(width: 48, height: 48)
                                            .background(Color.ghosttyRaised, in: RoundedRectangle(cornerRadius: 14))
                                    }
                                    .accessibilityLabel("Browse files on \(host.name)")
                                }
                            }
                        }
                    }

                    HStack {
                        ActionButton(title: "Add host", icon: "plus", action: { editedHost = Host() })
                        ActionButton(title: "Import key", icon: "key", action: { showingKeyImport = true })
                        ActionButton(title: "Preview", icon: "rectangle.on.rectangle", action: { showingPreview = true })
                    }
                }
                .padding(20)
            }
            .background(Color.ghosttySurface.ignoresSafeArea())
            .navigationDestination(for: UUID.self) { sessionID in
                if let record = sessions.record(id: sessionID) {
                    TerminalScreen(record: record) { selectedID in path = [selectedID] }
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
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
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
            }
            .buttonStyle(.plain)
            Button("Disconnect", role: .destructive, action: close)
                .font(.caption.bold())
        }
        .padding(14)
        .background(Color.ghosttyRaised, in: RoundedRectangle(cornerRadius: 14))
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
                Text("Your terminals, one tap away")
                    .font(.headline)
                Text("Add an SSH host. Credentials stay on this device and passwords are never saved.")
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

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(Color.ghosttyAccent)
                .frame(width: 42, height: 42)
                .background(Color.ghosttyAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(host.name).font(.headline)
                Text(host.destination).font(.system(.subheadline, design: .monospaced)).foregroundStyle(Color.ghosttySecondary)
                Text(host.authenticationType.label).font(.caption).foregroundStyle(Color.ghosttyAccent)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Color.ghosttySecondary)
        }
        .padding(16)
        .background(Color.ghosttyRaised, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.ghosttyRaised, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
