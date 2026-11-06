import SwiftUI

@MainActor
enum SettingsActionRouter {
    static var open: (() -> Void)?
}

@available(macOS 14, *)
struct SettingsActionBridge: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { SettingsActionRouter.open = { openSettings() } }
    }
}
