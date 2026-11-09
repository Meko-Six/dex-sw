# Dex control map

Every control drawn in [`mockup/xdj-mixer-alt.html`](../mockup/xdj-mixer-alt.html), in screen order, with what it
actually does in Dex today. Generated from [`mockup/controls.json`](../mockup/controls.json) by
`node mockup/build-control-map.mjs` — edit the JSON, not this file.

| Status | Meaning |
| --- | --- |
| **LIVE** | Has a working control in the app. |
| **PARTIAL** | The app has part of it, or does it with a different gesture or name. |
| **PLANNED** | Drawn for the layout study. Nothing behind it in Dex. |

**100 controls** — 83 live, 5 partial, 12 planned.

## Using the mockup

Open `mockup/xdj-mixer-alt.html` in a browser. Two switches in the top bar drive this map:

- **Function map** — outlines every control and numbers it, matching the `#` column below.
- **Controls** — opens the side panel. Click any control in the mockup, or any row in the panel, to read
  what it does, its shortcut, and the file it lives in.

Numbers are stable: they come from the order of `controls.json`, not from the plan being viewed.
Mirrored controls (deck A and deck B) share one number and highlight together.

## Top console

The library / tap / help cluster, the LED screen, and the output flank.

| # | Control | Status | What it does in Dex | Key | Source |
| --- | --- | --- | --- | --- | --- |
| 1 | **music / mixer pill (library)** | LIVE | MUSIC key at the top of the mixer. Opens the library: it slides up under the header with a deck panel on top (tap-to-load titles, PLAY · CUE, headphones, loop, crossfader). Tapping a deck's title on its card also opens it. | `Esc` | `src/renderer/ui/Mixer.tsx` |
| 2 | **3BAND frequency waveforms** | LIVE | Selects overlapping blue LOW, orange MID and white HIGH waveforms on both scrolling lanes and whole-track overviews. Default view. Uses source audio before EQ and trim, with equal brightness before and after the playhead. Display choice is saved. | — | `src/renderer/console/Band.tsx` |
| 3 | **energy waveform colors** | LIVE | Colors both scrolling lanes and whole-track overviews by estimated musical intensity, blue through cyan and amber to red, on the same scale for both decks. The lane label shows current energy from 0–100. Click again or select 3BAND for frequency bands. Brightness is equal throughout the track. The choice is saved. Older tracks are analyzed in the background on load. | — | `src/renderer/console/Band.tsx` |
| 4 | **tap** | LIVE | Opens the experimental input tap: pick an audio input (loopback devices are listed first), read its tempo and confidence, and match deck A or B to it. Analysis only — the captured audio never reaches the master or cue bus. | — | `src/renderer/ui/SystemTap.tsx` |
| 5 | **?** | LIVE | Opens the keyboard-shortcut sheet, which also explains the pointer gestures on the waveform, platter and faders. | `? or /` | `src/renderer/App.tsx` |
| 6 | **(i) · help** | LIVE | The round (i) key beside DONE or CLOSE on the beat grid, TAP, TRIM, EQ band, VOLUME and library opens that topic's instructions in a modal over everything: one row per control, a term and a sentence. Instructions are never on screen otherwise. CLOSE, a tap outside or Esc puts it away, before the sheet under it. | `Esc closes` | `src/renderer/console/Help.tsx` |
| 7 | **+ · ×4 · − (zoom stack)** | PARTIAL | Mockup proposal: zoom in, a numeric zoom readout and zoom out, stacked down the right edge of the screen beside both lanes. Dex zooms the waveform with a wheel or trackpad gesture and has no on-screen zoom keys yet. | — | `src/renderer/ui/Waveform.tsx` |
| 8 | **GRID (on the screen)** | LIVE | Opens the beat-grid editor for the focused deck: tap tempo, ±0.1 BPM, ±1 ms nudge, ÷2 and ×2. Every edit is written back to the library entry. | — | `src/renderer/ui/GridSheet.tsx` |
| 9 | **stacked zoom waveform** | LIVE | Both decks' waveforms, full width, one over the other, under one fixed white playhead at 50%. Drag either lane to scroll its waveform; the cue marker moves with it. In the native app a flick carries on after release, the same track distance at any zoom, and a touch catches it. | — | `src/renderer/ui/Waveform.tsx` |
| 10 | **whole-track overview** | LIVE | The whole track as a waveform under each deck's readouts, with numbered colour badges for hot cues. A click or drag jumps to the bar under the pointer: a playing deck keeps its place in the bar (in phase), a paused deck lands on the nearest bar line. A running loop moves along. Without a grid it seeks to the exact spot. | — | `src/renderer/console/Band.tsx` |
| 11 | **TIME · REMAIN · TEMPO · KEY · BPM** | LIVE | Each deck's card under the screen. TIME stacks elapsed time above the track length. REMAIN and TEMPO have their own columns beside KEY and the played BPM. Tap the cover to load. | — | `native/Sources/DexConsole/TrackWindows.swift` |
| 12 | **SPLIT CUE / 4-CH CUE** | LIVE | Header button. Switches headphone routing: split puts the master in the left ear and the cue bus in the right; 4-channel sends the cue bus to outputs 3/4 of an Aggregate Device. | — | `src/renderer/audio/routing.ts` |
| 13 | **48.0 kHz** | LIVE | Sample rate of the running AudioContext. Appears once the engine has started. | — | `src/renderer/App.tsx` |
| 14 | **ANALYSING · IMPORTING status pill** | LIVE | The header's progress pill while the library works: a spinner, ANALYSING 3 / 12 or IMPORTING or FINDING KEYS 3 / 4, the track it is on, and a hairline that fills as it works through the list. It is absent when nothing is running. | — | `native/Sources/DexConsole/Head.swift` |
| 15 | **SYNC · MASTER · playing chips** | LIVE | Status only, no click, in the header: which deck is synced, which deck is the tempo master, and whether either deck is running. | — | `src/renderer/App.tsx` |
| 16 | **CAN'T LOAD alert** | LIVE | A red bar under the header when a track cannot be loaded, naming the file and saying why — for example that it isn't on disk any more — with a ✕ that dismisses it. It also clears itself after a few seconds. | — | `native/Sources/DexConsole/Pops.swift` |
| 17 | **BEAT FX row** | PLANNED | AUTO, TAP, REVERB, ECHO, FLANGER from the XDJ-RR. Nothing implemented: Dex has no effects beyond the three EQ bands and the sweep filter, and no FX send bus. | — | `src/renderer/audio/eq.ts` |
| 18 | **BROWSE** | PLANNED | rekordbox-style on-device browser. Dex has no in-deck browse; the library sheet with its A / B load buttons is the equivalent. | — | — |
| 19 | **MENU** | PLANNED | Hardware utility menu (output routing, MIDI, preferences). Dex exposes the output mode as a single top-bar toggle and has no menu. | — | — |
| 92 | **VOLUME** | LIVE | Header button: a popover with the MASTER volume and CUE MIX faders. | — | `src/renderer/App.tsx` |

