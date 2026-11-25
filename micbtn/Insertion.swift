// Watches who presses keys, never what, so two things about the dictation app can be seen rather than
// guessed (`micbtn --button`):
//
//   landing   After the button ends dictation, the app transcribes and then puts the text in with keys of
//             its own (a paste, or typing). How long that takes grows with how long was said, so no fixed
//             wait before Enter is right. Keys posted by another process are the text landing; once they
//             stop for `insertQuiet`, it has landed.
//   armed     The dictation key pressed by anything but this process (the keyboard, or the analog mic's
//             button) ends hands-free dictation, and the button has to know it is no longer running.
//
// The tap only listens: it cannot hold a key back or slow typing down. A keyboard key's code is never
// looked at, except to tell the dictation key apart.

import CoreGraphics
import Foundation

final class Insertion {
    enum Watch { case nothing, armed, landing }
    var watch = Watch.nothing { didSet { if watch != .landing { quiet?.cancel(); quiet = nil } } }
    var onInserted: () -> Void = {}
    var onEndedElsewhere: () -> Void = {}
    private var tap: CFMachPort?
    private var quiet: DispatchWorkItem?
    private let dictationKey: CGKeyCode
    private let ours = Int64(getpid())

    init(dictationKey: CGKeyCode) { self.dictationKey = dictationKey }

    /// False when macOS refuses the tap (Accessibility or Input Monitoring is missing).
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.flagsChanged.rawValue)
        let this = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            Unmanaged<Insertion>.fromOpaque(context!).takeUnretainedValue().saw(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: this)
        guard let tap else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func saw(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS switches a tap off when it thinks it is slow. This one does no work; switch it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let source = event.getIntegerValueField(.eventSourceUnixProcessID)
        guard source != ours else { return }
        switch watch {
        case .nothing:
            return
        case .armed:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(dictationKey) else { return }
            // Fn is a modifier and arrives as a flags change, down when its flag is set. Any other key is a key down.
            if type == .flagsChanged ? event.flags.contains(.maskSecondaryFn) : type == .keyDown { onEndedElsewhere() }
        case .landing:
            // The keyboard's own keys have no process behind them. Typing while the text lands is not the text.
            guard type == .keyDown, source != 0 else { return }
            quiet?.cancel()
            let settled = DispatchWorkItem { [weak self] in
                guard let self, self.watch == .landing else { return }
                self.watch = .nothing
                self.onInserted()
            }
            quiet = settled
            DispatchQueue.main.asyncAfter(deadline: .now() + insertQuiet, execute: settled)
        }
    }
}
