// The gesture layer: clean press and release edges in, key and command actions out. It holds no audio and
// no clock of its own, so every sequence can be tested as a table (`micbtn --self-test`).
//
// Hold is the key held. A tap is a press of at most `tapTerm`. A second press within `doubleTerm` of the
// tap's start (press to press, as ZMK measures its quick-tap) is one of two gestures, told apart by how
// long it lasts: let go within `holdTerm` and it was a double tap, which is Enter; still down after
// `holdTerm` and it is tap, then hold, which runs the --double command. With a --triple command there is a
// third: tap, tap, then hold. A double tap's Enter then waits `tripleTerm` after its release for a third
// press; a third press let go within `holdTerm` is still one Enter. The key goes down at once on every
// press, the later ones included, so nothing said while it is being told apart, or while a pane opens, is lost.
//
// A press that may become a command prepares it the moment it goes down (`prepareCommand`), so the slow,
// invisible part of the command runs while the press is being told apart. It then either runs
// (`runCommand`) or is called off (`cancelCommand`). `holdTerm` is shorter than `tapTerm` because it is the
// latency of every command: measured taps last at most ~215 ms and holds at least ~800 ms.

struct Gesture {
    enum Event: Equatable { case press(soft: Bool), release(stray: Bool), holdElapsed, enterElapsed, commandDone }
    enum Action: Equatable { case keyDown, keyUp, prepareCommand(taps: Int), runCommand(taps: Int), cancelCommand, enter }

    var tapTerm: Double
    var holdTerm: Double
    var doubleTerm: Double
    var tripleTerm: Double
    var commands: Set<Int>  // taps before the hold that have a command: 1 is --double, 2 is --triple
    private(set) var held = false
    private(set) var taps = 0  // taps just before this press, while it is not yet known what it is; 0 once it is
    private(set) var enterPending = false  // a double tap, waiting out `tripleTerm` for a third press
    private var prepared = false
    private var pressedAt = 0.0
    private var chain = 0      // taps in a row that the next press can build on
    private var chainAt = 0.0  // one tap: its press. Two taps: the second one's release.
    private var commandRunning = false

    var awaitingHold: Bool { taps > 0 }

    init(tapTerm: Double, holdTerm: Double = 0.24, doubleTerm: Double, tripleTerm: Double = 0.5, commands: Set<Int>) {
        self.tapTerm = tapTerm; self.holdTerm = holdTerm; self.doubleTerm = doubleTerm; self.tripleTerm = tripleTerm
        self.commands = commands
    }

    /// `time` is when the edge happened at the button, in seconds on any one clock.
    mutating func handle(_ event: Event, at time: Double) -> [Action] {
        switch event {
        case .press(let soft):
            guard !held else { return [] }
            held = true
            pressedAt = time
            let follows = chain == 1 ? time - chainAt <= doubleTerm : chain == 2 ? time - chainAt <= tripleTerm : false
            // A soft press (no click) is the decoder catching up with the button: never part of a gesture.
            taps = follows && !soft ? chain : 0
            chain = 0
            // A double tap no third press joined is Enter, sent before this press's key goes down.
            let enter = enterPending && taps != 2
            enterPending = false
            prepared = taps > 0 && commands.contains(taps) && !commandRunning
            return (enter ? [.enter] : []) + [.keyDown] + (prepared ? [.prepareCommand(taps: taps)] : [])
        case .holdElapsed:
            // The caller's timer. One left over from an earlier press finds a younger hold and does nothing.
            guard held, taps > 0, time - pressedAt >= holdTerm else { return [] }
            return command()
        case .enterElapsed:
            // The caller's timer, `tripleTerm` after a double tap's release.
            guard enterPending, !held, time - chainAt >= tripleTerm else { return [] }
            enterPending = false
            chain = 0
            return [.enter]
        case .release(let stray):
            guard held else { return [] }
            held = false
            if taps == 0 {
                chain = !stray && time - pressedAt <= tapTerm ? 1 : 0
                chainAt = pressedAt
                return [.keyUp]
            }
            // A stray release (a knock, a click that was not this hold's own) is a guess: no Enter, no
            // command, and no tap for the next press to build on. A press after a tap is never the first
            // press of the next gesture, except a double tap's second, which a third press can join. Let go
            // just past `holdTerm`, before the timer came, it was still a hold.
            let short = !stray && time - pressedAt <= holdTerm
            if !short && !stray { return command() + [.keyUp] }
            let cancel: [Action] = prepared ? [.cancelCommand] : []
            prepared = false
            defer { taps = 0 }
            if short && taps == 1 && commands.contains(2) {
                chain = 2
                chainAt = time
                enterPending = true
                return [.keyUp] + cancel
            }
            return [.keyUp] + cancel + (short ? [.enter] : [])
        case .commandDone:
            commandRunning = false
            return []
        }
    }