## Deck bay

One per side; everything here is mirrored on deck A and deck B.

| # | Control | Status | What it does in Dex | Key | Source |
| --- | --- | --- | --- | --- | --- |
| 20 | **+ (load a track)** | LIVE | The + on each deck card. Opens a file picker and adds the chosen files to the library, loading the last one onto this deck. Dropping files on a deck does the same. | — | `src/renderer/ui/Console.tsx` |
| 21 | **☰ (library)** | LIVE | Opens the library sheet over the mixer, without changing the loaded track. | — | `src/renderer/ui/DeckPanel.tsx` |
| 22 | **deck letter (focus)** | LIVE | The deck letter on each info card. Tapping anywhere on a deck makes it the focused deck, and the keyboard shortcuts follow the focus: Space, M, L, [ and ] act on it. | — | `src/renderer/ui/DeckPanel.tsx` |
| 23 | **platter** | LIVE | Drag from the exposed record to scrub precisely: 90° moves half a beat, one full turn moves two beats. Touch reveals the tucked rim while the turn is held; the faders stay reachable. Clockwise moves forward; counterclockwise moves back. Sensitivity follows BPM and stays the same across track lengths and window sizes. The centre ignores small pointer movements. Manual platter movement retains fractional beats while SYNC is armed. The gap in the centre lights follows playback, CUE and jog position and freezes when paused. | — | `src/renderer/console/Chassis.tsx` |
| 24 | **CUE (on the platter)** | LIVE | Pre-listens this deck on the cue bus without touching the master output. It is a toggle, not a momentary button, and it is the same state as the channel CUE in the centre mixer. | `M` | `src/renderer/ui/Platter.tsx` |
| 25 | **EQ / PLATTER** | LIVE | Swaps the deck face between the spinning platter and the four tall tone faders. In the app the EQ key lives in the centre hub; the mockup moves it onto the face next to the control it switches. | — | `src/renderer/App.tsx` |
| 26 | **tag row** | LIVE | On each deck card, beside the overview: Camelot key, grid confidence, master or sync, vinyl and active loop length. All derived from the engine snapshot and the library. | — | `src/renderer/ui/Console.tsx` |
| 27 | **lane label** | LIVE | Each screen lane's label: deck, BPM at the current tempo, and playing / cued / empty. | — | `src/renderer/ui/Console.tsx` |

