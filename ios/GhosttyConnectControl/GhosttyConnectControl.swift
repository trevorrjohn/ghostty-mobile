import AppIntents
import SwiftUI
import WidgetKit

@available(iOSApplicationExtension 18.0, *)
struct QuickConnectControl: ControlWidget {
    static let kind = "dev.ghostty.connect.quick-connect"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "ghostty-connect://quick-connect")!)) {
                Label("Quick Connect", systemImage: "terminal.fill")
            }
        }
        .displayName("Quick Connect")
        .description("Open Ghostty Connect and choose a saved SSH host.")
    }
}

@main
@available(iOSApplicationExtension 18.0, *)
struct GhosttyConnectControlBundle: WidgetBundle {
    var body: some Widget {
        QuickConnectControl()
    }
}
