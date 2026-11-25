// `micbtn --button`: the HID button, the click gesture and the keys, as one process of its own.
//
// It shares nothing with the analog mic's process but the app it is launched from: no audio is read here,
// and neither can stall, restart or slow the other. Everything runs on the main thread (the reports, the
// key watcher and the timers all arrive there), so there is no state to guard. Keys go out on one serial
// queue, in the order they were asked for, because a tap of Fn is two events with a wait between them.

import AppKit
import ApplicationServices
import AVFoundation
import Foundation

final class ButtonMode {
    private var clicks = Clicks(clickTerm: clickTerm, armedTimeout: armedTimeout, insertTimeout: insertTimeout, sendGrace: sendGrace)
    private var armedAt = 0.0     // when dictation was started, on the receiver's clock
    private var micWatch: Timer?  // runs while armed: sees the dictation end with no click
    private var micSeen = false, micDoubted = false
    private var pressAt = 0.0, micCheckTook = 0.0  // the last click, for the timing line
    private let button: ButtonSource = buttonSource == "media" ? MediaButton() : HIDButton()
    private let insertion = Insertion(dictationKey: keyCode)
    private let voice = VoiceEnd()
    private let keys = DispatchQueue(label: "micbtn.keys", qos: .userInteractive)
    private let commands: [Int: String]
    private var device = ""

    /// When dictation was armed, as wall-clock seconds: what a restarted process resumes from.
    private static let stateFile = NSHomeDirectory() + "/Library/Application Support/micbtn/button.state"

    init(click: String?, tripleClick: String?) {
        commands = [1: click, 3: tripleClick].compactMapValues { $0 }
    }

