// micbtn: turn a push-to-talk mic's button into a held key (Fn by default).
//
// A mic whose talk button is analog (Teenage Engineering's EP-35 handy mic and the like) sends nothing over
// USB when the button moves: the USB device is only the cable's audio chip. What the Mac does see is the
// audio. Three layers, one file each:
//
//   Decoder.swift   audio -> press / release edges, each with the time it happened at the button
//   Gesture.swift   edges -> key down, key up, Enter (double tap), run --double (tap, then press and hold),
//                   run --triple (tap, tap, then press and hold)
//   main.swift      the mic, the key, the --double and --triple commands, permissions, the menu-bar dot, and the tools
//
// A wireless mic whose receiver reports its button over HID (DJI Mic Mini) is a different instrument: it is
// always live and its button only clicks. `micbtn --button` reads that, as a process of its own:
//
//   HIDButton.swift  the receiver's reports -> clicks, each with the time it reached the Mac
//   Clicks.swift     clicks -> dictation on, run --click or --triple-click, dictation off, Enter
//   Insertion.swift  when the dictated text has landed, and when dictation was ended some other way
//   Button.swift     the three wired together, the keys, permissions and the menu-bar dot
//   Gaze.swift       optional: a click where the eyes are before dictation starts (the tracker is ../gaze)
//
// Usage: micbtn [--device NAME] [--key fn|f13..f20|<keycode>] [--double "<shell command>"] [--triple "<shell command>"]
//               [--trace FILE] [--on 100] [--off 1.25] [--tap-term 400] [--hold-term 240]
//               [--double-term 1200] [--triple-term 500]
//        micbtn --button [--key ...] [--click "<shell command>"] [--triple-click "<shell command>"]
//               [--click-term 1500] [--armed-timeout 600] [--insert-timeout 20] [--levels]
//               [--no-gaze] [--gaze-timeout 1000]
//        micbtn --gaze            where the eye tracker says you are looking right now, if it is set up
//        micbtn --gaze-serve CMD  run the eye tracker's daemon as MicBtn's child, so the camera grant is MicBtn's
//        micbtn --inputs         list audio inputs and the one micbtn would pick
//        micbtn --levels          log the live levels and what the button would do; sends no keys
//        micbtn --replay FILE     run a recording (raw 16-bit mono 48 kHz, or a .trace file) through the
//                                 same logic and log what it would have done
//        micbtn --capture DIR     record a labelled session of real presses into DIR (guided, ~5 minutes)
//        micbtn --eval DIR        score the decoder and the gesture against a captured session
//        micbtn --self-test       the gesture table; exit 1 on any failure
//
// Without --device it takes the only USB input, or the system default input when several are plugged in.

import AVFoundation
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let keyName = (flag("--key") ?? "fn").lowercased()
let doubleCommand = flag("--double"), tripleCommand = flag("--triple")
let replayFile = flag("--replay"), traceFile = flag("--trace")
let levelsOnly = has("--levels") || replayFile != nil
let buttonOnly = has("--button")

let functionKeys: [String: CGKeyCode] = ["f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90]
let fnKeyCode: CGKeyCode = 63
let keyCode: CGKeyCode = {
    if keyName == "fn" { return fnKeyCode }
    if let code = functionKeys[keyName] ?? UInt16(keyName) { return code }
    print("unknown --key \(keyName): use fn, f13..f20 or a virtual keycode")
    exit(2)
}()

// MARK: self-test

if has("--self-test") {
    let failures = gestureFailures() + clickFailures()
    failures.forEach { print("FAIL \($0)") }
    print(failures.isEmpty ? "self-test passed" : "self-test: \(failures.count) failed")
    exit(failures.isEmpty ? 0 : 1)
}

if has("--mics") {
    let all = DictationMic.everyone()
    print(all.isEmpty ? "no app has a mic open" : all.joined(separator: "\n"))
    print(Call.others(in: all).isEmpty ? "not in a call" : "in a call: " + Call.others(in: all).joined(separator: ", "))
    exit(0)
}

// MARK: eye tracking (optional; Gaze.swift)

if let daemon = flag("--gaze-serve") { Gaze.serve(daemon) }
if has("--gaze") {
    print(Gaze.ask() ?? (Gaze.off ? "--no-gaze" : "no gaze daemon: see gaze/README.md"))
    exit(0)
}

// MARK: input selection

func inputs() -> [AVCaptureDevice] {
    return AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
}

/// A wireless mic whose button arrives over HID (`--button`) is always live. It has no dead line to read
/// a click off, and the decoder would take every loud word for a press, so it is never picked by itself.
/// A USB input's model is "name:vendor:product", the same ids its button reports under.
func isButtonMic(_ device: AVCaptureDevice) -> Bool {
    let fields = device.modelID.split(separator: ":")
    return fields.count >= 3 && Int(fields[fields.count - 2], radix: 16) == buttonVendor
}

enum Pick {
    case input(AVCaptureDevice)
    case none(String)
}

/// The input to listen on, or why none can be chosen yet.
func pickInput() -> Pick {
    let all = inputs()
    let names = all.map(\.localizedName).joined(separator: ", ")
    if let wanted = flag("--device") {
        let match = all.first { $0.localizedName == wanted } ?? all.first { $0.localizedName.localizedCaseInsensitiveContains(wanted) }
        return match.map { .input($0) } ?? .none("no input matching \"\(wanted)\" (inputs: \(names))")
    }
    let usb = all.filter { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeUSB) && !isButtonMic($0) }
    if usb.count == 1 { return .input(usb[0]) }
    if usb.isEmpty { return .none("no USB input plugged in (inputs: \(names))") }
    if let preferred = AVCaptureDevice.default(for: .audio), usb.contains(preferred) { return .input(preferred) }
    return .none("several USB inputs (\(usb.map(\.localizedName).joined(separator: ", "))): pass --device NAME")
}