## Tone and tempo

The EQ overlay that replaces the platter, plus the tempo fader.

| # | Control | Status | What it does in Dex | Key | Source |
| --- | --- | --- | --- | --- | --- |
| 28 | **FILTER** | LIVE | Opens the channel's bipolar sweep slider: left low-pass, right high-pass, centre off. The FILTER button shows OFF or the active cutoff. Reset or double-tap the slider to centre it. | — | `src/renderer/ui/Mixer.tsx` |
| 29 | **LOW** | LIVE | LOW cut fader on the inside of each channel next to the meter strip. Isolator band below 220 Hz (Linkwitz-Riley 24 dB/oct, src/shared/isolator.ts). Top of the travel is flat (0 dB); the travel only cuts: −3 dB at 80%, −6 at 60%, −12 at 40%, −24 at 20%, −∞ at the foot. Relative drag (no jump), double-tap returns to 0 dB, drag sideways off the fader for ¼ then ⅒ speed (the readout says FINE). | — | `src/renderer/ui/Mixer.tsx` |
| 30 | **MID** | LIVE | MID cut fader: isolator band 220 Hz – 3.5 kHz. Top of the travel is flat (0 dB); the travel only cuts: −3 dB at 80%, −6 at 60%, −12 at 40%, −24 at 20%, −∞ at the foot. Relative drag (no jump), double-tap returns to 0 dB, drag sideways off the fader for ¼ then ⅒ speed (the readout says FINE). | — | `src/renderer/ui/Mixer.tsx` |
| 31 | **HIGH** | LIVE | HI cut fader: isolator band above 3.5 kHz. Top of the travel is flat (0 dB); the travel only cuts: −3 dB at 80%, −6 at 60%, −12 at 40%, −24 at 20%, −∞ at the foot. Relative drag (no jump), double-tap returns to 0 dB, drag sideways off the fader for ¼ then ⅒ speed (the readout says FINE). | — | `src/renderer/ui/Mixer.tsx` |
| 32 | **TEMPO** | LIVE | On the outer edge of each deck. Tempo ±16%; down is faster, as on a CDJ. Pitch is preserved while KEY is on; turn KEY off for vinyl behaviour. Double-tap resets to 0%. No readout under the fader: the tempo shows in the track window. | — | `src/renderer/ui/Console.tsx` |
| 95 | **KILL (HI / MID / LOW)** | LIVE | Under each band fader. Tap latches the kill; press and hold kills only while held (momentary). The fader keeps its position, so un-killing returns to the exact level. A real mute (band gain 0) in the isolator. | — | `src/renderer/ui/Mixer.tsx` |

