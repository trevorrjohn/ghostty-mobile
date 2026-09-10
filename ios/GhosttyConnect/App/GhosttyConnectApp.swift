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

@main
struct GhosttyConnectApp: App {
    private let notificationDelegate: RemoteNotificationDelegate
    @StateObject private var appModel: AppModel
    @StateObject private var sessions: TerminalSessionRegistry
    @Environment(\.scenePhase) private var scenePhase

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
                        sessions.disconnectForBackground()
                    } else if phase == .active {
                        sessions.cancelBackgroundDisconnect()
                    }
                }
        }
    }
}
