# DexSliderLab

The test app for Dex's expandable mixer slider, built around the user's sketch (10 November 2026):
a chip at rest that touches open into a Control Centre–style bar, with the number above it and
the top of the meter above that. It runs on iPad and Mac from one target.

It replaces the earlier DexMixLab, which the user tried and set aside.

**After the first round (10 November):**
- The chips replace the rotary knobs: TRIM, HI, MID and LOW, plus CUE/MST, PHONES and MASTER in the space the kill buttons free up.
- LEVEL and TEMPO are always-visible faders in the same style, with no expansion, because the most-used controls need a fader you can see.
- The user chose:
  - relative drag;
  - LEVEL shows its percentage and the master meter while touched (option D);
  - the A·L·R·B meters stay in the centre;
  - TEMPO is fixed at ±16 %, reads to 0.1 %, and sticks gently at 0.
- In TUNE, LEVEL and TEMPO each switch between an open bar and a cap on a track, for comparing.

## Run

```sh
open DexSliderLab/DexSliderLab.xcodeproj    # scheme DexSliderLab: My Mac, or the iPad
swift test --package-path DexSliderLab/Packages/DexSlider
```

The minimum is iPadOS 18 / macOS 15, for `SpatialEventGesture` (several fingers at once, the same
code on the Mac). Dex itself is still 16 / 13; raising it or adding a UIKit touch path is a
decision for the graft. Signing uses team `33B24PEVAC`.

## What's here

- `Packages/DexSlider` holds the control on its own, with no audio and no Dex code:
  - `SliderChip`: at rest, it fills like a small bar and shows its number, so its setting can be read without opening it. The outline follows its meter, and TRIM has an orange AUTO tick.
  - `SliderPanelView`: the six-rung meter top, the big number, a caption (AUTO, or FINE ½ ¼ ⅒), and the bar.
  - `SliderStage`: owns every touch inside it and routes each finger to the chip it landed on.
  - `SliderBank`: the router and the values.
  - `SliderDrag`: the drag law. It is relative, and the bar's height covers the whole range. Moving sideways slows it, and it stretches past the ends.
  - `PanelPlacer`: opens the panel with its fill edge level with the finger, outward by default, and clear of another open panel.
  - `SliderFader`: LEVEL and TEMPO as an open bar or a cap on a track.
    - LEVEL's readout (master rungs and %) appears beside the fader, outward, while touched, so it never covers the EQ.
    - TEMPO fills from an orange 0 line. Up is slower, as on a CDJ. It shows % and BPM, sticks at 0, and dims to SYNC when locked.
- `DexSliderLab`, the app:
  - Decks A and B, each with TRIM, HI, MID, LOW and LEVEL; TEMPO at the outer edges.
  - Dex's A · L · R · B meters in the centre, with CUE/MST, PHONES and MASTER under them.
  - SYNC per deck: it holds that deck's TEMPO to the other deck's BPM.
  - A test signal: a beatmatched kick, clap and hats per deck, run through TRIM, the EQ (Dex's fader law), LEVEL and master volume 0.7, with Dex's meter ballistics. HOT / NORMAL / QUIET stand in for loading tracks; each has its own AUTO.
  - **TUNE** opens every look-and-feel number live. Changes are kept between launches, and **Copy settings** puts them on the clipboard to send back.

Behaviour: touching changes nothing, only moving does. Double-tap TRIM to go back to AUTO, an EQ to go
back to flat, or CUE/MST to go back to 50/50. LEVEL, TEMPO, PHONES and MASTER have no double-tap reset,
because a stray tap must never jump anything loud or audible. CUE/MST sticks at 50/50 as TEMPO does at 0.
MASTER drives the test signal's master; CUE/MST and PHONES have no effect yet, as the lab has no headphone output.
Several fingers work at once, and a finger keeps its control wherever it travels.

`-demo trim | levels | stretch | fine | tempo | cue` as a launch argument holds pretend fingers down, for
screenshots where touches can't be sent.

## Checked

- `swift test`: 32 tests pass. They cover readouts, the drag law, fine speeds, stretch, rungs, placement, routing, double-tap, TEMPO's direction, detent and BPM, the CUE/MST blend, and the SYNC lock.
- The Mac and iPad Simulator builds succeed.
- Simulator screenshots, portrait only, of the resting chips and of each `-demo` state.
- **Not yet checked:** real fingers on a real iPad, landscape, and the Mac with a mouse.

## Next

1. Tune the feel on the iPad, pick the LEVEL and TEMPO styles, and make the approved values the defaults.
2. Real tracks through Dex's own engine, so the sound, the trim and the meters are Dex's.
3. On the Mac: scroll wheel and arrow keys for fine moves.
4. Tempo.
5. Graft into DexConsole.
