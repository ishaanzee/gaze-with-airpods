// What does macOS show a process when a headset's button is pressed? Run it, press every button, read the log.
//   probe.sh media [seconds]   become the Now Playing app (silent audio) and log play/pause/next/previous commands
//   probe.sh mic [seconds]     open the default input and log the mute gesture, and whether the audio goes all-zero
// Both also log media-key system events, HID values from every device that is not a keyboard or the Mac's
// own, and the raw reports of a SteelSeries receiver (vendor 0x1038).
import AppKit
import AVFoundation
import MediaPlayer
import IOKit.hid

setvbuf(stdout, nil, _IOLBF, 0)
let t0 = Date()
func log(_ s: String) { print(String(format: "%7.3f ", Date().timeIntervalSince(t0)) + s) }
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "media"
let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 30 : 30
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let engine = AVAudioEngine()
if mode != "mic" {
    let player = AVAudioPlayerNode()
    engine.attach(player)
    let format = engine.mainMixerNode.outputFormat(forBus: 0)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    buffer.frameLength = 4800
    do { try engine.start() } catch { log("engine: \(error)") }
    player.scheduleBuffer(buffer, at: nil, options: .loops)
    player.play()
    let c = MPRemoteCommandCenter.shared()
    let all: [(String, MPRemoteCommand)] = [("play", c.playCommand), ("pause", c.pauseCommand), ("togglePlayPause", c.togglePlayPauseCommand), ("stop", c.stopCommand),
        ("next", c.nextTrackCommand), ("previous", c.previousTrackCommand), ("seekForward", c.seekForwardCommand), ("seekBackward", c.seekBackwardCommand)]
    for (name, command) in all {
        command.isEnabled = true
        command.addTarget { _ in log("REMOTE COMMAND: \(name)"); return .success }
    }
    let info = MPNowPlayingInfoCenter.default()
    info.nowPlayingInfo = [MPMediaItemPropertyTitle: "stem probe", MPMediaItemPropertyPlaybackDuration: 3600.0, MPNowPlayingInfoPropertyElapsedPlaybackTime: 1.0, MPNowPlayingInfoPropertyPlaybackRate: 1.0]
    info.playbackState = .playing
    log("now playing: registered, silent audio running")
} else {
    AVCaptureDevice.requestAccess(for: .audio) { log("microphone access: \($0)") }
    let input = engine.inputNode
    var peak: Float = 0, zeros = 0, buffers = 0
    input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
        guard let d = buffer.floatChannelData?[0] else { return }
        var m: Float = 0
        for i in 0..<Int(buffer.frameLength) { m = max(m, abs(d[i])) }
        peak = max(peak, m); buffers += 1; if m == 0 { zeros += 1 }
    }
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        log(String(format: "audio: peak %.5f, %d/%d buffers all-zero", peak, zeros, buffers)); peak = 0; zeros = 0; buffers = 0
    }
    do {
        try AVAudioApplication.shared.setInputMuteStateChangeHandler { muted in log("MUTE HANDLER: muted=\(muted)"); return true }
        log("mute handler set")
    } catch { log("mute handler: \(error)") }
    NotificationCenter.default.addObserver(forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: .main) { n in
        log("MUTE NOTIFICATION: \(n.userInfo ?? [:])")
    }
    do { try engine.start(); log("input running: \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "?"), \(input.outputFormat(forBus: 0).sampleRate) Hz") } catch { log("engine: \(error)") }
}

// Media keys (play/pause from a keyboard arrive here; does a headset's?)
let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(1 << 14), callback: { _, _, event, _ in
    if let e = NSEvent(cgEvent: event), e.subtype.rawValue == 8 {
        log(String(format: "SYSTEM EVENT: media key %d %@", (e.data1 & 0xFFFF0000) >> 16, ((e.data1 & 0xFF00) >> 8) == 0xA ? "down" : "up"))
    }
    return Unmanaged.passUnretained(event)
}, userInfo: nil)
if let tap { CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes); log("media-key tap on") } else { log("media-key tap refused") }

