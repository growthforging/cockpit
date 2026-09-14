import SwiftUI

@main
struct CockpitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(delegate.usage)
                .environmentObject(delegate.clips)
                .environmentObject(delegate.scroll)
        }
    }
}
