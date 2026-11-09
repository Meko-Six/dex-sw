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
- **`out/`** (ignored), including the audit's full logs and the transfer ZIP. The
  evidence summary and probe are tracked in `docs/audio-audit/`.
- **The app's library, playlists and tracks**, in
  `~/Library/Application Support/DexNative` (`DexNativePreview` for package runs).
  Expect an empty library on a new machine until music is imported.
- **Claude's chat history and memory.** New sessions start from these docs. What
  the memory held that wasn't written down elsewhere is under Standing user
  decisions.

To run on the iPad, Xcode needs a signing team on that machine; the project is set
to team `33B24PEVAC`. All measurements below came from the M3 MacBook Pro at 120 Hz,
so another Mac's numbers aren't a direct comparison, and the Bose has to be paired
again.

## Engine rebuild

The user decided on 5 November to replace the deck engine with one real-time audio loop that
owns everything audible, keeping the UI exactly. The brief is
[ENGINE-REBUILD-SPEC](docs/ENGINE-REBUILD-SPEC.md), and its clean-build rule overrides
everything: never read Mixxx or any other GPL DJ engine, including the Mixxx links in the audit
and plan. All results and the listening steps are in
[ENGINE-STRETCHER-MEASUREMENTS](docs/ENGINE-STRETCHER-MEASUREMENTS.md).

**The engine rebuild is done, 6 November 2026. The old engine is gone.** The user chose Bungee on 5 November
("without doubt, bungee"), passed gate 3 on 6 November ("Pass, gate 4"), then played both engines and said of the new
one: "way better ... Super tight, nice and responsive, easy cue lineup, just miles ahead. time to say goodbye to the
old engine". Merged to `main` on 6 November, with the old engine removed. Results:
[ENGINE-STRETCHER-MEASUREMENTS](docs/ENGINE-STRETCHER-MEASUREMENTS.md) (gates 1 and 2) and
[ENGINE-GATE3-RESULTS](docs/ENGINE-GATE3-RESULTS.md) (gates 3 and 4, and the removal).

- **What the app runs now:** `Sources/CDexEngine`, one real-time loop that owns everything audible, driven by
  `NativeDeck` and `NativeMixer` through `DexAudio/EngineCore.swift`. The AVAudioEngine graph is one source node to the
  device. The players, time-pitches, transition gates, the old jog renderer, loop reading, launch tickets, Apple's 1/512
  speed rule and the time-pitch delay allowance are all removed, as are the engine switch and its Xcode scheme.
  `ConsoleModel` and `DexConsole` are unchanged; `heardPosition(ahead:)` still feeds the lanes.
- **Checked after the removal, re-run 9 November:** `swift test` 306 tests (159 audio, 65 core, 44 engine,
  38 console): 300 passing, 6 optional skips, 0 failures; the Mac, iPad Simulator and iPad builds; `diff:native`
  within every budget; the 100-cycle soak (flat at 52.7 MiB); the muted live checks on the Bose (no missed blocks,
  decks 0.002–0.005 ms apart over a minute, starts and seeks within 0.31 ms of the click).
- **Fixed during the removal:** the engine's 64 MiB cache was counted inside the 128 MiB preparation budget, so a
  memory warning (which halves that budget) would have left no room to load a track for 30 s. It's now fixed memory on
  top of the budget (`AudioMemoryBudget.reserveFixed`), with a test.
- **Built again under Swift 6.2, 9 November:** `LibraryStorage.transaction` no longer wraps `body` in
  `autoreleasepool`. Swift 6.2 transfers that closure, and a `body` closure can't be sent
  (`#SendingRisksDataRace`), so the pool now sits where a transaction actually allocates: `decodeCatalog`, `commit`
  (both encodes and both writes) and `reloadCatalog`'s recovery write, with actor state assigned outside them. Same
  coverage as before, one file, no suppressions and no call-site changes. The suite above passes and the iPad
  Simulator build succeeds.
- **Gate 3's numbers:** Mac live, five minutes: waveform against sound under 0.9 ms, 0.006 ms drift. iPad, three
  minutes: under 0.44 ms, 0.018 ms drift. Release build: about 5% of a core for the whole process on the Mac, 12.5% on
  the iPad, and 64 MiB more memory than the old engine for the cache. On the Bose, the engine's own error is 1–3 ms;
  the speaker under-reports its delay by an amount that varies (4–20 ms seen), which only a per-speaker offset could
  remove, and none exists or has been agreed.
- **Musical differences from the old engine, all tested:** presses come out on the next block (10 ms more from
  stopped, for a whole attack) instead of after 30 and 120 ms pre-rolls; a quantized cue meets a beat still to come
  whole and joins a beat already gone 120 ms in; a start or plain seek that waits for the disk starts where asked;
  loops move at once; the end of a track shows when heard.
- **Things to know:** the tone section is flat only to 0.1% at DC (−0.009 dB). The engine's master limiter hasn't
  been compared by ear with Apple's, though the user has played it and is happy. CI's older Xcode hasn't seen this
  code, because nothing has been pushed. The clips from gate 2 are in `out/engine-clips/` in the main checkout, not in
  git.

## Mixer: readouts, AUTO trim and meters — 7 November 2026

The user asked for this on 7 November. State:

