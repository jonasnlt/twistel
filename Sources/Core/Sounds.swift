import AppKit
import AudioToolbox
import CoreAudio

/// The app's own sounds: done, error, cancelled, and a very quiet one when the chosen ring item changes. The files are
/// in `Resources/Sounds` under these names; another draft from `Design-Entwürfe/Klänge` only replaces the file. "Moved to the Trash"
/// (Undo) is the Mac's own Finder sound, played from macOS where it is (never copied into twistel); without it, twistel's own.
enum SoundEvent: String, CaseIterable, Sendable {
    case done = "fertig"
    case error = "fehler"
    case cancelled = "abgebrochen"
    case hover = "ueberfahren"
    case trashed = "papierkorb"

    /// The Finder's "move to trash" sound on this Mac (macOS 26 and 27). Only read, at the place macOS keeps it.
    static let systemTrashSound = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif")

    /// The same sound again no sooner than this: moving fast over the ring gives single ticks, never a rattle, and the ticks (under
    /// 40 ms) never overlap.
    var minimumGap: TimeInterval { self == .hover ? 0.06 : 0.4 }
}

/// Where the sounds go. In the app: the Mac's sound effects (`SystemSoundOutput`); tests put in one of their own.
protocol SoundOutput: AnyObject {
    func load(_ url: URL) -> UInt32?
    func unload(_ id: UInt32)
    /// Called off the main thread; `finished` comes when the system has played the sound (or given it up), on any thread.
    func play(_ id: UInt32, finished: @escaping @Sendable () -> Void)
}

/// The Mac's sound effects: the system plays them through the device chosen under System Settings › Sound › "Play sound effects
/// through", at the alert volume, and follows that device when it changes (AirPods in and out, Bluetooth asleep, another speaker).
final class SystemSoundOutput: SoundOutput {
    func load(_ url: URL) -> UInt32? {
        var id: SystemSoundID = 0
        return AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr ? id : nil
    }

    func unload(_ id: UInt32) {
        AudioServicesDisposeSystemSoundID(id)
    }

    func play(_ id: UInt32, finished: @escaping @Sendable () -> Void) {
        AudioServicesPlaySystemSoundWithCompletion(id, finished)
    }
}