if has("--inputs") {
    for device in inputs() { print(device.localizedName + (isButtonMic(device) ? "  (its button is read by --button; never picked without --device)" : "")) }
    switch pickInput() {
    case .input(let device): print("micbtn would use: \(device.localizedName)")
    case .none(let reason): print("micbtn cannot pick: \(reason)"); exit(1)
    }
    exit(0)
}

/// 16-bit mono from the mic, one ~10 ms buffer per call on `queue`.
final class Microphone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let heard: (UnsafeBufferPointer<Int16>) -> Void

    init(_ device: AVCaptureDevice, queue: DispatchQueue, heard: @escaping (UnsafeBufferPointer<Int16>) -> Void) throws {
        self.heard = heard
        super.init()
        session.addInput(try AVCaptureDeviceInput(device: device))
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var bytes: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &bytes)
        guard let bytes, length >= 2 else { return }
        bytes.withMemoryRebound(to: Int16.self, capacity: length / 2) { heard(UnsafeBufferPointer(start: $0, count: length / 2)) }
    }
}

// MARK: recordings

/// Runs 16-bit mono 48 kHz samples through a decoder and a gesture, and returns what they did.
struct Run {
    var edges: [Edge] = []
    var actions: [Gesture.Action] = []
    var holds: [Double] = []  // seconds, one per press that was released

    init(samples: UnsafeBufferPointer<Int16>, logging: Bool) {
        let decoder = Decoder()
        var gesture = Gesture(tapTerm: tapTerm, holdTerm: holdTerm, doubleTerm: doubleTerm, tripleTerm: tripleTerm, commands: [1, 2])
        var pressed = 0.0
        var edges: [Edge] = [], actions: [Gesture.Action] = [], holds: [Double] = []
        decoder.reportLevels = logging && has("--levels")
        decoder.onEdge = { edge in
            edges.append(edge)
            let event: Gesture.Event
            switch edge.kind {
            case .press(let soft): event = .press(soft: soft); pressed = edge.time
            case .release(let stray): event = .release(stray: stray); holds.append(edge.time - pressed)
            }
            var did = gesture.handle(event, at: edge.time)
            // A recording has no command to wait for: it finishes at once.
            if did.contains(where: { if case .runCommand = $0 { return true }; return false }) { did += gesture.handle(.commandDone, at: edge.time) }
            actions += did
            if logging { log("\(edge.isPress ? "press" : "release") (\(edge.detail)) -> \(did.map { "\($0)" }.joined(separator: ", "))") }
        }
        let size = 512
        for start in stride(from: 0, to: samples.count - size, by: size) {
            replayClock = Double(start) / 48000
            decoder.hear(UnsafeBufferPointer(rebasing: samples[start..<(start + size)]))
        }
        self.edges = edges; self.actions = actions; self.holds = holds
    }

    var presses: Int { edges.filter(\.isPress).count }
    var strays: Int { edges.filter { $0.kind == .release(stray: true) }.count }
    var doubles: Int { actions.filter { $0 == .runCommand(taps: 1) }.count }
}