- **Fader readouts removed** from LEVEL, HI, MID, LOW and TEMPO, in the mockup and the app ("not really a thing on
  any professional dj equipment"). TRIM keeps its number. The band names stay and still open the band sheet, which keeps
  its dB values; TEMPO moved up under its fader, whose length is unchanged.
- **AUTO trim is built in the app, not yet heard.** `DexCore/Loudness.swift` measures ITU BS.1770 loudness at import
  (Accelerate biquads, about 0.007 s per 32 s of audio in a debug build); older tracks are measured quietly in the background
  at launch (`readMissingLoudness`, for at most a minute per launch; whatever is left follows on later starts). A track loads at
  the trim that brings its **main groove** (the loudest half of its 3 s
  stretches) to **−10 LUFS**, within ±12 dB, and the chip lights green and reads AUTO. Moving TRIM remembers it for the track
  (`LibraryTrack.trimDb`, saved half a second after the trim rests); RESET, a double-tap or snapping within 0.25 dB returns to
  AUTO and forgets it. Only the console turns trimming on load on (`NativeDeck.trimsOnLoad`), so audio tests stay at unity.
- **Bench, 52 tracks in `accuracy/audio/`:** every one peaks at 0.0 dBFS; main groove −9.3 to −5.0 LUFS (median −6.8),
  whole-track −10.5 to −6.2; AUTO trims −0.7 to −5.0 dB, none boosted. So everything plays about 3 dB quieter than before
  and the master goes up to match. The −10 target and main-groove choice are the user's to confirm by ear.
- **Listening check, waiting for the user:** pairs at AUTO, judged matched or not, by ear (the meters show peaks, not loudness). Luga vs A Brief History Of Goa Trance
  (4.3 dB apart untrimmed: does AUTO work at all?); Buzz On vs Drink Drunk Junkie (main groove says 1.1 dB apart, whole
  track says 2.5: which measure is right?); Luga vs Traffic (techno, 3.4 dB apart).
- **Meters and crossfader, 8 November.** Four meters in the centre strip, A · L · R · B, replacing LOW Σ (gone from the
  mockup, `Chassis.swift` and `MixerMath`). First built with A and B as loudness before the faders; the user rejected that
  ("not usual"): a meter must show what actually goes in, as set by LEVEL, and two decks fully open should overload the
  master. So, agreed 8 November:
  - **All four are peaks on one scale, −30 to +6 dBFS.** A and B are each deck's peak after TRIM, EQ and FILTER and
    **before** LEVEL and the crossfader (changed the same day, see below). L and R are the master after VOLUME and **before** the limiter; red from 0 dBFS
    means the limiter is working (ceiling 0.99). Instant rise, 20 dB/s fall, 2 s held segment (`MeterBallistics`). No AUTO
    target line; AUTO still matches loudness on load.
  - **The crossfader is full on both sides until the centre** and fades only across the far half on a quarter cosine
    (`MixMath.crossfade`, mockup `xfGains`). It was equal-power, −3 dB each at centre, which with AUTO's cuts kept two full
    decks from ever overloading. The user mixes both ways: crossfader with EQ, or crossfader centred and LEVEL. A curve
    choice could come later if smooth crossfader blends suffer.
  - **A and B moved back before the faders, 8 November.** After reading Expert DJ's gain-staging video
    ("How To Set Your Volumes Like A Pro When DJing" on YouTube; the user's transcript isn't in the repo): trim so the loud part sits at the top green with peaks in the yellow, faders up,
    then master, then amp), the user decided the channel meters belong before LEVEL, as on Pioneer mixers, so TRIM can
    be set with LEVEL down. Still peaks on the one scale; the master meters show what actually goes in.
  - **Headroom, measured 9 November at −16 LUFS: no deck over −6 dBFS, two worst decks sum to −0.7.**
    At −10 a single deck peaks −0.7 to −5 dBFS, so an EQ'd blend reaches the limiter: all 52 bench tracks peak above
    −6, and the worst correlated pair would reach +5.3 dBFS. Re-run lower, −16 gives trims −11.0 to −6.7 dB and deck
    peaks −6.7 to −11.0 (median −9.2), 0 of 52 above −6; −14 leaves 11 above it, −12 leaves 44. So −16 is the
    highest target with real headroom, and the lowest the ±12 dB TRIM covers with a dB to spare (the loudest track clamps
    at −18). It costs 6 dB against today, not the 12 a strict analogue reading would. The app stays at −10 until the
    user chooses by ear. Standards, working and sources: [GAIN-STAGING-RESEARCH](docs/GAIN-STAGING-RESEARCH.md).
  - Engine: the mix loop keeps each deck's and each master side's highest sample since the last `dex_engine_read_meters`,
    which takes them. Tests: `EngineMeterTests` (a sine reads its level; TRIM moves the channel meter, LEVEL and the
    crossfader don't, though they move the master; left-only lights only L; two hot decks read over +3 dBFS while the output stays limited; a burst waits for the
    read).
  - App: `ConsoleModel.updateMeters` reads about 60 times a second while anything shows, ten when all is silent, into
    `ConsoleClock.meter`, so only the strip redraws. The old 15 Hz master RMS read is gone (`NativeMixer.meterDb` stays
    for its test). The old meter only ever filled 72% of its height (a stale CSS rule, copied into the port); both gone.
  - **Zones at the aim points and a clip cap, 9 November.** The bars' colours now end at fixed figures (`MeterZones`, the
    same ones the control map's aim points name): green to −6 dBFS, amber to −3, orange to 0, red above, hard boundaries
    rather than a ramp. A meter whose 2 s hold reaches 0 dBFS takes a 3 pt red cap and a red border, and its spoken value
    gains ", clipping". The mockup draws the same rules from the same figures, `paintMeters` toggling `clipping` on
    `hold >= 0`. No demo state reaches 0 dBFS, so the snapshot tool takes `--clip 1`, which sets deck A's meter to the
    clip level on the render only. The 3 pt cap sits on the top of the lit column rather than the top of the well, so it
    marks how far the bar has reached; checked 9 November with that flag, and L and R keep their white held segments and
    no cap. The mockup draws it in the same place, from the bar's own height (`--h` on the meter, not only its inner bar).
  - Without demo audio, the mockup and snapshot states show still levels (A playing alone, B cued and silent); an empty or
    loading deck shows a silent meter and TRIM 0.0. `diff:native` is within budget on all 42 screens, budgets unchanged.
  - Not yet seen or heard on a device.