/// Plays the sounds, loaded once so the first one isn't late. It never changes any volume itself.
///
/// Found in the system log: for every short sound the system switches the output device on and off. On the MacBook's speakers
/// that takes a few milliseconds; on AirPods 0.3 s on average, up to 0.7 s. A new tick sent meanwhile ended the one still waiting,
/// so on AirPods most ticks were never heard. Now a sound is not sent again while the same one is still on its way; it may come late
/// on Bluetooth, but it comes. A sound that never reports back counts as finished after 2 s, so nothing can stay silent, and the
/// other sounds never wait for the tick. On Bluetooth, while the ring is open, a silent stream keeps the headphones awake
/// (`OutputWake`), so the tick can come in time there too (`SoundRoute.clicksOnAwakeBluetooth`).
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer(output: SystemSoundOutput())
    /// Only the app itself plays: not the tests, not the test access.
    static var isActive = false
    /// A sound still "on its way" after this long has lost its report (the device went away): it no longer holds back the next one.
    nonisolated static let lostAfter: TimeInterval = 2

    private let output: SoundOutput
    private let bundle: Bundle
    /// Sounds are handed to the system here, never on the main thread: whatever the device does, the ring and the cards don't wait.
    private let queue = DispatchQueue(label: "twistel.sounds", qos: .userInitiated)
    /// Whether the device for sound effects plays a short click in time (`SoundRoute`); the tick is left out when it doesn't.
    private(set) var hoverFits = true
    /// … and whether it does once it is kept awake (Bluetooth while the ring is open).
    private(set) var hoverFitsAwake = true
    /// The device for sound effects when the sounds were loaded, to keep awake.
    private var device: AudioObjectID = 0
    /// Keeps Bluetooth awake while the ring is open; tests put in their own.
    var wake: OutputWaking = OutputWake()
    private var wakeLimit: DispatchWorkItem?
    /// The ring is never open this long; should its closing be missed, the stream ends here anyway.
    nonisolated static let longestWake: TimeInterval = 120
    /// Reads the device for sound effects; tests put in their own.
    var route: () -> SoundRoute = { SoundRoute.current() }
    private var ids: [SoundEvent: UInt32] = [:]
    private var lastPlayed: [SoundEvent: Date] = [:]
    private var onItsWay: [SoundEvent: Date] = [:]
    /// Counts the times the sounds were loaded anew after the output device changed; a report from before belongs to the old device.
    private(set) var generation = 0
    /// Whether sounds may play now (the app sets nothing here; tests let their own player play).
    var isAllowed: () -> Bool = { SoundPlayer.isActive && AppSettings.shared.soundsEnabled }
    /// Where the Mac's trash sound is looked for; tests point elsewhere.
    var systemTrashSound: URL = SoundEvent.systemTrashSound

    /// The file a sound is played from: the Mac's trash sound if it is there, else (and for all others) twistel's own.
    func url(for event: SoundEvent) -> URL? {
        if event == .trashed, FileManager.default.isReadableFile(atPath: systemTrashSound.path) { return systemTrashSound }
        return bundle.url(forResource: event.rawValue, withExtension: "wav", subdirectory: "Sounds")
    }

    init(output: SoundOutput, bundle: Bundle = .main) {
        self.output = output
        self.bundle = bundle
    }

    /// At launch, so the first sound isn't late.
    func preload() {
        let route = route()
        hoverFits = route.playsClicksInTime
        hoverFitsAwake = route.playsClicksInTime(awake: true)
        device = route.device
        for event in SoundEvent.allCases where ids[event] == nil {
            guard let url = url(for: event) else {
                DiagnosticLog.log("sound missing: \(event.rawValue).wav")
                continue
            }
            if let id = output.load(url) { ids[event] = id }
        }
    }

    /// The output device changed (AirPods in or out, Bluetooth asleep or awake, a display with speakers, headphones): sounds that were
    /// waiting for the old device may never report back, so they no longer hold anything back, and the sounds are loaded anew.
    func outputChanged() {
        DiagnosticLog.log("sound output changed; sounds loaded anew")
        for id in ids.values { output.unload(id) }
        ids = [:]
        onItsWay = [:]
        generation += 1
        // The stream belongs to the old device; the next ring starts one for the new device, if it needs one.
        ringClosed()
        preload()
    }

    /// The ring opened: on Bluetooth the device is kept awake from now on, so the ticks come in time. Nothing on other devices,
    /// nothing with sounds switched off.
    func ringOpened() {
        guard isAllowed(), !hoverFits, hoverFitsAwake, device != 0 else { return }
        wake.start(device: device)
        wakeLimit?.cancel()
        let limit = DispatchWorkItem { [weak self] in self?.ringClosed() }
        wakeLimit = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longestWake, execute: limit)
    }

    /// The ring closed: the silent stream ends at once.
    func ringClosed() {
        wakeLimit?.cancel()
        wakeLimit = nil
        wake.stop()
    }

    /// Whether a sound may play now: sounds are switched on, and it is not too soon after the same one.
    nonisolated static func shouldPlay(_ event: SoundEvent, now: Date, last: Date?, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= event.minimumGap
    }

    /// The same sound is still on its way (sent, not yet reported as played), unless that was so long ago that its report is lost.
    nonisolated static func isOnItsWay(since: Date?, now: Date) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) < lostAfter
    }

    func play(_ event: SoundEvent, now: Date = Date()) {
        guard isAllowed(), Self.shouldPlay(event, now: now, last: lastPlayed[event], enabled: true),
              !Self.isOnItsWay(since: onItsWay[event], now: now) else { return }
        // On Bluetooth only while the stream keeps the headphones awake; before it runs a tick would come late.
        if event == .hover, !hoverFits, !(hoverFitsAwake && wake.isAwake) { return }
        if ids[event] == nil { preload() }
        guard let id = ids[event] else { return }
        lastPlayed[event] = now
        onItsWay[event] = now
        let sentWith = generation
        let output = output
        queue.async {
            output.play(id) { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == sentWith else { return }
                        self.onItsWay[event] = nil
                    }
                }
            }
        }
    }

    /// Waits until the sounds handed over so far have reached the output (tests).
    func waitForOutput() { queue.sync {} }

    /// After Undo: the trash sound only when everything really went to the Trash; the error sound when anything stayed (the card
    /// says why); nothing when there was nothing to move.
    nonisolated static func event(forUndo trashed: [URL], left: [URL]) -> SoundEvent? {
        if !left.isEmpty { return .error }
        return trashed.isEmpty ? nil : .trashed
    }

    /// One sound for a whole batch: an error if anything failed, "cancelled" if everything was, else done.
    nonisolated static func event(for model: ResultCardModel) -> SoundEvent {
        if !model.failed.isEmpty { return .error }
        if model.cancelled { return .cancelled }
        return .done
    }
}

