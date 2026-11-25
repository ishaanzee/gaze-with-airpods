// Flags, constants and the log, shared by every file.

import Foundation

func flag(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}
func number(_ name: String, _ fallback: Double) -> Double { flag(name).flatMap(Double.init) ?? fallback }
func has(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

// Decoder: levels are multiples of the idle floor, counted in ~10 ms buffers.
let onRatio = number("--on", 100), deadRatio = number("--off", 1.25)
let softRatio = 4.0, softBuffers = 30     // a press with no click: this far over the floor, this long
let deadWindow = 47                       // a release with no click: the median of this many buffers (0.5 s)
let floorRise = 1.004                     // the floor's largest step up, 12 times a second
let clickRatio = 150.0, clickDecay = 6.0  // a click peaks this high and is this much lower 2 before and 5 after
let pressStep = 30.0                      // a press tail: the mean this far over the floor
let releaseDip = 2.5, releaseClick = 12.0  // a release tail: this many press tails below zero, after a click this many high
let releaseRise = 6.0, releaseFloor = 9.0  // and after the line rose this many press tails, never sinking this many since
let quietRatio = 20.0                     // a press too quiet for --on still fires once its tail is seen
let loneBuffers = 30                      // a click with no press behind it is judged within this long
let settleBuffers = 141, settleSpread = 1.7, settleRatio = 1.8  // 1.5 s this steady and this near the floor is idle
let silentBuffers = 2800                  // 30 s of a hold with nothing over the soft-press level: the key is stuck
let bufferSeconds = 512.0 / 48000

// Gesture: a double tap, tap then press and hold, and tap, tap then press and hold.
let tapTerm = number("--tap-term", 400) / 1000        // the longest press that counts as a tap
let holdTerm = number("--hold-term", 240) / 1000      // a press after a tap still down this long is a hold: the command's latency
let releaseLag = 0.055                                // a release is read ~45-53 ms after it happens, so a timer waits this much longer
let doubleTerm = number("--double-term", 1200) / 1000  // from the tap's press to the next press
let tripleTerm = number("--triple-term", 500) / 1000   // with --triple: from a double tap's release to a third press; Enter waits this long
let doublePressGuard = 0.7                            // seconds: a key down this soon after the last gets a Shift tap first, so no app reads a double press
let doubleTimeout = 5.0                               // seconds before a --double or --triple command that has not exited is killed

// Clicks: a button that reports each press over HID (`--button`).
let rawHID = has("--raw")                              // --button --raw: log every report from every interface the receiver has
let buttonVendor = 0x2ca3                             // DJI: the Mic Mini receiver's linking button arrives as a Volume Up click
let clickTerm = number("--click-term", 1500) / 1000   // from one click to the next of the same burst: the third runs --triple-click
let armedTimeout = number("--armed-timeout", 600)     // seconds of dictation with no click before the button forgets it
let insertTimeout = number("--insert-timeout", 20)    // seconds to wait for dictated text to land before giving up on Enter
let fnTap = 0.04, fnGap = 0.12                        // seconds a non-Fn --key is held, and between the two taps that start hands-free
let insertQuiet = 0.15                                // seconds with no more keys from the dictation app: its text has landed
let dictationApp = flag("--dictation-app") ?? "com.granola.app"  // bundle id (prefix) of the app whose open mic means dictation is running
let micGrace = 1.5                                    // seconds the app has to open the mic after a click starts dictation (~0.25 measured, 0.7 worst)
let micPoll = 0.2                                     // seconds between looks at the mic while dictation is thought to be running
let sendGrace = 3.0                                   // seconds after dictation is ended that another click is a nervous one, and ignored

let started = Date()
var replayClock: Double?  // seconds into a recording during --replay and --eval; the wall clock otherwise
var quiet = false         // --eval and --self-test print their own report
let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

/// Every line starts with a 13-character time: the wall clock, or seconds into a recording.
func log(_ line: String) {
    guard !quiet else { return }
    print((replayClock.map { String(format: "%12.3f", $0) } ?? clock.string(from: Date())) + " " + line)
}