## Control map — 8 November 2026

`npm run check:controls` now runs in CI's `verify` job, after the unit tests. It
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
letter's focus gesture is now anchored (`deck.focus`, on both deck cards), and the
header's status pill and CAN'T LOAD alert are described (`console.status`,
`console.error`), for 99 controls: 82 live, 5 partial, 12 planned.

## Where things stand — 5 November 2026

- **Electron is frozen; native Swift is the app being built.** Electron (`src/`)
  gets no new features or UI. Fix it only if it breaks. It stays in the repo,
  working, as the reference for parity and as the option for a PC version
  (Windows/Linux). Don't delete it. Native Swift (`native/`) is the Mac + iPad
  app, with transport, library and analysis largely done and the console ported.
- **New UI is designed in the HTML mockup** (`mockup/xdj-mixer-alt.html`,
  `mockup/console.css`), then ported to SwiftUI. Electron has its own frozen
  copy of the styles (`src/renderer/console/console.css`), so mockup changes
  don't reach it. It was brought up to the native app on 2 November: its Screen
  picker now has every state the app draws (FIND KEYS, importing, loading,
  saving, a track's own cover, missing file, the other drop and TAP states) and
  Height shows the elastic 13-inch stage. Where the mockup is still ahead
  (ENERGY, a working TAP, ↻ and ✕), the app is what has to catch up.
- **The port is exact.** No deviation unless an improvement is raised and agreed
  first. The reference is the mockup (`npm run diff:native`, which no longer
  needs the renderer). See [native/README.md](native/README.md)
  for scope and parity gates.
- **Console port** (on `main`): `DexConsole` library,
  `npm run diff:native` harness (41 screens), the whole console stage with its
  gestures, real waveforms, every sheet and popover, and the app running it
  through `ConsoleModel`. Left: keyboard shortcuts, ENERGY, scroll zoom,
  and controls waiting on the engine (TAP input, re-analysis, removal).
  Key analysis is ported and matches Electron on the bench. The LR4
  isolator and the headphone cue bus (CUE, SPLIT CUE, 4-CH CUE, cue mix) are
  in the engine, render-tested but not yet heard on headphones.
  Workflow and the full list in native/README "Console port".
- **Distortion fixed; the user heard it clean (3 November 2026).** The suspected cause:
  the tone section fed both its fader and the cue through an engine fan-out, with
  block-boundary filter disturbance suspected on affected launches. The precise
  cause was not isolated: several fixes landed together, and the fault never
  showed offline or in the live harness, only in a recording of the real app.
  Now the section feeds
  only its fader and copies its output to the cue. Also fixed: flat bands stay out
  of the signal, volume feeds the limiter, the cue has a peak guard, and the sweep
  is our own always-running filter with Electron's response.
- **The waveform allows for the output's delay; the user saw it line up.** On a
  Bluetooth speaker the sound ran about half a beat behind the waveform. The
  playhead now shows what is heard: graph time less the delay the device reports
  (`OutputLatency`). Hot cues and loops set from it land on the heard beat; jog and
  SYNC stay on graph time. If a speaker under-reports, the waveform stays partly
  ahead, and only a manual offset could fix that; none has been built or agreed.
  The Bose's report turned out accurate. See the next point for what was wrong.
  Recalling a cue still quantises on graph time, so it stays in phase but can land
  a beat later than it was pressed on Bluetooth.
- **SYNC is now a real grid lock (4 November, committed, not yet heard).** The user's
  rule: the grid is the truth, the master is the truth, and everything else, sound and
  display, follows it. See "Grid lock" under Measurements. The iPad silence that led here
  was the Mac holding the Bose: Dex's Mac engine keeps its output open even when idle.
  With the Mac's Bluetooth off the iPad had a good connection, so it wasn't W1. A
  speaker connected to both can go quiet like that.
- **The waveform also allows for the time-pitch's delay (4 November).** After the
  smoothness work the user saw a small offset on the Bose, on both Mac and iPad. Live,
  Apple's time-pitch holds audio back about 85 ms (4096 frames) while reporting 0, even
  bypassed, and offline renders don't show it, so every deck ran that late against its
  clock on any output. `OutputLatency.stretchDelay` now adds it. Measured with clicks
  and a mic on the Bose, the sound went from 92.8 ms to 13.6 ms after the waveform. The
  user then tried it on Mac and iPad and is happy with the waveform on both.
- **Dragging a lane coasts on release, scaled by zoom; the user tried it and loves it
  (4 November).** The engine had a coast, but the app discarded it with
  `release(velocity: 0)`, copying Electron, so the scrub had no inertia. A first version
  went up to about 6.7 s of track at every zoom; on the iPad the user found that good
  but a little too much, and asked for half, scaled by zoom. `JogFling` now makes the
  same hand speed carry the playhead the same track distance at any zoom, as a platter
  would, so it looks biggest zoomed in and smallest zoomed out. The hardest flick
  travels 3.33 s of track. Mac and iPad share the code, for mouse and touch alike. The
  platter still stops where it lifts, and a touch on a coasting lane catches it at once.
- **Audio architecture audit completed; implementation is under way** (3 November).
  The user requested the audit and plan first, with full Bluetooth DJ use on the
  Bose SoundLink Flex and equal Mac/iPad priority. See
  [AUDIO-ARCHITECTURE-AUDIT](docs/AUDIO-ARCHITECTURE-AUDIT.md). Keep the Apple
  audio foundation, but address unacknowledged scheduling deadlines, custom AU
  reset/error handling, and the cue/presentation contracts. Isolated probes
  reproduced clock advance before player startup, retained filter state after
  reset, and swallowed render errors. The existing suite passed; the 100-cycle
  soak passed with a longer synthetic fixture. The audit itself changed no
  production source.
  Follow-up competitive research is in the same audit: follow render-owned
  timing and explicit master/cue buses; revisit the agreed automatic stereo/split
  switch because physical split-cable channel assignments should remain stable.
  djay documents Bluetooth pre-cueing as unsupported on iPad, and NI warns
  against Bluetooth for real-time cueing. Do not treat wired split cue and
  independent Bluetooth master/headphone routing as an identical capability.
- **Audio plan under way; continue from
  [AUDIO-IMPLEMENTATION-PLAN](docs/AUDIO-IMPLEMENTATION-PLAN.md)**, the working
  brief. It holds the whole audio, split-output, Bluetooth-mode and jumpy-waveform
  discussion, work packages W0–W6, evidence, acceptance gates and scope boundaries;
  its completion record says what is done. Done on the `audio-reliability` branch
  (not merged to `main`): W0, the early W2 reset/error subset, and the waveform's
  cadence, movement and tiles, then W1's launch transaction. Open: the rest of W1 and W2, W3, W4, W6 and the rest of
  W5. Detail is under "Audio reliability work" below. Probe source, evidence and a
  starter prompt are in `docs/audio-audit/`; full logs are in ignored
  `out/audio-audit/`, and the transfer ZIP is in `out/`.
- **The lanes now scroll at a steady 60 frames a second on the Mac; the user tried
  it with no issues** on the Mac's built-in speakers (smoothness, sync, transport
  and sound). The numbers were measured without audio (`DexWaveProfile`). Not yet
  tried on the Bose or an iPad.
