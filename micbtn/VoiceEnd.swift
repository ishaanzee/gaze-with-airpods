// One press instead of two (`micbtn --button --auto-send [seconds]`): the press starts dictation, and it
// ends by itself once you have spoken and then been quiet for that long (1.5 s by default). Ending it is
// the same as the second press: dictation off, then Enter when the text has landed, in the pane the first
// press picked. A second press still ends it at once.
//
// It listens to the default input only while dictation is running, and only to how loud it is: speech is
// anything well over the quietest level heard so far. A headset mic with noise suppression (AirPods) goes
// nearly silent between words, which is what makes a short wait safe. Nothing said at all for `voiceIdle`
// ends it too, so a press by mistake never leaves dictation running.

import AVFoundation
import Foundation

let autoSend = has("--auto-send") ? number("--auto-send", 1.5) : 0  // seconds of quiet after speech; 0 is off
let voiceIdle = number("--auto-send-idle", 8)                       // seconds with nothing said at all
let voiceRatio = number("--auto-send-ratio", 4)                     // speech is this many times the quiet level

final class VoiceEnd {
    var onQuiet: (_ why: String) -> Void = { _ in }
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
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
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func listen() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return log("--auto-send: no input to listen to; press again to send") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum = 0.0
            for i in 0..<Int(buffer.frameLength) { sum += Double(samples[i]) * Double(samples[i]) }
            self.heard(rms: (sum / Double(buffer.frameLength)).squareRoot(), seconds: Double(buffer.frameLength) / format.sampleRate)
        }
        do { try engine.start() } catch { return log("--auto-send: cannot listen (\(error.localizedDescription)); press again to send") }
        self.engine = engine
        // The dictation app opening the same headset mic changes its format, which stops the engine.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.engine === engine, !self.state.sync(execute: { self.fired }) else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.listen()
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