func samples<T>(of path: String, _ body: (UnsafeBufferPointer<Int16>) -> T) -> T {
    guard let data = FileManager.default.contents(atPath: path) else { print("cannot read \(path)"); exit(1) }
    return data.withUnsafeBytes { body($0.bindMemory(to: Int16.self)) }
}

if let replayFile {
    if replayFile.hasSuffix(".trace") {
        // A trace holds levels, not audio: one hold per line, starting with its wall-clock time.
        let decoder = Decoder()
        decoder.onEdge = { log("\($0.isPress ? "press" : "release") (\($0.detail))") }
        var first: Double?
        for line in String(decoding: FileManager.default.contents(atPath: replayFile) ?? Data(), as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard let began = fields.first.flatMap({ Double($0) }) else { continue }
            first = first ?? began
            // Each buffer is `level:mean`. A trace from before the mean was kept has levels only, and
            // without the mean no release tail can be read from it.
            for (i, buffer) in fields.dropFirst().enumerated() {
                replayClock = began - first! + Double(i) * bufferSeconds
                let parts = buffer.split(separator: ":")
                decoder.hear(Double(parts[0]) ?? 0, mean: parts.count > 1 ? Double(parts[1]) ?? 0 : 0)
            }
        }
    } else {
        _ = samples(of: replayFile) { Run(samples: $0, logging: true) }
    }
    exit(0)
}

// MARK: capture and eval

/// What the session asks for, and what a correct decode of each step looks like.
struct Step {
    let name: String
    let ask: String
    let presses: Int   // presses a correct decode reports
    let doubles: Int   // tap-then-holds it recognises
    let longest: Double?   // every hold is at most this long (taps)
    let shortest: Double?  // every counted hold is at least this long (holds)
    let seconds: Double?   // timed step; nil waits for Return
}

let session: [Step] = [
    Step(name: "idle", ask: "Leave the mic alone. Do not touch it.", presses: 0, doubles: 0, longest: nil, shortest: nil, seconds: 15),
    Step(name: "talk", ask: "10 times: press, say a short sentence, let go.", presses: 10, doubles: 0, longest: nil, shortest: 0.5, seconds: nil),
    Step(name: "silent-hold", ask: "10 times: press, hold for about 3 seconds WITHOUT talking, let go.", presses: 10, doubles: 0, longest: nil, shortest: 2, seconds: nil),
    Step(name: "long-silent-hold", ask: "3 times: press, hold for about 10 seconds WITHOUT talking, let go.", presses: 3, doubles: 0, longest: nil, shortest: 7, seconds: nil),
    Step(name: "tap-hold", ask: "20 times, at your normal speed: tap, then press and hold about 2 seconds without talking, let go.", presses: 40, doubles: 20, longest: nil, shortest: nil, seconds: nil),
    Step(name: "tap-hold-talk", ask: "10 times: tap, then press and hold, say a sentence, let go.", presses: 20, doubles: 10, longest: nil, shortest: nil, seconds: nil),
    Step(name: "tap-hold-slow", ask: "5 times, deliberately slowly: tap, then press and hold about 2 seconds, let go.", presses: 10, doubles: 5, longest: nil, shortest: nil, seconds: nil),
    Step(name: "tap", ask: "15 single taps, a couple of seconds apart.", presses: 15, doubles: 0, longest: 0.6, shortest: nil, seconds: nil),
    Step(name: "long-talk", ask: "ONE press: hold it and read aloud for about a minute, loudly, with a few pauses. Then let go.", presses: 1, doubles: 0, longest: nil, shortest: 30, seconds: nil),
    Step(name: "knock", ask: "Button UP the whole time: knock on the mic, tap the grille, tug the cable, about 10 times.", presses: 0, doubles: 0, longest: nil, shortest: nil, seconds: nil),
]

/// Why a decode of one step is wrong, or nil.
func fault(in run: Run, for step: Step) -> String? {
    var faults: [String] = []
    if run.presses != step.presses { faults.append("\(run.presses) presses, expected \(step.presses)") }
    if run.doubles != step.doubles { faults.append("\(run.doubles) tap-then-holds, expected \(step.doubles)") }
    if run.strays > 0 { faults.append("\(run.strays) stray") }
    if run.edges.last?.isPress == true { faults.append("still held at the end") }
    if let longest = step.longest, let hold = run.holds.max(), hold > longest { faults.append(String(format: "a %.0f ms hold in a step of taps", hold * 1000)) }
    if let shortest = step.shortest, let hold = run.holds.min(), hold < shortest { faults.append(String(format: "a %.0f ms hold, expected over %.0f ms", hold * 1000, shortest * 1000)) }
    return faults.isEmpty ? nil : faults.joined(separator: "; ")
}

