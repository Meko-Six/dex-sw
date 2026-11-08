# Dex

[![CI](https://github.com/Meko-Six/dex-sw/actions/workflows/ci.yml/badge.svg)](https://github.com/Meko-Six/dex-sw/actions/workflows/ci.yml)

A bare-bones two-deck DJ mixer for macOS. Local audio files only, everything on
the machine, no accounts and no uploads.

Electron + TypeScript + React, with the audio graph and DSP in the renderer.
Tempo change is pitch-preserving (key-lockable), sync is tempo **and** beat
phase, and every claim below was measured by the app's own self-test.

## Native Swift rebuild

Development has moved to the Mac/iPad app in [`native/`](native/README.md),
whose console is ported exactly from this one. **This Electron app is frozen**
(1 November 2026): no new features or UI, only fixes if it breaks. It stays as
the working reference until the native app passes feature parity and
audio/device validation, and as the option for a PC version. New UI is designed
in the HTML mockup (below) and then built natively. [HANDOFF](HANDOFF.md) has
the current state.

## What it does

- **Load tracks** — drag files onto a deck, use *Load track*, or add files and
  folders to the persistent library (grids, waveform peaks and hot cues are
  cached).
- **Scrolling waveforms** — a fixed white playhead at the centre; playback and
  scrubbing move the peaks underneath it. Wheel zooms, double-click resets.
  **3BAND** is the default view: overlapping blue bass, orange mids and white
  highs, in both scrolling lanes and whole-track overviews. Both decks use
  the same frequency colors. Played and unplayed audio have equal brightness.
- **Musical intensity** — ENERGY colors both scrolling waveforms and track
  overviews from blue/cyan (calmer) to amber/red (harder), with a shared scale
  and a current 0–100 readout. Click ENERGY again or select 3BAND for frequency colors;
  the display preference is saved. A bar-level estimate combines relative section
  level, band attacks, bass and treble activity, normalized against mastering
  gain. This is a heuristic for comparing sections, not a human-rated energy
  classification. Imports/re-analysis also measure LUFS and suggested trim.
  Older tracks are analyzed in the background when loaded; results are cached.
  Their newly measured trim takes effect on the next load, avoiding a volume
  jump during playback.
- **Beat detection** — BPM, downbeat offset and a confidence score from a
  dependency-free spectral-flux detector running in a worker.
- **Grid editing** — a waveform view you drag onto the beat, plus tap-to-set
  downbeat, tap tempo, ±0.1 BPM, ±1 ms nudge (Shift = ±10 ms) and ×2/÷2
  interpretation. Edits are saved back to the library entry.
- **Tempo** — ±16% with key lock on by default; vinyl mode lets pitch follow.
- **Sync** — SYNC follows the MASTER deck's tempo and snaps the beats together
  when enabled during playback. It stays armed across track loads; PLAY and
  held CUE also snap to the playing deck's beat. Seeks and hot-cue recalls
  preserve beat phase while SYNC is on. A ±0.25% drift trim maintains alignment,
  and tempo changes preserve the playback clock's phase.
- **Hot cues** — eight per deck in a popover from each deck's CUES key, saved with the
  track and restored when it loads again (four-slot libraries still load). An
  empty pad sets at the playhead, a set pad jumps back to it; DELETE,
  Shift-click or right-click clears. Each slot has its own colour, and its
  numbered marker scrolls on the waveform in the same colour.
- **Loops** — a compact `‹ 8 ›` stepper beside play: the arrows halve or double
  the size (1–64 beats, a running loop follows), the readout starts a quantised
  loop or leaves it, and ROLL holds a loop at that size and drops back in where
  the track would have been.
  Active loops are highlighted in yellow on the main waveform, with their
  start/end boundaries and beat count, and marked in the track overview.
  Drag the yellow region to move the loop forward or backward in whole-beat
  steps; its length and playback phase stay intact. A focused loop also moves
  one beat with the left/right arrow keys.
- **Library** — click a deck's title (or `music`) and the library slides up;
  a deck panel stays on top (PLAY, CUE, loop stepper, time left, crossfader),
  so the mix stays in hand while you pick the next track. Tap a track, then tap
  a deck's title to load it. Playlists sit in a column on the left.
- **Mixer** — a centre console laid out like the mockup: per channel TRIM,
  sweep filter, LEVEL and cut-only HI / MID / LOW faders with latching or
  momentary kills, LINK LOWS for the bass swap, AUTO trim by loudness (native),
  four peak meters (A, master L/R, B; native); a crossfader with both decks
  full at centre (native; equal-power in Electron), master limiter, split-cue
  headphone monitoring (or 4-channel cue on an Aggregate Device). Master volume
  and cue mix live in the VOLUME popover.
- **Decks** — both waveforms stacked on one screen at a shared scale, deck
  cards with a whole-track overview, and per deck a tempo fader, platter,
  PLAY with a CDJ-style CUE (set, return, hold to preview), hot cues and loops.
  Drag around a platter to scrub: 90° moves half a beat, one full turn moves
  two beats. Clockwise moves forward; counterclockwise moves back.
  The center's radial display has two missing marks that follow the track
  position, moving during playback and stopping when paused.
  CUE previews lead into the saved cue on the playing deck's beat, preserving
  its first kick; a lead-in before 0:00 is silent. Hold CUE and slide onto PLAY
  to keep the preview running after release. Pressing PLAY while holding CUE
  does the same.
- **Input tap (experimental)** — reads any audio input's tempo, so a deck can be
  matched to a loopback device. Analysis only; see *Spotify* below.
- **Keyboard** — `?` shows the full list.

## Requirements

- macOS 13+ (developed on macOS 27 / Apple Silicon), Node 22.12+.
- `ffmpeg` on `PATH` is optional: it is only used as a last-resort decoder for
  formats Chromium refuses (e.g. some AIFF/ALAC files).

## Run it

```bash
npm install
npm run dev          # Electron + renderer with hot reload
npm start            # run the production build
npm run build        # typecheck + bundle
npm test             # DSP and reliability/security regression tests
npm run check:runtime # isolated production Electron checks (build + fixtures required)
npm run dist         # unsigned .dmg in release/
```

To check sync through the actual mixer and recorded worklet output, launch
`npm run dev -- --remoteDebuggingPort 9222`, then run
`node scripts/live-eval.mjs scripts/check-sync.js`. It checks starts, SYNC
during playback, tempo changes, CUE, loops, beat jump, seeks and hot cues. It
then freshly analyzes and plays Warehouse Trip against Traffic from
`accuracy/audio/`. The music
files must be present locally. It uses an isolated mixer, restores the saved
SYNC settings and exits nonzero on a failed measurement. Keep the source
unchanged while it runs: hot reload interrupts renderer measurements.

`node scripts/check-cue.mjs` tests actual mouse and touch input in an empty
dev window: repeated CUE taps, sliding onto PLAY, pressing PLAY during a held
CUE, and touch cancellation. It verifies the handoff adds no audio schedule
and that release does not stop the latched track.
It also checks platter calibration at 120/128 BPM and two window sizes,
including touch, direction changes, full turns and a playing SYNC deck.

With fixture WAVs present (`npm run fixtures`), run
`node scripts/live-eval.mjs scripts/check-cue-start.js` to verify that CUE never
skips its saved attack across different tap timings, including at 0:00.

`node scripts/live-eval.mjs scripts/check-loops.js` records uniquely pitched
beats to verify that the selected audio content repeats through playback,
SYNC, tempo changes, resizing and a CUE-to-PLAY start. Identical clicks alone
cannot distinguish a working loop from uninterrupted playback.

With `npm run dev:renderer` running, use
`node_modules/.bin/electron scripts/check-loop-drag.mjs` for isolated native
mouse/touch checks of loop movement, beat snapping, bounds, zoom and SYNC.

Dev without Electron (UI + audio self-test in a plain browser):

```bash
npm run dev:renderer   # http://127.0.0.1:5299
open 'http://127.0.0.1:5299/?selftest=1'
```

## Importing a folder of tracks

Dex plays audio files on your own computer only. Use files you own or have the
right to play. A folder with a `manifest.json` that lists its tracks can be
analysed into the library in one go:

```bash
npm run import:crate -- ~/Music/MyCrate --genre psytrance
```

The import reads only the manifest and the files it lists.

## Verified numbers

`?selftest=1` renders real audio through the actual deck engine and measures it
rather than trusting the scheduler. On an M4 Pro (Chrome/Electron, 48 kHz), all
sixteen checks pass:

| Measurement | Result | Target |
| --- | --- | --- |
| Sync beat alignment, median | 0 ms | < 15 ms |
| Sync beat alignment, worst beat | 0 ms | < 25 ms |
| Synced beat period | 500 ms for 120 BPM against 128 BPM source | ±5 ms |
| Synced late start, median | 0 ms | < 15 ms |
| Synced late start, worst beat | 0 ms | < 25 ms |
| 4-beat loop repeat period | 2000 ms | ±3 ms |
| Loop accent spacing | 2000 ms | ±10 ms |
| Loop self-similarity at the repeat | 0.77 corr | > 0.70 |
| Loop seam discontinuity vs normal slew | 1.04× | < 3× |
| Low EQ kill at 100 Hz | −42.0 dB | < −18 dB |
| Low-kill bleed at 1 kHz | 0.0 dB | ±3 dB |
| High EQ boost at 8 kHz | +5.7 dB | > +4.5 dB |
| Sweep filter low-pass at 8 kHz | −74 dB | < −20 dB |
| Sweep filter high-pass at 100 Hz | −80 dB | < −20 dB |
| Crossfader level at centre | 0.0 dB vs −3.01 | ±0.6 dB |
| Crossfader L/R balance at centre | 0.0 dB | ±0.3 dB |

Beat detection is checked on real WAV files as well as synthetic patterns.
`npm run fixtures` writes four deterministic 24–32 s loops to `fixtures/`, and
the detector returns:

```
deep-122.wav   122.00 BPM   offset 489.9 ms   0.95 confidence
house-124.wav  124.01 BPM   offset 483.0 ms   0.96 confidence
offset-100.wav  99.99 BPM   offset 247.3 ms   0.98 confidence  (true offset 250 ms)
techno-128.wav 128.00 BPM   offset 466.7 ms   0.92 confidence
```

Offsets are reported modulo the beat period, so 483.0 ms at 124 BPM is the same
grid line as 0 ms. Analysis takes 22–116 ms per 24–32 s track in a worker.

## How it fits together

```
src/shared/      pure DSP, no DOM: fft, detector, grid, sync, loop, curves
src/main/        sandboxed Electron shell and validated IPC
  services/       approved audio files, atomic library repository, bounded ffmpeg
src/preload/     contextBridge surface (dex.readFile, pickFiles, …)
src/renderer/
  audio/deck.ts      one deck: stretch worklet transport + EQ + cue routing
  audio/engine.ts    mixer: decks, sync loop, snapshots and lifecycle
  audio/deck-loads.ts latest selection and serialized commit ordering
  audio/work-queue.ts bounded priority queue for decode/analysis
  lib/library-writer.ts coalesced, acknowledged saves
  audio/tap.ts       input tap: capture → rolling window → tempo
  audio/routing.ts   master limiter, cue bus, split/4-channel outputs
  state/library.ts   persistent track metadata and grids (zustand)
  ui/                decks, waveform, knobs, library, tap panel
  selftest/          in-app measurement page (?selftest=1)
```

The deck transport lives on a [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch)
worklet, which owns the decoded buffer, the playback position, native looping
and its own latency compensation. React never drives audio; it reads immutable
snapshots through `useSyncExternalStore` at display rate.

Sync combines a tempo ratio (`masterBPM / deckBPM`, clamped to ±16%) with a
phase snap calculated at the scheduled output time. Starts choose the nearest
matching phase inside the audio file; enabling SYNC during playback jumps
forward to match. A slow proportional trim then absorbs remaining drift.
The transport clock integrates each rate from its scheduled output time, so
changing tempo never applies the new rate to audio that has already elapsed.

Detection is a 11.025 kHz mono STFT → spectral-flux onset envelope →
autocorrelation tempo estimate with a log-Gaussian prior → **global comb fit**
over period and phase. Fitting the constant-tempo grid directly avoids the
classic failure of frame-by-frame trackers locking onto half-beat hats.

## Spotify

Spotify's Web Playback SDK does not expose decoded audio: playback is
DRM-protected and there is no PCM to analyse or mix. Its developer terms also
forbid altering, mixing or analysing Spotify content, and only licensed partners
(djay, Serato, rekordbox) get audio access. There is therefore no supported way
to load a Spotify track into a deck, and this app does not try to.

The **input tap** is a separate, experimental feature. It measures the tempo of
any audio input, such as a microphone or a loopback device, and can match a deck
to it. It only analyses: the incoming audio is never connected to the master or
cue buses, never recorded and never uploaded. Local files remain the only
supported source.

This machine has no audio input devices, so the tap's hardware path could not be
verified here. Its capture → window → detector → readout path was verified in the
app with a synthetic 128 BPM input stream (127.99 BPM at 86% confidence over five
windows).

## UI layout study

The iPad layout work lives beside the app, not inside it:

- [`docs/UI-CAPABILITIES.md`](docs/UI-CAPABILITIES.md) — every capability the
  app has today (read out of the source), mapped feature-by-feature onto the
  Pioneer XDJ-RR, plus a touch-sizing spec for a 1194 × 834 pt screen.
- [`mockup/xdj-mixer-alt.html`](mockup/xdj-mixer-alt.html) — the design
  document: this app was built from it, and new UI is designed in it before the
  native app picks it up. Electron keeps a frozen copy of its styles
  (`src/renderer/console/console.css`), so later mockup changes don't reach
  this app. It is a standalone, dependency-free iPad study
  (1194 × 834) with both decks' waveforms stacked under one shared playhead,
  deck cards with whole-track overviews, and a deck · mixer · deck chassis
  whose centre mixer has TRIM, filter, LEVEL and cut-only HI / MID / LOW
  faders, kills, LINK LOWS and LOW Σ, with demo audio running through an
  LR4 isolator. Open it directly in a browser, then use
  **Function map** to outline and number every control and **Controls** to
  open the inspector: clicking a control, or a row in the list, says what it
  does in the app, whether it is live, partial or planned, its shortcut and
  the file it lives in. **Grid sheet** opens the mockup's beat-grid editor
  over the mixer — waveform, bar numbers, drag to shift and tap-to-set
  downbeat — the same editor that now ships in the app.
- **Notes in the study** — every inspector card has a note field, keyed by
  the control id, and the **Sections** tab holds one note for a whole area:
  the top console, either deck bay, the centre mixer, the bottom rail, the
  library or the beat-grid sheet. Selecting a control in an area also shows
  that area's note on its card, with a jump to the editor. **Notes**
  collects section notes and annotated controls in screen order under one
  whole-set brief; **Copy brief** / **Download .md** turn it into a single
  Markdown handoff, with JSON backup and restore alongside. Notes autosave in
  the browser, so a batch of adjustments can be gathered before any code
  changes. Save the `.md` as `mockup/notes.md` if you want the agent to read
  it from the repo; the static page cannot write files itself.
- [`docs/CONTROL-MAP.md`](docs/CONTROL-MAP.md) — the same list as a document,
  grouped by screen area. Generated from
  [`mockup/controls.json`](mockup/controls.json) with
  `node mockup/build-control-map.mjs`; that command also writes the mockup's
  `controls.data.js` and fails if an id is misspelled on one side only.
- The earlier XDJ layout study (`mockup/xdj-layout.html`, its shot renderer
  and the other agent's last pass) is kept on the `archive/xdj-layout-study`
  branch of the private archive repository, which isn't public.
- `screenshots/` — Dex's own layout drawing and review screenshots.

## Reliability and security

Library imports leave decks untouched; explicit loading requires a paused deck.
Loads preserve the current track while a replacement is prepared, and the latest
selection wins. Saves are ordered and atomic with a previous-revision backup;
`NOT SAVED · RETRY` remains visible on failure. Closing waits for pending saves.
The Electron renderer is sandboxed with a production CSP and approved-file access.

Regressions for the 30 October review run in `npm run check:runtime` and
`node scripts/review-project.mjs`. Full-track
PCM decoding still creates substantial temporary memory use. The 512 MiB queue
budget is not a total process-memory limit.

## Known limits

- No MIDI, no recording, no effects beyond the EQ and sweep filter, no
  streaming-service integration.
- Tempo range is ±16%; beyond that the stretch artefacts stop being DJ-grade.
- Beat grids are constant-tempo. Live drummers and tempo-mapped tracks need the
  grid nudge, and very loose material will score low confidence.
- Beat grids assume 4/4. The bar lines, the four-bar editor window and SET
  DOWNBEAT all treat a bar as four beats; 3/4 and 6/8 would need a
  time-signature field.
- Split cue folds the master to mono; the 4-channel mode needs hardware (or an
  Aggregate Device) that exposes four channels.
- The build is unsigned (`identity: null`), so macOS will warn on first launch.

## Licence

Dex is free software under the GNU General Public License, version 3 (`LICENSE`). Bundled
third-party code keeps its own licence: see `native/Sources/CDexEngine/vendor/README.md` and the
licence files beside each vendored library.
