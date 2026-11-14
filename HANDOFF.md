# Dex handoff

Current state only. History lives in git (`git log`, and the deleted dated
handoffs/notes before 31 October 2026 are in history). Update this file in
place at closeout; don't add dated copies.

## Picking up on another machine

Day-to-day work happens in the public repository,
[Meko-Six/dex-sw](https://github.com/Meko-Six/dex-sw) (GPL-3.0), from 6 November 2026.
Its history starts with one snapshot of `main`. Everything is in `main` there: the
audio fixes, the new engine and the redesigned deck keys. CI runs there free, on pull
requests and on pushes to `main`.

```sh
git clone git@github.com:Meko-Six/dex-sw.git dex && cd dex
```

The private `Meko-Six/Dex` is an archive of the earlier history and branches. On the
original Mac it's the `private` remote, and `origin` is dex-sw. Its CI doesn't run,
because its free minutes are used up. Don't publish its history or branches to dex-sw.
Never commit other companies' artwork or screenshots.

Then follow Setup below, and run `swift test --package-path native` to confirm the
machine is good.

Only this file and the repo travel. These stayed on the original Mac:

- **Private music** in `accuracy/audio/` (886 MB, ignored). Only the marked-song
  bench and the stretcher clips need it.
- **`out/`** (ignored), including the audit's full logs, the transfer ZIP and the
  gate 2 clips (`out/engine-clips/`). The evidence summary and probe are tracked in
  `docs/audio-audit/`.
- **The app's library, playlists and tracks**, in
  `~/Library/Application Support/DexNative` (`DexNativePreview` for package runs).
  Expect an empty library on a new machine until music is imported.
- **Claude's chat history and memory.** New sessions start from these docs. What
  the memory held that wasn't written down elsewhere is under Standing user
  decisions.

To run on the iPad, Xcode needs a signing team on that machine; the project is set
to team `33B24PEVAC`. All measurements came from the M3 MacBook Pro at 120 Hz and the
13-inch iPad Air M3, so another machine's numbers aren't a direct comparison, and the
Bose has to be paired again.

## Where things stand

- **Electron is frozen; native Swift is the app being built.** Electron (`src/`) gets no
  new features or UI; fix it only if it breaks. It stays in the repo, working, as the
  reference for parity and as the option for a PC version. Don't delete it. Native Swift
  (`native/`) is the Mac + iPad app, with transport, library and analysis largely done and
  the console ported.
- **New UI is designed in the HTML mockup** (`mockup/xdj-mixer-alt.html`,
  `mockup/console.css`), then ported to SwiftUI. Electron has its own frozen copy of the
  styles, so mockup changes don't reach it. Where the mockup is still ahead (ENERGY, a
  working TAP, ↻ and ✕), the app has to catch up.
- **The port is exact.** No deviation unless an improvement is raised and agreed first.
  The reference is the mockup (`npm run diff:native`, 42 screens). See
  [native/README.md](native/README.md) for scope and parity gates. Left: keyboard
  shortcuts, ENERGY, scroll zoom, and controls waiting on the engine (TAP input,
  re-analysis, removal). Key analysis is ported and matches Electron on the bench.
- **CI:** three jobs (Electron typecheck/test/build, Electron production integration,
  native tests plus Mac/iPad builds). GitHub's macOS runner ships an older Xcode than this
  Mac, so native code must compile on both SDKs. CI passed on `d60a6b6`; it was still
  running on `21213e5` (the transport work, pushed 13 November) at closeout, so check it.
- **Tests:** `swift test`, 13 November 2026 (14 Nov added the PHONES render test and set-history tests; 189 in the last full run, 0 failures): 346 tests (187 audio, 70 core, 47 engine,
  42 console), 0 failures, 6 optional skips.

### The engine (6 November 2026)

`Sources/CDexEngine` is one real-time loop that owns everything audible, driven by
`NativeDeck` and `NativeMixer` through `DexAudio/EngineCore.swift`; the AVAudioEngine graph
is one source node to the device. It holds the stretcher (Bungee) and SYNC's lock, and also
runs the LR4 isolator and headphone cue bus. `ConsoleModel` and `DexConsole` didn't change;
`NativeDeck.heardPosition(ahead:)` feeds the lanes. The old engine is removed. The brief,
[ENGINE-REBUILD-SPEC](docs/ENGINE-REBUILD-SPEC.md), has a clean-build rule that overrides
everything: never read Mixxx or any other GPL DJ engine, including the Mixxx links in the
audit and plan. The user chose Bungee on 5 November ("without doubt, bungee"), passed gate 3
on 6 November ("Pass, gate 4"), then played both engines and said of the new one: "way
better ... Super tight, nice and responsive, easy cue lineup, just miles ahead. time to say
goodbye to the old engine". Results: [ENGINE-STRETCHER-MEASUREMENTS](docs/ENGINE-STRETCHER-MEASUREMENTS.md)
(gates 1 and 2) and [ENGINE-GATE3-RESULTS](docs/ENGINE-GATE3-RESULTS.md) (gates 3 and 4, and
the removal).

- **Measured (gate 3):** waveform against sound under 0.9 ms with 0.006 ms drift between
  decks on the Mac (five minutes), under 0.44 ms with 0.018 ms drift on the iPad (three
  minutes). Release build: about 5% of a core on the Mac, 12.5% on the iPad, and 64 MiB
  more memory than the old engine, for the cache.
- **Musical differences from the old engine, all tested:** presses come out on the next
  block (10 ms more from stopped, for a whole attack); a quantized cue meets a beat still to
  come whole and joins a beat already gone 120 ms in; a start or plain seek that waits for
  the disk starts where asked; loops move at once; the end of a track shows when heard.