// HID: every device that is not a keyboard, mouse or the Mac's own.
let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, nil)
func prop(_ d: IOHIDDevice, _ k: String) -> Any? { IOHIDDeviceGetProperty(d, k as CFString) }
func interesting(_ d: IOHIDDevice) -> Bool {
    let page = prop(d, kIOHIDPrimaryUsagePageKey) as? Int ?? 0, usage = prop(d, kIOHIDPrimaryUsageKey) as? Int ?? 0
    if page == 1 && [2, 6].contains(usage) { return false }
    return !["SPU", "FIFO", "SPMI", "USB"].contains(prop(d, kIOHIDTransportKey) as? String ?? "") || (prop(d, kIOHIDVendorIDKey) as? Int ?? 0) == 0x1038
}
var seen: [String: Int] = [:]
IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, d in
    if interesting(d) && (prop(d, kIOHIDTransportKey) as? String) != "BT-AACP" { log(String(format: "hid device: %@ vendor 0x%04x product 0x%04x %@ page 0x%x usage 0x%x%@", prop(d, kIOHIDProductKey) as? String ?? "?", prop(d, kIOHIDVendorIDKey) as? Int ?? 0,
               prop(d, kIOHIDProductIDKey) as? Int ?? 0, prop(d, kIOHIDTransportKey) as? String ?? "?", prop(d, kIOHIDPrimaryUsagePageKey) as? Int ?? 0, prop(d, kIOHIDPrimaryUsageKey) as? Int ?? 0, "")) }
}, nil)
IOHIDManagerRegisterInputValueCallback(manager, { _, _, sender, value in
    let d = Unmanaged<IOHIDDevice>.fromOpaque(sender!).takeUnretainedValue()
    guard interesting(d) else { return }
    let e = IOHIDValueGetElement(value)
    let key = String(format: "%@ [%@ dev 0x%x/0x%x] page 0x%x usage 0x%x", prop(d, kIOHIDProductKey) as? String ?? "?", prop(d, kIOHIDTransportKey) as? String ?? "?", prop(d, kIOHIDPrimaryUsagePageKey) as? Int ?? 0, prop(d, kIOHIDPrimaryUsageKey) as? Int ?? 0, IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e))
    seen[key, default: 0] += 1
    if seen[key]! <= 12 { log("HID: \(key) value \(IOHIDValueGetIntegerValue(value)) len \(IOHIDValueGetLength(value))") }
}, nil)
// Raw reports: a vendor page has no usages worth the name, so the bytes are the only thing to read.
var lastReport: [String: [UInt8]] = [:]
IOHIDManagerRegisterInputReportCallback(manager, { _, _, sender, _, id, bytes, length in
    let d = Unmanaged<IOHIDDevice>.fromOpaque(sender!).takeUnretainedValue()
    guard (prop(d, kIOHIDVendorIDKey) as? Int ?? 0) == 0x1038 else { return }
    let report = Array(UnsafeBufferPointer(start: bytes, count: min(length, 24)))
    let key = String(format: "0x%x/0x%x #%d", prop(d, kIOHIDPrimaryUsagePageKey) as? Int ?? 0, prop(d, kIOHIDPrimaryUsageKey) as? Int ?? 0, id)
    guard lastReport[key] != report else { return }
    lastReport[key] = report
    log("REPORT: \(prop(d, kIOHIDProductKey) as? String ?? "?") [\(key)] " + report.map { String(format: "%02x", $0) }.joined(separator: " "))
}, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
log(String(format: "hid open: 0x%x", UInt32(bitPattern: IOHIDManagerOpen(manager, 0))))

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { for (k, n) in seen where n > 12 { log("HID total: \(k) x\(n)") }; log("done"); exit(0) }
app.run()