- **The user's iPad pass came back quite good, with nothing really bad and one
  request (4 November):** far more scrub inertia, now built. The list was audible
  waveform scrubbing and inertia, held CUE, hot-cue timing windows, bar jumps, loop
  halving (shrinking keeps the half the playhead is in), and the console's multi-touch
  gestures (two faders at once, kill hold/latch, CUE → PLAY slide). They didn't itemise
  it, so don't report any single item as measured or as individually signed off.
- CI: three jobs (Electron typecheck/test/build, Electron production
  integration, native tests plus Mac/iPad builds). GitHub's macOS runner ships
  an older Xcode than this Mac, so native code must compile on both SDKs.

## Audio reliability work

The [plan](docs/AUDIO-IMPLEMENTATION-PLAN.md) stays the authority for every work
package, gate and piece of evidence, and nothing has been removed from it. Read it
in full before starting the next package. Sections 1–11 are the brief as written at transfer, and
its completion record is newer where they describe code or test state. This section
is the state of play.

### What the user wants

They reported bass/EQ distortion, Bluetooth sound lagging the waveforms, and
"jumpy" scrolling. Earlier fixes sounded and looked right to them, but they want a
reliable architecture, not accumulating workarounds: "If the entire audio system has
to be rewritten, I don't care." The goal is reliability, efficient CPU and memory,
smooth and accurately synced waveforms, and established DJ-engine practice, not a
rewrite for its own sake. Mac and iPad have equal priority. The hardware is an M3
MacBook Pro on macOS 27.0.1 and a Bose SoundLink Flex, with full DJ use over
Bluetooth, including cueing and scrubbing, as the goal. Project docs name a 13-inch
iPad Air M3 on iPadOS 27 as the main tablet; confirm the actual device before
claiming a result. Don't promise to remove a speaker's own buffering, and don't buy
or silently pick a DJ SDK.

### Order

The user chose: W0, the small reset and error fixes, the first waveform work, then
their iPad pass **before** W1 and W2 change the engine, so regressions can be told
from old faults. This replaces the plan's original W0 → W1 → W2 → W3/W4 → W5 → W6.
After the iPad pass, W1 and W2 are scaled by what the new diagnostics show, then
W3/W4, the rest of W5, then W6. The user gave the go-ahead for W1 on 4 November.

### Done, not merged to `main`

