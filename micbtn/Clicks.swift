// The click gesture, for a button that only clicks: a wireless mic whose receiver reports each press over
// HID as one instant, with no hold to read (`micbtn --button`). Like Gesture.swift it holds no clock and
// posts nothing, so every sequence can be tested as a table (`micbtn --self-test`).
//
// The button is a toggle around the dictation app's hands-free mode:
//
//   idle      a click starts dictation at once, and runs the --click command if there is one: nothing waits
//             to see whether more clicks follow. If dictation is already running (started from the
//             keyboard), the click ends it instead, like any click while armed.
//   armed     dictation is running. A second and a third click, each within `clickTerm` of the one
//             before, belong to the click that armed it: the third runs the --triple-click command (we run
//             claude-split.sh: a new pane, which the dictation already running then lands in, since the
//             app pastes into whatever has focus when it ends). (Two fast presses are not a gesture: on the DJI
//             transmitter they start pairing.) Any later click ends dictation, and Enter follows once the
//             text has landed. A fourth click of the burst is ignored.
//   sending   dictation was ended and its text is on the way. A click in the first `sendGrace` is a nervous
//             second press and is ignored, so it never opens a pane under text still arriving. A later one
//             means nothing is coming (nothing was said): it starts the next round, never a dead button.
//
// The gesture never trusts its own memory of whether dictation is running. Every click comes with the
// answer (`dictating`: the dictation app has the mic open), and whatever else ends the dictation is told to
// it: Escape, the keyboard or the app itself (`endedElsewhere`, when the mic is seen closed), the receiver
// going away or the Mac going to sleep (`interrupted`), a command that failed, or nothing for `armedTimeout`.

struct Clicks {
    enum Event: Equatable {
        case click, commandFailed, inserted, gaveUp, endedElsewhere, expired
        case interrupted(String)
    }
    enum Action: Equatable { case startDictation, run(clicks: Int), endDictation, enter, fault(String) }
    enum State: String { case idle, armed, sending }

    var clickTerm: Double
    var armedTimeout: Double
    var insertTimeout: Double
    var sendGrace: Double
    private(set) var state = State.idle
    private var since = 0.0  // armed: the click that armed it. sending: the click that ended it.
    private var burst = 0    // armed: clicks in the burst that armed it; 0 once the burst is over
    private var last = 0.0   // armed: the burst's latest click

    init(clickTerm: Double, armedTimeout: Double, insertTimeout: Double, sendGrace: Double = 3) {
        self.clickTerm = clickTerm; self.armedTimeout = armedTimeout; self.insertTimeout = insertTimeout; self.sendGrace = sendGrace
    }

    /// A process that restarts while dictation is running picks the state up where it was left.
    mutating func resume(armedAt time: Double) {
        enter(.armed, at: time)
    }

    /// `time` is when the event happened, in seconds on any one clock: a click's is the receiver's own.
    /// `dictating` is whether dictation is really running at a click, as far as the mic shows.
    mutating func handle(_ event: Event, at time: Double, dictating: Bool = false) -> [Action] {
        switch (state, event) {
        case (.idle, .click), (.sending, .click):
            if state == .sending, time - since <= sendGrace { return [] }
            guard !dictating else {
                // Started from the keyboard, or left running by a round this one lost track of.
                enter(.sending, at: time)
                return [.endDictation]
            }
            enter(.armed, at: time)
            burst = 1
            last = time
            return [.startDictation, .run(clicks: 1)]
        case (.armed, .click):
            guard burst == 0 || time - last > clickTerm else {
                // Still the burst that armed it. After the third, the rest of it is ignored.
                burst += 1
                last = time
                return burst == 3 ? [.run(clicks: 3)] : []
            }
            enter(.sending, at: time)
            return [.endDictation]
        case (.armed, .commandFailed):
            // Dictation started on the click, but there is no pane for it to land in.
            enter(.idle, at: time)
            return [.endDictation, .fault("the command failed")]
        case (.armed, .endedElsewhere):
            enter(.idle, at: time)
            return []
        case (.armed, .expired):
            guard time - since >= armedTimeout else { return [] }
            enter(.idle, at: time)
            return [.fault("nothing for \(Int(armedTimeout)) s")]
        case (.armed, .interrupted(let why)):
            enter(.idle, at: time)
            return [.endDictation, .fault(why)]
        case (.sending, .inserted):
            enter(.idle, at: time)
            return [.enter]
        case (.sending, .gaveUp):
            guard time - since >= insertTimeout else { return [] }
            enter(.idle, at: time)
            return [.fault("no text arrived")]
        default:
            return []
        }
    }

    private mutating func enter(_ next: State, at time: Double) {
        state = next
        since = time
        burst = 0
    }
}

