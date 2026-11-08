# Dex — capability inventory & XDJ-RR layout mapping

Everything below was read out of the source, not from the README. Status codes:

| Code | Meaning |
| --- | --- |
| **LIVE** | Wired to the audio engine or the UI today, reachable by a user |
| **PARTIAL** | The engine has it, but the UI exposes only part of it |
| **MODULE** | Implemented and unit-tested in `src/shared/`, but nothing in the app calls it yet |
| **NONE** | Not built. The XDJ-RR has it; Dex does not |

---

## 1. Track sources and the library — LIVE

| Capability | Where | Notes |
| --- | --- | --- |
| Load audio files | `state/library.ts` → `addFiles` | mp3, flac, wav, aiff, aif, m4a, aac, ogg, opus |
| Load a whole folder | `addFolder` → recursive scan, 3000 files max | Sorted by path |
| Drag & drop onto a deck | `DeckPanel` `onDrop` | Dropped file loads onto the deck it was dropped on |
| Persistent library | `main/index.ts` → `library.json` in `userData` | Browser fallback: `localStorage` |
| Per-track metadata stored | `shared/types.ts` `TrackMeta` | name, path, duration, bpm, offsetMs, confidence, waveform peaks, hot cues, analysedAt |
| Optional external fields | `TrackMeta` | key, camelot, keyConfidence, lufs, gainDb, peakToLoudnessDb, source, sourceUrl, isrc, spotifyId, qualityGrade — written by the import manifest, read and displayed by Dex |
| Beat detection on ingest | `audio/analysis.worker.ts` | Spectral-flux onsets → BPM, downbeat offset, confidence. 22–116 ms per 24–32 s track, off the UI thread |
| Waveform peaks on ingest | same worker | Rendered by `ui/Waveform.tsx` |
| Re-analyse one track | Library row MORE, asks twice | Re-runs detection and pushes the new grid to the deck if it is loaded |
| Remove a track | Library row MORE, asks twice | Refused while a deck holds it |
| Search | Library sheet | Name substring, case-insensitive |
| Load to deck A / B | Tap a row to select it, then tap the deck's title in the library's deck panel (or drag the row onto it) | A playing deck refuses the load. Rows show which deck a track is on |
| Playlists | Library's left column (`shared/playlist.ts`, `LibraryDoc.playlists`) | Create with `+`, double-click to rename, `✕` then `Delete?` to delete. Add tracks by dragging a row onto a playlist or from a row's `+` menu; `−` takes a track out of the playlist being viewed. Playlists keep their own order and are saved with the library |
| Hot-cue memory | `TrackMeta.hotCues` → `applyHotCues` | Eight positions per track, saved in the library entry and restored when the track is loaded; four-slot entries load into slots 1–4 |
| Missing-file detection | `markMissing` | Row flagged "file missing", load is blocked |
| Last-resort decode | `main/index.ts` `transcodeToWav` | ffmpeg, only for formats Chromium refuses. Desktop only |

