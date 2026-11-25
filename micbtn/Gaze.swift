// Eye tracking, optional (`micbtn --button`): click where the eyes are as dictation starts, so the text
// lands in the window being looked at and not in whichever had focus. Dictation never waits for it.
//
// The tracker is `gaze/` in this repo. Its daemon (`gaze --serve`) answers one question on a local socket:
// where on the screens is this person looking, in the coordinates a mouse event takes. With no daemon
// there is no socket, nothing is asked and nothing is clicked: the button is exactly what it was.
//
// The daemon reads the camera, and macOS gives the camera to an app, not to a bare python under launchd.
// So its launchd job is `micbtn --gaze-serve "<command>"`: MicBtn asks for the camera and runs the
// daemon as its child, which makes the grant MicBtn's.

import AVFoundation
import CoreGraphics
import Foundation

enum Gaze {
    static let socketPath = NSHomeDirectory() + "/Library/Application Support/gaze/gaze.sock"
    static let off = has("--no-gaze")
    static let timeout = number("--gaze-timeout", 1000) / 1000  // seconds the daemon has to answer; later than that, no click

    /// Whether a click may come before dictation: the daemon's socket is there and nothing turned it off.
    static var on: Bool { !off && FileManager.default.fileExists(atPath: socketPath) }

    /// The daemon's answer, "x y laptop|external" or "none <why>". Nil with no daemon, or one that is too slow.
    static func ask() -> String? {
        guard on else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var wait = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1e6))
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            setsockopt(fd, SOL_SOCKET, option, &wait, socklen_t(MemoryLayout<timeval>.size))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { to in path.withUnsafeBytes { to.copyMemory(from: $0) } }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, write(fd, "point\n", 6) == 6 else { return nil }
        var answer = [UInt8](repeating: 0, count: 128)
        let count = read(fd, &answer, answer.count)
        guard count > 0 else { return nil }
        return String(decoding: answer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A left click where the eyes are, without holding anything up: the daemon is asked on a queue of its
    /// own (about 0.3 s), and the click is then posted on the key queue, so it lands whole between keys and
    /// never between the two presses that start dictation. Anything but a point (no daemon, no face,
    /// looking off the screens) clicks nothing.
    static func click(after keys: DispatchQueue) {
        guard on else { return }
        DispatchQueue.global(qos: .userInteractive).async {
            let asked = Date()
            guard let answer = ask() else { return log("gaze: no answer in \(Int(timeout * 1000)) ms: no click") }
            let parts = answer.split(separator: " ")
            guard parts.count >= 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return log("gaze: \(answer): no click") }
            let took = Date().timeIntervalSince(asked) * 1000
            keys.async {
                log(String(format: "gaze: click at %.0f,%.0f (%@, answered in %.0f ms, clicked %.0f ms after the button)", x, y,
                           parts.count > 2 ? String(parts[2]) : "?", took, Date().timeIntervalSince(asked) * 1000))
                guard !levelsOnly else { return }
                let source = CGEventSource(stateID: .hidSystemState)
                for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }
    }

    /// `micbtn --gaze-serve "<command>"`: asks for the camera as MicBtn, then runs the daemon as a child and
    /// ends when it does, so launchd restarts the pair.
    static func serve(_ command: String) -> Never {
        let asked = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .video) { granted = $0; asked.signal() }
        asked.wait()
        guard granted else {
            log("needs Camera: turn on MicBtn in System Settings > Privacy & Security > Camera")
            sleep(30)
            exit(1)
        }
        // launchd cannot be relied on to start it again (a login session stuck in "on-demand-only mode" never
        // does: macOS 27), so the daemon is restarted from here, for as long as MicBtn runs.
        var daemon: Process?
        signal(SIGTERM, SIG_IGN)
        let terminated = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminated.setEventHandler { daemon?.terminate(); exit(0) }
        terminated.resume()
        // In a call the daemon lets go of the camera: it looks for this file (Call.swift says when).
        let inCall = (socketPath as NSString).deletingLastPathComponent + "/in-call"
        try? FileManager.default.removeItem(atPath: inCall)
        Call.watch { apps in
            log(apps.isEmpty ? "the call is over: gaze resumes" : "in a call (\(apps.joined(separator: ", "))): gaze pauses")
            if apps.isEmpty { try? FileManager.default.removeItem(atPath: inCall) } else { FileManager.default.createFile(atPath: inCall, contents: nil) }
        }
        DispatchQueue.global().async {
            while true {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "exec " + command]
                do { try process.run() } catch {
                    log("cannot run \(command): \(error.localizedDescription)")
                    exit(1)
                }
                daemon = process
                process.waitUntilExit()
                log("the gaze daemon ended (\(process.terminationStatus)): starting it again in 5 s")
                sleep(5)
            }
        }
        dispatchMain()
    }
}