## Pads and loops

Grid-quantised loops and the momentary roll.

| # | Control | Status | What it does in Dex | Key | Source |
| --- | --- | --- | --- | --- | --- |
| 33 | **½ · 1 · 2 · 4 · 8 · 16** | LIVE | Loop stepper readout, in beats (1 … 64), in large type. Tap starts a loop at that size, quantised to the grid; while it runs the whole widget lights like a lit CUE key (orange border, orange legend, dark orange tint). The main waveform highlights its actual start, end and beat count in yellow, with a matching track-overview marker. Drag the yellow region to move the whole loop in beat steps while preserving its length and playback phase; left/right arrows move a focused loop by one beat. Tap the readout again to leave the loop. | — | `src/renderer/console/Chassis.tsx` |
| 34 | **‹** | LIVE | Loop stepper: halve the size. A running loop follows straight away. | `Shift + L` | `src/renderer/ui/LoopStepper.tsx` |
| 35 | **›** | LIVE | Loop stepper: double the size. A running loop follows straight away. | — | `src/renderer/ui/LoopStepper.tsx` |
| 36 | **EXIT** | LIVE | Leaves the loop on its end boundary rather than wherever the finger lands, so the mix stays on the grid. | `L` | `src/renderer/ui/DeckPanel.tsx` |
| 61 | **hot cues ×8** | LIVE | A 4 × 2 bank under the platter, as on Traktor, with a HOT CUES label and DELETE. An empty pad has a blue outline; a set pad is solid blue and shows its time. An empty pad captures the playhead, a set pad jumps to it; DELETE turns set pads into erasers until it is pressed again or nothing is left. Saved per track. | — | `src/renderer/ui/HotCuePanel.tsx` |
| 91 | **LOOP / HOT CUE bank** | PLANNED | Two tabs over each deck's pads that swap the bank: LOOP shows the loop lengths, ½×, 2×, EXIT and ROLL; HOT CUE shows the four hot cues. Dex shows loop and hot cue pads side by side today. | — | `src/renderer/ui/DeckPanel.tsx` |

## Transport

Play, cue and the four mode keys.

| # | Control | Status | What it does in Dex | Key | Source |
| --- | --- | --- | --- | --- | --- |
| 37 | **PLAY / PAUSE** | LIVE | Starts or pauses this deck. The deck auto-pauses when the track reaches the end. | `1 / 2, or Space` | `src/renderer/ui/Transport.tsx` |
| 38 | **CUE** | LIVE | CDJ cue point, beside PLAY. Paused: sets the cue point. Playing: returns to it and stops. Held while paused on it: plays until released; PLAY while held keeps playing. Auto-cue on load is the first downbeat; a red CUE marker shows it on the waveforms. Key C. | `M` | `src/renderer/ui/Transport.tsx` |
| 39 | **SYNC** | LIVE | A setting of the deck, not the track: it can be armed on an empty deck, stays on across loads, is remembered between sessions, and both decks can have it. A synced deck that is not master takes the master's tempo as soon as a track is in, and its CUE preview and PLAY start on the master's closest beat (at most half a beat either side of the cue). While both play, a ±0.25% trim keeps removing drift. Moving a follower's tempo fader turns its SYNC off. | `S` | `src/renderer/audio/engine.ts` |
| 40 | **MASTER** | LIVE | The tempo reference that synced decks follow. It moves to whichever deck is playing on its own, as on a CDJ, so a synced deck always follows the deck that is playing; press it to choose. Moving the master's tempo carries its followers along. Exactly one deck is master at a time. | `Shift + S` | `src/renderer/audio/engine.ts` |
| 41 | **KEY** | LIVE | Key lock, on by default: tempo changes leave pitch alone. Turn it off for vinyl mode and the tag row switches to 'vinyl pitch'. | — | `src/renderer/ui/DeckPanel.tsx` |
| 42 | **GRID** | LIVE | Opens the beat-grid sheet for this deck. Same sheet as the GRID key on the screen. | — | `src/renderer/ui/GridSheet.tsx` |

