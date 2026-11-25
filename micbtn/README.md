# micbtn: a mic's talk button as a keyboard key

Hold the button on a push-to-talk mic and the Mac sees Fn held (or any key you pick). Let go and the key
comes up. One button opens the mic and starts dictation.

## How it works

A mic like the Teenage Engineering EP-2350 has an analog talk button: audio only leaves the mic while it
is held. Plugged in through a USB-C audio cable, the Mac sees a plain "USB Audio" device that belongs to
the cable's chip. The button sends no HID report and flips no mute flag, so there is nothing to remap.

What does change is the audio. Button up, the line is dead and the input sits at its idle noise floor.
Button down lands a click hundreds of times louder, then the mic's own hiss and your voice. Connecting the
mic also steps the line one way and disconnecting it steps it the other, so each click leaves a slow tail in
the signal's offset: up after a press, far down after a release. Speech and knocks leave none. `micbtn`
listens in ~10 ms buffers and measures everything against the idle floor (the median of the last two
seconds with the button up), so a different cable or input volume needs no tuning:

- **key down** on the first buffer at 100x the floor (the press click), about 10 to 20 ms after the press.
  A click too quiet for that still fires about 50 ms later, when its press tail shows.
- **key up** about 45 ms after release, read off the release tail. Nothing in the room can change it, and
  a pause mid-sentence, however quiet, is not a release. Three slower checks back it up, so the key is never
  left down: half a second of dead line, a line that settled at a new floor, and 30 s of nothing but hiss.
- **a knock** on the mic or the cable can be as loud as a click, but has no press tail behind it: the key
  comes back up about 150 ms later and it never counts toward a gesture.

## Double tap: Enter

Tap the button twice and the Mac gets Return: dictate, let go, tap tap, sent. Both presses are taps (up to
400 ms each, `--tap-term`), the second starting within 1200 ms of the first one's start (`--double-term`).
It needs no `--double` command.

## Tap, then hold: a second gesture

Tap the button, then press again and keep holding. Once the second press has lasted longer than a tap does
(`--hold-term`, 240 ms: measured taps last at most ~215 ms and holds at least ~800 ms), it runs the
`--double` command. It is a normal key hold from
its first moment: the key goes down at once, before it is known which gesture this is, so nothing you say
is lost. `claude-split.sh` is the one we use: it splits the current iTerm
pane vertically and starts Claude Code in the new pane on the model it is given, so you tap, hold, and
dictate straight into a fresh session.

## Tap, tap, then hold: a third gesture

With `--triple`, two taps and then a hold run that command the same way. We run
`claude-split.sh claude-opus-5-5` on tap-then-hold and `claude-split.sh claude-fable-5-2` on tap-tap-hold
(full model names: the `opus` alias still resolved to Opus 4.8). The third press has to start within 500 ms of the
second tap's release (`--triple-term`). That is also how long a double tap's Enter waits before it is sent,
only when `--triple` is set: two taps then nothing is still Enter, and three taps are still one Enter.

The tap and the gap are the double tap's. A short sound says it registered. A `--double` command that has
not exited after 5 s is killed, and its exit status is in the log. A knock or a press with no click
(a "soft" press) never counts as either half: no pane opens and no Enter is sent on a guess.

**Letting go always ends it.** Granola and Wispr Flow read two quick Fn presses as hands-free mode, where
dictation locks on and ignores the key coming up. A tap-then-hold is exactly that to them. So when the key
goes down within 700 ms of the last time, micbtn posts a Shift tap first: the app then sees two separate
presses, and the second is a normal hold that ends when you let go. Hands-free is still there from the
keyboard.

## Under 500 ms from the press to a running Claude

The budget, measured from the second (or third) press going down to the new pane showing a ready prompt:

| stage | ms |
|---|---|
| press read off the audio | ~15 |
| told apart from a tap: `--hold-term` + the ~55 ms a release takes to be read | ~295 |
| `go` reaches osascript, `claude-warm take` | ~10 |
| iTerm splits and starts the pane's command | ~90-140 |
| dtach attaches; Claude redraws its prompt | ~20 |
| **total** | **~430-480** |

Two things make that possible:

- **The command starts before the gesture is known.** micbtn starts `--double`/`--triple` the moment the press
  that may become it goes down, with a pipe on its stdin, then writes `go` when the hold is decided or closes
  the pipe when it was a tap. A command has to wait for that line before doing anything visible.
  `claude-split.sh` spends the wait starting bash and osascript, compiling its AppleScript and asking iTerm
  for the current pane's directory, so after `go` only the split is left.
