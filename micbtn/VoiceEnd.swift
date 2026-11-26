// One press instead of two (`micbtn --button --auto-send [seconds]`): the press starts dictation, and it
// ends by itself once you have spoken and then been quiet for that long (1.5 s by default). Ending it is
// the same as the second press: dictation off, then Enter when the text has landed, in the pane the first
// press picked. A second press still ends it at once.
//
// It listens to the Mac's built-in mic only while dictation is running, and only to how loud it is: speech
// is anything well over the quietest level heard so far. (Not the headset's mic: opening that puts
// AirPods in call mode, and whatever is playing gets louder.) Nothing said at all for `voiceIdle`
// ends it too, so a press by mistake never leaves dictation running.

import AVFoundation
import CoreAudio
import Foundation

let autoSend = has("--auto-send") ? number("--auto-send", 1.5) : 0  // seconds of quiet after speech; 0 is off
let voiceIdle = number("--auto-send-idle", 8)                       // seconds with nothing said at all
let voiceRatio = number("--auto-send-ratio", 4)                     // speech is this many times the quiet level

final class VoiceEnd {
    var onQuiet: (_ why: String) -> Void = { _ in }
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var device: AudioDeviceID = 0     // the built-in mic, while it is being read
    private var proc: AudioDeviceIOProcID?
    private let state = DispatchQueue(label: "micbtn.voice")
    // On `state`:
    private var floor = 0.0, spoken = 0.0, peak = 0.0
    private var began = 0.0, lastSpeech = 0.0, fired = true

    static func allowed() -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        let done = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { granted = $0; done.signal() }
        done.wait()
        return granted
    }

    func start() {
        stop()
        state.sync { floor = 0; spoken = 0; peak = 0; began = HIDButton.now(); lastSpeech = 0; fired = false }
        listen()
    }

    func stop() {
        state.sync { fired = true }
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        proc = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// The Mac's own microphone. Opening a Bluetooth headset's mic puts it in call mode: whatever is playing
    /// gets louder and worse for as long as dictation runs. `--auto-send-mic default` listens to the system
    /// default input instead.
    private static func builtInMic() -> AudioDeviceID? {
        func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var at = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &at, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &at, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { device in
            var transport: UInt32 = 0, n = UInt32(MemoryLayout<UInt32>.size)
            var kind = address(kAudioDevicePropertyTransportType)
            guard AudioObjectGetPropertyData(device, &kind, 0, nil, &n, &transport) == noErr, transport == kAudioDeviceTransportTypeBuiltIn else { return false }
            var streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput), bytes: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &bytes) == noErr && bytes > 0
        }
    }

    private func listen() {
        if (flag("--auto-send-mic") ?? "builtin") != "default", let mic = VoiceEnd.builtInMic() {
            if listen(to: mic) { return }
            log("--auto-send: cannot read the built-in mic: using the default input")
        }
        listenToDefault()
    }

    /// Reads the built-in mic straight from CoreAudio, and nothing else. An AVAudioEngine cannot do this:
    /// its input node starts life on an aggregate of the default input and output, and when the default
    /// input is the headset's mic that alone puts AirPods in call mode (measured: 30 ms after the click,
    /// 270 ms before the engine could be moved to the built-in mic), and the sound breaks up for seconds.
    private func listen(to mic: AudioDeviceID) -> Bool {
        var at = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                            mElement: kAudioObjectPropertyElementMain)
        var rate = 0.0, size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(mic, &at, 0, nil, &size, &rate) == noErr, rate > 0 else { return false }
        var id: AudioDeviceIOProcID?
        // The device hands every reader 32-bit floats, channels interleaved.
        let status = AudioDeviceCreateIOProcIDWithBlock(&id, mic, nil) { [weak self] _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let self, let buffer = buffers.first, let data = buffer.mData, buffer.mNumberChannels > 0 else { return }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            guard count > 0 else { return }
            let samples = data.assumingMemoryBound(to: Float32.self)
            var sum = 0.0
            for i in 0..<count { sum += Double(samples[i]) * Double(samples[i]) }
            self.heard(rms: (sum / Double(count)).squareRoot(), seconds: Double(count / Int(buffer.mNumberChannels)) / rate)
        }
        guard status == noErr, let id else { return false }
        guard AudioDeviceStart(mic, id) == noErr else { AudioDeviceDestroyIOProcID(mic, id); return false }
        device = mic
        proc = id
        return true
    }

    private func listenToDefault() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return log("--auto-send: no input to listen to; press again to send") }
        // No format asked for: the tap takes whatever the input has at that moment. Asking for the one read
        // above raised an uncaught "format mismatch" when the input changed in between (the headset going
        // to a phone, or coming back, mid-dictation), which killed the process.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }
            var sum = 0.0
            for i in 0..<Int(buffer.frameLength) { sum += Double(samples[i]) * Double(samples[i]) }
            self.heard(rms: (sum / Double(buffer.frameLength)).squareRoot(), seconds: Double(buffer.frameLength) / buffer.format.sampleRate)
        }
        do { try engine.start() } catch { return log("--auto-send: cannot listen (\(error.localizedDescription)); press again to send") }
        self.engine = engine
        // The dictation app opening the same headset mic changes its format, which stops the engine.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.engine === engine, !self.state.sync(execute: { self.fired }) else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.listenToDefault()
        }
    }

    private func heard(rms: Double, seconds: Double) {
        state.async { [self] in
            guard !fired else { return }
            let now = HIDButton.now()
            // The quiet level: the lowest heard, creeping up so one dead buffer does not pin it at zero.
            floor = floor == 0 ? rms : min(rms, floor * 1.002 + 1e-7)
            peak = max(peak, rms)
            if rms > max(floor * voiceRatio, 0.004) {
                spoken += seconds
                lastSpeech = now
            }
            var why: String?
            if spoken >= 0.25, now - lastSpeech >= autoSend, now - began > clickTerm {
                why = String(format: "quiet for %.1f s after %.1f s of speech (peak %.4f, quiet level %.5f)", now - lastSpeech, spoken, peak, floor)
            } else if spoken < 0.25, now - began >= voiceIdle {
                why = String(format: "nothing said in %.0f s (peak %.4f, quiet level %.5f)", voiceIdle, peak, floor)
            }
            guard let why else { return }
            fired = true
            DispatchQueue.main.async { self.onQuiet(why) }
        }
    }
}