- **W0.** The audit probes are now `AudioAuditRegressionTests`. They reproduced the
  reset residual (0.013661941) and the swallowed router error (−50 returned as
  success) before the fixes. The stalled-queue test (display 0.311 s, output silent)
  was an `XCTExpectFailure` until W1 fixed it. W1 also meant the test failing loudly and
  that's the cue to remove the marker. The soak's default fixture is now 60 seconds.
  The four-second one's 26 failures were the fixture's fault, and loop validation
  wasn't weakened. `AudioDiagnostics` logs the output, formats, reported delay, launch
  margins and failed pulls, off the render thread.
- **Early W2.** `IsolatorUnit.reset()` and `OutputRouterUnit.reset()` clear filter,
  cue and router history and keep the controls. The render thread does the clearing
  (`resetPending`), so it's safe while rendering. `finishStart` calls them on an
  engine restart, for the router and non-playing decks only, because the plan says
  not to zero an active tone section. A failed master pull is now the render's error;
  a failed cue pull is counted and the master keeps playing. One input's silence flag
  no longer marks the whole output silent.
- **W5 steps 2–6, Mac.**
  - `FrameLink` runs a display link fixed at 60 Hz, with a `Timer` fallback on
    macOS 13, and evaluates the heard position for the coming frame's time.
  - `ConsoleClock` is split into per-deck and meter objects, so each update redraws
    only what it moves. Both lanes sample one display time; readouts and the meter
    stay on the 33 ms ticker.
  - Columns are anchored in track time and the view slides by the remainder, with
    the cue, loop and grid markers on the same offset (`lanePlace`).
  - `WaveTiles` caches finished images, capped at 8 MiB. Density includes the
    stage's outer scale. Snapshots still draw directly, so `diff:native` is unaffected.
- **Tooling.** `DexWaveProfile` (Mac only) measures lane pacing with no audio. See
  Verify for the log command.

- **W1's launch transaction.** A launch used to move the clock and set the crossfade on
  the main actor, then hope the control lane started the player in time. Now the gates'
  ramps are held in the render (`dex_ramp_schedule_held`) and what is shown follows the
  old timeline (`heardAt`, `Launch.before`). The control lane queues the audio, starts
  the player, and only then arms the gates through a `LaunchTicket`, which settles once.
  If the player can't start at least 10 ms before its time (`launchMargin`, about one
  output buffer), nothing audible or on the clock has changed: the outgoing voice keeps
  playing and `settleLaunch` plans it again from the original press. Hot-cue timing then
  picks the next reachable entry, and bar jumps re-admit whole bars. After two misses
  it allows more lead, up to 120 ms, so a launch always ends up starting. A later press
  wins even while the framework call is under way. `stretch.reset` moved to the control
  lane, ahead of the launch. What is shown can't run more than 50 ms past the last block
  rendered, so a stalled engine freezes the display instead of inventing progress.

### Measurements

`DexWaveProfile`, release build, M3 MacBook Pro at 120 Hz, two lanes, no audio, 12 s
zoom. These time drawing, not light leaving the screen.

| | Before | Display link, no tiles | Display link and tiles |
| --- | --- | --- | --- |
| Lane updates per second | 28.6 | about 51 | 60.0 |
| Update interval p50 / p95 / max | 35 / 37 / 38 ms | 17 / 34 / 52 ms | 16.7 / 20 / 25 ms |
| Movement per update | about 6 px (derived) | 2.9 px, up to 11 px | 2.91 px, at most 2.93 px |
| Uneven steps | not measured | 14–17% | 0.0% |
| Process CPU, one core = 100% | 21–28% | 27–29% | 30–32% |

- `TimelineView(.animation)` was tried first and gave about 51 fps with drops.
  Rebuilding thousands of rectangles a frame held up the main thread, so even the
  display link fired late. Tiles are what fixed it, so don't drop them to save memory
  without measuring again.
- Most of the remaining CPU is SwiftUI's view graph, not drawing. Smoothness cost
  about 5–10 points of one core; energy and thermal weren't measured.
- Tiles are built on the main thread when first needed, at most about 6 ms, once
  every few seconds per lane. Step 6's off-thread preparation wasn't needed on the
  M3. Recheck on the iPad, where a late tile would show as a periodic hitch.