- **Claude Code is already running.** A cold `claude` needs ~310 ms to draw its prompt. `claude-warm` keeps
  one session per model per recently used directory running detached under `dtach`; the pane attaches to it
  and a replacement starts behind it. A directory with nothing warm starts cold once and is warm next time.
  Sessions are recycled after 30 minutes (Claude Code reads CLAUDE.md, git status and the date at start), only
  the last 4 model/directory pairs are kept (each is a ~400 MB process), and closing the pane ends its session.
  `claude-warm install` runs the refresh every 10 minutes; `claude-warm status` lists them.
  It needs `brew install dtach`.

## A wireless mic with a HID button (DJI Mic Mini)

The DJI Mic Mini is the opposite kind of mic: always live, so there is no dead line to read a click off,
and its receiver reports the transmitter's **linking button** over USB as a Volume Up key, down and up a
millisecond apart. There is no hold to read. So the button is a toggle around the dictation app's
hands-free mode, and it runs as a second process (`micbtn --button`, launchd job `io.github.bhaktatejas922.micbtn.button`)
that reads no audio and shares nothing with the analog mic's process.

| You do | It does |
|---|---|
| one click | at once: Fn+Space (the hands-free shortcut), into whatever has focus. Nothing waits to see whether more clicks follow |
| two more clicks, each within `--click-term` (1.5 s) of the one before | the `--triple-click` command on the third: `claude-split.sh` splits the iTerm pane and starts Claude in it. Dictation is already running and Granola pastes into whatever has focus when it ends, so the text lands in the new pane |
| one click while dictating, after that | one Fn press (dictation ends), then Enter once the text has landed |
| one click with dictation already running (started from the keyboard) | the same: it ends and sends, and opens nothing |

Two fast presses are left alone: on the transmitter that starts pairing. The power button never reaches the
Mac (it switches noise cancelling on the transmitter), so it cannot be used.

- **Press to open mic in ~200 ms, nearly all of it Granola's.** micbtn's part is ~5 ms, and each line of the
  log says where the time went (`timing: ... dictation keys done +2 ... opened the mic +179 ms`). It was
  ~450 ms: asking CoreAudio about all ~50 audio processes on every click (30-140 ms), App Nap stretching
  the sleeps between two Fn presses (200 ms of sleeps took 420), and the two presses themselves. Now the
  mic state is kept current from CoreAudio's device notifications, App Nap is off for the app, and the
  start is one Fn+Space chord sent back to back.
- **Enter waits for the text, not for a timer.** Transcribing takes longer the more was said. The dictation
  app puts the text in with a key of its own (Granola posts one Cmd+V); micbtn watches for keys from another
  process and sends Enter 150 ms after they stop. If none comes in 20 s (`--insert-timeout`: nothing was
  said), no Enter is sent and it plays the error sound. It sees who pressed a key, never which key.
- **The press is micbtn's alone.** The receiver's HID interface is seized, so macOS no longer turns the
  volume up on every click. If macOS asks, turn on MicBtn under Privacy & Security > Input Monitoring.
- **It asks whether dictation is running; it does not remember.** A toggle that only counts its own clicks
  is wrong the moment dictation ends another way: click, pane opens, Escape, and the next click used to be
  read as "stop" (it started a 40 ms dictation instead, and the button then ignored every press for 20 s).
  CoreAudio knows which apps are reading a mic, the same fact as the orange dot, so micbtn looks: Granola
  opens the mic ~250 ms after dictation starts and closes it ~100 ms after it ends. While dictating it looks
  five times a second and, once the mic has been closed for longer than the app takes to open it (1.5 s),
  the round is over: Escape, Granola's own stop, Fn from the keyboard, or a start that never took. The log
  says `the dictation app's mic is closed: dictation ended with no click`, and the next click starts a new
  round. Every click also looks first, so one that finds dictation running ends it, whoever started it.
  `--dictation-app <bundle id>` names another app (default `com.granola.app`); until that app has been
  seen opening the mic once, nothing is concluded from a closed one and the log says so.
- **Never a dead button.** After the click that ends dictation, a second click within 3 s is a nervous one
  and is ignored. A later one means no text is coming (nothing was said) and starts the next round.
- **The rest that ends it.** The receiver unplugged, the Mac going to sleep or a failed command end the
  dictation with no Enter. Ten minutes with no click (`--armed-timeout`) and it forgets the round. A
  restart while dictating picks the round up where it was.
