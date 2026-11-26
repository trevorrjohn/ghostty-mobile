import UIKit
import UniformTypeIdentifiers

/// Copies shared images into the App Group inbox and hands off to the app. It never connects to anything:
/// SSH sessions, host trust and credentials stay in the main app.
final class ShareViewController: UIViewController {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.text = "Preparing images…"
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        spinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
        Task { await run() }
    }

    private func run() async {
        guard let inbox = ShareInbox.shared else {
            return finish(message: "Seance Shell isn't set up for sharing on this build.", opened: false)
        }
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
            .prefix(ShareInbox.maximumImages)
        guard !providers.isEmpty else {
            return finish(message: "Seance Shell can only receive images.", opened: false)
        }
        do {
            inbox.purgeStale()
            let batch = try inbox.makeBatch()
            for (index, provider) in providers.enumerated() {
                _ = try await copy(provider, into: batch.directory, index: index)
            }
            let opened = ShareInbox.openURL(batchID: batch.id).map(openHostApp) ?? false
            finish(
                message: opened ? "Opening Seance Shell…" : "Saved. Open Seance Shell to choose where to upload.",
                opened: opened
            )
        } catch {
            finish(message: "The image could not be prepared.", opened: false)
        }
    }

    private func copy(_ provider: NSItemProvider, into directory: URL, index: Int) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { source, error in
                guard let source else { return continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                // The system deletes `source` when this handler returns, so copy before resuming.
                let name = String(format: "%02d-%@", index, source.lastPathComponent)
                let destination = directory.appendingPathComponent(name)
                do {
                    try FileManager.default.copyItem(at: source, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Extensions cannot call `UIApplication.shared`, so walk the responder chain to the host application
    /// and ask it to open the URL. If this fails the images stay in the inbox and the app collects them
    /// the next time it becomes active.
    private func openHostApp(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication {
                let modern = NSSelectorFromString("openURL:options:completionHandler:")
                if current.responds(to: modern) {
                    typealias Open = @convention(c) (AnyObject, Selector, URL, [UIApplication.OpenExternalURLOptionsKey: Any], ((Bool) -> Void)?) -> Void
                    let implementation = unsafeBitCast(current.method(for: modern), to: Open.self)
                    implementation(current, modern, url, [:], nil)
                    return true
                }
                let legacy = NSSelectorFromString("openURL:")
                if current.responds(to: legacy) {
                    _ = current.perform(legacy, with: url)
                    return true
                }
            }
            responder = current.next
        }
        return false
    }

    private func finish(message: String, opened: Bool) {
        spinner.stopAnimating()
        label.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + (opened ? 0.3 : 1.6)) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