## Beat grid sheet

The modal editor behind GRID. It opens over the mixer, not inside a deck, so the platter stays a playing surface.

| # | Control | Status | What it does in Dex | Key | Source |
| --- | --- | --- | --- | --- | --- |
| 43 | **BPM · confidence · offset** | LIVE | Detected tempo, how much the detector trusts the grid, and the grid's downbeat offset in milliseconds. The offset is folded at the bar, not the beat: a value larger than one beat is how the grid records which beat is the downbeat. | — | `src/renderer/ui/GridSheet.tsx` |
| 44 | **waveform · beat grid overlay** | LIVE | The track's waveform at full detail, with a line on every beat and a heavier line and bar number every four. Dragging moves the waveform and the lines stay still, setting the grid's offset; the result folds into one bar on release. A live playhead crosses it. | — | `src/renderer/ui/GridSheet.tsx` |
| 45 | **Zoom − +** | LIVE | Zooms the waveform in steps from 8 seconds across down to 250 ms, about its centre, so the attack of a beat can be seen. | — | `src/renderer/ui/GridSheet.tsx` |
| 46 | **◀ Beat · Beat ▶** | LIVE | Centres the grid line before or after the middle of the window. | — | `src/renderer/ui/GridSheet.tsx` |
| 47 | **Track strip** | LIVE | The whole track under the waveform, marking the window. Tap or drag to move the window along the track, for checking the grid at the start and the end. | — | `src/renderer/ui/GridSheet.tsx` |
| 48 | **SET DOWNBEAT** | LIVE | Arms the waveform, then a press on the first beat of a bar re-phases the grid so that beat is bar 1. The offset is recomputed modulo the bar, correcting a rotated downbeat in one gesture instead of a count of 1 ms nudges. The button turns accent-coloured while armed. | — | `src/renderer/ui/GridSheet.tsx` |
| 49 | **TAP** | LIVE | Tap three or more times with the beat; the average interval sets the BPM, clamped to 60–200, at 50% confidence because a tap is a human estimate. Gaps longer than 2.6 seconds are ignored. | — | `src/renderer/ui/GridSheet.tsx` |
| 50 | **−0.1 BPM** | LIVE | Trims the grid tempo by 0.1 BPM. Use it when the detector is close but the beat markers drift over a long mix. | — | `src/renderer/ui/GridSheet.tsx` |
| 51 | **+0.1 BPM** | LIVE | Raises the grid tempo by 0.1 BPM. | — | `src/renderer/ui/GridSheet.tsx` |
| 52 | **◀ 1 ms** | LIVE | Slides the whole grid 1 ms earlier without changing tempo. The offset is folded at the bar, so nudging never rotates the downbeat. The arrow keys do the same on the focused deck, with Shift for 10 ms steps. | `← / →` | `src/renderer/ui/GridSheet.tsx` |
| 53 | **1 ms ▶** | LIVE | Slides the whole grid 1 ms later without changing tempo, preserving the bar phase. | — | `src/renderer/ui/GridSheet.tsx` |
| 54 | **÷2** | LIVE | Reinterprets the grid at half time: same music, twice the beat period. Use it when the detector locked onto double-time hats and the markers look twice as dense as the music. | — | `src/renderer/ui/GridSheet.tsx` |
| 55 | **×2** | LIVE | Reinterprets the grid at double time. Use it when the markers look half as dense as the music. | — | `src/renderer/ui/GridSheet.tsx` |
| 56 | **Other readings · 88.67 2/3×** | LIVE | The tempos the analysis turned down, each with its own downbeat and its ratio to the current grid. A tap swaps one in; the reading it replaces joins the row. Headed amber "Not sure of this tempo · it may be" when the track is flagged as an uncertain tempo, which also turns the confidence readout and the library's grid cell amber with a ?. | — | `src/renderer/console/Sheets.tsx` |
| 57 | **Close** | LIVE | Closes the sheet; Esc does the same. There is nothing to apply or cancel because every edit is already written to the deck and the library entry. | `Esc` | `src/renderer/ui/GridSheet.tsx` |

