import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu?
    private var services: ServiceProvider?
    private let dragMonitor = DragMonitor()
    private let radial = RadialController()
    private var settingsWindow: NSWindow?
    /// Held for the life of the app: a second start sees it and ends (`SingleInstance`).
    private var instanceLock: Int32?
    #if DEBUG
    /// Long enough that a release build would show it as text, so `scripts/release.sh` can make sure it is not there.
    static let regularAppMarker = "TWISTEL-DEBUG-REGULAR-APP: started with a Dock icon (--as-regular-app)"
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Test access (--run-tool): no status item, no drag monitor, no windows.
        if ToolDriver.startIfRequested() { return }
        #endif
        DiagnosticLog.start()
        switch SingleInstance.claim() {
        case .first(let descriptor): instanceLock = descriptor
        case .second(let running) where running == AppIdentity.name:
            DiagnosticLog.log("\(AppIdentity.name) is already running; this second start ends at once")
            exit(0)
        case .second(let running):
            DiagnosticLog.log("\(running) is running; \(AppIdentity.name) says so and ends")
            MainActor.assumeIsolated { SingleInstance.tellAndQuit(running: running) }
        case .unknown: DiagnosticLog.log("instance lock could not be opened; starting anyway")
        }
        MainActor.assumeIsolated {
            SoundPlayer.isActive = true
            SoundPlayer.shared.preload()
            // AirPods in or out, Bluetooth asleep, another speaker: the sounds follow at once.
            OutputDeviceWatch.start { MainActor.assumeIsolated { SoundPlayer.shared.outputChanged() } }
        }
        AppLanguage.current = AppSettings.shared.language
        AppSettings.shared.applyPrivacy()
        DispatchQueue.global(qos: .background).async { TemporaryFiles.removeLeftovers() }
        #if DEBUG
        // --as-regular-app: with a Dock icon like a normal app, so that screen control (which offers only such apps) can reach it for tests. Not in release builds.
        if CommandLine.arguments.contains("--as-regular-app") {
            DiagnosticLog.log(Self.regularAppMarker)
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
        #else
        NSApp.setActivationPolicy(.accessory)
        #endif
        MainActor.assumeIsolated {
            let menu = StatusMenu(radial: radial)
            menu.openSettings = { [weak self] in self?.openSettings() }
            menu.showIntroduction = { IntroductionWindow.shared.show() }
            IntroductionWindow.shared.openRing = { [weak self] files, ring in self?.radial.presentPicker(for: files, ring: ring) }
            menu.install()
            statusMenu = menu
            let provider = ServiceProvider(radial: radial)
            NSApp.servicesProvider = provider
            services = provider
        }
        #if DEBUG
        if ScreenshotDriver.isEnabled {
            ScreenshotDriver.run(radial: radial)
            return
        }
        #endif
        radial.onChoose = { entry, files, ring, quickRun, point in
            MainActor.assumeIsolated { RingDispatch.run(entry, files: files, ring: ring, quickRun: quickRun, at: point) }
        }
        radial.onPresent = { ring, files in MainActor.assumeIsolated { IntroductionWindow.shared.ringOpened(ring, files: files) } }
        radial.prepare()
        // Which helper programs are there, and whether the network lock can start a program (Hardened Runtime included): in the log
        // from the first second, and the first conversion does not wait for the lock check.
        DispatchQueue.global(qos: .utility).async {
            let found = HelperPrograms.refreshNow().filter(\.value).map { "\($0.key)" }.sorted()
            DiagnosticLog.log("helper programs found: \(found); network lock \(Shell.withoutNetwork != nil ? "works" : "MISSING")")
        }
        dragMonitor.delegate = radial
        dragMonitor.start()
        MainActor.assumeIsolated { IntroductionWindow.showAtFirstLaunch() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        radial.presentPicker(for: urls, takesKeyboard: false)
    }

    @MainActor
    static func makeSettingsWindow() -> NSWindow {
        SettingsWindowController.makeWindow()
    }

    @MainActor
    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = Self.makeSettingsWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