    func start() {
        guard levelsOnly || AXIsProcessTrusted() else { return waitForAccessibility() }
        guard buttonSource == "media" || HIDButton.allowed(asking: true) else {
            return blocked("needs Input Monitoring: turn on MicBtn in System Settings > Privacy & Security > Input Monitoring") {
                HIDButton.allowed(asking: false)
            }
        }
        guard levelsOnly || DictationMic.start() else { return blocked("CoreAudio will not say when \(dictationApp) opens the mic", until: { false }) }
        guard insertion.start() else { return blocked("cannot watch for the dictated text: check MicBtn under Accessibility", until: { false }) }
        if autoSend > 0 {
            guard VoiceEnd.allowed() else {
                return blocked("--auto-send needs Microphone: allow MicBtn in System Settings > Privacy & Security > Microphone") {
                    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                }
            }
            voice.onQuiet = { [self] why in
                guard clicks.state == .armed else { return }
                log("auto-send: " + why)
                handle(.click)
            }
        }
        insertion.onInserted = { [self] in handle(.inserted) }
        insertion.onEndedElsewhere = { [self] in handle(.endedElsewhere) }
        button.onClick = { [self] time in handle(.click, at: time) }
        button.onOther = { log("ignored: \($0)") }
        button.onAttach = { [self] name in
            device = name
            log("listening on the \"\(name)\" button -> \(levelsOnly ? "log only" : keyName)")
            settle()
        }
        button.onDetach = { [self] name in
            log("\(name) disconnected")
            if button.attached == 0 { handle(.interrupted("the receiver was unplugged")) }
            settle()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [self] _ in
            handle(.interrupted("the Mac went to sleep"))
        }
        resume()
        let opened = button.open()
        guard opened == kIOReturnSuccess else {
            // Another program holds the button for itself. A fresh process tries again once it lets go.
            return blocked(String(format: "cannot take the button for itself (0x%x): is another program holding it?", UInt32(bitPattern: opened)), until: { false })
        }
        // A receiver already plugged in is reported on the next turn of the run loop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if button.attached == 0 { log("waiting: no button receiver plugged in") }
            settle()
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if !levelsOnly, !AXIsProcessTrusted() { stop("Accessibility was switched off") }
        }
    }

    /// Says what is missing, and ends the process once it is there (or after a while, to look again):
    /// launchd starts a fresh one, which is the only kind that reliably sees a new grant.
    private func blocked(_ reason: String, until granted: @escaping () -> Bool) {
        log(reason)
        show(.blocked, reason)
        var waited = 0
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            waited += 2
            if granted() || waited >= 30 { exit(granted() ? 0 : 1) }
        }
    }

    /// Whether the dictation app has the mic open. The first time it is seen open proves the reading
    /// works with this app; until then nothing is concluded from a closed mic.
    private func micOpen() -> Bool {
        guard !levelsOnly, DictationMic.open else { return false }
        micSeen = true
        return true
    }

    /// Armed means dictation is running, and the mic says whether it still is. Closed after the app had
    /// time to open it: it ended with no click (Escape, the app's own stop) or never started.
    private func checkMic() {
        guard clicks.state == .armed, !levelsOnly, !micOpen(), HIDButton.now() - armedAt > micGrace else { return }
        guard micSeen else {
            if !micDoubted { log("\(dictationApp) has not opened the mic: going by clicks alone until it does (another app? --dictation-app <bundle id>)") }
            micDoubted = true
            return
        }
        log("the dictation app's mic is closed: dictation ended with no click")
        handle(.endedElsewhere)
    }

    private func handle(_ event: Clicks.Event, at time: Double = HIDButton.now()) {
        var dictating = false
        if case .click = event {
            pressAt = time
            let asking = HIDButton.now()
            checkMic()
            // While armed the burst's clicks come before the mic is open: only the other states ask.
            dictating = clicks.state != .armed && micOpen()
            micCheckTook = HIDButton.now() - asking
        }
        let before = clicks.state
        let actions = clicks.handle(event, at: time, dictating: dictating)
        if case .click = event {
            let found = dictating && !actions.isEmpty ? " (it was already running)" : ""
            log("click -> " + (actions.isEmpty ? "ignored (\(before.rawValue))" : describe(actions) + found))
        } else if !actions.isEmpty || clicks.state != before {
            log("\(event) -> " + (actions.isEmpty ? clicks.state.rawValue : describe(actions)))
        }
        for action in actions { perform(action) }
        if clicks.state != before { entered(clicks.state, at: time) }
        settle()
    }

    private func describe(_ actions: [Clicks.Action]) -> String {
        actions.map { action -> String in
            switch action {
            case .startDictation: return "dictation on"
            case .run(let n): return commands[n].map { _ in "running \(n == 3 ? "--triple-click" : "--click")" } ?? "\(n) click\(n == 1 ? "" : "s"), no command"
            case .endDictation: return "dictation off"
            case .enter: return "Enter"
            case .fault(let why): return "gave up: \(why)"
            }
        }.joined(separator: ", ")
    }

    private func perform(_ action: Clicks.Action) {
        switch action {
        case .startDictation:
            // The hands-free shortcut, which stays on with the keys up: Fn+Space, or a double press of --key.
            let press = pressAt, handled = HIDButton.now(), checked = micCheckTook
            keys.async {
                let first = HIDButton.now()
                var posts: [Int] = []
                func timed(_ post: () -> Void) { let a = HIDButton.now(); post(); posts.append(Int((HIDButton.now() - a) * 1000)) }
                if keyCode == fnKeyCode {
                    // Fn+Space: the dictation app's hands-free shortcut as one chord, with no gap to wait out.
                    // Back to back: the events arrive in order, and a sleep of a few ms comes back as ~30 (measured).
                    timed { post(down: true) }
                    timed { postSpace(down: true) }
                    timed { postSpace(down: false) }
                    timed { post(down: false) }
                } else {
                    // Any other key: two quick presses, which is hands-free in apps that take a double press.
                    timed { post(down: true) }; Thread.sleep(forTimeInterval: fnTap); timed { post(down: false) }
                    Thread.sleep(forTimeInterval: fnGap)
                    timed { post(down: true) }; Thread.sleep(forTimeInterval: fnTap); timed { post(down: false) }
                }
                let sent = HIDButton.now()
                // Where the time from the press to an open mic goes, one line per start.
                DispatchQueue.global(qos: .utility).async {
                    var opened: Double?, polled: Double?
                    while opened == nil || polled == nil, HIDButton.now() - press < 3 {
                        if opened == nil, DictationMic.open { opened = HIDButton.now() }
                        if polled == nil, DictationMic.asked() { polled = HIDButton.now() }
                        usleep(2000)
                    }
                    let ms = { (t: Double) in Int((t - press) * 1000) }
                    log("timing: handled +\(ms(handled)) ms (mic check \(Int(checked * 1000)) ms), first key +\(ms(first)), dictation keys done +\(ms(sent)) (posts \(posts) ms), "
                        + (polled.map { "the dictation app opened the mic +\(ms($0)) ms" } ?? "the mic did not open in 3 s")
                        + (opened.map { ", heard +\(ms($0)) ms" } ?? ", never heard"))
                }
            }
            // With eye tracking set up, a click where the eyes are, asked for at the same moment and never
            // waited on: the text goes in when dictation ends, long after the click has landed.
            Gaze.click(after: keys)
        case .endDictation:
            keys.async { tapKey() }
        case .enter:
            keys.async { postEnter() }
        case .run(let n):
            guard let command = commands[n], !levelsOnly else { return }
            NSSound(named: "Tink")?.play()
            // Told `go` the moment it starts: a click has no press to wait out.
            Command(n == 3 ? "--triple-click" : "--click", command).go { outcome in
                DispatchQueue.main.async { [self] in
                    log(outcome)
                    if !outcome.contains(" exit 0,") { handle(.commandFailed) }
                }
            }
        case .fault:
            if !levelsOnly { NSSound(named: "Basso")?.play() }
        }
    }

    /// The timer each state waits on. One that comes after its state has moved on is told so by the gesture.
    private func entered(_ state: Clicks.State, at time: Double) {
        func after(_ seconds: Double, _ event: Clicks.Event) {
            // A click's time is the receiver's, a moment ago: the timer is set from then, not from now.
            let wait = max(0, time + seconds - HIDButton.now()) + 0.01
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in handle(event) }
        }
        micWatch?.invalidate()
        micWatch = nil
        if autoSend > 0 { state == .armed ? voice.start() : voice.stop() }
        switch state {
        case .idle: break
        case .armed:
            armedAt = time
            after(armedTimeout, .expired)
            micWatch = Timer.scheduledTimer(withTimeInterval: micPoll, repeats: true) { [self] _ in checkMic() }
        case .sending: after(insertTimeout, .gaveUp)
        }
    }

    /// Everything that follows from the state alone: what the key watcher looks for, the menu-bar symbol,
    /// and the note a restarted process resumes from.
    private func settle() {
        let state = clicks.state
        insertion.watch = state == .armed ? .armed : state == .sending ? .landing : .nothing
        let files = FileManager.default
        if state == .armed {
            if !files.fileExists(atPath: ButtonMode.stateFile) {
                try? files.createDirectory(atPath: (ButtonMode.stateFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                files.createFile(atPath: ButtonMode.stateFile, contents: Data("\(Date().timeIntervalSince1970)".utf8))
            }
        } else {
            try? files.removeItem(atPath: ButtonMode.stateFile)
        }
        switch state {
        case .idle where button.attached == 0: show(.waiting, "no button receiver plugged in")
        case .idle:
            let pane = commands[1] != nil ? " into a new pane" : commands[3] != nil ? ", triple-click for a new pane" : ""
            show(.ready, "\(device) button: click to dictate\(pane)")
        case .armed: show(.armed, "dictating: click to send")
        case .sending: show(.armed, "waiting for the text to land")
        }
    }

    private func resume() {
        guard let note = FileManager.default.contents(atPath: ButtonMode.stateFile), let armedAt = Double(String(decoding: note, as: UTF8.self)) else { return }
        let age = Date().timeIntervalSince1970 - armedAt
        guard age >= 0, age < armedTimeout else { return }
        clicks.resume(armedAt: HIDButton.now() - age)
        entered(.armed, at: HIDButton.now() - age)
        log(String(format: "resumed: dictation was armed %.0f s ago", age))
    }
}

/// Space, with Fn held: the second half of the Fn+Space chord.
private func postSpace(down: Bool) {
    guard !levelsOnly, let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 49, keyDown: down) else { return }
    event.flags = .maskSecondaryFn
    event.post(tap: .cghidEventTap)
}

/// The dictation key, down and up.
private func tapKey() {
    post(down: true)
    Thread.sleep(forTimeInterval: fnTap)
    post(down: false)
}