- For W4: on the built-in speakers the HAL path reports 15.8 ms and
  `presentationLatency` 1.5 ms. On the Bose both report 253.2 ms (11166 frames at the
  device's 44.1 kHz).

Acoustic and live delay, 4 November, M3 MacBook Pro on the Bose. The method and source
are in [EVIDENCE](docs/audio-audit/EVIDENCE.md).

| Test | Result |
| --- | --- |
| Clicks and mic, plain engine: scheduled to heard | 257.5 ms, then 257.1 ms (reports 253.2 ms) |
| Clicks and mic, Dex's engine: sound after waveform, before the fix | 92.8 ms |
| Clicks and mic, Dex's engine: sound after waveform, after the fix | 13.6 ms |
| Muted live test, Dex's engine: time-pitch output against the clock, after the fix | 0.9 ms |
| Muted live, plain time-pitch against schedule: Bose, bypassed, Mac speakers | 81.3, 81.2, 85.4 ms |
| Muted live, plain engine, no time-pitch: Bose, Mac speakers | −2.7, 0.0 ms |
| Muted live, Dex's engine, key lock on, 84 / 92 / 100 / 108 / 116% | 89.5 / 87.3 / 85.4 / 86.2 / 79.7 ms |
| Muted live, Dex's engine, key lock off, 84 / 92 / 100 / 108 / 116% | 87.6 / 84.4 / 87.1 / 81.7 / 74.6 ms |
| Offline render of Dex's engine, against the clock | 0.3–3.0 ms |

W1's gate, 4 November, clock against the sound. Offline, by clicks at known positions:
starts and seeks at 10/30/120/350 ms stalls are all 2.0 ms. Live and muted on the Mac's
speakers, with the control lane really stalled and tapping the signal after the time-pitch,
each cell being the medians of three runs:

| Stall | Start, 100% | Start, 92% | Start, 108% | Seek, 100% | Seek, 92% | Seek, 108% |
| --- | --- | --- | --- | --- | --- | --- |
| None | 0.9, 1.9, 0.0 | not run | not run | 0.0, 0.0, 4.1 | not run | not run |
| 120 ms | 0.0, 1.4, 2.6 | 1.7, 1.7, 9.0 | −3.0, −2.8, −3.2 | 2.8, 3.6, 3.0 | 1.4, 1.7, 2.1 | −1.7, 3.6, −3.0 |
| 350 ms | 0.0, 3.5, 3.4 | not run | not run | 3.5, 0.0, 2.7 | not run | not run |

The 9.0 ms is one run's outlier, unexplained, and within the test's 15 ms limit.

No real session on the Mac logged a missed launch before W1, so these are safeguards
against a slow moment; how often the iPad needs them is unknown.

- The clicks repeated to within 0.1 ms, but absolute mic figures may read up to about
  20 ms low: the Mac speakers control measured −3.7 ms against a reported 15.8 ms,
  probably because the mic reports more delay than it has. So the remaining sound lead
  could be 14–33 ms, before the screen's own delay, which works the other way. That's
  been left alone. Don't tune it without a better reference.
- The screen's delay isn't measured. The mic only sees the clock, not the pixels.
- The allowance is one constant, so tempo extremes stay up to about 11 ms out.

- **Grid lock (4 November):**
  - **Why:** Apple's time-pitch plays the nearest multiple of 1/512 of the asked speed, key
    lock on or off, offline and live. 136 synced to 147 asks 1.08088 and gets 553/512 =
    1.08008. The follower's sound slipped 0.74 ms a second (19 ms at 30 s, 197 ms at
    4.5 min) while the clocks read 0, because they ran on the asked speed. Any deck off 0%
    also parted from its own waveform by up to about 1 ms a second. Native had no
    correction; Electron has `SyncController`.
  - **Now:** `NativeDeck.playRate` is the real speed and every clock and timing uses it.
    `holdLock` (each 100 ms, from a mixer loop while anything plays, not from the display)
    moves the follower between neighbouring steps to stay on the master's grid. An error
    over 20 ms is a real jump on the master, so the follower re-lands with it, at once.
    Limits: ±0.4% steering, 0.25 s between re-landings, no lock out of tempo range or
    during a jog, a master's cue hold, or a launch. A loop under a beat locks to its own
    length, so it isn't chased. The master is never moved.
  - **Master rules ported from Electron, missing in native:** a deck playing alone leads,
    only when what's playing changes, so MASTER on a stopped deck stays until then. Starting
    beside a playing deck leaves that deck leading. SYNC on the master beside a deck to
    follow moves the master there. MASTER now re-lands a synced follower: before, SYNC on
    the master then MASTER on the other left the beats 162 ms apart on a 441 ms beat.
  - **Display:** a locked follower's lane shows `spanSec x masterBPM / ownBPM` seconds
    (`ConsoleState.laneSpan`), so beats match across the width and scroll together. An
    agreed change from Electron, made in the mockup first. Scrub and coast use that span.
  - **Offline, by each deck's sound on its own channel (`GridLockTests`):** B against A
    stays at -2.2 ms, within about 0.5 ms, for 180 s, through bar jumps, a 40 s 4-beat loop
    on the follower, a 20 s 1-beat loop on the master, a master at +3%, and master
    hand-overs. Part of the -2 ms is the test's two click tones. Clock against sound after
    94 s at +3%: 1.0 ms (was about 64 ms by calculation). Speed steps show no dip at 2 ms.
  - **Live, muted, on the Mac's speakers:** no drift over 2 minutes, within about 0.5 ms.
    The player's own sample count agrees with the clock to under 1 ms.
  - **Limit, not fixed:** on a live engine a deck off unity settles early by an amount
    that changes per start: 136 to 147 measured 4.7–14.4 ms in eight starts, and one run at
    0.90 was +3.3 ms. It's steady once settled. It's inside the time-pitch and not visible
    in the player's count, so it can't be corrected from here. Measured with both decks in
    one tap on `sum`; separate taps per node read the same range. Only a stretcher that
    reports its position could remove it (W6), which is the user's decision.
  - A SYNC press with a large tempo jump still dips the outgoing voice for about 15 ms
    (a DC test signal fell to 43%). It predates this work.
  - The probes are not in the repo. Steps haven't been measured on a physical iPad.

### Checked

- **Automated, on the final code before commit:**
  - `swift test`: 238 tests (58 + 32 + 148), no failures. Six optional ones skip by
    default.
  - Mac and iPad Simulator builds succeed.
  - `npm run diff:native` is within budget on every screen.
  - The 100-cycle soak passes on the 60-second fixture, with footprint samples of
    17.5–18.2 MiB. That's a short offline process, not a full-app ceiling.
  - The three muted live clock checks pass on the Mac's speakers, and the first two
    earlier on the Bose too. The stalled-launch one hasn't run on the Bose. They read the
    clock and the graph, so they aren't acoustic checks.
  - The app launched at rest logged: `output: MacBook Pro Speakers (built-in) 2 ch
    48000 Hz, delay reported 15.8 ms, used 15.8 ms, presentation 1.5 ms`.
