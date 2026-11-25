// A headset's own button, with no receiver and no HID report to read: an AirPods stem, or the play/pause
// button of any Bluetooth headset (`micbtn --button --button-source media`).
//
// Such a button reaches the Mac as a play/pause command over Bluetooth (AVRCP), and macOS hands it to
// whichever app is "Now Playing". So MicBtn says it is playing something. Nothing is read from the
// headset, no private API is used, and the press arrives about as fast as it would at a music player.
//
//   one press (play/pause)        a click
//   three presses (previous)      three clicks at once: the --triple-click command, dictation already on
//   two presses (next)            nothing; logged
//
// The cost is the one a music player pays: while MicBtn is the Now Playing app, the keyboard's play/pause
// key comes here too, and an app that starts playing after it takes the button until MicBtn claims it back
// (every `mediaReclaim` seconds while that app is not playing, see `claim`). `--media-silence` also keeps
// a silent output stream running, which holds the headset on this Mac instead of an iPhone nearby.

import AVFoundation
import Foundation
import IOKit
import MediaPlayer

let mediaSilence = has("--media-silence")
let mediaReclaim = number("--media-reclaim", 5)

final class MediaButton: ButtonSource {
    var onClick: (_ time: Double) -> Void = { _ in }
    var onAttach: (_ name: String) -> Void = { _ in }
    var onDetach: (_ name: String) -> Void = { _ in }
    var onOther: (_ what: String) -> Void = { _ in }
    private(set) var attached = 0
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    func open() -> IOReturn {
        let center = MPRemoteCommandCenter.shared()
        let click: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            guard !Call.on else { return .commandFailed }
            self?.onClick(HIDButton.now())
            self?.claim()  // a pause must not leave MicBtn "paused": the next press has to come here too
            return .success
        }
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] {
            command.isEnabled = true
            command.addTarget(handler: click)
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            let now = HIDButton.now()
            for i in 0..<3 { self?.onClick(now + Double(i) * 0.001) }
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onOther("two presses (next track)")
            return .success
        }
        if mediaSilence { startSilence() }
        // In a call the stem is the call's (mute, hang up): give Now Playing up until it is over.
        Call.watch { [weak self] apps in
            log(apps.isEmpty ? "the call is over: the button is back" : "in a call (\(apps.joined(separator: ", "))): the button stands down")
            self?.claim()
        }
        claim()
        Timer.scheduledTimer(withTimeInterval: mediaReclaim, repeats: true) { [weak self] _ in self?.claim() }
        attached = 1
        DispatchQueue.main.async { [self] in onAttach("headset play/pause") }
        return kIOReturnSuccess
    }

    /// Says "playing" again. macOS gives the buttons to the app that said so last, unless another is
    /// really playing.
    private func claim() {
        let info = MPNowPlayingInfoCenter.default()
        guard !Call.on else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        info.nowPlayingInfo = [MPMediaItemPropertyTitle: "MicBtn: press to dictate", MPNowPlayingInfoPropertyPlaybackRate: 1.0,
                               MPNowPlayingInfoPropertyIsLiveStream: true]
        info.playbackState = .paused
        info.playbackState = .playing
    }

    private func startSilence() {
        engine.attach(player)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800) else { return }
        buffer.frameLength = 4800
        do { try engine.start() } catch { return log("--media-silence: \(error.localizedDescription)") }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        // The output device changing (headset in or out of the ears) stops the engine: start it again.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            try? self.engine.start()
            self.player.play()
        }
    }
}