- **While Granola records a meeting its mic is open the whole time**, so every click reads as "dictation
  is running" and only ends: the button cannot start dictation during a recorded meeting.
- **The analog decoder never listens to this mic.** A USB input whose model carries the button's vendor id
  is skipped when picking the input (`micbtn --inputs` says so); `--device` still forces it.

### Dictate into the window you are looking at (optional)

With the eye tracker at the top of this repo set up, the click that starts dictation also left-clicks where your eyes
are, so the text and the Enter land in that window or pane. Dictation starts at once and the click lands
about 0.3 s later, while you are already talking: the text only goes in when dictation ends. The click
that ends dictation clicks nothing.

```bash
./install.sh && gaze        # install, then calibrate once (about a minute per screen)
./install.sh --daemon       # the tracker's daemon at login; allow Camera for MicBtn
```

- **Nothing changes without it.** micbtn asks the daemon over a local socket. No socket (gaze was never
  installed, or its daemon is stopped) means no question and no click. `--no-gaze` turns it off with the
  daemon running.
- **It never holds dictation back.** The tracker is asked as dictation starts and is not waited on. An
  answer later than `--gaze-timeout` (1000 ms), no face, or a gaze off the screens: no click.
- **It is a real click.** It lands within a centimetre or two of where you look, so look at the middle of
  the pane, not at a button in it. The pointer stays where it clicked.
- **See it first.** `./install.sh --daemon --glow` puts a small dot in the corner of the iTerm pane
  you are looking at, and the click then always lands inside that pane. It also makes the answer instant.
- `micbtn --gaze` prints what the daemon says right now. The button's log has one line per click:
  `gaze: click at 745,-866 (external, answered in 309 ms, clicked 310 ms after the button)`.

The analog mic's hold does not use it: only the `--button` click does.

Install it by adding the triple-click command to the usual install line:
`--triple-click "$PWD/micbtn/claude-split.sh claude-opus-5-5"`. `--click` (a command on the single click as
well, at once) is still accepted; without it a single click is dictation only.
Like `--double`, each command waits for `go` on stdin; a click has no press to wait out, so it is told `go` as it starts.

Log: `~/Library/Logs/micbtn-button.log`, one line per click. `micbtn --button --levels` logs what each
click would do and sends no keys.

## Install

Plug the mic in, then:

```bash
git clone https://github.com/bhaktatejas922/gaze && cd gaze
xcode-select --install                                        # once: micbtn is built from source
brew install dtach && ./micbtn/claude-warm install          # warm Claude sessions for the splits
./micbtn/install.sh \
  --double "$PWD/micbtn/claude-split.sh claude-opus-5-5" \
  --triple "$PWD/micbtn/claude-split.sh claude-fable-5-2"   # Fn, plus iTerm split + claude: tap-hold Opus, tap-tap-hold Fable
./micbtn/install.sh                                           # Fn only
./micbtn/install.sh --uninstall
```

The installer builds the app from the Swift sources, tests the gesture table, signs it with a local identity
it creates once in your login keychain (so macOS keeps its permissions across rebuilds), copies it into
`~/Applications/MicBtn.app`, starts it at login under launchd, and stays on screen until it is
listening, printing whatever it is waiting on:

1. Allow the **Microphone** prompt.
2. It opens System Settings > Privacy & Security > Accessibility: turn on **MicBtn**. It picks the
   switch up within a few seconds; there is nothing to restart.
3. With `--double`, the first tap-then-hold asks to let MicBtn control iTerm.

It runs on macOS 14 and later, Apple silicon and Intel. Log: `~/Library/Logs/micbtn.log`.

**Unplugging.** The mic does not have to be there. Installed with it unplugged, or unplugged later,
`micbtn` idles (no audio is read, no orange dot) and starts listening within a second or two of the mic being
plugged in. Unplugging mid-hold lifts the key. The log says `waiting: no USB input plugged in` while it idles.

**Which input.** With one USB audio input plugged in, that is the one. With several, it takes the system
default input if that is a USB one; otherwise pass `--device` with any part of the name shown in System
Settings > Sound > Input. `~/Applications/MicBtn.app/Contents/MacOS/micbtn --inputs` lists them and says
which it would pick.

**Which key.** `--key` takes `fn` (default), `f13`..`f20` or a virtual keycode.

**After `git pull`.** Re-run the installer. It signs every build with the same local identity, so macOS sees
the same app and the permissions carry over: Accessibility is one click, once. A build whose gesture table
fails its self-test never replaces the one that works.

