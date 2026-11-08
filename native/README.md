# Dex Native

Native Swift rebuild for Mac and iPad: the app being built. Electron is frozen
as the reference and a possible PC version. **This is a development build, not
a feature-complete replacement.** Keep using Electron for sets until the
[parity gates](#feature-parity-gates) pass.

## Agreed scope

- macOS and iPadOS from the start, sharing the audio/analysis/library core.
  A native Mac app, not Catalyst. Compile floors are macOS 13 / iPadOS 16
  (untested on those versions).
- **Port the Electron console exactly.** The frozen Electron UI
  (`src/renderer/console/`) is the reference for layout, controls, sizing and
  behaviour of everything it has. Deviate only where an improvement has been
  raised and agreed. [UI-CAPABILITIES](../docs/UI-CAPABILITIES.md) and
  [CONTROL-MAP](../docs/CONTROL-MAP.md) are the inventory. The app runs the
  ported console.
- **New UI starts in the HTML mockup** (`mockup/xdj-mixer-alt.html` and
  `mockup/console.css`) and is ported from there, not built in Electron first.
  Electron keeps its own frozen copy of the styles.
- **Screen sizes: elastic height.** The base stage is **1174 × 814 pt** (the
  11" iPad Pro's 1194 × 834 minus the mockup's 10 pt bezel; a near-exact fit
  for the common 11" Air and base iPad). Scale uniformly to fit. Spare height,
  up to a **4:3** window (the 13" iPads, 66.5 pt), grows the zoom-lane box; the
  two lanes share it, and everything else keeps its size and moves down. Beyond
  4:3, letterbox. Widths never stretch, so the base view stays pixel-exact.
  Electron implements this as `MAX_STRETCH` / `--stretch`; the port matches it.
  Still to settle during the port: a minimum usable window size (Split View,
  Stage Manager, Mac) with a "make the window larger" notice instead of
  sub-44 pt controls; iPad mini support (91% scale); deferring the system
  swipe-up gesture over the bottom transport row. iPhone is out of scope.
- Primary tablet: **13-inch iPad Air M3, iPadOS 27**. The user has confirmed
  launches on that iPad and their MacBook Pro.
- Fresh native library. No Electron data migration.
- Standard stereo output must work alone. Split cue / four-channel cue stay
  available for capable outputs. Physical split/USB monitoring checks are
  deferred (no splitter or USB interface on hand).
- **Deferred:** ROLL (removed) and loop dragging. See [IDEAS](../docs/IDEAS.md).

## Run

Open `DexNative.xcodeproj`, choose the **DexNative** scheme (not the
`DexMacPreview` package executable), then **My Mac** or the connected iPad by
name. **⌘R** installs and launches; ⌘B only compiles. Pick your own development
team in Signing & Capabilities on another account. No credentials are committed.

Quick Mac launch without Xcode: `swift run --package-path native DexMacPreview`
(uses a separate `DexNativePreview` data folder).

If Xcode reports "Unable to resolve module dependency: DexAudio", reload the
project, select **My Mac** and build again (Debug builds only the active
architecture, for the app and packages alike).

## Behaviour

Numbers below are deliberate, user-agreed choices. Change them only on request.

**Transport.** One real-time loop (`Sources/CDexEngine`) plays both decks. Every change
of position is a landing: a voice started on a chosen output frame and source frame, with a
**10 ms** crossfade. Nothing is pre-rolled, so a press comes out on the next audio block (a
start from stopped also takes the 10 ms fade, so its attack is whole). A landing whose audio
isn't read yet waits with the outgoing audio playing: a start or plain seek then starts where
it was asked, while a quantized cue, bar jump or loop slides on to keep the beat count. The
display follows the outgoing audio until the landing is heard. A later press replaces one
that hasn't landed. Tempo ±16%, key lock (Bungee).

**SYNC / MASTER.** The master is the truth. SYNC is sticky per deck. A synced deck takes
the master's tempo, starts beat-aligned, and is held on the master's grid while both
play, through loops, jumps, seeks and recalls. The engine holds the lock in its own loop,
steering the follower's speed and re-landing it on a real jump on the master. A deck playing alone
leads; starting beside a playing deck leaves that deck leading; MASTER on a stopped deck
holds until what's playing changes. SYNC on the master beside a deck to follow moves the
master there. A locked deck's lane is scaled so its beats match the master's across the
width (an agreed change from Electron). Beyond ±16% the grids can't lock and aren't chased.

**Main CUE.** Loading parks the playhead and CUE on the first grid beat. Setting
CUE while paused snaps to the nearest beat. Hold to audition, release to return.
PLAY while holding latches the preview. CUE while playing stops and returns.
With the other deck playing, the preview launches on that deck's beat, chosen
from the moment of the press (SYNC off is fine). A press up to **150 ms late**
(capped at 30% of a beat) still joins that beat at the matching source point. A
missed attack is never replayed late. On iPad the key uses a direct UIKit touch
control, so holds survive redraws and a second finger can press PLAY.

**Hot cues.** HOT CUES toggles a 4 × 2 bank over the platter that leaves the
transport usable. Empty pads save the nearest beat. Saved pads jump while keeping
play/pause state. A playing recall keeps the deck's own **1–2–3–4 count**: a
beat-one cue waits for the outgoing beat one (no other deck or SYNC needed),
with a **100 ms late window** (capped at 20% of a beat). DELETE arms deletion:
saved pads turn red and a tap deletes without confirmation until DELETE or
DONE. Cues snap to the grid when loaded or when the grid is corrected.

**Loops.** ‹ number › selects ½–64 beats. The number enters or leaves the loop
(quantized to the next beat). ‹ halves and › doubles, live or while preparing.
**Growing keeps loop-in. Shrinking keeps the window the playhead is in**, so it
plays on: halving a 4-beat loop on beat 3 keeps beats 3–4. The old audio plays
until the new region is ready. Expansions past the track end are rejected and
the old loop stays.

**Bar jumps.** ◀ ▶ with a 1/4/16/32-bar selector. Playing jumps keep the
position within the bar. Paused jumps start from the nearest bar line and stay
paused. Near the track ends, only whole bars that fit are moved. An active loop
moves with the jump.

**Waveforms and jog.** Two detailed three-band lanes (blue lows, orange mids,
cream highs) share a centred playhead. Zoom is 4/8/16/32 output seconds and
scales with tempo, so synced beats line up. Overviews seek. Dragging a lane
**scrubs audibly like vinyl** (±8 source s/s), then coasts to rest on release.
The same hand speed carries the playhead the same track distance at any zoom, up to
3.33 source seconds, as a platter would (`JogFling`): it looks biggest zoomed in and
smallest zoomed out. This is an agreed improvement on Electron, whose scrub stops
where the finger lifts; the platter still stops there too.
A deck that was playing resumes normal playback afterwards; a paused one stays
paused. A fresh touch catches the coast. Any transport action takes over at once.

**Grid editor.** GRID A/B opens the beat grid sheet, as in Electron: an
eight-second waveform to drag, SET DOWNBEAT then tap, ±1 ms, ±0.1 BPM, ÷2/×2,
TAP (3–8 taps, 60–200 BPM) and the other readings the analysis found. Edits
save, update a second deck on the same track, exit loops and re-snap cues.
Offsets keep bar phase. (The old native editor's typed BPM/offset fields went
with it; Electron has none.)

**Library.** ADD FILES, ADD FOLDER and files dropped on a deck import an
app-owned copy, deduplicated by streamed SHA-256. Grids, corrections and eight
hot cues persist. Writes are atomic, with a backup, damaged-catalog recovery
and RETRY on failure. A newer schema is never overwritten. Playlists save
beside the catalog in `playlists.json` (last writer wins). Data lives in
Application Support/DexNative.

**Lifecycle.** Audio continues when the iPad locks. Interruptions freeze
positions, and permitted resumption restarts normal playback. Route changes or
service resets rebuild the graph and wait for PLAY. Memory pressure cancels
optional preparation, never active playback.

## Engine

`Sources/CDexEngine`, one real-time loop owning everything audible, built from
[ENGINE-REBUILD-SPEC](../docs/ENGINE-REBUILD-SPEC.md), with results in
[ENGINE-STRETCHER-MEASUREMENTS](../docs/ENGINE-STRETCHER-MEASUREMENTS.md) (gates 1 and 2) and
[ENGINE-GATE3-RESULTS](../docs/ENGINE-GATE3-RESULTS.md) (gates 3 and 4). `NativeDeck` and `NativeMixer` drive it
through `DexAudio/EngineCore.swift`. It replaced the AVAudioEngine players and time-pitches on 6 November 2026, when
the user chose it at gate 4. It stays optimised in Debug, because a stretcher is far too slow otherwise. Never read
Mixxx or another GPL DJ engine while working on it.

## Console port

The SwiftUI console lives in the `DexConsole` library: pure views over a
`ConsoleState` value plus `ConsoleActions` closures, so the same views render
in the app, in tests and in snapshots. Port region by region:

1. Read the reference from the mockup: the computed styles and boxes of every
   element in the region. `npm run diff:native` writes every element's box to
   `out/native-diff/*/a.json`.
2. Build the region in `DexConsole`, keeping the CSS's layout rules (flex
   rows, padding inside borders) rather than hard-coding positions. Size text
   with `Label`, which uses CoreText's fractional widths as Chromium does.
3. Add the region to `only` in `scripts/native-diff.json` and run `npm run
   diff:native`. It renders the native side with
   `DexConsoleSnapshot` and diffs it with an anti-aliasing tolerance. Lower
   each pair's `budget` to the new count; never raise it to pass.

A design change in the mockup is ported the same way: give the native demo
state the mockup's demo data where they differ, and set a fresh budget from the
first count on a pair whose screen changed. Once the mockup moves on, `npm run
diff:mockup` (mockup against the frozen renderer) shows those changes as
differences; that is expected.

Done: the whole console stage — top bar, zoom lanes, track windows, deck
bays (keys, tempo, platter, beat jump, CUE/PLAY, loop stepper) and mixer
(TRIM, FILTER, faders, meters, kills, LINK LOWS, crossfader) — with its
gestures (`Gestures.swift`, ported from `useMixDrags.ts`, `Chassis.tsx` and
`Band.tsx`): relative fader drags with FINE ¼ / ⅒ and double-tap reset, kill
hold/latch, CUE hold with slide onto PLAY, platter and lane scrubbing (on the
deck's jog, no coast), overview seeking and double-tap zoom reset. Real
waveforms draw as the WebGL shader's three-band mode (`TrackWave`). The sheets
and popovers (`Sheets.swift`, `Pops.swift`, `Library.swift`): the library with
playlists, sorting, search and key filtering; the beat grid sheet; VOLUME,
TRIM, the band sheet and the hot cue bank; shortcuts; TAP; the (i) help;
alerts; empty decks; and drag-and-drop onto a deck. Every `?demo=mockup`
screen of the mockup diff is a `native-diff.json` pair, and so is each state
the mockup gained after the freeze. Since the library redesign every pair diffs
against the mockup, not the frozen renderer. The app runs it all
through `ConsoleModel` (`DexApp`), which builds `ConsoleState` from the engine
and publishes playheads and the meter on a separate `ConsoleClock`, one object
per deck and one for the meter, so each redraws only what it moves. Overviews,
platters and time readouts update at 30 Hz. The zoom lanes follow the display:
`FrameLink` asks each playing deck what will be heard when the coming frame
appears, 60 times a second, and only the lane's contents redraw. A playing lane
slides by fractions of a pixel, its markers with it; at rest everything snaps to
device pixels as the mockup does. Live lanes draw from `WaveTiles`, finished
images fixed in track time and capped at 8 MiB, because asking the renderer for
thousands of rectangles a frame held up the main thread and dropped frames.
Snapshots still draw directly, so the mockup diff is unaffected.

Text that wraps uses `Para`, which breaks lines greedily as Chromium does (the
system keeps a lone last word off its line) on CSS line boxes. Snapshots set
`ConsoleStage(snapshot: true)`, which draws the search field, the track list's
scroll view and the drop targets as plain views: `ImageRenderer` cannot draw
platform views.

Waiting on the engine: TAP (no audio-input tempo reader; the sheet says so),
swapping the readings list when another reading is
taken, and a master above 100 % (VOLUME's top fifth holds at 100 %). The
beat grid sheet draws its waveform from the audio file for the visible window
(`GridWaveReader`, its own file handle), since the stored envelope stops at 5 ms a
bin; zoom runs from 8 s to 250 ms across and a drag moves the waveform under still
lines. A library row's MORE reads album, genre, subgenre (a custom SUBGENRE tag only), remixer and
release from the tags, showing the date in the system's short format, and tracks
saved earlier fill in the background on launch.
Re-analyse asks twice, then is Electron's: grid, readings and key are replaced, hand-edited grids
included, and hot cues stay, snapped to the new grid on a deck as on any grid change. Remove deletes the library's copy and cover, leaving
the original file; it is refused while a deck holds the track, since a deck
reopens its file after an audio route change. SPLIT CUE,
the channel CUE keys and VOLUME's CUE MIX drive the engine's cue bus. Not yet
ported: ENERGY mode, scroll-wheel zoom and keyboard shortcuts (the shortcuts
sheet lists Electron's). Loop dragging in the lane is deferred, not missing.
Residuals: glyph edges (SwiftUI draws stems a fraction of a pixel
heavier than Chromium at 1×), and in `home` the synthetic demo waveform's
hairlines, which Chromium's SVG rasteriser anti-aliases differently.
`home-overlays` hides those demo strokes on both sides so everything drawn
over them is held to a tight budget. Chromium snaps CSS boxes to whole device
pixels; overlays placed at fractional positions use `snap(_:_:)` to match.

**Label face: Avenir Next Condensed** (decided 31 October 2026), a system font
on macOS and iPadOS, in both apps. CSS weights 400/700/800 are its Regular,
Bold and Heavy cuts. Until then `--font-cond` named "DIN Condensed Bold",
which Chromium doesn't recognize, so labels had silently fallen back to Arial
Narrow (macOS-only, licence needed to bundle). Switch points: `--font-cond` in
`mockup/console.css` and `Face.cond` natively.

## Architecture and memory

- `DexCore`: beat grid, output-time transport clock, loop regions, cue snapping
  and timing windows, bar-jump planning, sync ratios, gain law, jog motion.
  Pure and fully unit-tested.
- `DexAudio`: the AVAudioEngine graph is one source node calling the engine's loop, which
  runs, per deck, the cache-fed voices → Bungee when key lock is on → trim + isolator + sweep
  filter → fader, then the sum → master volume → limiter → router → output, with each deck's
  tone section also feeding the router's cue inputs. The isolator (`Isolator`, from
  `src/shared/isolator.ts`) and the router (`routing.ts`) are the C DSP in `CDexDSP`. Files are
  read by a loader thread into a fixed cache of 64 chunks per deck; no full-track PCM. The loop
  never allocates, waits or reads files (`EngineRealtimeTests`).
- Gain staging keeps kicks out of the limiter. Summed LR4 bands are flat in level
  but rotate the phase, lifting real tracks' peaks by 1–5 dB, so flat bands stay
  out of the signal and crossfade in when one moves (Electron always runs them).
  Volume feeds the limiter, so the default 70 % leaves one deck untouched. The
  cue bypasses the limiter, so the router holds it at full scale with a peak guard.
- Blocking AVFoundation control (session activation, engine start/stop, player
  stop/schedule/play) runs FIFO on `AudioControlExecutor`, never on the main
  thread. Objects crossing to it go through `ControlHandle`, because CI's older
  SDK doesn't mark them Sendable.
- `DeckLoopController` / `LoopAudio`: explicit off/active/preparing states. A
  pending request carries its playhead shift (set by bar jumps, kept by resizes).
  Loop regions are capped at **32 MiB**, with shared **128 MiB** preparation
  accounting.
- `DeckJog` / `DexJog` (C): eight-second windows (≤2.93 MiB, ≤3 per deck) and
  lock-free variable-rate rendering. Reusable for future platter input.
- `RhythmReader` / `BeatDetector`: streaming 22.05 kHz mono analysis (downmixed
  explicitly), autocorrelation, comb and kick refinement, alternatives. Features
  are capped at 20 minutes.
- `WaveformReader` / `WaveformEnvelope`: one decode pass feeds envelopes and
  rhythm. Packed pyramid stays under 5 MiB per track; disposable binary cache.
- `NativeLibrary` / `LibraryStorage`: versioned JSON catalog with locked field
  merges and a coalescing writer; app-owned audio.
- `DexApp`: `ConsoleModel`, the engine ↔ console bridge, and the system file
  picker behind ADD FILES and ADD FOLDER.

These budgets cover what the app admits, not total process RSS. A long-session
flat-RSS profile on hardware is still to do.

## Feature parity gates

| Area | Native status | Required before switching |
| --- | --- | --- |
| Layout / touch | Console stage, gestures, sheets and popovers ported and in the app | Keyboard shortcuts, accessibility; device feel |
| Mac + iPad | Both build; lifecycle policies graph-tested; user confirmed launches | Physical iPad lifecycle/route/Files checks, long sessions |
| Decode | File-backed streaming | Format matrix incl. Ogg/Opus, memory profile |
| Tempo / key lock | ±16% pitch/beat-period checks; music exports | Listening comparison against Electron's Signalsmith |
| Clock / SYNC | Live, muted, five minutes on the Mac and three on the iPad: waveform against sound under 1 ms, decks 0.02 ms apart. The playhead shows what is heard: the engine's time less its own 2 ms and the output device's reported delay (`OutputLatency`). On the Bose the engine's own error is 1–3 ms by mic; the speaker under-reports its delay by an amount that varies (4–20 ms seen) | Other speakers' real delay against their reports, the screen's delay, a per-speaker offset if wanted |
| CUE / hot cues | All behaviour above | Slide CUE→PLAY, keyboard parity, device feel |
| Loops / jumps | All behaviour above | Device listening, keyboard parity |
| Waveforms / jog | Three-band lanes, overlays, audible inertia | Device feel and frame pacing; ENERGY mode |
| Mixer | Fader law, trim, crossfader, LR4 isolator (220 Hz / 3.5 kHz, bypassed while flat, kills mute; offline-render tested against Electron's maths), sweep filter, LINK LOWS, AUTO trim (BS.1770 loudness at import), four peak meters A · L · R · B (decks after LEVEL and crossfader, master before the limiter), limiter; headphone CUE pre-fader, SPLIT CUE (stereo master until a deck is on CUE, then mono master left and mono cue right; agreed improvement on Electron), 4-CH CUE (1/2, 3/4; split without four outputs), cue mix (routing render-tested) | Listening on headphones, split cable and a four-output interface |
| Analysis | 28/28 marked songs within 0.5 BPM, worst beat <8 ms; key/Camelot (`KeyDetector`, from `src/shared/key.ts`): same key as Electron on all 51 bench tracks with a marked key, 65 % exact and 82 % top-3 against Beatport, confidence within 0.02 | Intensity, LUFS/trim, more genres |
| Track windows | Cover, artist and title from the file's tags on each load (`Tags`, from `src/shared/tags.ts`: ID3, FLAC, MP4, AIFF/WAV ID3 chunk; same result as Electron on every library track tried), cover kept as a 320 px thumbnail only while the deck holds the track, two-colour placeholder otherwise | — |
| Grid editing | All behaviour above | Device gestures, keyboard parity |
| Library | Managed audio, metadata, recovery; the Electron sheet with search, sorting, key filter, playlists, folder import, drops; keys read at import, FIND KEYS for older tracks (key only: grids and cues stay); artist and title from the tags at import, or on an older track's first load, for rows, search and status | Re-analysis, removal, session restore |
| Input tap | Sheet ported; no input reader | Permissioned analysis-only input |
| Release | Local dev signing | Long-session RSS, oldest OS, release signing/notarization |

Don't mark a gate done based only on UI presence or position maths.

## Verification

```sh
swift test --package-path native
xcodebuild -project native/DexNative.xcodeproj -scheme DexNative -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project native/DexNative.xcodeproj -scheme DexNative -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

CI runs the same three on GitHub's `macos-latest`, which currently ships
**Xcode 26** (one SDK behind local Xcode 27). Code has to compile on both; see
`ControlHandle` above.

Tests render the real graph offline and analyse the recorded audio: pitch, beat
phase, cue attacks, loop content, gaps (2 ms windows) and the 1–2–3–4 count.
"0 ms" means indistinguishable at 2 ms resolution. These are offline results,
not hardware latency guarantees. Optional checks, skipped by default:

- `DEX_NATIVE_REFERENCE_AUDIO=/path/track.mp3 DEX_NATIVE_AUDIO_OUTPUT=/path/out`
  exports 84/100/116% listening excerpts (`--filter MusicRenderTests`).
- `DEX_NATIVE_LIVE_CHECKS=1` runs the muted live checks on the real output
  (`LiveOutputTests`): two key-locked decks for `DEX_LIVE_MINUTES` (3 by default), and
  starts and seeks against the click. The sound is silenced after the engine.
- `DEX_NATIVE_SOAK_CYCLES=100` runs the two-deck endurance check on a synthetic
  60-second track.
- `swift run -c release --package-path native DexWaveProfile [--span 12]` opens
  a window for a few seconds and reports how evenly the lanes move, with no audio;
  `--audio 1` plays two tracks through the engine, muted, with the EQ moving, and
  `--window 0` leaves the window out to measure the audio's CPU alone.
- Marked-song bench (local collection):
  `swift run --package-path native -c release DexAnalysisBench --manifest accuracy/manifest.json --marked --verify`
  fails on decode errors, BPM error >0.5 or any beat mark >25 ms.

While the app runs, what the audio control plane sees goes to the system log: the
output in use and its reported delay, and on leaving the foreground the engine's
counters (landings, late landings, blocks waited, starved blocks, output gaps):

```sh
/usr/bin/log stream --level info --predicate 'subsystem == "dex.native"'
```

Physical iPad acceptance (touch, listening, frame pacing, lifecycle) is always
the user's check. Never claim it passed from offline runs.