/// The device the Mac plays sound effects through, and whether a short click arrives in time there. Bluetooth (AirPods) and AirPlay
/// start their output for each short sound and need 0.3 s on average, up to 0.7 s (system log): a click that late reads as broken,
/// so the tick is left out there; done, error and cancelled still play. Other devices count by the delay they report.
struct SoundRoute: Equatable, Sendable {
    var transport: UInt32
    var latency: TimeInterval
    var device: AudioObjectID = 0

    /// More than this between sending a click and hearing it, and the click is left out.
    static let longestClickDelay: TimeInterval = 0.1
    /// Whether Bluetooth headphones play the tick while a silent stream keeps them awake (`OutputWake`). Decided by measuring:
    /// the tick plays there only if it then comes within about 150 ms on average. Measured on Bluetooth headphones:
    /// asleep 190–368 ms on average (up to 841 ms), awake 66–70 ms (up to 97 ms).
    static let clicksOnAwakeBluetooth = true

    var isWireless: Bool {
        [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeAirPlay].contains(transport)
    }

    var isBluetooth: Bool { [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport) }

    var playsClicksInTime: Bool { playsClicksInTime(awake: false) }

    /// `awake`: a silent stream keeps the device running. That helps Bluetooth (no waking for each sound), not AirPlay (which is
    /// late by design).
    func playsClicksInTime(awake: Bool) -> Bool {
        if awake, isBluetooth, Self.clicksOnAwakeBluetooth { return true }
        return !isWireless && latency <= Self.longestClickDelay
    }

    /// Read from Core Audio: the device for sound effects, its kind of connection and the delay it reports (device, safety offset and
    /// buffer, in frames at its sample rate). Unknown counts as in time: a click too many is better than none on the built-in speakers.
    static func current() -> SoundRoute {
        func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ empty: T) -> T {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value = empty
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : empty
        }
        let device: AudioObjectID = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0))
        guard device != 0 else { return SoundRoute(transport: 0, latency: 0) }
        let transport: UInt32 = get(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0))
        let rate: Float64 = get(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0))
        let frames = [kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyBufferFrameSize]
            .map { Double(get(device, $0, kAudioObjectPropertyScopeOutput, UInt32(0))) }.reduce(0, +)
        return SoundRoute(transport: transport, latency: rate > 0 ? frames / rate : 0, device: device)
    }
}

/// Tells when the Mac's output for sound effects or its default output changes, or a device comes or goes. Only listens; the block
/// runs on the main thread and only asks the player to reload.
enum OutputDeviceWatch {
    static let watched: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDevices,
    ]

    static func start(onChange: @escaping @Sendable () -> Void) {
        for selector in watched {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in onChange() }
            if status != noErr { DiagnosticLog.log("could not watch the sound output (\(status))") }
        }
    }
}

/// A fine tick of the Force Touch trackpad when the chosen ring item changes (not on every movement of the pointer).
@MainActor
enum Haptics {
    static func selectionChanged() {
        guard SoundPlayer.isActive, AppSettings.shared.hapticsEnabled else { return }
        // .generic: a change of choice (HIG); .alignment is for snapping into place.
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .drawCompleted)
    }
}
