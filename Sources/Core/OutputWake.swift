import AVFoundation
import AudioToolbox
import CoreAudio

/// What keeps the output awake; tests put in their own.
protocol OutputWaking: AnyObject {
    var isAwake: Bool { get }
    func start(device: AudioObjectID)
    func stop()
}

/// Keeps the device for sound effects running while the ring is open, with a silent stream (zeros, nothing to hear), so Bluetooth
/// headphones need not wake up for every tick. Found in the system log: for each short sound the Mac switches the output on and
/// off, which takes 0.3 s on average on AirPods. Started when the ring opens and stopped the moment it closes: no running in the
/// background, no battery used for nothing, the headphones free for other apps. Only listens to the Mac's output setting, never
/// changes a device or a volume.
///
/// Everything with the audio engine happens on its own queue: starting can take as long as the headphones need to wake.
final class OutputWake: OutputWaking, @unchecked Sendable {
    private let queue = DispatchQueue(label: "twistel.outputWake", qos: .userInitiated)
    /// Only touched on `queue`.
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var awake = false
    var log: @Sendable (String) -> Void = { _ in }

    /// The stream is running (the device is awake).
    var isAwake: Bool { lock.withLock { awake } }

    /// Starts the silent stream to this device (nothing happens when it runs already).
    func start(device: AudioObjectID) {
        queue.async { [self] in
            guard engine == nil else { return }
            let engine = AVAudioEngine()
            guard let unit = engine.outputNode.audioUnit else { return log("output wake: no output unit") }
            var id = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size))
            guard status == noErr else { return log("output wake: device not taken (\(status))") }
            let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            let silence = AVAudioSourceNode { _, _, _, buffers in
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) where buffer.mData != nil {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return noErr
            }
            engine.attach(silence)
            engine.connect(silence, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 2))
            do {
                try engine.start()
            } catch {
                return log("output wake: could not start (\(error.localizedDescription))")
            }
            self.engine = engine
            lock.withLock { awake = true }
        }
    }

    /// Ends the stream at once; the device may sleep again.
    func stop() {
        lock.withLock { awake = false }
        queue.async { [self] in
            engine?.stop()
            engine = nil
            // Also here: a start that was still running when stop was asked for set it again.
            lock.withLock { awake = false }
        }
    }

    /// Waits until starting or stopping is done (tests, measuring).
    func waitUntilSettled() { queue.sync {} }
}
