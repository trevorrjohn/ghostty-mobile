import SwiftUI
import UIKit
import UserNotifications

private final class RemoteNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Keeps sessions connected briefly after backgrounding so quick app switches
/// don't drop SSH, then disconnects before iOS suspends the process.
@MainActor
private final class BackgroundGrace {
    private static let duration: Duration = .seconds(20)
    private var task: Task<Void, Never>?
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin(disconnect: @escaping @MainActor () -> Task<Void, Never>) {
        cancel()
        identifier = UIApplication.shared.beginBackgroundTask(withName: "ssh-background-grace") { [weak self] in
            // Time is up: disconnect now rather than being suspended mid-session.
            Task { @MainActor in
                guard let self else { return }
                self.task?.cancel()
                await disconnect().value
                self.finish()
            }
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            await disconnect().value
            self?.finish()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        finish()
    }

    private func finish() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

@main
struct GhosttyConnectApp: App {
    private let notificationDelegate: RemoteNotificationDelegate
    @StateObject private var appModel: AppModel
    @StateObject private var sessions: TerminalSessionRegistry
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundGrace = BackgroundGrace()

    init() {
        let notificationDelegate = RemoteNotificationDelegate()
        self.notificationDelegate = notificationDelegate
        UNUserNotificationCenter.current().delegate = notificationDelegate
        let appModel = AppModel()
        _appModel = StateObject(wrappedValue: appModel)
        _sessions = StateObject(wrappedValue: TerminalSessionRegistry(
            keyProvider: { [weak appModel] id in appModel?.key(id: id) },
            clipboardWriter: { write in
                switch write {
                case .text(let text): UIPasteboard.general.string = text
                case .clear: UIPasteboard.general.items = []
                }
            },
            bellHandler: {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            },
            notificationWriter: { notification, sessionLabel in
                let center = UNUserNotificationCenter.current()
                let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
                guard allowed, !Task.isCancelled else { return }
                let content = UNMutableNotificationContent()
                content.title = sessionLabel
                content.body = notification.title.isEmpty
                    ? notification.body
                    : "\(notification.title)\n\(notification.body)"
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                guard !Task.isCancelled else { return }
                try? await center.add(request)
            }
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .environmentObject(sessions)
                .preferredColorScheme(.dark)
                .onOpenURL(perform: appModel.handle)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        backgroundGrace.begin { sessions.disconnectForBackground() }
                    } else if phase == .active {
                        backgroundGrace.cancel()
                        sessions.cancelBackgroundDisconnect()
                    }
                }
        }
    }
}