/// The steps a corpus was recorded against: its own `expect` file (one `name presses doubles longest
/// shortest` per line, `-` for no limit, as `window.sh` writes it), or the guided session.
func steps(of directory: String) -> [Step] {
    guard let expect = FileManager.default.contents(atPath: "\(directory)/expect") else { return session }
    return String(decoding: expect, as: UTF8.self).split(separator: "\n").compactMap { line in
        let f = line.split(separator: " ").map(String.init)
        guard f.count == 5, let presses = Int(f[1]), let doubles = Int(f[2]) else { return nil }
        return Step(name: f[0], ask: "", presses: presses, doubles: doubles, longest: Double(f[3]), shortest: Double(f[4]), seconds: nil)
    }
}

if let file = flag("--record") {
    // Raw audio straight to a file until killed (or for --seconds): no prompts, no keys, no decoding.
    guard case .input(let device) = pickInput() else { print("no mic to record: \(pickInput())"); exit(1) }
    FileManager.default.createFile(atPath: file, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: file) else { print("cannot write \(file)"); exit(1) }
    let microphone: Microphone
    do {
        microphone = try Microphone(device, queue: DispatchQueue(label: "micbtn.record")) { handle.write(Data(buffer: $0)) }
    } catch { print("cannot open \(device.localizedName): \(error.localizedDescription)"); exit(1) }
    microphone.session.startRunning()
    print("recording \"\(device.localizedName)\" into \(file)")
    Thread.sleep(forTimeInterval: number("--seconds", 3600))
    microphone.session.stopRunning()
    exit(0)
}

if let directory = flag("--eval") {
    quiet = !has("--verbose")
    var failed = 0, scored = 0
    var seen: [Int] = []  // how long after each release it was reported, ms
    for step in steps(of: directory) {
        let path = "\(directory)/\(step.name).raw"
        guard FileManager.default.fileExists(atPath: path) else { print("  --    \(step.name): not recorded"); continue }
        let run = samples(of: path) { Run(samples: $0, logging: !quiet) }
        replayClock = nil
        scored += 1
        for edge in run.edges where !edge.isPress {
            if let range = edge.detail.range(of: #"seen (\d+) ms"#, options: .regularExpression) {
                seen.append(Int(edge.detail[range].split(separator: " ")[1]) ?? 0)
            }
        }
        if let fault = fault(in: run, for: step) {
            failed += 1
            print("  FAIL  \(step.name): \(fault)")
        } else {
            print("  ok    \(step.name): \(run.presses) presses, \(run.doubles) tap-then-holds")
        }
    }
    seen.sort()
    if !seen.isEmpty { print("  release seen after: median \(seen[seen.count / 2]) ms, worst \(seen.last!) ms") }
    print(failed == 0 ? "eval passed: \(scored) steps" : "eval: \(failed) of \(scored) steps failed")
    exit(failed == 0 && scored > 0 ? 0 : 1)
}

if let directory = flag("--capture") {
    guard case .input(let device) = pickInput() else { print("no mic to record: \(pickInput())"); exit(1) }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let queue = DispatchQueue(label: "micbtn.capture")
    var recording: Data?
    let microphone: Microphone
    do {
        microphone = try Microphone(device, queue: queue) { samples in recording?.append(samples) }
    } catch { print("cannot open \(device.localizedName): \(error.localizedDescription)"); exit(1) }
    microphone.session.startRunning()
    quiet = true
    print("Recording \"\(device.localizedName)\" into \(directory). Nothing is typed or run during this.")
    print("The audio stays on this Mac. After each step: Return to go on, r + Return to redo it.\n")
    for (i, step) in session.enumerated() {
        while true {
            print("[\(i + 1)/\(session.count)] \(step.ask)")
            queue.sync { recording = Data() }
            if let seconds = step.seconds {
                print("      (\(Int(seconds)) seconds)")
                Thread.sleep(forTimeInterval: seconds)
            } else {
                print("      Return when done: ", terminator: "")
                fflush(stdout)
            }
            let answer = step.seconds == nil ? (readLine() ?? "") : ""
            Thread.sleep(forTimeInterval: 0.5)  // the tail of the last release
            let data = queue.sync { () -> Data in let d = recording ?? Data(); recording = nil; return d }
            if answer.lowercased().hasPrefix("r") { continue }
            FileManager.default.createFile(atPath: "\(directory)/\(step.name).raw", contents: data)
            let run = data.withUnsafeBytes { Run(samples: $0.bindMemory(to: Int16.self), logging: false) }
            replayClock = nil
            print("      heard \(run.presses) presses, \(run.doubles) tap-then-holds" + (fault(in: run, for: step).map { "  <- misread: \($0)" } ?? "") + "\n")
            break
        }
    }
    microphone.session.stopRunning()
    print("Done. Score it with: micbtn --eval \(directory)")
    exit(0)
}

