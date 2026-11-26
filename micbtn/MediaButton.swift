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
        let click: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] event in
            guard !Call.on else { return .commandFailed }
            if let why = MediaButton.notAPress(String(describing: event)) {
                self?.onOther("a pause or play nobody pressed (\(why))")
                self?.claim()
                return .success
            }
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

    /// Why a play or pause command is not a button press, or nil when it is one (or cannot be told).
    ///
    /// macOS pauses the Now Playing app by itself, with the same command a squeeze sends, when the
    /// headset leaves: an iPhone takes the AirPods for a call (sent by the AirPods daemon, cloudpaird;
    /// several per call, the first ~120 ms before the audio route changes), or an AirPod comes out of
    /// the ear (sent by mediaremoted with no sender; `play` again when it goes back in). A real press
    /// comes from rcd. The only thing that tells them apart is the sender, and the only public place it
    /// shows is the event's description (measured on macOS 27):
    ///   ... sourceID=SenderDevice = <Mac>, SenderBundleIdentifier = <com.apple.rcd>, SenderPID = <22340> ((null))>
    ///   ... sourceID=SenderDevice = <Mac>, SenderBundleIdentifier = <com.apple.cloudpaird>, SenderPID = <1007> ((null))>
    ///   ... sourceID=(null) ((null))>
    /// A description with no sourceID at all is a press: if macOS stops printing it, the button keeps working.
    static func notAPress(_ description: String) -> String? {
        guard let source = description.range(of: "sourceID=") else { return nil }
        let rest = description[source.upperBound...]
        if rest.hasPrefix("(null)") { return "no sender: an AirPod went out of, or into, the ear" }
        guard let start = rest.range(of: "SenderBundleIdentifier = <"),
              let end = rest[start.upperBound...].firstIndex(of: ">") else { return nil }
        let sender = String(rest[start.upperBound..<end])
        return sender == "com.apple.cloudpaird" ? "from \(sender): the headset went to another device" : nil
    }

    static func senderFailures() -> [String] {
        let event = "<MPRemoteCommandEvent: 0x7760c17540 commandID=74BAC8F4 command=<MPRemoteCommand: 0x7760b30780 type=Pause (1) enabled=YES handlers=[0x7761756220]> "
        let cases: [(String, Bool)] = [
            (event + "sourceID=SenderDevice = <Mac>, SenderBundleIdentifier = <com.apple.rcd>, SenderPID = <22340> ((null))>", true),
            (event + "sourceID=SenderDevice = <>, SenderBundleIdentifier = <com.apple.rcd>, SenderPID = <22340> ((null))>", true),
            (event + "sourceID=SenderDevice = <Mac>, SenderBundleIdentifier = <com.apple.cloudpaird>, SenderPID = <1007> ((null))>", false),
            (event + "sourceID=(null) ((null))>", false),
            (event + ">", true),
            ("", true),
        ]
        return cases.filter { (notAPress($0.0) == nil) != $0.1 }.map { "media sender: \($0.0.suffix(90))" }
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