- **Things to know:** the tone section is flat only to 0.1% at DC (−0.009 dB). The master
  limiter hasn't been compared by ear with Apple's, though the user has played it and is
  happy. The LR4 isolator and cue bus (CUE, SPLIT CUE, 4-CH CUE, cue mix) are render-tested
  but not yet heard on headphones.
- **SYNC is a grid lock.** The user's rule: the grid is the truth, the master is the truth,
  and everything else, sound and display, follows it. The engine holds the lock; `NativeDeck`
  follows what was played (`playRate`, `holdLock`). A locked follower's lane shows
  `spanSec x masterBPM / ownBPM` seconds (`ConsoleState.laneSpan`), so beats match across the
  width; an agreed change from Electron, made in the mockup first. `GridLockTests` check B
  against A over minutes through bar jumps, loops and master hand-overs. Electron's master
  rules are ported (a deck playing alone leads, only when what's playing changes; starting
  beside a playing deck leaves that deck leading; MASTER re-lands a synced follower). The
  user hasn't been recorded as hearing the grid lock on the new engine.

### Output delay and the Bose

The playhead shows what is heard: graph time less the delay the device reports
(`OutputLatency`). Hot cues and loops set from it land on the heard beat; jog and SYNC stay
on graph time. The user saw the waveform line up on the Mac and iPad (4 November, on the
old engine). The Bose SoundLink Flex **under-reports its delay by an amount that changes
between connections** (4–20 ms seen; about 39 ms in absolute terms on 6 November), so the
waveform runs that far ahead of the sound there. Only a per-speaker offset, measured or set
by hand, could remove it, and none exists or has been agreed. The engine's own error on the
Bose is 1–3 ms. The Mac's built-in speakers report 15.8 ms; the Bose 253.2 ms. Recalling a
cue still quantises on graph time, so it stays in phase but can land a beat later than it
was pressed on Bluetooth. Method and numbers: [EVIDENCE](docs/audio-audit/EVIDENCE.md) and
[ENGINE-GATE3-RESULTS](docs/ENGINE-GATE3-RESULTS.md).

### The lanes

- **They scroll at a steady 60 frames a second on the Mac, and the user tried it with no
  issues** on the built-in speakers (smoothness, sync, transport and sound). Measured
  (`DexWaveProfile`): 60.0 updates a second, 0% uneven steps without audio, 0.1–0.2% with
  audio and the engine. On the Bose the user found the waveform really good on Mac and iPad,
  smooth with no real jumps.
- `FrameLink` runs a display link fixed at 60 Hz (a `Timer` on macOS 13); `ConsoleClock`
  is split per deck and meter so each update redraws only what it moves; columns are
  anchored in track time and slide by the remainder (`lanePlace`); `WaveTiles` caches
  finished images (8 MiB cap). Don't drop the tiles to save memory without measuring
  again: without them the main thread stalled and the display link fired late. Tiles are
  built on the main thread (at most about 6 ms, once every few seconds per lane); recheck
  on the iPad, where a late tile would show as a periodic hitch.
- **Dragging a lane coasts on release, scaled by zoom; the user tried it and loves it
  (4 November; which device wasn't said).** `JogFling` makes the same hand speed carry the playhead the same
  track distance at any zoom, as a platter would; the hardest flick travels 3.33 s of track.
  Mac and iPad share the code, for mouse and touch alike. A touch on a coasting lane catches
  it at once. **It's signed off; leave it unless the user asks.** To tune it,
  `JogFling.referenceDamping` sets how far a flick goes (lower is further). The lane's speed
  at release still starts the coast, so pitch doesn't jump: a zoomed-in coast starts slower
  and runs longer (up to 6 s), and on a playing deck the music resumes only when the coast
  ends, so it can hold the music off that long unless a touch catches it. Handing back to
  the music as the coast reaches playing speed is an option if that drags, but it needs a
  clean audio handover.
- **Should the platter coast too?** Open. It still stops where it lifts, because the control
  map calls it precise. The user asked about the scrub and mouse dragging on the lanes.
- **The user's iPad pass came back quite good, with nothing really bad and one request (4
  November):** far more scrub inertia, now built. The list was audible waveform scrubbing and
  inertia, held CUE, hot-cue timing windows, bar jumps, loop halving (shrinking keeps the
  half the playhead is in), and the console's multi-touch gestures (two faders at once, kill
  hold/latch, CUE → PLAY slide). They didn't itemise it, so don't report any single item as
  measured or as individually signed off.
- **Distortion fixed; the user heard it clean (3 November).** The precise cause was never
  isolated (several fixes landed together; it only showed in a recording of the real app).
  The tone section now feeds only its fader and copies its output to the cue.

## Audio work still open

The brief is [AUDIO-IMPLEMENTATION-PLAN](docs/AUDIO-IMPLEMENTATION-PLAN.md); its completion
record and sections on the old players, launch transaction, `stretchDelay` and Apple's
time-pitch are history. Background: [AUDIO-ARCHITECTURE-AUDIT](docs/AUDIO-ARCHITECTURE-AUDIT.md),
`docs/audio-audit/`. The user wants reliable audio, efficient CPU and memory, accurately
synced waveforms, and full DJ use over Bluetooth on the Bose SoundLink Flex including cueing
and scrubbing, Mac and iPad of equal priority. Don't promise to remove a speaker's own
buffering, and don't buy or silently pick a DJ SDK.