// MARK: the key, the command, the trace

/// Fn is a modifier, so it travels as a flagsChanged event; every other key is a plain down/up.
func post(down: Bool) {
    guard !levelsOnly else { return }
    guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: keyCode, keyDown: down) else { return }
    if keyCode == fnKeyCode {
        event.type = .flagsChanged
        event.flags = down ? .maskSecondaryFn : []
    }
    event.post(tap: .cghidEventTap)
}

let audioQueue = DispatchQueue(label: "micbtn.audio", qos: .userInteractive)

/// A --double or --triple command, started the moment its press goes down so that whatever it does before
/// acting (start an interpreter, compile a script, ask an app a question) overlaps the press being told
/// apart. It must wait for a line on stdin: `go` when the gesture completes, end of file when it was called
/// off. One that has not exited `doubleTimeout` after `go` (a permission prompt nobody answers), or that is
/// still around a few seconds after being called off, is killed, so the key is never left waiting on it.
final class Command {
    let name: String
    private let shell = Process()
    private let stdin = Pipe()
    private let started = Date()
    private var committed: Date?
    private var finished: ((String) -> Void)?

    init(_ name: String, _ command: String) {
        self.name = name
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", command]
        shell.standardInput = stdin
        shell.terminationHandler = { [self] shell in
            let outcome = shell.terminationReason == .uncaughtSignal ? "killed" : "exit \(shell.terminationStatus)"
            audioQueue.async { [self] in
                if let committed {
                    finished?(String(format: "%@ %@, %.0f ms after go (started %.0f ms before it)", name, outcome,
                                     Date().timeIntervalSince(committed) * 1000, committed.timeIntervalSince(started) * 1000))
                } else {
                    log("\(name) called off: \(outcome)")
                }
            }
        }
        do { try shell.run() } catch { log("\(name) failed to start: \(error.localizedDescription)") }
        // Never resolved (it should always be): it goes anyway.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [self] in if shell.isRunning && committed == nil { shell.terminate() } }
    }

    /// Calls `finished` on the audio queue once it exits, however that happens.
    func go(finished: @escaping (String) -> Void) {
        self.finished = finished
        committed = Date()
        guard shell.isRunning else { finished("\(name) was not running"); return }
        try? stdin.fileHandleForWriting.write(contentsOf: Data("go\n".utf8))
        try? stdin.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + doubleTimeout) { [self] in if shell.isRunning { shell.terminate() } }
    }

    func callOff() {
        try? stdin.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in if shell.isRunning { shell.terminate() } }
    }
}

/// Every hold's levels and means with a second either side, one hold per line, so a misread press can be
/// replayed.
final class Trace {
    private let handle: FileHandle?
    private var before: [String] = [], line: [String] = [], open = false, began = 0.0
    init(_ path: String?) {
        guard let path else { handle = nil; return }
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        if size == 0 || size > 16_000_000 { FileManager.default.createFile(atPath: path, contents: nil) }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }
    func add(_ rms: Double, mean: Double, active: Bool) {
        guard let handle else { return }
        let level = "\(Int(rms.rounded())):\(Int(mean.rounded()))"
        if active {
            if !open { open = true; began = Date().timeIntervalSince1970 - Double(before.count) * bufferSeconds; line = before; before = [] }
            line.append(level)
        } else if open {
            open = false
            handle.write((String(format: "%.3f ", began) + line.joined(separator: " ") + "\n").data(using: .utf8)!)
            before = [level]
        } else {
            before.append(level)
            if before.count > 100 { before.removeFirst() }
        }
    }
}

