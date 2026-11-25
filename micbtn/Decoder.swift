// The decoder: audio in, press and release edges out. It posts no keys and knows no gestures.
//
// The mic's talk button is analog. With it up the line is dead and idles at its noise floor. Pressing it
// lands a click hundreds of times louder and opens the mic, whose hiss then sits a few floors up even in a
// silent room. Letting go lands another click and disconnects the mic.
//
// Loudness says that something happened; the offset says what. Connecting the mic steps the line one way
// and disconnecting it steps it the other, so each click leaves a slow tail in the buffer's mean:
//
//   press     the mean settles near +80x floor a few buffers after the click and fades over ~60 ms
//   release   the mean drops about five times as far the other way and fades by a third every buffer
//
// Speech swings both ways inside one buffer, so its mean is small beside its level, and a knock on the mic
// leaves no step at all. A plosive loud enough to overload the mic does leave a tail as it recovers, the
// same shape as a release but smaller, so a release is measured against the press tail: the two steps are
// the same switch, and their sizes stay in step whatever the cable or the input volume.
//
// Following QMK's asym_eager_defer and libinput's debounce, the press is reported at once and the release
// only once it is certain:
//
//   press     one buffer at --on x floor (the click). A click too quiet for that still fires ~50 ms later,
//             when its press tail is seen. 30 buffers in a row at 4x is a press with no click at all.
//   release   released  the release tail, two buffers of it: ~45 ms after letting go
//             dead      half a second whose median is under --off x floor, for a release with no click
//             settled   1.5 s of steady noise under 1.8x floor: the floor itself has moved, and this is it
//             silent    30 s with nothing louder than hiss, so the key is never left down for good
//
// A click the key went down for is checked against its tail. A release tail straight after it means the
// button had been down all along and that click was the release. No press tail and a dead line means a
// knock. Both end the hold as a stray release, which keeps the key right but never counts toward a gesture.
//
// The floor may fall at once but only creeps up (5% a second). When a release is ever misjudged, the open
// mic's hiss is what gets measured as "idle", and a floor that followed it would call the next quiet hold
// dead too.

import Foundation

struct Edge {
    /// A soft press had no click, and a stray release had no discharge: the decoder is catching up with the
    /// button, and the time is approximate.
    enum Kind: Equatable { case press(soft: Bool), release(stray: Bool) }
    var isPress: Bool { if case .press = kind { return true } else { return false } }
    let kind: Kind
    let time: Double    // when it happened at the button, seconds on the decoder's clock
    let detail: String  // for the log
}

final class Decoder {
    var onEdge: (Edge) -> Void = { _ in }
    var onLevel: ((_ rms: Double, _ mean: Double, _ active: Bool) -> Void)?  // every buffer, for the trace
    var onSuspect: ((_ reason: String) -> Void)?  // a reading the decoder is unsure of, worth keeping the audio for
    var reportLevels = false
    private(set) var held = false
    private(set) var floor = 0.0  // 0 until the first second has been heard

    private var idle: [Double] = []  // levels of the last two seconds with the button up
    private var last: [Double] = []  // the last 12 levels: a click and what follows it
    private var means: [Double] = []  // the same 12 buffers' means: the tail a click leaves
    private var confirmed = false  // this hold's press tail has been seen
    private var heights: [Double] = []  // the peak of each of the last nine press tails
    private var step = 0.0  // their median: one press that began mid-word does not move it
    private var transient = -1000  // `count` at the last buffer over the quiet-press level with the button up
    private var blip = -1000  // `count` at a transient that has fired nothing yet
    private var count = 0  // buffers heard, dropped packets included: the decoder's clock
    private var loud = 0  // consecutive buffers over the soft-press level
    private var silent = 0  // consecutive buffers of a hold under it
    private var pressedAt = 0, byClick = false  // `count` when the hold began, and how
    private var releasedAt = -1000  // `count` when the last hold ended
    private var clicks: [Int] = []  // `count` at each click of this hold
    private var hold: [Double] = []  // levels of the last 1.5 s of the hold
    private var second = 0, low = Double.infinity, high = 0.0

    var time: Double { Double(count) * bufferSeconds }
    private func time(_ at: Int) -> Double { Double(at) * bufferSeconds }
    private func ms(since at: Int) -> Int { Int(Double(count - at) * bufferSeconds * 1000) }