## XDJ-RR only — planned

Drawn for the layout study because the hardware has it. Dashed in the mockup, nothing behind it in Dex.

| # | Control | Status | What it does in Dex | Key | Source |
| --- | --- | --- | --- | --- | --- |
| 58 | **JOG MODE** | PARTIAL | Vinyl / jog-mode switch. Dex's closest equivalent is the KEY toggle: key lock off makes pitch follow the tempo. There is no slip mode and no jog sensitivity. | — | — |
| 59 | **TEMPO ±16** | PARTIAL | Range selector (±6 / 10 / 16 / WIDE). Dex has one range: ±16%. | — | — |
| 60 | **MASTER TEMPO** | PLANNED | Applies one tempo to both decks from a single control. Not built; each deck has its own tempo and SYNC bridges them. | — | — |
| 62 | **BEAT LOOP** | PARTIAL | Auto beat loop. Dex's loop pads already do this, quantised to the grid — the labelling is what differs. | — | — |
| 63 | **SLIP LOOP** | PARTIAL | A loop that keeps the underlying position running. Dex's ROLL is the closest thing; there is no separate slip mode. | — | — |
| 64 | **◀ JUMP · 1 · 4 · 16 · 32 · JUMP ▶** | LIVE | Beat jump, CDJ style. ◀ and ▶ sit in the platter's lower corners; each press jumps back or forward by whole bars of the deck's grid (no auto-repeat), keeping the place in the bar, so a synced deck stays in phase. The selector under the platter picks 1, 4, 16 or 32 bars (default 1). A paused deck lands on the nearest bar line. Near either end it jumps as many whole bars as fit. A running loop moves with the jump. | `Q / W deck A, O / P deck B` | `src/renderer/console/Chassis.tsx` |
| 65 | **IN · OUT · RELOOP** | PLANNED | Manual loop in and out points, plus re-loop. Dex loops are grid-quantised lengths with no in/out marks. | — | — |
| 66 | **CUE/LOOP CALL · DELETE · MEMORY** | PLANNED | Stored cue and loop memory, recall and delete. Not built; nothing about a track's cue points is persisted. | — | — |
| 67 | **SHIFT** | PLANNED | Hardware modifier that doubles the function of every other key. No equivalent; held ROLL is Dex's only momentary control. | — | — |
| 68 | **TALK · LEVEL** | PLANNED | Mic input with talk-over ducking. There is no microphone path into the master and no routing UI for one. | — | — |
| 69 | **WAKE UP · TRACK MARK** | PLANNED | Master recording and track marks. Nothing is recorded; the only capture path (the input tap) is analysis-only and never connected to the output. | — | — |
| 71 | **PHONES** | PLANNED | Headphone volume. Dex has cue mix and split/4-channel routing, but no cue level. | — | — |

## Centre mixer

Channel A and B meters flank the stereo master, with printed scales between them. MASTER LEVEL sits above the meters; each deck has a FILTER popover, channel cue, and faders.