/// The audio behind a reading nobody can check afterwards. The last 20 s are kept in memory, and a reading
/// the decoder is unsure of (a click that fired nothing, a soft press, a release it had to guess) writes
/// the last few seconds to the corpus as raw audio that `--replay` reads. The menu saves all 20 s by hand,
/// for a press it was sure of and got wrong. The folder stays on this Mac and is kept under 300 MB.
final class Suspects {
    static let directory = NSHomeDirectory() + "/Library/Application Support/micbtn/corpus/suspects"
    private var ring = Data()
    private var pending = false, saved = Date.distantPast
    private let bytesPerSecond = 96_000

    /// On the audio queue, like everything here.
    func hear(_ samples: UnsafeBufferPointer<Int16>) {
        ring.append(samples)
        if ring.count > 21 * bytesPerSecond { ring.removeFirst(ring.count - 20 * bytesPerSecond) }
    }

    /// Writes the last `seconds`, once `after` more have been heard, so what the button did next is in it.
    func save(_ reason: String, seconds: Int, after: Double) {
        guard !pending, after == 0 || Date().timeIntervalSince(saved) > 5 else { return }
        pending = true
        audioQueue.asyncAfter(deadline: .now() + after) { [self] in
            pending = false
            saved = Date()
            let audio = Data(ring.suffix(seconds * bytesPerSecond))
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let path = "\(Suspects.directory)/\(stamp.string(from: Date()))-\(reason).raw"
            log("kept the last \(audio.count / bytesPerSecond) s of audio: \(reason)")
            DispatchQueue.global(qos: .utility).async {
                let files = FileManager.default
                try? files.createDirectory(atPath: Suspects.directory, withIntermediateDirectories: true)
                files.createFile(atPath: path, contents: audio)
                // Names start with the time, so sorted is oldest first.
                var names = ((try? files.contentsOfDirectory(atPath: Suspects.directory)) ?? []).filter { $0.hasSuffix(".raw") }.sorted()
                var total = names.reduce(0) { $0 + (((try? files.attributesOfItem(atPath: "\(Suspects.directory)/\($1)"))?[.size] as? Int) ?? 0) }
                while total > 300_000_000, let oldest = names.first {
                    total -= ((try? files.attributesOfItem(atPath: "\(Suspects.directory)/\(oldest)"))?[.size] as? Int) ?? 0
                    try? files.removeItem(atPath: "\(Suspects.directory)/\(oldest)")
                    names.removeFirst()
                }
            }
        }
    }
}
let suspects: Suspects? = levelsOnly || has("--no-suspects") ? nil : Suspects()

// MARK: the menu-bar dot

/// One glance says whether the button is alive: listening, held, waiting for the mic, or blocked.
enum Status: String {
    case starting = "mic", waiting = "mic.slash", listening = "mic.fill", held = "mic.circle.fill", blocked = "exclamationmark.triangle.fill"
    case ready = "button.programmable", armed = "waveform.circle.fill"  // --button: waiting for a click, and dictating
}
let application = NSApplication.shared  // the status bar needs it to exist first
let statusItem: NSStatusItem? = levelsOnly ? nil : NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
let statusLine = NSMenuItem(title: "micbtn", action: nil, keyEquivalent: "")