**Key detection — LIVE.** `src/shared/key.ts` (chroma extraction, Sha'ath profile correlation, Camelot mapping) runs in the analysis worker when a track is added or re-analysed, and writes `key`, `camelot` and `keyConfidence`. A track with no pitched material keeps `keyConfidence: 0` and no code. Libraries from before this show **Find keys (n)** in the library header, which re-analyses only those tracks. Confidence is in each badge's tooltip; it does not separate right from wrong keys cleanly (a drum-only test tone scored 0.30, a correct C major chord 0.38), so nothing is hidden on it. `src/shared/camelot.ts` holds the wheel colours, order and compatible keys. `src/shared/loudness.ts` (BS.1770 LUFS, peak-to-loudness, auto-gain) is still a MODULE: the app never calls it.

---

## 2. Deck transport — LIVE

| Capability | Notes |
| --- | --- |
| Play / pause per deck | `engine.togglePlay`; keys `1` / `2` / `Space` |
| Stop both decks | `Esc` |
| Seek | Waveform tap/drag, platter drag-scrub, `engine.seek` |
| Playhead | Fixed at 50% of the waveform; playback and scrubbing scroll the peaks underneath it |
| Waveform zoom | Wheel to zoom around the fixed playhead, double-click to reset |
| Elapsed / total time | Header clock, `formatTime` |
| Auto-pause at end of track | Checked in the 250 ms engine tick |
| Loop stepper | `‹ size ›` beside play (`ui/LoopStepper.tsx`): 1, 2, 4, 8, 16, 32, 64 beats. The readout starts a loop quantised to the grid, or leaves it on its end boundary |
| Halve / double a loop | The stepper arrows; a running loop takes the new size straight away |
| Loop roll | `ROLL` — momentary at the stepper size, drops back where the track would have been |
| Hot cues ×8 | `CUES` key in the transport row opens a popover over the deck face (`ui/HotCuePanel.tsx`), 4 × 2 pads; the key's icon lights the set slots in their colours. Closes from the key, ✕, Escape or a tap outside. An empty pad captures the playhead; a set pad jumps back to it. DELETE, Shift-click or right-click clears. Saved with the track and restored on load |
| Hot-cue markers | Numbered lines in each slot's colour, scrolling with the peaks under the fixed playhead |
| Grid: tap tempo | Grid sheet, 3+ taps, 60–200 BPM |
| Grid: ±0.1 BPM | `−0.1` / `+0.1` |
| Grid: ±1 ms nudge | `◀ 1 ms` / `1 ms ▶`; `←` / `→` keys (±10 ms with Shift); folds at the bar so the downbeat does not rotate |
| Grid: ×2 / ÷2 | Double / half-time interpretation |
| Grid: waveform drag | Grid sheet; drag the waveform under still lines, raw while dragging and folded at the bar on release. Zoom − + from 8 s to 250 ms, ◀ BEAT ▶ and a track strip move the window |
| Grid: set downbeat | Arm `SET DOWNBEAT`, then tap the first beat of a bar |
| Grid edits persist | Written back to the library entry |
| Tempo ±16 % | Slider 0.84–1.16, `[` / `]` nudge 0.1 %, double-click resets |
| Key lock (on by default) | Pitch preserved when the tempo changes |
| Vinyl mode (key lock off) | Pitch follows the tempo |
| SYNC | Matches tempo *and* beat phase to the master deck over 2.5 beats, then trims ±0.25 % drift forever |
| MASTER deck | Whichever deck is master defines the tempo; `S` / `Shift+S` pick the direction |
| Sync a paused deck | Starts it on the master's beat instead of wherever it stopped |
| CUE per deck | Pre-listen into the cue bus; CUE button beside PLAY or `M` |
| Focus | Tapping a deck focuses it (keyboard shortcuts follow the focus) |

---

## 3. Tone and mixing — LIVE

| Capability | Notes |
| --- | --- |
| 3-band EQ per deck | Isolator: Linkwitz-Riley 24 dB/oct crossovers at 220 Hz and 3.5 kHz, bands summed flat at unity (`src/shared/isolator.ts`). Cut-only faders in the centre mixer on one law (`src/shared/mixer.ts`): unity at the top, −3 / −6 / −12 / −24 / −48 dB marks, silence at the foot |
| Kills | `KILL` pad under each band: tap latches, hold is momentary. The fader keeps its position, so releasing restores the exact level |
| Channel fader (LEVEL) | Per deck, same law as the bands, outermost column of the mixer |
| TRIM | Per deck input gain, ±12 dB, before the EQ (so headphone cue hears it). Chip above LEVEL opens a popover with a fader and Reset |
| LINK LOWS | Couples the two LOW faders: drag either and the other moves the same distance the opposite way, the bass swap in one gesture |
| LOW Σ | Both decks' low band summed as if the kicks were in phase, after trim, LEVEL and crossfader. 0 dB = one full low alone; amber from +1 dB, red from +3 dB |
| Sweep filter per deck | Horizontal fader above each channel. Centre transparent, left = low-pass to 120 Hz, right = high-pass to 9 kHz, rising resonance; the label reads `LP 1.2k` / `HP 2.2k`. Sits after the EQ |
| Crossfader | Equal-power, A … B, at the foot of the mixer, double-click to centre |
| Faders | Relative drag (the cap never jumps), slide sideways off the fader for fine moves (¼, then ⅒, shown in the readout), double-click to reset, arrow keys nudge. Several can be ridden at once |
| Master volume | VOLUME popover in the header, 0–1.2, default 0.85 |
| Master limiter | `DynamicsCompressor`, −3 dB threshold, 20:1 |
| Master meter | RMS in dBFS, polled at 60 ms |
| CUE MIX | VOLUME popover: blends the cue bus against the master in the headphones |
| SPLIT CUE / 4-CH CUE | Split = master left ear, cue right ear. 4-channel = master on 1/2, cue on 3/4 of an Aggregate Device. Auto-falls back to split when the hardware cannot take 4 channels |
| Channel CUE (headphones) | Mixer key under LEVEL, or `M`; also a headphone key on each deck in the library panel |
| Deck CUE (CDJ cue point) | Beside PLAY. Paused: sets the cue point. Playing: returns to it and stops. Held while paused on it: plays until released; PLAY while held keeps playing. Auto-cue on load is the first downbeat. Red `CUE` marker on the waveforms. Key `C` |

**Not built (NONE)** — all of these exist on the XDJ-RR:

- TRIM **AUTO** (match loudness): built in the native app (`native/Sources/DexCore/Loudness.swift`, measured at import, 7 November 2026). Electron's `src/shared/loudness.ts` is still unused, as Electron is frozen.
- The mockup's **band sheet** (tap a band readout for a long fader covering both decks).
- Per-deck **level meter** (Dex meters the master only).
- **Headphone level** knob (Dex has the cue *mix* but no cue/headphone volume).
- **Beat FX** (reverb, echo, flanger, noise, delay).
- **Sound colour FX** beyond the sweep filter (pitch, noise, delay).
- **Slip loop** as a separate mode (Dex's ROLL is the closest thing).
- **Beat jump**, **track search / browse** inside a deck.
- **Master tempo** (a global tempo applied to both decks).
- **Mic input** (talk-over), **master recording**, **MIDI**, **on-air/record** state.
- **Auto-Cue / time-mode** behaviour.

---

## 4. Input tap (experimental) — LIVE

| Capability | Notes |
| --- | --- |
| Pick an audio input | Loopback devices (BlackHole, Loopback, VB-Cable) are detected and listed first |
| Read its tempo | 8 s rolling window, median-filtered, with a confidence % and window count |
| Input level meter | dB readout |
| Match deck A / B | Sets the deck's tempo to the tapped BPM, showing the % it would run at |
| Dev-only test signal | Synthetic 128 BPM stream, for verifying the path without hardware |

Analysis only: the captured audio never reaches the master or cue bus, is never recorded and never uploaded.

---

## 5. Shells, sheets and screens — LIVE

| Screen | Contents |
| --- | --- |
| Top bar | Brand, `music` / `mixer` pill, analysis progress, sample rate, SPLIT CUE / 4-CH CUE toggle, Tap, `?` |
| Screen | Both decks' waveforms stacked across the full width at one shared scale in seconds, under one fixed playhead; `+` / `−` zoom keys with the span readout. Scroll zooms both lanes, drag scrubs |
| Deck cards | Letter, track name (opens the library), REMAIN / BPM / TEMPO, `+` load, Camelot key, grid %, MASTER / SYNC / vinyl / loop tags, and the whole-track overview with the screen's window boxed in orange |
| Deck bays | SYNC / MASTER / KEY / GRID keys, the tempo fader on the outside edge (down = faster, ±16 %), the platter, and PLAY · CUE, the CUES popover and the loop stepper + ROLL along the bottom |
| Centre mixer | MUSIC key (library), per channel TRIM and FILTER, LEVEL · HI · MID · LOW faders with readouts, channel CUE and KILL pads, master meter, LOW Σ meter, LINK LOWS, crossfader |
| Deck face: platter | Rotating record at 33⅓ rpm, drag to scrub, generated centre label |
| Deck face: EQ overlay | Four tall faders — FILTER, LOW, MID, HIGH — with a centre detent, click-to-jump, drag, arrow keys, double-click to centre |
| Library sheet | Slides up over the decks and footer. A deck panel stays on top: per deck a load button where the title sits, BPM, PLAY, CUE and the loop stepper, with time remaining and the crossfader in the middle. A playlist column on the left (All tracks, then playlists). Each deck shows its Camelot key. Rows: name, key name, Camelot badge in wheel colours, on-deck badge, BPM, duration, grid %, `+` playlist menu, re-analyse, remove. Tap any key (row or deck) to filter to it and its harmonic matches (±1 on the ring and the relative major/minor), with `only` / `+ compatible` and Clear. Tap a column heading to sort, again to reverse. Search matches name, key and BPM; a Camelot code like `4a` matches that key exactly |
| Grid sheet | BPM / confidence / offset readout; four-bar waveform with beat and bar lines and a live playhead; drag to shift; `SET DOWNBEAT`; TAP, ±0.1, ±1 ms, ÷2, ×2 |
| Help sheet | Keyboard shortcuts and pointer hints |
| Toasts | Analysis errors, auto-dismiss after 7 s |
| Banners | Empty-state hint, audio-engine start-up failure |
| Self-test | `?selftest=1` — 16 measured checks (sync, loops, EQ, filter, crossfader) |

The grid editor assumes a four-beat bar (4/4): the bar lines, the four-bar window and `SET DOWNBEAT` all derive from `BEATS_PER_BAR`.

**Keyboard map:** `1`/`2` play/pause · `Space` play/pause focused · `S` sync other to focused · `Shift+S` sync focused to other · `L` start / leave a loop at the stepper size · `Shift+L` halve loop · `M` cue · `[`/`]` tempo ∓0.1 % · `←`/`→` grid nudge ∓1 ms (Shift = 10 ms) · `Esc` stop both / close sheet · `?` help.

---

## 6. XDJ-RR → Dex mapping

### Deck sections (left and right, mirrored)

| XDJ-RR | Dex | Status |
| --- | --- | --- |
| Jog wheel | Platter: rotates, drag to scrub | **LIVE** (no slip/jog mode) |
| JOG MODE (VINYL) | KEY toggle (key lock / vinyl pitch) | **PARTIAL** |
| BEAT SYNC (SYNC / MASTER) | SYNC + MASTER buttons | **LIVE** |
| TEMPO slider ±6/10/16 %, WIDE | Tempo slider ±16 % | **LIVE** (one range) |
| MASTER TEMPO | — | **NONE** |
| PLAY / PAUSE, CUE | PLAY and CUE side by side in the transport row | **LIVE** |
| SHIFT | — | **NONE** (held ROLL is the closest) |
| HOT CUE ×4, BEAT LOOP, SLIP LOOP, BEAT JUMP ×2 rows | Four hot-cue pads, loop pads ½–16, ½×, 2×, EXIT, ROLL | **PARTIAL** — hot cues are live; no slip loop or beat jump |
| IN / OUT / RELOOP / EXIT | Loop length pads + EXIT (exit on the boundary) | **PARTIAL** — no IN/OUT points, no re-loop |
| CUE / LOOP CALL, DELETE, MEMORY | — | **NONE** |
| TRACK SEARCH, SEARCH (nudge) | Grid nudge ±1 ms, tempo ±0.1 % | **PARTIAL** — no in-deck browse |
| TIME MODE / AUTO CUE | — | **NONE** |
| QUANTIZE | Loops are quantised to the grid | **PARTIAL** |
| USB 1 / USB 2, MIDI | Add files / Add folder | **PARTIAL** (a different source) |
| Mic: TALK ON/OVER, LEVEL, LOW/HI | — | **NONE** |
| MASTER REC, TRACK MARK | — | **NONE** |

### Centre mixer

| XDJ-RR | Dex | Status |
| --- | --- | --- |
| TRIM per channel | — | **NONE** |
| HI / MID / LOW knobs per channel (with kill) | LOW / MID / HIGH faders per deck, kill at full-left | **LIVE** |
| COLOR knob (LOW→HI) | Sweep FILTER fader | **PARTIAL** — no separate colour control |
| Channel level faders ×2 | — | **NONE** |
| Per-channel LED meters, MASTER CLIP | Single master meter | **PARTIAL** |
| MASTER LEVEL | MASTER knob | **LIVE** |
| Crossfader with graduated scale | Crossfader, double-click to centre | **LIVE** (no cut-in points) |
| HEADPHONES MIXING: CUE / MASTER knobs | CUE MIX knob + SPLIT CUE / 4-CH toggle | **LIVE** |
| Headphone LEVEL | — | **NONE** |
| Cue buttons 1 / 2 | Per-deck CUE beside PLAY | **LIVE** |
| BEAT FX: AUTO, TAP, REVERB, ECHO, FLANGER | — | **NONE** |
| SOUND COLOR FX: D.ECHO, PITCH, NOISE, FILTER | Sweep filter only | **PARTIAL** |
| AUX (LINE / PORTABLE) | — | **NONE** |

### Top console

| XDJ-RR | Dex | Status |
| --- | --- | --- |
| Dual waveform display | Two canvas waveforms, one per deck, at the top of each column, each with a fixed 50% playhead. The mockup moves both into one LED screen with a single shared line | **LIVE** |
| Track info (name, deck, remain, quantize) | Deck header: name, elapsed / total, tag row. The mockup adds a deck card at each end of the screen: name, REMAIN, BPM, TEMPO, whole-track waveform | **LIVE** |
| BEAT FX panel, 124.0 BPM, 4 BEAT | Master BPM card in the centre hub. The mockup keeps the BEAT FX row in the console flank, where the XDJ-RR has it | **LIVE** |
| Browse knob, LOAD 1/2 | Library: select a row, tap the deck's title | **LIVE** |
| BROWSE, TAG LIST, INFO, MENU | Library sheet, grid sheet, help sheet | **PARTIAL** — no tag list |
| rekordbox / USB | Local files and folders only | **NONE** (by design) |

### Dex features with no XDJ-RR equivalent

- **Input tap** — read the tempo of any external input and match a deck to it.
- **Grid editor** — waveform drag, tap-to-set downbeat, tap tempo, ±0.1 BPM, ±1 ms nudge, ×2/÷2, saved to the library.
- **Library confidence %** — how much the detector trusts each grid.
- **Per-deck key lock** as a first-class toggle, and key / Camelot in the library.
- **Split / 4-channel cue routing** as an explicit mode switch.
- **In-app self-test** that measures the claims above.

---

## 7. Touch sizing spec for iPad

Target: iPad Pro 11" landscape, 1194 × 834 CSS pt. Keep 1024 × 768 (iPad 10.9" landscape, scaled) usable.

*Update 31 October 2026:* the app's stage is that canvas minus the 10 pt
bezel (1174 × 814), and taller screens up to 4:3 give their spare height to
the zoom lanes instead of black bars. See "elastic height" in
[native/README](../native/README.md#agreed-scope).

Apple's minimum is 44 × 44 pt. For a surface you use with sweaty hands, mid-performance, use these:

| Control | Size | Spacing |
| --- | --- | --- |
| PLAY / PAUSE, CUE | 68 × 68 pt | 12 pt |
| Performance pad | 64 × 64 pt | 10 pt |
| Rotary knob (visual) | 52 pt, **hit area 64 pt** | 12 pt |
| EQ / filter fader | rail travel ≥ 200 pt, thumb 48 × 32 pt, **hit area 64 pt wide** | 10 pt |
| Channel fader | rail travel ≥ 240 pt | — |
| Crossfader | travel ≥ 260 pt, thumb 64 × 44 pt | — |
| Tempo slider | travel ≥ 220 pt, thumb 44 × 44 pt | — |
| Jog / platter | ≥ 220 pt diameter | 24 pt from the nearest control |
| Waveform strip | ≥ 96 pt tall | 12 pt |
| Sheet / overlay buttons | 48 pt tall | 12 pt |
| Text | 15 pt minimum, 20 pt for readouts | — |

Other rules that matter more than the numbers:

- **No control inside a 24 pt radius of another.** Fingers overlap; the XDJ-RR's 8 mm knobs and 4 mm buttons are hardware-sized, not finger-sized.
- **Every slider needs a big invisible hit area.** The visible rail can be 12 pt wide; the touch target should be the full 64 pt column.
- **Knobs need a vertical drag with a fine mode.** A 150 px drag for the full range is right; add a double-tap to recentre, which Dex already has.
- **Never put a destructive control next to a transport control.** XDJ-RR separates DELETE from PLAY with a physical gap — keep that.
- **Two-handed use**: primary (PLAY, CUE, crossfader, tempo) inside a comfortable thumb arc; secondary (SYNC, GRID, library) reachable but not accidental.
- **Gestures that conflict**: the waveform already uses drag-to-scrub and wheel-to-zoom. On touch, replace the wheel zoom with pinch, and keep double-tap-to-reset.
- **Platter drag vs. deck-area drag**: the platter must capture its own pointer (it does), or a thumb resting on the deck will scrub the track.
- **The EQ overlay should replace the platter, not sit on top of it** — on a 11" screen a translucent overlay over a rotating record is unreadable, and the faders need the full column height.

---

## 8. What a layout has to contain

A checklist to mark off as you design:

1. Two deck columns, each with: track identity, time, waveform, a face (platter or EQ), a transport strip, a pad row.
2. A centre strip: master BPM, master meter, crossfader, master level, cue mix, the output-mode switch.
3. Per-deck tone: FILTER, LOW, MID, HIGH, reachable as big faders.
4. Per-deck transport: play, cue, tempo, sync, master, key lock, grid.
5. Loops: a `‹ size ›` stepper (1–64 beats), start / leave, roll. Hot cues: eight recallable points with per-slot colours, matching markers on the waveform.
6. A library view: search, add files, add folder, load to either deck, per-track BPM / key / duration / confidence, re-analyse, remove.
7. A grid editor: waveform drag, tap-to-set downbeat, tap tempo, ±0.1 BPM, ±1 ms, ×2 / ÷2.
8. An input-tap view: device picker, BPM readout, level, match deck A/B.
9. Global: sample rate, output mode, help, errors, analysis progress.

---

## 9. The layout mockup

`mockup/xdj-layout.html` is a standalone, dependency-free page that draws the XDJ-RR chassis at exactly
1194 × 834 pt and toggles between two plans:

- **Dex has today** — only controls the engine actually has, in the arrangement the current app uses.
- **Full XDJ-RR** — the target layout, with everything Dex lacks drawn as a dashed **planned** block.

Study controls in the top bar: plan toggle, deck A's EQ overlay, a 64 pt touch-target overlay, the library sheet,
a beat-grid sheet (deck A or B, opened from either GRID button) with the visual grid editor the app now ships —waveform, bar numbers, drag to shift and tap-to-set the downbeat — a function map that outlines and numbers every
control, and a control inspector with **Controls**, **Sections** and **Notes** views. The inspector reads
`mockup/controls.json` — one entry per function with its status, description, shortcut and source — and the
same data is written to [`CONTROL-MAP.md`](CONTROL-MAP.md) by `node mockup/build-control-map.mjs`.

Every inspector card has a **note field**, keyed by the control id. **Sections** adds one note per area — the top
console, deck A, the centre mixer, deck B, the bottom rail, the library and the beat-grid sheet — for instructions
that apply to a whole region rather than one control. Selecting a control inside an annotated area repeats
that area note on its inspector card, with a shortcut back to the section editor. The **Notes** tab collects
section notes and annotated controls in screen order under a whole-set brief and exports one Markdown change
brief (copy or download), with JSON backup and restore. Notes autosave in the browser, so a batch of
adjustments can be gathered before any code changes; the export is deliberately the handoff, because a static
page cannot write into the repo. Save the brief as `mockup/notes.md` or paste it into the request. The brief
carries the section notes before the control notes, and its file summary includes the section sources, which is
the quickest view of which changes share code.
`mockup/shoot.js` renders every state offscreen with Electron and writes PNGs to `mockup/shots/`.

### The top console is one screen, not two strips

Both decks' waveforms leave the deck columns and move into a single LED screen across the top of both bays,
after the Pioneer console:

- **Stacked zoom window** — deck A over deck B, each 595 × 61 pt, with one white playhead fixed at 50%
  through both lanes, a red cue marker per lane and a header pill (`DECK A · 133.0 BPM · PLAYING`). Drag
  either lane to scroll its waveform and cue under the line; the whole-track bracket follows. The zoom control
  (`−`, `ZOOM ×4`, `+`, `GRID`) sits on the screen itself, over the top-right corner, because it is a property
  of the screen.
- **A deck card at each end** — deck A at the left end, deck B at the right end. Each card carries the track
  name, REMAIN / BPM / TEMPO, and the **entire waveform of the track** with the zoomed region bracketed in
  amber. That is the sub-screen from the Pioneer: the whole track at a glance, plus the window you are
  actually looking at.

The screen is 613 pt wide — 77 % of the 798 pt the two deck bays span — and 250 pt tall.

### What the render measured (full XDJ-RR plan, 1194 × 834)

Copying the XDJ-RR one-to-one does not survive the iPad's touch rules. Measured in the rendered page:

| Element | XDJ-RR at this size | Touch target | Verdict |
| --- | --- | --- | --- |
| Stacked zoom strip | 61 pt tall | 96 pt | short |
| Full-track overview | 43 pt tall | 96 pt | short |
| Jog wheel | 124 pt diameter | 220 pt | well short |
| Performance pad | 44 pt | 64 pt | short |
| Ghost button row | 34 pt | 44 pt | short |
| Play / CUE | 56 pt | 68 pt | short |
| Channel fader travel | 196 pt (thumb 48 × 32 pt) | 240 pt | short |
| Centre mixer column | 320 pt wide | — | fits 2 channels; the XDJ's AUX + CH1 + CH2 + FX row does not |

The hardware is dense because it is 8 mm knobs and 4 mm buttons operated with two hands on a desk. On an 11" screen
the same arrangement has to be re-proportioned, not merely resized.

### Four resolutions used in the mockup

1. **One screen instead of two strips.** Both waveforms move out of the deck columns into a single wide LED
   console, stacked, with the whole-track overview and the track info at each end. Two 96 pt strips in two
   columns become one 61 pt strip in each half of one screen that both decks share, which is what the Pioneer
   does and what a DJ actually looks at while mixing.
2. **The XDJ-RR's arrangement, Dex's controls.** The three-column chassis, the console strip, the mixer in the middle
   and the pads under each deck are kept. The controls inside them are the ones the engine has, plus dashed placeholders
   for the rest, so the gap is visible rather than implied.
3. **Sliders, never knobs.** Every rotary control on the XDJ-RR (TRIM, HI/MID/LOW, COLOR, MASTER LEVEL, browse knob,
   headphone level) becomes a fader or a slider in the mockup. The per-deck tone stack is the four tall faders of the
   EQ overlay — FILTER, LOW, MID, HIGH — which is also what the app already has.
4. **The tone overlay replaces the platter.** A translucent overlay on a rotating record is unreadable at this size and
   the faders need the full column height, so the deck face swaps between the two.

### Still undecided (for the layout to settle)

- Where the crossfader lives. It sits at the foot of the mixer column, XDJ-style, and that is what costs the
  channel faders their last 44 pt of travel: 196 pt against the 240 pt the spec asks for. Moving it into the
  bottom rail would meet the spec, but separates the control from the two channels it crossfades.
- Whether the deck bay keeps Dex's 10 loop pads (½–16, ½×, 2×, EXIT, ROLL) or gives the space to the XDJ's 8 pads
  (hot cue / beat loop / slip loop / beat jump). The two sets need different hardware behaviour, not just labels.
- Whether the XDJ-RR's per-channel faders are worth building. They are the single biggest missing feature: without them
  the centre mixer cannot copy the XDJ-RR's shape, because a mixer column with no channel faders is mostly empty.
  They are drawn as *planned* blocks in both plans for that reason.