    private mutating func command() -> [Action] {
        let n = taps
        taps = 0
        let wasPrepared = prepared
        prepared = false
        guard commands.contains(n), !commandRunning else { return wasPrepared ? [.cancelCommand] : [] }
        commandRunning = true
        return [.runCommand(taps: n)]
    }
}

/// Every sequence the button can produce, with the exact actions expected. Times are seconds.
func gestureFailures() -> [String] {
    typealias E = Gesture.Event
    typealias A = Gesture.Action
    let p = E.press(soft: false), r = E.release(stray: false), h = E.holdElapsed, done = E.commandDone, n = E.enterElapsed
    let one = A.runCommand(taps: 1), two = A.runCommand(taps: 2), prep1 = A.prepareCommand(taps: 1), prep2 = A.prepareCommand(taps: 2)
    let cases: [(String, Set<Int>, [(Double, E)], [A])] = [
        ("plain hold", [1], [(0, p), (3, r)], [.keyDown, .keyUp]),
        ("double tap is Enter", [1], [(0, p), (0.1, r), (0.25, p), (0.35, r)], [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .enter]),
        ("double tap, the timer comes after it", [1], [(0, p), (0.1, r), (0.25, p), (0.35, r), (0.75, h)], [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .enter]),
        ("double tap, slow", [1], [(0, p), (0.38, r), (1.15, p), (1.35, r)], [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .enter]),
        ("double tap with no command configured", [], [(0, p), (0.15, r), (0.3, p), (0.4, r)], [.keyDown, .keyUp, .keyDown, .keyUp, .enter]),
        ("tap then hold, fast", [1], [(0, p), (0.15, r), (0.22, p), (0.72, h), (1.2, done), (4, r)], [.keyDown, .keyUp, .keyDown, prep1, one, .keyUp]),
        ("tap then hold, slow", [1], [(0, p), (0.38, r), (1.15, p), (1.65, h), (2.1, done), (4, r)], [.keyDown, .keyUp, .keyDown, prep1, one, .keyUp]),
        ("tap then hold, let go before the timer", [1], [(0, p), (0.15, r), (0.3, p), (0.75, r)], [.keyDown, .keyUp, .keyDown, prep1, one, .keyUp]),
        ("tap then hold with no command configured", [], [(0, p), (0.15, r), (0.3, p), (0.8, h), (3, r)], [.keyDown, .keyUp, .keyDown, .keyUp]),
        ("second press too late", [1], [(0, p), (0.2, r), (1.3, p), (1.4, r)], [.keyDown, .keyUp, .keyDown, .keyUp]),
        ("first press too long to be a tap", [1], [(0, p), (0.6, r), (0.8, p), (1.4, h), (3, r)], [.keyDown, .keyUp, .keyDown, .keyUp]),
        ("released while the command runs, then a plain hold before it ends", [1],
         [(0, p), (0.15, r), (0.3, p), (0.8, h), (1.0, r), (1.2, p), (1.5, done), (3, r)],
         [.keyDown, .keyUp, .keyDown, prep1, one, .keyUp, .keyDown, .keyUp]),
        ("a second tap then hold while the command still runs", [1],
         [(0, p), (0.15, r), (0.3, p), (0.8, h), (1.0, r), (1.5, p), (1.6, r), (1.8, p), (2.3, h), (3, r)],
         [.keyDown, .keyUp, .keyDown, prep1, one, .keyUp, .keyDown, .keyUp, .keyDown, .keyUp]),
        ("three taps are one Enter", [1], [(0, p), (0.1, r), (0.25, p), (0.35, r), (0.5, p), (0.6, r)],
         [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .enter, .keyDown, .keyUp]),
        ("a hold after a double tap is a plain hold", [1], [(0, p), (0.1, r), (0.25, p), (0.35, r), (0.5, p), (1.0, h), (3, r)],
         [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .enter, .keyDown, .keyUp]),
        ("a timer left from an earlier press runs nothing", [1],
         [(0, p), (0.1, r), (0.25, p), (0.35, r), (0.5, p), (0.6, r), (0.7, p), (0.75, h), (0.8, r)],
         [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .enter, .keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .enter]),
        ("a stray hold is not a tap", [1], [(0, p), (0.1, .release(stray: true)), (0.3, p), (0.4, r)], [.keyDown, .keyUp, .keyDown, .keyUp]),
        ("a stray second release is not Enter", [1], [(0, p), (0.1, r), (0.25, p), (0.35, .release(stray: true))], [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand]),
        ("a soft press never completes the gesture", [1], [(0, p), (0.15, r), (0.3, .press(soft: true)), (0.4, r), (0.8, h)], [.keyDown, .keyUp, .keyDown, .keyUp]),
        ("repeated edges change nothing", [1], [(0, p), (0.1, p), (3, r), (3.1, r)], [.keyDown, .keyUp]),
        // With --triple: tap, tap, then hold. A double tap's Enter waits for the third press.
        ("triple: double tap is Enter once the window passes", [1, 2], [(0, p), (0.1, r), (0.25, p), (0.35, r), (0.85, n)],
         [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .enter]),
        ("triple: an early timer sends nothing, the real one sends Enter", [1, 2], [(0, p), (0.1, r), (0.25, p), (0.35, r), (0.6, n), (0.9, n), (1.0, n)],
         [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .enter]),
        ("triple: tap, tap, hold runs --triple, no Enter", [1, 2], [(0, p), (0.1, r), (0.25, p), (0.35, r), (0.5, p), (0.85, n), (1.0, h), (1.3, done), (4, r)],
         [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .keyDown, prep2, two, .keyUp]),
        ("triple: let go before the timer, still --triple", [1, 2], [(0, p), (0.1, r), (0.25, p), (0.35, r), (0.5, p), (0.95, r)],
         [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .keyDown, prep2, two, .keyUp]),
        ("triple: tap then hold is still --double", [1, 2], [(0, p), (0.15, r), (0.22, p), (0.72, h), (1.2, done), (4, r)],
         [.keyDown, .keyUp, .keyDown, prep1, one, .keyUp]),
        ("triple: three taps are one Enter", [1, 2], [(0, p), (0.1, r), (0.25, p), (0.35, r), (0.5, p), (0.6, r), (1.2, n)],
         [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .keyDown, prep2, .keyUp, .cancelCommand, .enter]),
        ("triple: a press after the window sends Enter first, then is a plain hold", [1, 2], [(0, p), (0.1, r), (0.25, p), (0.35, r), (0.9, p), (1.4, h), (3, r)],
         [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .enter, .keyDown, .keyUp]),
        ("triple: a soft third press sends Enter and is a plain hold", [1, 2], [(0, p), (0.1, r), (0.25, p), (0.35, r), (0.5, .press(soft: true)), (1.0, h), (3, r)],
         [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .enter, .keyDown, .keyUp]),
        ("triple: a stray second release is not Enter", [1, 2], [(0, p), (0.1, r), (0.25, p), (0.35, .release(stray: true)), (0.9, n)],
         [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand]),
        ("triple: a fourth press starts over", [1, 2], [(0, p), (0.1, r), (0.25, p), (0.35, r), (0.5, p), (0.6, r), (0.7, p), (1.2, h), (3, r)],
         [.keyDown, .keyUp, .keyDown, prep1, .keyUp, .cancelCommand, .keyDown, prep2, .keyUp, .cancelCommand, .enter, .keyDown, .keyUp]),
        ("triple only: tap, tap, hold with no --double", [2], [(0, p), (0.1, r), (0.25, p), (0.35, r), (0.5, p), (1.0, h), (3, r)],
         [.keyDown, .keyUp, .keyDown, .keyUp, .keyDown, prep2, two, .keyUp]),
    ]
    var failures: [String] = []
    for (name, commands, events, expected) in cases {
        var gesture = Gesture(tapTerm: 0.4, holdTerm: 0.25, doubleTerm: 1.2, tripleTerm: 0.5, commands: commands)
        let got = events.flatMap { gesture.handle($0.1, at: $0.0) }
        if got != expected { failures.append("\(name): expected \(expected), got \(got)") }
    }
    return failures
}