final class MenuTarget: NSObject {
    @objc func saveMiss() { audioQueue.async { suspects?.save("missed", seconds: 20, after: 0) } }
    @objc func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/\(buttonOnly ? "micbtn-button" : "micbtn").log")) }
    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
let menuTarget = MenuTarget()

func show(_ status: Status, _ text: String) {
    DispatchQueue.main.async {
        guard let statusItem else { return }
        statusItem.button?.image = NSImage(systemSymbolName: status.rawValue, accessibilityDescription: text)
        statusItem.button?.toolTip = "micbtn: \(text)"
        statusLine.title = text
    }
}

if let statusItem {
    let menu = NSMenu()
    menu.addItem(statusLine)
    menu.addItem(.separator())
    // The audio behind a misread press is the analog mic's; a click over HID has none.
    let misread = buttonOnly ? [] : [("That press was misread: keep the last 20 s", #selector(MenuTarget.saveMiss))]
    for (title, action) in misread + [("Open the log", #selector(MenuTarget.openLog)), ("Accessibility settings", #selector(MenuTarget.openAccessibility))] {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = menuTarget
        menu.addItem(item)
    }
    statusItem.menu = menu
    show(.starting, "starting")
}

// MARK: permissions

func microphoneGranted() -> Bool {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
    let done = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .audio) { granted = $0; done.signal() }
    done.wait()
    return granted
}

/// Without Accessibility the key cannot be posted. The dot says so, the system prompt is shown once, and
/// the process waits here for the switch; a fresh process then starts, because a grant made while one is
/// running does not always reach the event tap it already holds.
func waitForAccessibility() {
    log("needs Accessibility: turn on MicBtn in System Settings > Privacy & Security > Accessibility")
    show(.blocked, "needs Accessibility: turn on MicBtn in Privacy & Security")
    let asked = "askedForAccessibility"
    if !UserDefaults.standard.bool(forKey: asked) {
        UserDefaults.standard.set(true, forKey: asked)
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        if AXIsProcessTrusted() { log("Accessibility granted"); exit(0) }
    }
}

// MARK: run

let decoder = Decoder()
var gesture = Gesture(tapTerm: tapTerm, holdTerm: holdTerm, doubleTerm: doubleTerm, tripleTerm: tripleTerm,
                      commands: Set([doubleCommand.map { _ in 1 }, tripleCommand.map { _ in 2 }].compactMap { $0 }))
let trace = Trace(traceFile)
var keyDown = false
var heard = Date()  // when the last buffer arrived; touched only on the audio queue

var lastDown = Date.distantPast  // when the key last went down; touched only on the audio queue

/// A Shift tap, which no app acts on. Dictation apps read two quick presses of their key as "hands-free":
/// dictation locks on and the key coming up no longer ends it (Granola and Wispr Flow both do this with Fn).
/// Any other key between the two presses makes them two separate presses again.
func postBreaker() {
    guard !levelsOnly else { return }
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 56, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? .maskShift : []
        event.post(tap: .cghidEventTap)
    }
}

/// Return, down and up, with no modifier on it: the double tap.
func postEnter() {
    guard !levelsOnly else { return }
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 36, keyDown: down) else { return }
        event.flags = []
        event.post(tap: .cghidEventTap)
    }
}

/// The key only ever moves to the other state, so it cannot be pressed twice or left down. Letting go of
/// the button always has to end the hold, so a press soon after the last one is never a double press to
/// whatever listens for the key: a tap-then-hold, a knock before a press, a quick second try.
func setKey(down: Bool) {
    guard down != keyDown else { return }
    keyDown = down
    if down {
        if Date().timeIntervalSince(lastDown) < doublePressGuard { postBreaker() }
        lastDown = Date()
    }
    post(down: down)
    show(down ? .held : .listening, down ? "key held" : "listening")
}

var prepared: Command?  // the command a press in progress may run; touched only on the audio queue

func perform(_ actions: [Gesture.Action]) {
    for action in actions {
        switch action {
        case .keyDown: setKey(down: true)
        case .keyUp: setKey(down: false)
        case .enter: postEnter()
        case .prepareCommand(let taps):
            guard let command = taps == 1 ? doubleCommand : tripleCommand, !levelsOnly else { continue }
            prepared?.callOff()
            prepared = Command(taps == 1 ? "--double" : "--triple", command)
        case .cancelCommand:
            prepared?.callOff()
            prepared = nil
        case .runCommand(let taps):
            let name = taps == 1 ? "--double" : "--triple"
            guard let command = taps == 1 ? doubleCommand : tripleCommand, !levelsOnly else {
                perform(gesture.handle(.commandDone, at: decoder.time))
                continue
            }
            DispatchQueue.main.async { NSSound(named: "Tink")?.play() }
            let ready = prepared?.name == name ? prepared! : Command(name, command)
            prepared = nil
            ready.go { outcome in
                perform(gesture.handle(.commandDone, at: decoder.time))
                log(outcome)
            }
        }
    }
}