    /// One buffer of 16-bit samples.
    func hear(_ samples: UnsafeBufferPointer<Int16>) {
        guard !samples.isEmpty else { return }
        var sum = 0.0, squares = 0.0
        for sample in samples { let v = Double(sample); sum += v; squares += v * v }
        let mean = sum / Double(samples.count)
        hear(max(0, squares / Double(samples.count) - mean * mean).squareRoot(), mean: mean)
    }

    /// One buffer's level, and its mean.
    func hear(_ rms: Double, mean: Double = 0) {
        count += 1
        // Exact digital silence is a dropped USB packet, not a level: the idle line still carries noise.
        // Counting it would read a glitch as the button being let go.
        guard rms >= 0.5 else { return }
        guard floor > 0 else { track(idle: rms); return }
        if reportLevels { report(rms) }
        last.append(rms); means.append(mean)
        if last.count > 12 { last.removeFirst(); means.removeFirst() }
        held ? holding(rms) : waiting(rms)
        onLevel?(rms, mean, held || count - releasedAt < 94)
    }

    /// Ends a hold in progress, for when the audio is about to stop.
    func letGo() { if held { release(at: count, "stopping", stray: true) } }

    private func waiting(_ rms: Double) {
        loud = rms >= softRatio * floor ? loud + 1 : 0
        let settled = count - releasedAt > 30  // the first 0.3 s after a release is still its tail
        if settled, rms >= quietRatio * floor {
            if count - transient > 8 { blip = count }
            transient = count
        }
        if rms >= onRatio * floor {
            press(at: count, byClick: true, String(format: "click, rms %.0f, floor %.1f", rms, floor))
            if rms < 2 * onRatio * floor { onSuspect?("weak-click") }
        } else if settled, count - transient <= 7, pressTail() {
            press(at: transient, byClick: true, String(format: "quiet click, read off its tail, peak %.0f, floor %.1f", last.max() ?? 0, floor))
            confirm()
            onSuspect?("quiet-click")
        } else if loud >= softBuffers {
            press(at: count, byClick: false, String(format: "soft, rms %.0f, floor %.1f", rms, floor))
            onSuspect?("soft-press")
        } else {
            if loud == 0, settled { track(idle: rms) }
            // Something loud enough to be a quiet press came and went, and nothing was read from it.
            if count - blip == 10 { onSuspect?("blip") }
        }
    }

    private func press(at: Int, byClick click: Bool, _ detail: String) {
        held = true
        pressedAt = at; byClick = click
        loud = 0; silent = 0; confirmed = false; blip = -1000
        clicks = click ? [at] : []
        hold.removeAll(keepingCapacity: true)
        onEdge(Edge(kind: .press(soft: !click), time: time(at), detail: detail))
    }

    private func holding(_ rms: Double) {
        hold.append(rms)
        if hold.count > settleBuffers { hold.removeFirst() }
        silent = rms < softRatio * floor ? silent + 1 : 0

        if sawClick(), count - 5 - (clicks.last ?? -100) > 2 { clicks.append(count - 5) }  // the peak is 5 buffers back

        let age = count - pressedAt
        if !confirmed, age <= loneBuffers, pressTail() { confirm() }

        if let peak = releasePeak() {
            // The click that started this hold was itself the release: the button had been down all along.
            let stray = byClick && !confirmed && age <= 6
            release(at: stray ? pressedAt : peak, stray ? "stray: that click was a release" : "released", stray: stray)
        } else if byClick, !confirmed, age >= 8, age <= loneBuffers, last.suffix(6).sorted()[3] < deadRatio * floor {
            release(at: pressedAt, "lone click, no press behind it", stray: true)
        } else if hold.count >= deadWindow, hold.suffix(deadWindow).sorted()[deadWindow / 2] < deadRatio * floor {
            release(at: count - deadWindow, "line dead", stray: false)
        } else if hold.count == settleBuffers, count % 16 == 0 {
            // The floor moved a little while the button was down, so the dead level is wrong. Steady noise
            // near the old floor for 1.5 s is the dead line. An open mic's hiss is steady too, but sits higher.
            let sorted = hold.sorted()
            if sorted[settleBuffers * 9 / 10] < settleSpread * max(sorted[settleBuffers / 10], 0.1), sorted[settleBuffers / 2] < settleRatio * floor {
                idle = hold
                floor = max(1, sorted[settleBuffers / 2])
                release(at: count - settleBuffers, String(format: "line settled at a new floor of %.1f", floor), stray: true)
            } else if silent >= silentBuffers {
                release(at: count, "nothing but hiss for 30 s", stray: true)
            }
        }
    }

