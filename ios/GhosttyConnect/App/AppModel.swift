import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var hosts: [Host] = []
    @Published private(set) var keys: [StoredKey] = []
    @Published private(set) var trustedHosts: [TrustedHost] = []
    @Published var settings = AppSettings() { didSet { persistSettings() } }
    @Published var keyboardBarConfig = KeyboardBarConfig.defaults { didSet { persistKeyboardBar() } }
    @Published var alertMessage: String?
    @Published private(set) var quickConnectRequest: UUID?

    private let store = SecureStore()
    private let trustedHostStore = KeychainKnownHostStore()

    init() {
        do {
            let storedKeys = try store.read([StoredKey].self, account: "keys", default: [])
            let metadataMigration = IdentityMetadataMigration.enrich(keys: storedKeys)
            keys = metadataMigration.keys
            if metadataMigration.changed { try store.write(keys, account: "keys") }
            let storedHosts = try store.read([Host].self, account: "hosts", default: [])
            let migration = IdentityReferenceMigration.migrate(hosts: storedHosts, keys: keys)
            hosts = migration.hosts
            if migration.changed { try store.write(hosts, account: "hosts") }
            settings = try store.read(AppSettings.self, account: "settings", default: AppSettings())
            trustedHosts = try trustedHostStore.records()
        } catch {
            alertMessage = error.localizedDescription
        }
        do {
            keyboardBarConfig = try store.read(
                KeyboardBarConfig.self,
                account: "keyboard-bar",
                default: .defaults,
                maximumBytes: KeyboardBarConfig.maximumEncodedBytes
            )
        } catch {
            alertMessage = "Keyboard bar settings could not be loaded. Open Settings, Keyboard Bar, then reset defaults to repair them."
        }
    }

    func save(host: Host) {
        var updated = hosts
        if let index = updated.firstIndex(where: { $0.id == host.id }) { updated[index] = host } else { updated.append(host) }
        updated.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        do { try store.write(updated, account: "hosts"); hosts = updated }
        catch { alertMessage = error.localizedDescription }
    }

    func delete(host: Host) {
        let updated = hosts.filter { $0.id != host.id }
        do { try store.write(updated, account: "hosts"); hosts = updated }
        catch { alertMessage = error.localizedDescription }
    }

    func handle(url: URL) {
        guard ["seance-shell", "ghostty-connect"].contains(url.scheme), url.host == "quick-connect" else { return }
        quickConnectRequest = UUID()
    }

    func forgetHostKey(for host: Host) {
        do {
            try trustedHostStore.remove(account: KeychainHostKeyValidator.account(host: host.hostname, port: host.port))
            trustedHosts = try trustedHostStore.records()
            alertMessage = "The trusted host key for \(host.hostname):\(host.port) was removed."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func reloadTrustedHosts() {
        do { trustedHosts = try trustedHostStore.records() }
        catch { alertMessage = error.localizedDescription }
    }

    func forget(trustedHost: TrustedHost) {
        do {
            try trustedHostStore.remove(account: trustedHost.id)
            trustedHosts = try trustedHostStore.records()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func importKey(data: Data, name: String? = nil) throws -> StoredKey {
        guard data.count <= 1_048_576 else { throw KeyInspectionError.tooLarge }
        let details = try SSHKeyInspector.inspect(data)
        let requestedName = String(name?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80) ?? "")
        let baseName = requestedName.isEmpty ? details.suggestedName : requestedName
        let key = StoredKey(
            name: SSHKeyInspector.uniqueName(baseName, keys.map(\.name)),
            data: data,
            requiresPassphrase: details.requiresPassphrase,
            algorithm: details.algorithm,
            fingerprint: details.fingerprint,
            publicKey: details.publicKey
        )
        let updated = keys + [key]
        try store.write(updated, account: "keys")
        keys = updated
        return key
    }

    func key(for host: Host) -> StoredKey? {
        guard let identityID = host.identityID else { return nil }
        return key(id: identityID)
    }

    func key(id: UUID) -> StoredKey? {
        keys.first { $0.id == id }
    }

    func hosts(using key: StoredKey) -> [Host] {
        hosts.filter { $0.identityID == key.id }
    }

    func rename(key: StoredKey, to requestedName: String) -> Bool {
        let name = String(requestedName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty else {
            alertMessage = "SSH key names cannot be empty."
            return false
        }
        guard !keys.contains(where: { $0.id != key.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            alertMessage = "An SSH key named \(name) already exists."
            return false
        }
        guard let index = keys.firstIndex(where: { $0.id == key.id }) else { return false }
        var updated = keys
        updated[index].name = name
        do {
            try store.write(updated, account: "keys")
            keys = updated
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func delete(key: StoredKey) {
        let updated = keys.filter { $0.id != key.id }
        do {
            try store.write(updated, account: "keys")
            keys = updated
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func persist<T: Encodable>(_ value: T, account: String) {
        do { try store.write(value, account: account) } catch { alertMessage = error.localizedDescription }
    }

    private func persistSettings() { persist(settings, account: "settings") }
    private func persistKeyboardBar() { persist(keyboardBarConfig, account: "keyboard-bar") }
}