decoder.reportLevels = has("--levels")
decoder.onLevel = { trace.add($0, mean: $1, active: $2) }
decoder.onSuspect = { suspects?.save($0, seconds: 8, after: 1.5) }
decoder.onEdge = { edge in
    let event: Gesture.Event
    switch edge.kind {
    case .press(let soft): event = .press(soft: soft)
    case .release(let stray): event = .release(stray: stray)
    }
    let actions = gesture.handle(event, at: edge.time)
    perform(actions)
    if gesture.awaitingHold {
        // Still down once a tap can no longer be what this is: tap, then hold. A release is read about
        // 50 ms after it happened, so the timer waits that out and a slow double tap is never a hold.
        audioQueue.asyncAfter(deadline: .now() + holdTerm + releaseLag) {
            let actions = gesture.handle(.holdElapsed, at: decoder.time)
            perform(actions)
            if let started = ran(actions) { log(started) }
        }
    }
    if gesture.enterPending && !gesture.held {
        // A double tap with --triple set: Enter once no third press has come. A press is read up to ~50 ms
        // after it happened, so the timer waits that out too.
        audioQueue.asyncAfter(deadline: .now() + tripleTerm + releaseLag) {
            if gesture.handle(.enterElapsed, at: decoder.time) == [.enter] { perform([.enter]); log("double tap: Enter") }
        }
    }
    let key = actions.contains(.keyDown) ? "key down" : actions.contains(.keyUp) ? "key up" : "nothing"
    let did = key + (actions.contains(.enter) ? ", double tap: Enter" : ran(actions).map { ", \($0)" }
        ?? (gesture.enterPending ? ", double tap: Enter unless a third press comes" : gesture.awaitingHold ? ", after \(gesture.taps == 1 ? "a tap" : "two taps")" : ""))
    log("\(edge.isPress ? "press" : "release") (\(edge.detail)) -> \(did)")
}

/// What a run of actions started, for the log.
func ran(_ actions: [Gesture.Action]) -> String? {
    if actions.contains(.runCommand(taps: 1)) { return "tap, then hold: running --double" }
    if actions.contains(.runCommand(taps: 2)) { return "tap, tap, then hold: running --triple" }
    return nil
}

// Anything that stops the audio (unplugged mic, sleep, a capture error, a stalled stream, a lost permission)
// ends this process with the key up; launchd starts a fresh one that waits for the mic and re-measures the floor.
func stop(_ reason: String) -> Never {
    audioQueue.sync { decoder.letGo(); setKey(down: false) }
    log(reason)
    exit(1)
}

var microphone: Microphone?
func listen(on device: AVCaptureDevice) {
    do {
        microphone = try Microphone(device, queue: audioQueue) { samples in
            heard = Date()
            suspects?.hear(samples)
            decoder.hear(samples)
        }
    } catch {
        log("cannot open \(device.localizedName): \(error.localizedDescription)")
        show(.blocked, "cannot open \(device.localizedName)")
        sleep(5)
        exit(1)
    }
    NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main) { _ in
        stop("\(device.localizedName) disconnected")
    }
    NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: microphone!.session, queue: .main) { note in
        stop("capture error: \((note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "unknown")")
    }
    audioQueue.sync { heard = Date() }
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        let silence = audioQueue.sync { Date().timeIntervalSince(heard) }
        if silence > 3 { stop(String(format: "no audio for %.0f s", silence)) }
        if !levelsOnly, !AXIsProcessTrusted() { stop("Accessibility was switched off") }
    }
    microphone!.session.startRunning()
    log("listening on \"\(device.localizedName)\" -> \(levelsOnly ? "levels only" : keyName)")
    show(.listening, "listening on \(device.localizedName)")
}

/// Waits for the mic on the main run loop, never in a sleep: AVFoundation delivers device arrivals there,
/// so a process that blocks its main thread keeps the device list it started with and never sees the
/// mic plugged back in.
var waitingOn = ""
func waitForInput() {
    switch pickInput() {
    case .input(let device): listen(on: device)
    case .none(let reason):
        if reason != waitingOn { log("waiting: \(reason)"); waitingOn = reason; show(.waiting, reason) }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in waitForInput() }
    }
}

signal(SIGTERM, SIG_IGN)
let terminated = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminated.setEventHandler { stop("terminated") }
terminated.resume()

// A menu-bar app with no window is App Napped: its timers are coalesced, so a 40 ms sleep between two key
// presses took ~100 ms and the press-to-mic path doubled (418 ms for 200 ms of sleeps, measured). Held for
// the whole process; idle sleep of the Mac is still allowed.
let awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                  reason: "a button press has to reach the keys within milliseconds")

let buttonMode = buttonOnly ? ButtonMode(click: flag("--click"), tripleClick: flag("--triple-click")) : nil
if let buttonMode {
    buttonMode.start()
} else if !microphoneGranted() {
    log("needs Microphone: allow MicBtn in System Settings > Privacy & Security > Microphone")
    show(.blocked, "needs Microphone: allow MicBtn in Privacy & Security")
    Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in exit(1) }
} else if !levelsOnly, !AXIsProcessTrusted() {
    waitForAccessibility()
} else {
    waitForInput()
}

if statusItem != nil {
    application.setActivationPolicy(.accessory)
    application.run()
} else {
    RunLoop.main.run()
}