    private func release(at: Int, _ reason: String, stray: Bool) {
        let at = max(at, pressedAt)
        let detail = "\(Int(Double(at - pressedAt) * bufferSeconds * 1000)) ms, \(reason), seen \(ms(since: at)) ms later, "
            + "clicks at \(clicks.map { Int(Double($0 - pressedAt) * bufferSeconds * 1000) }), tail \(hold.suffix(24).map { String(Int($0)) }.joined(separator: " "))"
        held = false
        releasedAt = count
        onEdge(Edge(kind: .release(stray: stray), time: time(at), detail: detail))
        if reason != "released" { onSuspect?(reason.split(separator: " ").prefix(2).joined(separator: "-").filter { $0.isLetter || $0 == "-" }) }
    }

    /// `count` at the peak of a release click, when the last three buffers are its tail. Letting go throws
    /// the line far up for a buffer or two, then drops it several press tails below zero, and from there it
    /// fades by up to a half each buffer with almost nothing else in the buffer.
    ///
    /// Loud speech imitates parts of that. A plosive that overloads the mic leaves a tail of the right
    /// shape as it recovers, but it gets there from far below zero, not from above, and its tail breaks up
    /// within three buffers as the next syllable starts. A press click swings below zero too, and comes
    /// back four times faster. When this is too strict for a real release, the dead line still ends the
    /// hold half a second later; when it is too loose, a sentence is cut in two. So it is strict.
    private func releasePeak() -> Int? {
        guard means.count == 12 else { return nil }
        let a = means[9], b = means[10], c = means[11], tail = step > 0 ? step : 80 * floor
        guard min(means[8], a) <= -releaseDip * tail, c < 0 else { return nil }
        guard b <= 0.45 * a, b >= 0.95 * a, c <= 0.45 * b, c >= 0.95 * b else { return nil }
        guard last[9] <= 0.22 * -a, last[10] <= 0.22 * -b, last[11] <= 0.22 * -c else { return nil }
        let rise = means[5...8].firstIndex(of: means[5...8].max()!)!
        guard means[rise] >= releaseRise * tail, means[rise...].min()! >= -releaseFloor * tail else { return nil }
        let before = last[4..<9]
        guard before.max()! >= releaseClick * tail else { return nil }
        return count - 11 + before.firstIndex(of: before.max()!)!
    }

    private func confirm() {
        confirmed = true
        heights.append(means[9...].max()!)  // the plateau, not the click before it
        if heights.count > 9 { heights.removeFirst() }
        step = heights.sorted()[heights.count / 2]
    }

    /// True when the last two buffers are a press tail: the mean well above zero and holding steady, and
    /// almost nothing else in the buffer.
    private func pressTail() -> Bool {
        guard means.count == 12 else { return false }
        let a = means[10], b = means[11]
        return a >= pressStep * floor && b >= pressStep * floor && b >= 0.6 * a && b <= 1.25 * a
            && last[10] <= 0.4 * a && last[11] <= 0.4 * b
    }

    /// True when the buffer 5 back was a click: a peak far over the floor that was not there 2 buffers
    /// earlier and is gone 5 later. Speech rises and falls too slowly to pass.
    private func sawClick() -> Bool {
        guard last.count == 12 else { return false }
        let recent = Array(last[4...])
        let peak = recent[2]
        return peak >= clickRatio * floor && peak >= recent[1] && peak >= recent[3]
            && recent[0] < peak / clickDecay && recent[7] < peak / clickDecay
    }

    /// A median shrugs off a bump or a cough. It follows the line down at once and up only slowly.
    private func track(idle rms: Double) {
        idle.append(rms)
        if idle.count > 188 { idle.removeFirst() }
        guard idle.count >= 94, count % 8 == 0 || floor == 0 else { return }
        let median = max(1, idle.sorted()[idle.count / 2])
        guard floor > 0 else {
            floor = median
            log(String(format: "idle floor %.1f rms: press at %.0f, dead under %.1f", floor, onRatio * floor, deadRatio * floor))
            return
        }
        floor = min(median, floor * floorRise)
    }

    private func report(_ rms: Double) {
        low = min(low, rms); high = max(high, rms)
        let now = Int(time)
        guard now != second else { return }
        log(String(format: "rms min %.0f max %.0f (floor %.1f)", low, high, floor))
        second = now; low = .infinity; high = 0
    }
}