- **W3, output modes.** Stereo, DJ split cable (fixed mono master and mono cue, even with
  no deck on CUE) and multichannel, with preference, capability and effective route kept
  separate. Remove CUE-driven folding (today's SPLIT CUE, see Standing user decisions).
  Route controls go in the HTML mockup first; exact labels and placement aren't signed off.
  Headphone CUE may be gated by route; the transport CUE never is. Never put cue material on
  the audience output. Physical split and USB checks stay pending. Wired split cue and
  independent Bluetooth routing aren't the same capability (djay documents Bluetooth
  pre-cueing as unsupported on iPad; NI warns against it), and an independent Bluetooth
  speaker plus separate headphones isn't established as available: investigate before
  promising it.
- **W4, presentation.** One route-aware service with macOS and iPad adapters; stable route
  identity, not a Bluetooth name match; estimates with validity rather than silent zero;
  replace the 750 ms cap on the reported delay (`OutputLatency.longest`); optional remembered
  calibration; automatic compensation with a discreet notice, never a required prompt.
  Bluetooth is a route property, not a second engine and not a synonym for split.
  `heardPosition` and `FrameLink` should consume this service, not become a competing
  clock. The Bose's under-report and any per-speaker offset belong here. The iPad's silence
  on the Bose (4 November) was the Mac's Dex holding the speaker with its idle output open;
  a speaker connected to both can go quiet like that.
- **Rest of W5, the waveform on iPad.** `DexWaveProfile` runs on the Mac only, so iPad frame
  pacing hasn't been measured; also external-display and refresh-rate changes,
  tile-boundary and marker checks, and `Screen.Lane` still passing the common span, so
  tempo-scaled zoom is unchecked.
- **Rest of W2** (formal master/cue ownership, validating formats, buses and maximum frames,
  reset and allocation tests) was written against the old graph; how much still applies now
  the engine owns mixing hasn't been re-judged. **W6** (stretcher comparison) was settled by
  the engine rebuild; a multi-hour two-device release profile is what's left.
- **Open risk, not reproduced:** the cue handoff identifies only a frame count (plan §5).

Standing rules for audio work: no allocation, locks, logging or async dispatch in render
code; caches and command queues stay bounded; don't raise snapshot budgets to pass; no
audible tests without the task authorising them, and the live check stays muted. Musical
behaviour in plan §4 and `native/README.md` must survive: two prepared voices, ±16% tempo,
sticky SYNC, CUE and hot-cue timing windows, loops, jog, route-loss safety, iPad background
audio.

Tools: BSD `sed` has no `\b`, so a substitution using it silently does nothing, and
zsh's builtin `log` shadows the tool, so use `/usr/bin/log`.

## Set history, ratings, platter lift, CUE slide — 14 November 2026

Mocked up first (`mockup/xdj-mixer-alt.html` + `console.css` for the library and title bars,
`mockup/stage-two-decks.html` for the platter and CUE), then ported. The user chose each rule.

- **Played in this set.** A track counts once the crowd has heard it for 30 s in all on one load:
  playing, not a CUE preview, LEVEL × its crossfader side at −12 dB or louder (`PlayCounter` in
  `DexCore/SetHistory.swift`, counted once a second in `ConsoleModel`). Its music note turns orange
  in the library and the deck's title bar. **This set** (sidebar) lists plays in order with the
  time; **New set** asks twice, then clears the marks; the old set stays under **Past sets**.
  **Save as playlist** makes a playlist of a set, each track once, in play order. Saved as
  `sets.json` (with a backup) beside the catalog.
- **Ratings:** 1–5 stars, a RATING column (sortable, most stars first) and stars in each deck's
  title bar; tap the top lit star to clear. Stored on the track (`LibraryTrack.rating`).
- **Platter lift:** scrubbing redraws that platter over the mixer with a shadow until the finger
  lifts. The platters are now their own PDF, `chassis-platters.pdf` (three PDFs from
  `build-stage-art.mjs`).
- **CUE slide:** holding CUE shows an orange track joining CUE to PLAY and a puck under the
  finger; both turn green once it reaches PLAY (the preview latches).
- **CUE and PLAY touch fix.** After the stage-two port they ignored touches on the iPad (DexSlider's
  stage gesture cancelled their UIKit control). `Press` now uses `SpatialEventGesture`, so a quick
  CUE tap is a real press and release (a short blip from the cue point), hold plays and returns,
  and slide-to-PLAY latches. PLAY is play/pause on the press itself, not the release. Checked in
  the simulator; the user confirmed CUE on the iPad. Two-finger CUE+PLAY and the Mac with a
  mouse are untried.
- **Press-to-sound.** The app now asks iOS for a 256-frame (5.3 ms) IO buffer. Measured in the
  simulator: a start from stopped is scheduled 27 ms after the press. The delay the user heard
  was Bluetooth (150–250 ms, not removable); cue on wired output. CUE's wait for the other
  deck's beat is deliberate and was kept (the user confirmed, 14 Nov).

## Stage two from the user's drawing — 14 November 2026

**Start here for the console's look.** Everything below the track windows is now the user's
Illustrator drawing, `mockup/stage-two-decks FA.svg`, by way of the mockup
`mockup/stage-two-decks.html` (the reference; commit 1ce2466), ported to the app the same day.

- **How it's drawn.** The drawing's static art (fascia, platters, faceplate, fader scales, meter
  frame, legends) is two vector PDFs in `native/Sources/DexConsole/Art/`, printed from the mockup
  by `npx electron mockup/build-stage-art.mjs`: re-run it after any change to the drawing.
  Everything that moves is drawn over it in `Chassis.swift` at the drawing's own coordinates
  (`Layout`: drawing x − 10, y − 348) in the drawing's styles: keys, chips, LEVEL and TEMPO caps,
  crossfader, transport, beat jump, the platter displays' marks and the meter rungs. The old
  chassis's parts the popovers still use moved to `MixerParts.swift`.