| # | Control | Status | What it does in Dex | Key | Source |
| --- | --- | --- | --- | --- | --- |
| 70 | **LEVEL fader** | LIVE | Channel LEVEL, the outermost fader of each channel, on the same law as the bands with 0 dB at the top. Relative drag, double-tap resets. Its index line carries the deck colour. | — | `src/renderer/ui/Mixer.tsx` |
| 72 | **master BPM** | LIVE | The master deck's detected BPM and track name. Master is whichever deck the MASTER key is on; the dot takes that deck's accent colour. | — | `src/renderer/App.tsx` |
| 73 | **master meters L · R** | LIVE | The two middle bars: stereo peaks after MASTER LEVEL and before the limiter. A printed −30 to +6 dBFS scale sits on each side of the pair. The thin lines mark −3 dBFS. CLIP lights when either side's peak hold reaches 0 dBFS on the signal entering the limiter. | — | `native/Sources/CDexEngine/DexEngine.cpp` |
| 74 | **channel meters A · B** | LIVE | The outer bars, CH A and CH B. Each deck's peak is read after TRIM, EQ and FILTER, before LEVEL and the crossfader. The thin line marks −6 dBFS for setting TRIM, even with LEVEL down. The scale is printed between each channel and its adjacent master bar. | — | `native/Sources/CDexEngine/DexEngine.cpp` |
| 75 | **MASTER LEVEL** | LIVE | Shows master output level directly above the meter strip. Opens a popover with the same master fader available in the header's VOLUME popover. | — | `native/Sources/DexConsole/Chassis.swift` |
| 76 | **channel CUE** | LIVE | CUE under each channel's LEVEL fader: pre-listen that deck in the headphones (M). In the library's deck panel the same switch is the headphone key beside PLAY · CUE. | — | `src/renderer/ui/Mixer.tsx` |
| 77 | **channel EQ** | LIVE | Opens that deck's tone overlay on its own deck face. The hub's A / B EQ keys do the same thing; the mockup draws both. | — | `src/renderer/App.tsx` |
| 78 | **crossfader** | LIVE | Crossfader at the foot of the mixer. Each deck stays fully open until the centre and fades only across the far half, as a club mixer's cut curve: centred, LEVEL alone sets the mix. Relative drag, double-tap centres it. | — | `native/Sources/DexCore/Transport.swift` |
| 96 | **TRIM** | LIVE | Input gain before the EQ (so the headphones hear it), ±12 dB. AUTO aims for −11 LUFS in the main groove on load (ITU BS.1770 loudness, measured at import; older tracks are measured in the background). The popover opens clear of the meters so the −6 dBFS channel guide stays visible. The DJ can trim a hot track by hand. Dex remembers that trim per track; RESET, a double-tap or snapping within 0.25 dB returns to AUTO. | — | `native/Sources/DexCore/Loudness.swift` |
| 97 | **LINK LOWS** | LIVE | Couples the two LOW faders: drag either one and the other moves the same distance the opposite way. The bass swap in one gesture; unlink to ride them separately. | — | `src/renderer/ui/Mixer.tsx` |
| 98 | **band sheet** | PLANNED | Tap a band name above its fader: that band for BOTH decks on 300 pt horizontal sliders, with both kills (and LINK for LOW). For long, slow rides. Not in the app yet. | — | — |

## Bottom rail

Master level and cue mix, kept out of the mixer so they are always reachable.

| # | Control | Status | What it does in Dex | Key | Source |
| --- | --- | --- | --- | --- | --- |
| 79 | **MASTER** | LIVE | In the MASTER LEVEL and VOLUME popovers. Sets master output from mute to unity; the mixer's MASTER LEVEL button shows the same value. The −3 dBFS line on the master meters is a guide for mixing. | — | `native/Sources/DexConsole/Pops.swift` |
| 80 | **CUE MIX** | LIVE | In the VOLUME popover. Blends the headphones from the cued deck to the master. | — | `src/renderer/App.tsx` |

## Library sheet

The crate. A full-width sheet over both decks.

