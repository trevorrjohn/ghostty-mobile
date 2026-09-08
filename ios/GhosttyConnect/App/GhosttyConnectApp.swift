import SwiftUI

@main
struct GhosttyConnectApp: App {
    @StateObject private var appModel: AppModel
    @StateObject private var sessions: TerminalSessionRegistry
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let appModel = AppModel()
        _appModel = StateObject(wrappedValue: appModel)
        _sessions = StateObject(wrappedValue: TerminalSessionRegistry(
            keyProvider: { [weak appModel] id in appModel?.key(id: id) }
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
