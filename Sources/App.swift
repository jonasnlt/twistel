import AppKit
import SwiftUI

@main
struct TwistelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settingsTabs = SettingsTabModel()

    var body: some Scene {
        // The settings window itself is AppKit's (`SettingsWindowController`), opened from the menu bar icon.
        Settings {
            SettingsView(model: settingsTabs)
                .environmentObject(AppSettings.shared)
        }
    }
}