| # | Control | Status | What it does in Dex | Key | Source |
| --- | --- | --- | --- | --- | --- |
| 81 | **search** | LIVE | Filters the list as you type, case-insensitive, across title, key name, Camelot code and BPM. Typing a Camelot code such as 4A matches that key exactly. It takes focus when the sheet opens and the header shows how many tracks match. | — | `src/renderer/ui/LibrarySheet.tsx` |
| 82 | **Add files** | LIVE | Adds audio files to the library and loads the last one onto the last focused deck. mp3, flac, wav, aiff, aif, m4a, aac, ogg and opus are accepted; BPM, offset and waveform peaks are analysed on ingest. | — | `src/renderer/state/library.ts` |
| 83 | **Add folder** | LIVE | Scans a folder recursively, up to 3000 files, sorted by path, and analyses each one in a worker off the UI thread. | — | `src/renderer/state/library.ts` |
| 84 | **Track details (⋯)** | LIVE | At the end of each row: opens the track's details (artists, album, genre, BPM, key, length and release date where available), its playlists to switch on and off, re-analyse and remove. | — | `native/Sources/DexConsole/Library.swift` |
| 85 | **Find keys** | LIVE | Shown when tracks have no key yet, with how many. Reads only the key of each, one at a time, so grids and hot cues edited by hand stay. FINDING KEYS shows progress in the header. | — | `native/Sources/DexAudio/NativeLibrary.swift` |
| 86 | **Close** | LIVE | Closes the library and returns to the mixer. Esc does the same. | — | `native/Sources/DexConsole/Library.swift` |
| 87 | **BPM value** | LIVE | The detected BPM. It is underlined in the mockup, which makes it look tappable — in the app it is plain text, and corrections happen in the GRID sheet. | — | `src/renderer/ui/LibrarySheet.tsx` |
| 88 | **grid confidence** | LIVE | How much the detector trusts the beat grid, colour-coded. Low confidence is the cue to open GRID and nudge. | — | `src/renderer/ui/LibrarySheet.tsx` |
| 89 | **Re-analyse (in track details)** | LIVE | In track details, asks twice: runs the whole analysis again. The grid, its other readings and the key are replaced, hand-edited grids included; hot cues stay. | — | `native/Sources/DexAudio/NativeLibrary.swift` |
| 90 | **Remove from library (in track details)** | LIVE | In track details, red, asks twice: deletes the library's copy and cover and takes the track out of every playlist. The original file stays. Refused while a deck holds the track. | — | `native/Sources/DexAudio/NativeLibrary.swift` |
| 93 | **Camelot key** | LIVE | Camelot code (8A, 4B…) in the wheel's colour: minor keys on the pastel A ring, major on the saturated B ring. Keys are detected on import ("Find keys" backfills older tracks). Tap one to filter the list to that key plus its harmonic matches (±1 on the wheel and the relative major / minor), or switch the filter bar to that key only. Also on each deck card and in the deck panel. | — | `src/renderer/ui/CamelotBadge.tsx` |
| 94 | **column sort** | LIVE | Tap a column header — track, key, BPM, time or grid — to sort by it; tap again to reverse. Key sorts round the Camelot wheel (1A, 1B, 2A…), so harmonic neighbours sit together. Unsorted, the library runs by name and a playlist in its own order. | — | `src/renderer/ui/LibrarySheet.tsx` |
| 99 | **playlist column** | LIVE | Left of the list: All tracks, then each playlist with its count. + makes one, double-click renames, ✕ then Delete? removes it (tracks stay in the library). Drag rows onto a playlist to add them. | — | `src/renderer/ui/LibrarySheet.tsx` |
| 100 | **Playlists (in track details)** | LIVE | In track details, click a playlist to add or take out the track. Create playlists with + in the library sidebar. | — | `native/Sources/DexConsole/Library.swift` |

## Shortcuts on the drawn controls

| Keys | Control |
| --- | --- |
| `Esc` | music / mixer pill (library) (#1) |
| `? or /` | ? (#5) |
| `Esc closes` | (i) · help (#6) |
| `M` | CUE (on the platter) (#24) |
| `Shift + L` | ‹ (#34) |
| `L` | EXIT (#36) |
| `1 / 2, or Space` | PLAY / PAUSE (#37) |
| `M` | CUE (#38) |
| `S` | SYNC (#39) |
| `Shift + S` | MASTER (#40) |
| `← / →` | ◀ 1 ms (#52) |
| `Esc` | Close (#57) |
| `Q / W deck A, O / P deck B` | ◀ JUMP · 1 · 4 · 16 · 32 · JUMP ▶ (#64) |

The in-app `?` sheet is authoritative for keys that have no drawn control — arrow-key grid nudging,
for instance.