- **After the grid lock, on the final code:** `swift test` 252 tests (58 + 32 + 162) with
  7 optional skips and no failures; `npm test` 251; `diff:native` within budget on all 42
  comparisons (budgets unchanged); Mac and iPad Simulator builds succeed; the 100-cycle soak
  passes at 17.4–18.1 MiB; all four muted live checks pass on the Mac's speakers.
- **CI:** all three jobs passed on `9c2fd8d`, including the native tests and the
  Mac and iPad builds on GitHub's older Xcode. The scrub coast then passed too (`c4d8052`).
  W1 and the grid lock were pushed together on 5 November and have their own run; check its result.
- **The user's own try (3 November):** a Debug build made after the last source
  change, on the Mac's built-in speakers. They found no issues with waveform
  smoothness, waveform and sound sync, or transport and sound. Which transport actions
  they tried wasn't itemised, so this doesn't sign off any single one.
- **The user's Bose try (4 November), before the time-pitch fix:** on the Mac and on
  a physical iPad, both on the Bose. The waveform looked really good on both, smooth
  with no real jumps. They saw a slight offset, under half a beat, similar on both.
  This covers smoothness and that offset, not the rest of the iPad list.
- **The user's try of the time-pitch fix (4 November):** the waveform performs very
  well on both devices, and they're happy with it. The rest of the iPad list was quite
  good with nothing really bad, apart from wanting more scrub inertia. A first coast
  then felt good but a little too much on the iPad, which led to the scaled version,
  and the user loves that one.

### Not checked: never report these as passed

- The zoom-scaled coast with a mouse on the Mac isn't separately confirmed. The user
  didn't say which device they tried it on, and asked that the desktop has it. It's the
  same code with no platform branches, it's in the Mac build, and its tests run on the Mac.
- Anything measured on an iPad. The time-pitch constant comes from the Mac. The iPad
  uses the same unit and the user is happy with it by eye, but neither its delay nor
  its reported Bose delay has been read.
- iPad frame pacing, measured. `DexWaveProfile` doesn't run there.
- Hot cues and loops set by ear against the fix, as a specific check, and the jog
  handover. Jog audio skips
  the time-pitch, so entering and leaving a jog may shift by about 85 ms.
- A measured release build with real audio playing, or two decks with EQ and filter
  moving while profiling.
- Split cable and USB interface (no hardware), multi-hour sessions, energy and
  thermal.

### Awaiting the user

- W1 and the grid lock are committed together on `audio-reliability`. The user hasn't heard
  the grid lock or tried it on the iPad.
- Whether the 3–14 ms settle is good enough by ear, or worth comparing stretchers for (W6).

- **The zoom-scaled coast is signed off; leave it unless the user asks.** To tune it,
  `JogFling.referenceDamping` sets how far a flick goes (lower is further), and the
  hardest flick's distance follows from it. The lane's speed at release still starts the
  coast, so pitch doesn't jump, which means a zoomed-in coast starts slower and runs
  longer: up to 6 s. On a playing deck the music only resumes when the coast ends, so
  it can hold the music off for that long unless a touch catches it first. Handing back to
  the music as the coast reaches playing speed is an option if that drags, but it needs
  a clean audio handover.
- **Should the platter coast too?** It still stops where it lifts, because the control
  map calls it precise. The user asked about the scrub and mouse dragging on the lanes.
- **Play on the W1 build, Mac and iPad,** rebuilding first: hot cues, seeks, loops and
  bar jumps, listening for anything newly late or any gap. Then say whether the next
  package is the rest of W2 or something else. The iPad is where a slower control lane
  would show.

### Left to do

Summaries only; the gates are in the plan.

- **Replace `stretchDelay` when W4 can.** It's a measured constant, not an
  acknowledged render position, and it hides an Apple behaviour that could change with
  an OS. The muted live test catches that when run, but CI doesn't run it.
- **Rest of W1.** The gate is met, but these parts of it aren't done: graph construction
  and recovery rebuilds still run on the main actor (step 1); rendering confirms how far
  it has got but not which source position it played, so `stretchDelay` stays a constant
  (step 4); and PLAY lights on the press, before the launch is confirmed (step 6). That's
  deliberate for button feedback, but it's a stated choice rather than effective state.
- **Rest of W2, buses.** Reset for gate queues and state, plus allocate/deallocate
  tests. Formal master/cue ownership: a render-once AU or a consolidated mixer owner,
  whichever is simplest and passes; a frame-count check alone isn't enough. Validate
  formats, buses, maximum frames and nil outputs (the DSP assumes 48 kHz planar
  Float32 stereo). Recovery must not emit old cue data, and duplicate or changed-size
  pulls must not process source state twice. Keep the gain staging and smoothing fixes.
- **W3, output modes.** Stereo, DJ split cable (fixed mono master and mono cue, even
  with no deck on CUE) and multichannel, with preference, capability and effective
  route kept separate. Remove CUE-driven folding. Route controls go in the HTML
  mockup first; exact labels and placement aren't signed off. Headphone CUE may be
  gated by route; the transport CUE never is. Never put cue material on the audience
  output. Physical split and USB checks stay pending.