**The menu-bar mic** shows the state at a glance: filled when listening, circled while the key is held,
slashed while the mic is unplugged, a warning triangle when a permission is missing. Its menu opens the log.

## Measuring it

`./micbtn/window.sh` records a 3-minute window of real presses with spoken cues (holds, silent holds,
tap-then-holds, lazy tap-then-holds, taps, one long talking hold) and scores the decoder against what you
were asked to do. `./micbtn/capture.sh` is the long version (about 5 minutes, with knocks). micbtn is
stopped while either runs, so nothing is typed. The audio stays in
`~/Library/Application Support/micbtn/corpus/`. A cue you did differently from what was asked (six presses
for five) is corrected in that corpus's `expect` file, one `name presses doubles longest shortest` per line.

```bash
micbtn --eval "<corpus dir>"            # every step: ok, or what was misread
micbtn --eval "<corpus dir>" --verbose  # with every press and release
micbtn --replay "<file.raw>"            # one recording, every edge
micbtn --self-test                      # the gesture table, no mic needed
```

Change the decoder against this, not by feel: a change ships when the eval passes on every corpus kept.

**Misses keep their own audio.** A press that was never read leaves nothing in the log, so micbtn keeps the
last 20 s of audio in memory and writes the last 8 s to `corpus/suspects/<time>-<reason>.raw` whenever it
is unsure of a reading: a click that fired nothing (`blip`), a press read off its tail (`quiet-click`) or
barely over the level (`weak-click`), a soft press, and any release that was not read off its tail. When it
was sure and wrong, the menu-bar item "That press was misread: keep the last 20 s" saves it by hand as
`<time>-missed.raw`. Each file replays with `micbtn --replay`. The folder is kept under 300 MB, never
leaves this Mac, and `--no-suspects` turns it off.

## If it does not trigger

`~/Library/Logs/micbtn.log` has one line per press and release, with the wall-clock time and the reason:

```
11:52:03.120 press (click, rms 16949, floor 9.1) -> key down
11:52:03.260 release (96 ms, released, seen 42 ms later, ...) -> key up
11:52:03.420 press (click, rms 15120, floor 9.1) -> key down, after a tap
11:52:03.920 tap, then hold: running --double
11:52:04.410 --double exit 0, 140 ms after go (started 300 ms before it)
11:52:12.300 release (...) -> key up, double tap: Enter unless a third press comes
11:52:12.900 double tap: Enter
11:52:09.150 release (5780 ms, released, seen 42 ms later, ...) -> key up
```

- `waiting: no USB input plugged in` with the mic plugged in: the Mac does not see it as a USB input.
  `micbtn --inputs` lists what it sees.
- Nothing in the log at all: it is not running. `launchctl print gui/$(id -u)/io.github.bhaktatejas922.micbtn` should say
  `state = running`; re-run the installer if it is missing. Run it only through the installer, never as a
  loose binary: only the launchd job restarts it after an unplug, sleep or reboot.
- No `down` on a press: the click is under 100x the floor. Lower `--on` (try 50). Too low and a knock on
  the mic taps the key.
- `release (... line dead ...)` while you are still holding and silent: the mic's hiss is within 1.25x of the
  floor. Lower `--off` (1.1).
- `stray: that click was a release`: the key had come up while the button was still down, or the press
  was never read. The line before it says which, and the audio is in `corpus/suspects/`.
- `lone click, no press behind it`: a knock, or the mic being put down.
- `key up, double tap: Enter` is the other ending of `after a tap`: the second press was let go in time.
- `--double exit 1`: the command failed; its own error is the line above.
- `needs Accessibility` in the log forever with MicBtn switched on: the switch belongs to an older build.
  Re-run the installer, which clears it.

**Replaying a misread press.** Every hold's levels and offsets are kept in `~/Library/Logs/micbtn.trace` (no
audio; it starts over at 16 MB). `micbtn --replay ~/Library/Logs/micbtn.trace --double x` runs them through
the same logic and prints what it would do, without sending keys, so a change can be checked against the
presses that went wrong. `micbtn --levels` shows the live levels the same way.

## Limits

- The orange mic-in-use dot stays on, because the input is always being read.
- It only works for a mic that goes silent with the button up. A mic that is always live has no edge to read.
- A hard knock on the mic still taps the key for about 150 ms before it is told apart from a press. It
  never opens a pane.
- The key is posted in software. An app that reads the physical keyboard directly will not see it; pick
  another `--key` and bind that in the app.