/// Every sequence the button can produce, with the exact actions expected. Times are seconds.
func clickFailures() -> [String] {
    typealias E = Clicks.Event
    typealias A = Clicks.Action
    typealias Step = (at: Double, event: E, dictating: Bool)
    let c = E.click, gone = E.interrupted("gone")
    let start = A.startDictation, end = A.endDictation, one = A.run(clicks: 1), three = A.run(clicks: 3)
    // Clicks of one burst are at most 1.5 s apart.
    let plain: [(String, [(Double, E)], [A], Clicks.State)] = [
        ("one click starts dictation and runs --click at once", [(0, c)], [start, one], .armed),
        ("the full round: click, talk, click, text lands, Enter", [(0, c), (8, c), (9.2, .inserted)], [start, one, end, .enter], .idle),
        ("a second click of the burst does nothing", [(0, c), (1.1, c)], [start, one], .armed),
        ("two clicks, then a later one ends it", [(0, c), (1.1, c), (8, c)], [start, one, end], .sending),
        ("three clicks run --triple-click on the third", [(0, c), (1.1, c), (2.2, c)], [start, one, three], .armed),
        ("a fourth and fifth click of the burst are ignored", [(0, c), (1.1, c), (2.2, c), (3.3, c), (4.4, c)], [start, one, three], .armed),
        ("a click well after three ends it", [(0, c), (1.1, c), (2.2, c), (9, c), (10, .inserted)], [start, one, three, end, .enter], .idle),
        ("a click just past the burst's window ends it", [(0, c), (1.6, c)], [start, one, end], .sending),
        ("a third click too late after the second ends it", [(0, c), (1.1, c), (2.7, c)], [start, one, end], .sending),
        ("clicks while the text is on its way are ignored", [(0, c), (8, c), (8.3, c), (8.6, c), (9.2, .inserted)], [start, one, end, .enter], .idle),
        ("a click well after the end, with no text: nothing was said, the next round starts", [(0, c), (8, c), (11.5, c)], [start, one, end, start, one], .armed),
        ("text that lands after the next round started is not sent", [(0, c), (8, c), (11.5, c), (12, .inserted)], [start, one, end, start, one], .armed),
        ("Escape, then a click: a new round, not an end", [(0, c), (3, .endedElsewhere), (60, c), (70, c), (71, .inserted)], [start, one, start, one, end, .enter], .idle),
        ("a click after Enter starts the next round", [(0, c), (8, c), (9.2, .inserted), (9.5, c)], [start, one, end, .enter, start, one], .armed),
        ("nothing was said: no Enter", [(0, c), (8, c), (28, .gaveUp)], [start, one, end, .fault("no text arrived")], .idle),
        ("an early give-up waits", [(0, c), (8, c), (10, .gaveUp)], [start, one, end], .sending),
        ("text that lands after the wait was given up sends nothing", [(0, c), (8, c), (28, .gaveUp), (29, .inserted)],
         [start, one, end, .fault("no text arrived")], .idle),
        ("ended from the keyboard: the next click starts over", [(0, c), (5, .endedElsewhere), (9, c)], [start, one, start, one], .armed),
        ("text landing while armed is not ours to send", [(0, c), (5, .inserted)], [start, one], .armed),
        ("the command failed: dictation ends, no Enter", [(0, c), (0.5, .commandFailed)], [start, one, end, .fault("the command failed")], .idle),
        ("the command failed after dictation was already ended", [(0, c), (2.0, c), (2.1, .commandFailed), (3, .inserted)], [start, one, end, .enter], .idle),
        ("the receiver went away while armed", [(0, c), (5, gone)], [start, one, end, .fault("gone")], .idle),
        ("the receiver going away while idle is nothing", [(0, gone)], [], .idle),
        ("the receiver going away while text is on its way still sends it", [(0, c), (8, c), (8.5, gone), (9.2, .inserted)], [start, one, end, .enter], .idle),
        ("armed for too long", [(0, c), (601, .expired)], [start, one, .fault("nothing for 600 s")], .idle),
        ("an early expiry waits", [(0, c), (300, .expired)], [start, one], .armed),
        ("an expiry left from an earlier round waits", [(0, c), (8, c), (9, .inserted), (500, c), (601, .expired)],
         [start, one, end, .enter, start, one], .armed),
    ]
    // Clicks that find dictation already running: the mic is open before the click.
    let live: [(String, [Step], [A], Clicks.State)] = [
        ("started from the keyboard: a click ends it and sends", [(0, c, true), (1, .inserted, false)], [end, .enter], .idle),
        ("started from the keyboard while a wait was running out", [(0, c, false), (8, c, true), (30, c, true), (31, .inserted, false)],
         [start, one, end, end, .enter], .idle),
        ("a nervous click is ignored even with the mic still closing", [(0, c, false), (8, c, true), (8.2, c, true)], [start, one, end], .sending),
    ]
    let cases = plain.map { ($0.0, $0.1.map { Step($0.0, $0.1, false) }, $0.2, $0.3) } + live
    var failures: [String] = []
    for (name, events, expected, state) in cases {
        var clicks = Clicks(clickTerm: 1.5, armedTimeout: 600, insertTimeout: 20)
        let got = events.flatMap { clicks.handle($0.event, at: $0.at, dictating: $0.dictating) }
        if got != expected { failures.append("clicks, \(name): expected \(expected), got \(got)") }
        if clicks.state != state { failures.append("clicks, \(name): expected to end \(state), ended \(clicks.state)") }
    }
    var resumed = Clicks(clickTerm: 1.5, armedTimeout: 600, insertTimeout: 20)
    resumed.resume(armedAt: 100)
    if resumed.handle(.click, at: 100.5) != [end] { failures.append("clicks, resumed armed: a click did not end dictation") }
    return failures
}
