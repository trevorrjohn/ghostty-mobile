import SwiftUI

struct HostsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editedHost: Host?
    @State private var showingKeyImport = false
    @State private var showingPreview = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Ghostty Connect")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("A fast, native SSH terminal")
                            .foregroundStyle(Color.ghosttySecondary)
                    }

                    if model.hosts.isEmpty {
                        EmptyHostsView(add: { editedHost = Host() })
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(model.hosts) { host in
                                NavigationLink(value: host) { HostCard(host: host) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Edit") { editedHost = host }
                                        Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicate(host: host) }
                                        Button("Delete", role: .destructive) { model.delete(host: host) }
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
            .navigationDestination(for: Host.self) { TerminalScreen(host: $0) }
            .sheet(item: $editedHost) { HostEditorView(host: $0) }
            .sheet(isPresented: $showingKeyImport) { KeyImportView() }
            .sheet(isPresented: $showingPreview) { TerminalPreview() }
        }
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
