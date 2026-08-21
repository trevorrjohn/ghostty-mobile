import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var hosts: [Host] = []
    @Published private(set) var keys: [StoredKey] = []
    @Published private(set) var trustedHosts: [TrustedHost] = []
    @Published var settings = AppSettings() { didSet { persistSettings() } }
    @Published var alertMessage: String?

    private let store = SecureStore()
    private let trustedHostStore = KeychainKnownHostStore()

    init() {
        do {
            hosts = try store.read([Host].self, account: "hosts", default: [])
            keys = try store.read([StoredKey].self, account: "keys", default: [])
            settings = try store.read(AppSettings.self, account: "settings", default: AppSettings())
            trustedHosts = try trustedHostStore.records()
        } catch {
            alertMessage = error.localizedDescription
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

    func duplicate(host: Host) {
        save(host: host.duplicated(existingNames: hosts.map(\.name)))
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

    func importKey(data: Data) throws -> StoredKey {
        guard data.count <= 1_048_576 else { throw KeyInspectionError.tooLarge }
        let details = try SSHKeyInspector.inspect(data, existingNames: keys.map(\.name))
        let key = StoredKey(name: details.suggestedName, data: data, requiresPassphrase: details.requiresPassphrase)
        let updated = keys + [key]
        try store.write(updated, account: "keys")
        keys = updated
        return key
    }

    private func persist<T: Encodable>(_ value: T, account: String) {
        do { try store.write(value, account: account) } catch { alertMessage = error.localizedDescription }
    }

    private func persistSettings() { persist(settings, account: "settings") }
}