- **The chips and faders are DexSliderLab's**, through its package (`DexSliderLab/Packages/DexSlider`,
  now a dependency of DexConsole): one `SliderBank` in `ConsoleStage`, its `SliderStage` wrapped
  round the whole console so panels can rise over the track windows. `BankSync` in `Chassis.swift`
  keeps it and the console in step. The tuning is the user's 10 November iPad tuning, with the
  faders' travel set to the drawing's (LEVEL 174.55 pt, TEMPO 170 pt).
- **Package changes made for the app:** TEMPO's readout above the fader (`tempoReadoutAbove`),
  `removeFrame` (chips hidden while the library is up), shields so a tap on the effect list or an
  open panel can't reach a control under it (the crossfader took one in the simulator), and a tap
  that arrives already ended still counts. The lab's own behaviour is unchanged.
- **Minimum OS is now iPadOS 18 / macOS 15** (the user's choice, 14 Nov), for the package.
- **PHONES is new in the engine:** a plain gain on the cue output after its peak guard, gliding
  like the cue mix; the master never hears it (`dex_router_set_phones`,
  `testPhonesTurnsDownTheCueAndNeverTheMaster`). Not yet heard.
- **FX:** the list offers FILTER, REVERB, DELAY and GATER (the user's choice); only FILTER makes a
  sound. Choosing another effect sets the filter to off; the chip keeps its name and amount.
- **Mapped onto what was there:** MASTER TEMPO is the old KEY lock; LOCK LOWS the old LINK LOWS;
  CUE/MST the cue mix (the engine's 1 is all cue, the chip's left side). The kill pads, FILTER /
  TRIM / band / master popovers are no longer reachable from the chassis (the code stays, and the
  snapshot demos still draw them).
- **Choices made in the port, to check with the user:** transport CUE lights whenever a track is
  loaded (the drawing's two looks, lit and unlit; the app had it always lit); the crossfader
  jumps to the finger, as in the mockup (it was a relative drag); the ◀ ▶ keys jump by the
  selected bars as before (the mockup stepped the size); the platter display's gap is four marks,
  as drawn (it was two); a touched platter no longer shows its rim under the mixer.
- **Checked:** snapshot renders against the mockup; in the iPad simulator, a chip drag, the
  readouts, two fingers at once (LEVEL A with HI B), keys, LOCK LOWS, the crossfader, and the
  effect list by hold, then tap. Mac and iPad builds pass. **Not tried on the real iPad.**

## Architecture audit and fixes — 12–13 November 2026

**Start here if you're picking this up.** The user asked for an architectural review of the
native app, then for the findings to be worked through, most urgent first. The full findings,
with what each fix did and what it left, are in [ARCHITECTURE-AUDIT](docs/ARCHITECTURE-AUDIT.md).

**The goal.** Bring the app around the engine up to the engine's standard: one source of
truth for what is playing, failures that are reported and never hidden, data that can't be
lost by a bad file, and code that can be changed in one place. The user is a DJ, not a
developer: explain in plain terms, and anything that changes timing or sound needs their ears
before it counts as done.

**Verdict, then and now.** The engine was production-grade; the app around it a well-tested
late prototype whose biggest risk was a deck's position, loop, tempo and master existing
twice. That is now fixed (finding 1, below), and so are typed errors.

### Done and pushed

All on `main` in dex-sw, last `21213e5`.

| Fix | What changed |
| --- | --- |
| **One transport truth** (finding 1, 13 Nov) | Five stages, each heard by the user. (1) The engine elects the master. (2) A locked follower's TEMPO is the engine's lock; out of ±16% it sits at the limit and chases nothing. (3) `DeckTimeline` replaces the clock and loop clock, following the engine's blocks and loop. (4) A pending start and the heard end come from the engine and the timeline; the one intent left, `soundRequested`, lives in the timeline by the user's choice. (5) The mixer's 30 Hz heartbeat is the only transport loop; it can't go, since it keeps decks current in the background. The deck's own flags are now just `playing` and `dropped` |
| The engine signals changes (finding 10, 13 Nov) | No transport loop left. The audio loop signals a semaphore after a block that changed something the app reacts to; a waiting thread wakes the main actor once, and the mixer catches the decks up. TIME and REMAIN move with the display clock. Nothing runs while nothing changes. Heard and passed, 14 Nov |
| Audio lifecycle (finding 7, 13 Nov) | One state machine, `AudioLifecycle`, in place of loose flags; the mixer carries out what it decides. One new behaviour: a start that fails mid output change retries once, half a second later. Every path unit-tested; not tried on a device |
| Typed errors (finding 5, 13 Nov) | Errors are values (`Problems.swift`), turned into words only in `ProblemText` in the app. Not checked by the user as such: see Awaiting the user |
| Unreadable audio | A failed read is never stored as silence. The loader retries it every 250 ms, the engine waits for it as for any audio not there yet, and the deck reports it once per spell of trouble |
| Playlists | Versioned file, backup of the save before, an unreadable file copied aside first, a newer version's never written, nothing written before reading. Saved through `LibraryStorage`, under its lock, off the main thread |
| Alerts | A problem raised again with the same words shows again after it was dismissed, with a fresh seven seconds. A standing notice isn't raised again by each track loaded |
| Output changes during start-up | Held and judged when the start finishes, never dropped. Acted on if the engine stopped again or the output (device, channels, rate) is a different one |
| Catalog reads | The catalog is re-read only when the file on disk is no longer the one last read or written. An import went from five whole-catalog decodes to none |
| Screen rebuilds | Library rows are remade only for tracks that changed, so a fader move costs the same at any library size |
| Track loads and a full queue | A load takes nothing when the engine's command queue is full, where before the loader and the audio loop could end up on different tracks |
| Sample rate | The engine's 48 kHz is one constant, `EngineCore.sampleRate` |

Found and fixed on the way, 13 November:

- **The loop box drew off the beat on a short loop.** Its label sat inside the box, so a loop
  narrower than the label grew to the label's width and was centred over the loop. The label
  is an overlay now, as in the mockup; a half-beat loop reads 0.5. Heard and seen by the user.
- **Hot cues in the zoom lanes** (the user asked): a full-height line in the slot's colour
  with its number flagged at the top and a dark edge. Designed in the mockup (`.zw-hc`),
  ported (`HotCueMarker`), matched at 8×. Both demos have hot cue 3 inside deck A's loop.
- **The console's concurrency warnings** (Swift 6 would make them errors) are gone, and **Dex
  is full screen only on the iPad** (landscape-only needs it; Split View and Slide Over are
  given up, the user's choice).
- `DexConsoleSnapshot --loop <beats>` draws deck A with a loop, for checking the box.

### Checked

Test count above; new this round: `LoopDisplayTests`, `EndOfTrackTests`, the timeline's cases
in `TransportTests`, `GridLockTests.testTheFollowersTempoFollowsTheMasters`. Mac and iPad
Xcode builds exit 0; the one Swift warning left is an older one in `OutputLatency.swift:86`
(forming a raw pointer to a generic value), not chased. Not run: the muted live checks, the soak.

**`npm run diff:native` doesn't work on this Mac.** Every mockup capture comes out 410×284,
not the 1174×814 stage: the offscreen Electron window opens too small and the mockup scales
itself to fit. Not caused by these changes; unresolved. A capture that pins `.ipad` at the
window's top left with `transform:none; zoom:0.5; position:fixed; z-index` set gets the full
stage, which is how the hot cue marker was compared.

### Still to do, in the suggested order

1. **The user's checks** (Awaiting the user, below).
2. **Restructuring, if wanted at all** (findings 4, 11): `NativeDeck` split into rules,
   engine port and observable; the library in its own module; the engine file split by
   concern. None of it changes what is seen or heard.
3. ~~The engine telling the app when something changes~~ — built 13 November, see the
   table above; waits for the user's listen.

Small things left by these fixes: the unreadable-audio alert shows only while the deck
plays; a failed playlist save isn't retried until the next playlist edit; an unreadable
playlists file is copied aside again at each launch until a playlist is edited; a change to
one library track still walks the whole library once; the typed errors' wording has no test
(`DexApp` is an executable).

### Working notes

- The transport stages were done one at a time, each with the full suite, both Xcode builds
  and then the user listening, before the next. Work on `main` from now: the side branch it
  started on (`needs-checking/typed-errors`) is merged and deleted.
- Two agents at once worked when each had its own files and its own build folder
  (`--build-path` under `$TMPDIR`; `native/.gitignore` only covers `.build/`). Each starts
  cold, so they cost more than working alone.
- On the original Mac every shell prints an fnm warning that the Node path isn't on PATH,
  yet `node -v` reports v24.22.1. Unresolved; the fnm line in `~/.zshenv` may want a look.

## Mixer: readouts, AUTO trim and meters — 7–9 November 2026

- **Fader readouts removed** from LEVEL, HI, MID, LOW and TEMPO, in the mockup and the app
  ("not really a thing on any professional dj equipment"). TRIM keeps its number. The band
  names stay and still open the band sheet, which keeps its dB values; TEMPO moved up under
  its fader, whose length is unchanged.
- **AUTO trim is built in the app, not yet heard.** `DexCore/Loudness.swift` measures ITU
  BS.1770 loudness at import; older tracks are measured quietly in the background at launch
  (`readMissingLoudness`, for at most a minute per launch; whatever is left follows on later
  starts). A track loads at the trim that brings its **main groove** (the loudest half of
  its 3 s stretches) to **−11 LUFS**, within ±12 dB, and the chip lights green and reads
  AUTO. Moving TRIM remembers it for the track (`LibraryTrack.trimDb`, saved half a second
  after the trim rests); RESET, a double-tap or snapping within 0.25 dB returns to AUTO and
  forgets it. Only the console turns trimming on load on (`NativeDeck.trimsOnLoad`), so
  audio tests stay at unity.
- **Bench, 52 tracks in `accuracy/audio/`:** every one peaks at 0.0 dBFS; main groove −9.3
  to −5.0 LUFS (median −6.8), whole-track −10.5 to −6.2. The user chose −11 for normal use,
  with hot tracks handled by hand. Headroom, measured 9 November: at −16 LUFS no deck peaks
  over −6 dBFS and the two worst decks sum to −0.7; at −10 an EQ'd blend reaches the
  limiter (all 52 peak above −6, and the worst correlated pair would reach +5.3 dBFS); −14
  leaves 11 above −6, −12 leaves 44. −16 is the highest target with real headroom and the
  lowest the ±12 dB TRIM covers with a dB to spare. The app aims for −11 and leaves extra
  trim for unusually hot tracks to the DJ. Standards, working and sources:
  [GAIN-STAGING-RESEARCH](docs/GAIN-STAGING-RESEARCH.md).
- **Meters** (the user rejected a first version with A and B as loudness before the faders:
  "not usual"; a meter must show what actually goes in, and two decks fully open should
  overload the master). Four in the centre strip, A · L · R · B, replacing LOW Σ (gone
  from the mockup, `Chassis.swift` and `MixerMath`):
  - **All four are peaks on one scale, −30 to +6 dBFS.** A and B are each deck's peak after
    TRIM, EQ and FILTER and **before** LEVEL and the crossfader, as on Pioneer mixers, so
    TRIM can be set with LEVEL down (decided 8 November after Expert DJ's gain-staging
    video; summary in [Set Your Volumes Like A Pro](docs/Set%20Your%20Volumes%20Like%20A%20Pro.md)).
    L and R are the master after VOLUME and **before** the limiter; red from 0 dBFS means
    the limiter is working (ceiling 0.99). Instant rise, 20 dB/s fall, 2 s held segment
    (`MeterBallistics`). No AUTO target line; AUTO still matches loudness on load.
  - **The crossfader is full on both sides until the centre** and fades only across the far
    half on a quarter cosine (`MixMath.crossfade`, mockup `xfGains`). It was equal-power,
    which with AUTO's cuts kept two full decks from ever overloading. The user mixes both
    ways: crossfader with EQ, or crossfader centred and LEVEL. A curve choice could come
    later if smooth crossfader blends suffer.
  - **Engine and app:** the mix loop keeps each deck's and master side's highest sample
    since the last `dex_engine_read_meters`, which takes them (`EngineMeterTests`).
    `ConsoleModel.updateMeters` reads about 60 times a second while anything shows, ten when
    silent, into `ConsoleClock.meter`.
  - **Rungs copied from a reference mixer (9 November):** twelve even blocks of 3 dB across
    −30 … +6: six green (−30 … −15), four amber (−12 … −3), two red (0, 3). The bar reads
    in 3 dB steps; the 2 s hold lights its own rung white. A meter whose hold reaches 0
    dBFS takes a 3 pt red cap on the lit column and a red border, and its spoken value
    gains ", clipping". The mockup draws the same ladder (`METER.ladder`, `paintMeters`);
    the snapshot tool's `--clip 1` renders the cap. Thin neutral marks show −6 dBFS on A/B
    and −3 dBFS on L/R as manual peak guides.
  - **Layout:** wider, XDJ-RR-inspired: the mixer fills 55% of the drawing and tucks each
    platter's inner rim just outside the rotation lights (touching the exposed disc reveals
    the rim until release; it doesn't take hits from the mixer). CH A and CH B flank the
    stereo master, with dBFS scales in the gaps and a master CLIP lamp. MASTER LEVEL above
    the meters opens a master-only popover; each FILTER button shows OFF or the cutoff and
    opens the sweep in a popover. TRIM opens above the mixer.
  - Without demo audio, the mockup and snapshots show still levels (A playing alone, B cued
    and silent); an empty or loading deck shows a silent meter and TRIM 0.0.
- **Not yet seen or heard on a device**: the layout, meters and AUTO trim. The listening
  check is in the user's list below.

## Control map — 8 November 2026

`npm run check:controls` runs in CI's `verify` job, after the unit tests. It
regenerates the map and fails if the mockup has a `data-ctl` that `controls.json`
doesn't describe, if a described control isn't drawn, or if a `controls.json` edit was
committed without regenerating `CONTROL-MAP.md` and `controls.data.js`. The cross-check
alone passes when the generated files are stale, which is why it is paired with
`git diff --exit-code`.

Two ids are gone: `lib.loadA` and `lib.loadB`. They described Electron's library deck
panel, where a deck's title read TAP TO LOAD. Neither the mockup nor the native app
draws that panel — the native app taps a row and then the deck's art, already mapped as
`deck.load` — so there was no title to anchor, and inventing one would have been worse.
Add them back only if the title load returns to the mockup as a real control. The deck
letter's focus gesture is anchored (`deck.focus`, on both deck cards), and the
header's status pill and CAN'T LOAD alert are described (`console.status`,
`console.error`), for 99 controls: 82 live, 5 partial, 12 planned.

## Awaiting the user

None of this has been tried or heard by the user, except where it says otherwise. **Never report any of it as passed.**

- **The stage-two console on the iPad** (14 Nov): the chips and their panels by finger, two
  hands at once, the effect list, PHONES on headphones, and the port's own choices listed under
  Stage two (transport CUE's light, the crossfader jumping to the finger, the four-mark gap).

- **AUTO trim listening check:** pairs at AUTO, judged matched or not, by ear (the meters
  show peaks, not loudness). Luga vs A Brief History Of Goa Trance (4.3 dB apart untrimmed:
  does AUTO work at all?); Buzz On vs Drink Drunk Junkie (main groove says 1.1 dB apart,
  whole track says 2.5: which measure is right?); Luga vs Traffic (techno, 3.4 dB apart).
  Target and measure stay pending until then.
- **The mixer rework on a device:** layout, meters, crossfader law.
- **The LR4 isolator and headphone cue bus** (CUE, SPLIT CUE, 4-CH CUE, cue mix) on
  headphones. Split cable and USB interface checks wait for hardware (none available).
- **Multi-hour sessions, energy and thermal** haven't been tried. The grid lock was
  heard by the user only on the old engine, if at all (see The engine).
- **The zoom-scaled coast with a mouse on the Mac** isn't separately confirmed: the user
  didn't say which device they tried it on, and asked that the desktop has it. It's the
  same code with no platform branches, it's in the Mac build, and its tests run on the Mac.
- **Deck keys' touch area** reaches 2 pt past each drawn edge (44 pt of height); not yet
  tried by finger.
- **Seen in the app?** Hot cues in the zoom lanes, and Dex full screen on the iPad, were
  built and committed without the user saying they'd seen them in the app.
- **Typed errors** were merged without a check of their own. Alerts should read as before:
  try a refused key (a beat jump with no grid), a load of a file that isn't audio (it now
  says so, rather than a Cocoa error code), and an import of a few files with one bad one.
- **From the architecture fixes** (nothing in this group has been tried in the running
  app, on the Mac or the iPad):
  - *Output changes during start-up.* Only the decision rule is tested. Switch output
    (Bose on or off, headphones in or out) just as the app starts or comes back, on both
    devices. Expect "Audio output changed. Press PLAY to continue." and sound after PLAY.
  - *Unreadable audio on a real drive.* Tested with a fake source only. Play a track from a
    drive, then unplug it: the deck should fade out, hold its place and raise the alert, not
    play silence under a moving waveform. Whether it recovers when the drive returns depends
    on the open file surviving, which is unknown.
  - *Alerts in the app.* `ConsoleModel` has no test target. Try a refused key twice (a beat
    jump on a deck with no grid), dismissing the alert between: it should show both times.
  - *The library with two apps open at once.* The catalog's read-skip was tested with two
    stores in one process, not two processes.
  - *A large library.* The row cache was measured in a harness at 5,000 tracks, not in the app.

## Standing user decisions

- **Clean build (5 November 2026), overriding everything else:** never read, search or fetch Mixxx or any
  other GPL DJ engine. Nothing paid. Allowed stretchers are Signalsmith Stretch (MIT) and Bungee (MPL-2.0).
  Rubber Band's GPL version only in a private listening build that's never committed or shipped.
- **Electron frozen (1 November 2026)**, kept working for a possible PC
  version. UI work happens in the HTML mockup, then SwiftUI.
- **FIND KEYS reads only the key** (agreed improvement, 1 November 2026): it
  never re-reads grids or cues, unlike Electron's full re-analysis.
- **Elastic height**: 1174 × 814 base stage, uniform scale, spare height up
  to 4:3 grows the zoom lanes, letterbox beyond. Done in Electron and the
  native port. Open: minimum window size, iPad mini, swipe-up deferral.
- Label/readout face is **Avenir Next Condensed** in both apps (system font on
  Mac and iPad); body text is Helvetica Neue.
- UI is flat Pioneer styling (the deck keys' on state is the one agreed gradient), readable in a dark club: 12 px minimum text,
  buttons around 16–22 px. Song/track windows keep their original sizes.
- Instructions live behind a round **(i)** help key. No instruction text on screen.
- DONE / CLOSE are a green outline and (i) a yellow one, everywhere (2 November
  2026, ported).
- Library rows (2 November 2026, signed off and ported): titles only for now,
  with MORE opening the track's details, playlist buttons, re-analyse and remove
  from library. A track on both decks shows both badges. The note icon is
  `icons/music.note.svg`, used everywhere.
- MORE's pop-out (2 November 2026, signed off and ported): Avenir Next, not the
  condensed cut, for its text; album instead of label; playlists switch on by
  clicking; the date in the system's short format. No grid figure or new-playlist
  key there.
- The blue is `#276fff`, for deck A, selected rows, the sidebar line and the beat
  jump's length; text on it is black. Headphone CUE is `#e18400` with black text.
  Hot cue 1 and the waveforms keep their own blue.
- The deck's SYNC · MASTER · KEY · HOT CUE keys (5 November 2026, the user's design,
  signed off and ported): they run the full width of the deck,
  78 × 40 pt with 6 pt gaps. The 40 pt height, shorter than the old 44, is deliberate.
  Off, a dark face with outline and 18 pt legend in the key's colour: `#f2f4f3`,
  `#e18400`, `#276fff` for both KEY and HOT CUE. On, an elliptical gradient with a black
  outline and legend, sampled from their picture. The tempo fader starts 23 pt
  under SYNC, the gap the user chose by eye after 7 and 46 pt, and its foot is level with
  the mixer faders' (251 pt, 215 of travel), with its readout and then TEMPO below
  it. The user asked for room
  around every control for big fingers. The keys' touch area reaches 2 pt past each
  drawn edge, for 44 pt of height, not yet tried by finger. The platter stays 262 pt
  (the user's decision, 7 November 2026, "fine at this point"); shrinking it to about
  240 pt had been proposed because it sits 10 pt under the keys and 8 pt over the beat
  jump row.
- The beat grid sheet (2 November 2026, signed off and ported): a drag moves the
  waveform, not the lines, as Traktor does on iPad. Zoom − + from 8 s to 250 ms,
  ◀ BEAT ▶ and a track strip to move along the track. Re-analyse asks twice.
- Removing a track from the library is refused while a deck holds it (agreed 2
  November 2026): load another track there first.
- Layout makes room for new widgets; never cram.
- Faders carry no number readout (7 November 2026): the cap's place shows where it is. TRIM keeps its number.
- Mixer meters: CH A and CH B outside stereo MASTER, with labelled dBFS scales between them; LOW Σ dropped.
  A and B before LEVEL and the crossfader, as on a Pioneer mixer, so TRIM is set by them; the master before the limiter,
  so two full decks overload it.
- Crossfader (8 November 2026): both decks full at centre, fading only across the far half.
- AUTO trim (7 November 2026): loudness-matched on load, aiming to be right for most tracks; a hand-set trim is
  remembered per track. Target and measure pending the user's listening check.
- ROLL is removed and loop dragging is deferred. Both are future ideas in
  [IDEAS](docs/IDEAS.md).
- Waveform drag is audible vinyl scrubbing with inertia. A deck resumes only if
  it was playing. A lane coasts past where it's released (agreed improvement, 4 November
  2026; Electron stops where the finger lifts), on mouse and touch alike. The same hand
  speed travels the same track distance at any zoom, like a platter, so the effect looks
  biggest zoomed in and smallest zoomed out.
- SPLIT CUE plays the stereo master until a deck is on CUE, then folds to mono
  master left and mono cue right (agreed improvement, 3 November 2026; Electron
  always folds). On a split cable the master side carries only the left channel
  until then. **This is legacy behavior pending the explicit output-mode work**
  in the implementation plan. The latest discussion favors a Traktor-like split
  switch with fixed channel meaning, separate from Bluetooth timing handling.
- No splitter or USB audio output is available, so physical split-cue checks are
  deferred.
- Playing lanes and their markers slide by fractions of a pixel at 60 Hz (agreed 4
  November 2026; the user saw it on Mac and iPad and said it looks really good), where
  the mockup and Electron move in whole pixels at 30 Hz. At rest they snap as before.
- Don't tune analysis for single-track misses. The user declined an uncertainty
  flag for near-tie bar votes (29 October 2026): bad analysis is bound to happen,
  some psytrance breaks standard phrasing, and they fix the odd track by hand in the
  grid editor. Report a miss and move on unless a pattern shows across several tracks.
- The user's design images are tagged Display P3, so convert samples to sRGB (check
  with `sips -g profile`). P3 `#3c6df6` is the sRGB `#276fff`; Photoshop's `#6100fd`
  for the same blue renders violet. Other agreed values: yellow `#dbe22d`, green
  `#49ba60`.
- The user judges UI by eye against the mockup and the Traktor screenshots in
  `screenshots/`, and sketches layout changes directly.

## Setup

Node 24 is installed via **fnm**; the repo pins it in `.node-version`. fnm is
switched on in `~/.zprofile` for login shells and `~/.zshenv` for non-login ones,
which is what agents' commands run in. On a new Mac, run these once, then restart
the Claude app:

```sh
echo 'eval "$(fnm env --use-on-cd --shell zsh)"' >> ~/.zprofile
echo 'eval "$(/opt/homebrew/bin/fnm env --use-on-cd --shell zsh)"' >> ~/.zshenv
```

Don't install Node any other way (see [CLAUDE.md](CLAUDE.md)).

Then, for a fresh checkout: `npm ci && npm run fixtures`. Xcode 27 is required
for the native app. Private music (`accuracy/audio/`), `out/` and build products
are ignored and stay local.

## Verify

The `swift` and `diff:native` steps need **Xcode**, not CommandLineTools. On this
Mac `xcode-select -p` reports CommandLineTools, where `DexConsole` fails to
compile (`Stage.swift`: ambiguous use of operator '/'), so `swift test` and
`npm run diff:native` stop before doing anything. Set `DEVELOPER_DIR` once per
shell, or prefix those commands — the export below covers the blocks as written:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer  # console sources need Xcode
npm test                     # Electron unit tests
npm run check:controls       # mockup anchors against controls.json, generated map current
npm run build                # typecheck + bundles
npm run check:runtime        # production Electron integration
swift test --package-path native
xcodebuild -project native/DexNative.xcodeproj -scheme DexNative -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project native/DexNative.xcodeproj -scheme DexNative -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
npm run diff:native          # native screens against the mockup
```

For audio and waveform work, also:

```sh
DEX_NATIVE_SOAK_CYCLES=100 swift test --package-path native --filter HardeningTests/testTwoDeckEnduranceWithLibrarySyncLoopsCuesAndRecovery
DEX_NATIVE_LIVE_CHECKS=1 swift test --package-path native --filter LiveOutputTests   # muted; DEX_LIVE_MINUTES sets the length (3 by default)
swift test --package-path native --filter DexEngineTests                             # the engine's own tests
swift run -c release --package-path native DexEngineBench cpu|speed|jump|live|clips  # stretcher bench, never plays aloud
swift run -c release --package-path native DexWaveProfile --span 12                  # lane pacing, opens a window, no audio
/usr/bin/log stream --level info --predicate 'subsystem == "dex.native"'             # output, delay, failed pulls
```

Dev servers (`.claude/launch.json`): Electron renderer on **5299**, mockup on
**8765** (5199 belongs to another project).

## Docs map

- [README](README.md): what Dex does, how to run it, verified numbers.
- [native/README](native/README.md): native scope, agreed behaviour, architecture, parity gates.
- [ENGINE-REBUILD-SPEC](docs/ENGINE-REBUILD-SPEC.md): the replacement engine's brief and rules,
  [ENGINE-STRETCHER-MEASUREMENTS](docs/ENGINE-STRETCHER-MEASUREMENTS.md) (gates 1 and 2) and
  [ENGINE-GATE3-RESULTS](docs/ENGINE-GATE3-RESULTS.md) (gates 3 and 4, and the old engine's removal).
- [ARCHITECTURE-AUDIT](docs/ARCHITECTURE-AUDIT.md): the 12 November review of the native app, each
  finding with its fix and what is still open.
- [AUDIO-IMPLEMENTATION-PLAN](docs/AUDIO-IMPLEMENTATION-PLAN.md): brief for output modes, Bluetooth
  presentation and waveforms (its old-engine parts are history).
- [AUDIO-ARCHITECTURE-AUDIT](docs/AUDIO-ARCHITECTURE-AUDIT.md): original findings,
  competitive research and evidence limits.
- [docs/audio-audit/](docs/audio-audit/): the audit's probe source, evidence index
  and starter prompt, as recorded at transfer, plus the click and mic delay probe.
- [UI-CAPABILITIES](docs/UI-CAPABILITIES.md) and [CONTROL-MAP](docs/CONTROL-MAP.md): UI inventory and control spec.
- [GAIN-STAGING-RESEARCH](docs/GAIN-STAGING-RESEARCH.md): gain staging, meter references and the AUTO trim target, with sources.
  [Set Your Volumes Like A Pro](docs/Set%20Your%20Volumes%20Like%20A%20Pro.md): notes on the gain-staging video.
- [ANALYSIS-SUMMARY](docs/ANALYSIS-SUMMARY.md) / [ANALYSIS-RESEARCH](docs/ANALYSIS-RESEARCH.md) and [accuracy/](accuracy/README.md): BPM/grid analysis and the marked-song bench.
- [IDEAS](docs/IDEAS.md): later goals.