- **W4, presentation.** One route-aware service with macOS and iPad adapters; stable
  route identity, not a Bluetooth name match; estimates with validity rather than
  silent zero; replace the 750 ms cap and one-second history coupling; coalesce
  configuration changes instead of dropping them during startup; define pause, seek
  and draining behaviour; optional remembered calibration; automatic compensation
  with a discreet notice, never a required prompt. Bluetooth is a route property, not
  a second engine and not a synonym for split. `heardPosition` and `FrameLink` should
  then consume this service rather than become a competing clock.
- **Rest of W5.** iPad measurement and step 6 if needed, a release run with real
  audio, external-display and refresh changes, tile-boundary and marker checks, and
  discontinuities following effective audio time. Since W1, a stalled launch no
  longer shows as progress that isn't sounding.
  `Screen.Lane` still passes the common span, so tempo-scaled zoom is unchecked.
- **W6, comparison and certification.** A narrow same-task comparison with djay or
  similar, benchmarking the current Apple player and time-pitch before any rewrite, a
  proven component behind the same transport interface only if the gates need it, and
  a multi-hour two-device release profile.

### Keep in mind

- Musical behaviour in plan §4 and `native/README.md` must survive every package:
  two prepared voices, 30 ms and about 120 ms pre-rolls and 10 ms fades (benchmark
  them, don't change them arbitrarily), ±16% tempo, sticky SYNC, CUE and hot-cue
  timing windows, loops, jog, route-loss safety, iPad background audio.
- No allocation, locks, logging or async dispatch in render code. Caches and command
  queues stay bounded. Don't raise snapshot budgets to pass.
- No audible tests without the task authorising them. The live check stays muted.
- Open risks not reproduced as failures, in plan §5: the cue handoff identifies only
  a frame count, configuration notifications can be dropped during startup, and the
  original distortion's precise cause is still unisolated.
- Independent Bluetooth speaker plus separate headphones isn't established as
  available; investigate before promising it.
- Offline renders can't show live time-pitch delay, so any timing claim about it needs
  a live graph or the mic. Offline, time-pitch fills itself the moment it's rendered, so
  a launch reaching the player between blocks measures 2 ms, and one landing after a
  block measures up to 85 ms. That's a test race, not an app fault, so offline launch
  tests settle the control lane before each block. A live engine always renders first,
  which is why it's a steady 85 ms. Judge launches with clicks, not the ramp fixture.
  A delayed player start is scaled by the tempo, so carry waiting in source frames (the
  lead after two misses is the one last-resort exception). The engine's roughly 90 ms replacement pre-roll is what
  keeps a recall from opening its gate on silence; don't shorten it without checking.
- Tools: BSD `sed` has no `\b`, so a substitution using it silently does nothing, and
  zsh's builtin `log` shadows the tool, so use `/usr/bin/log`.

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
- Mixer meters (8 November 2026): A · L · R · B together in the centre strip, LOW Σ dropped, all peaks on one scale.
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
DEX_NATIVE_LIVE_CHECKS=1 swift test --package-path native --filter LiveClockTests    # muted
swift test --package-path native --filter DexEngineTests                             # engine rebuild, gate 1
swift run -c release --package-path native DexEngineBench cpu|speed|jump|live|clips  # gate 2, never plays aloud
swift run -c release --package-path native DexWaveProfile --span 12                  # lane pacing, opens a window, no audio
/usr/bin/log stream --level info --predicate 'subsystem == "dex.native"'             # output, delay, missed launches, failed pulls
```

Dev servers (`.claude/launch.json`): Electron renderer on **5299**, mockup on
**8765** (5199 belongs to another project).

## Docs map

- [README](README.md): what Dex does, how to run it, verified numbers.
- [native/README](native/README.md): native scope, agreed behaviour, architecture, parity gates.
- [ENGINE-REBUILD-SPEC](docs/ENGINE-REBUILD-SPEC.md): the replacement engine's brief and rules, and
  [ENGINE-STRETCHER-MEASUREMENTS](docs/ENGINE-STRETCHER-MEASUREMENTS.md): its results and the listening steps.
- [AUDIO-IMPLEMENTATION-PLAN](docs/AUDIO-IMPLEMENTATION-PLAN.md): next-agent brief,
  intent, staged implementation and acceptance for audio/routing/Bluetooth/waveforms.
- [AUDIO-ARCHITECTURE-AUDIT](docs/AUDIO-ARCHITECTURE-AUDIT.md): original findings,
  competitive research and evidence limits.
- [docs/audio-audit/](docs/audio-audit/): the audit's probe source, evidence index
  and starter prompt, as recorded at transfer, plus the click and mic delay probe.
- [UI-CAPABILITIES](docs/UI-CAPABILITIES.md) and [CONTROL-MAP](docs/CONTROL-MAP.md): UI inventory and control spec.
- [GAIN-STAGING-RESEARCH](docs/GAIN-STAGING-RESEARCH.md): gain staging, meter references and the AUTO trim target, with sources.
- [ANALYSIS-SUMMARY](docs/ANALYSIS-SUMMARY.md) / [ANALYSIS-RESEARCH](docs/ANALYSIS-RESEARCH.md) and [accuracy/](accuracy/README.md): BPM/grid analysis and the marked-song bench.
- [IDEAS](docs/IDEAS.md): later goals.
