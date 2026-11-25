// A call, or anything else that wants the headset for itself: some other app has a microphone open.
//
// During one the button stands down (MediaButton gives up Now Playing, so the stem is the call's: mute,
// hang up) and the eye tracker lets go of the camera (Gaze.serve tells the daemon). Both come back when
// the mic is closed again. macOS shares the camera between apps, so nothing breaks without this; it is
// here so a squeeze during a call never starts dictation or clicks a pane.
//
// "Other" is anything but the dictation app, MicBtn itself and `--call-ignore <bundle id prefix>`.
// There is no public way to ask who has the camera open (AVCaptureDevice.isInUseByAnotherApplication
// stays false with two apps reading it, measured on macOS 27), and a call always has a mic.

import Foundation

enum Call {
    private static let ignored: [String] = {
        var prefixes = [dictationApp, Bundle.main.bundleIdentifier ?? "io.github.ishaanzee.micbtn"]
        let a = CommandLine.arguments
        for (i, arg) in a.enumerated() where arg == "--call-ignore" && i + 1 < a.count { prefixes.append(a[i + 1]) }
        return prefixes
    }()
    private static let lock = NSLock()
    private static var current: [String] = []
    private static var timer: DispatchSourceTimer?
    static let off = has("--no-call-pause")

    /// The apps that make this a call, out of everything with a mic open.
    static func others(in all: [String]) -> [String] {
        all.filter { id in !id.isEmpty && !ignored.contains { id.hasPrefix($0) } }
    }

    /// The apps in a call right now; empty when there is none. As of the last look, at most `every` seconds ago.
    static var apps: [String] { lock.lock(); defer { lock.unlock() }; return current }
    static var on: Bool { !apps.isEmpty }

    /// Looks every `every` seconds, off the main thread, and reports each change on the main queue.
    static func watch(every: Double = 2, changed: @escaping (_ apps: [String]) -> Void) {
        guard !off else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: every)
        timer.setEventHandler {
            let now = others(in: DictationMic.everyone())
            lock.lock()
            let was = current
            current = now
            lock.unlock()
            if now.isEmpty != was.isEmpty { DispatchQueue.main.async { changed(now) } }
        }
        timer.resume()
        self.timer = timer
    }
}
