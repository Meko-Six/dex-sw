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

**FX (10 November):** each deck has one FX chip under LOW. It is FILTER by default, or one of the
effects that can take its place, as with Traktor's Mixer FX. The user chose:
- a vertical bar, read here as up for high-pass and down for low-pass (TUNE can flip it);
- the reading as a position, OFF at the centre and −40 % / +40 % either side;
- the switchable chip only, with no separate FX unit for now;
- FILTER, REVERB, DELAY and GATER;
- the effect chosen per deck.

Hold a finger still on the FX chip (0.5 s, tunable) and the effect list comes up with the current
effect under the finger. Slide to another and lift to take it, or lift without sliding and tap one.
The amount stays where it was, as a hardware knob would. Every effect has OFF at the centre,
high-pass on one side and low-pass on the other. The lab makes no sound, so each effect shows only
in the deck meter: the filter thins or darkens it, reverb fills the gaps, delay adds echoes, and
gater chops it in sixteenths. Dex has the filter but none of the effects yet; they need writing for
its engine.

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
  - `EffectPickerView` and `PickerPlacer`: the FX chip's effect list.
  - `PanelPlacer`: opens the panel with its fill edge level with the finger, outward by default, and clear of another open panel.
  - `SliderFader`: LEVEL and TEMPO as an open bar or a cap on a track.
    - LEVEL's readout (master rungs and %) appears beside the fader, outward, while touched, so it never covers the EQ.
    - TEMPO fills from an orange 0 line. Up is slower, as on a CDJ. It shows % and BPM, sticks at 0, and dims to SYNC when locked.
- `DexSliderLab`, the app:
  - Decks A and B, each with TRIM, HI, MID, LOW, FX and LEVEL; TEMPO at the outer edges.
  - Dex's A · L · R · B meters in the centre, with CUE/MST, PHONES and MASTER under them.
  - SYNC per deck: it holds that deck's TEMPO to the other deck's BPM.
  - A test signal: a beatmatched kick, clap and hats per deck, run through TRIM, the EQ (Dex's fader law), LEVEL and master volume 0.7, with Dex's meter ballistics. HOT / NORMAL / QUIET stand in for loading tracks; each has its own AUTO.
  - **TUNE** opens every look-and-feel number live. Changes are kept between launches, and **Copy settings** puts them on the clipboard to send back.

Behaviour: touching changes nothing, only moving does. Double-tap TRIM to go back to AUTO, an EQ to go
back to flat, FX to go back to OFF, or CUE/MST to go back to 50/50. LEVEL, TEMPO, PHONES and MASTER have no double-tap reset,
because a stray tap must never jump anything loud or audible. CUE/MST sticks at 50/50 as TEMPO does at 0.
MASTER drives the test signal's master; CUE/MST and PHONES have no effect yet, as the lab has no headphone output.
Several fingers work at once, and a finger keeps its control wherever it travels.

`-demo trim | levels | stretch | fine | tempo | cue | fx | picker` as a launch argument holds pretend fingers down, for
screenshots where touches can't be sent.

## Checked

- `swift test`: 43 tests pass. They cover readouts, the drag law, fine speeds, stretch, rungs, placement, routing, double-tap, TEMPO's direction, detent and BPM, the CUE/MST blend, the SYNC lock, FX readouts and direction, and the effect list (hold, slide and lift, tap, dismiss).
- The Mac and iPad Simulator builds succeed.
- Simulator screenshots, portrait only, of the resting chips and of each `-demo` state, FX and the effect list included.
- **Not yet checked:** real fingers on a real iPad, landscape, and the Mac with a mouse.

## Next

1. Done 10 November: the user's iPad tuning is now the defaults in `SliderTuning`. That means cap faders, LEVEL's readout above, TEMPO's readout only while touched, panels on the finger, a 140 pt bar, 1.5 dB rungs, a 0.13 s hold, and Dex black. Keep tuning, and send changes with TUNE → Copy settings, or read them off the device:
   `xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier com.dex.sliderlab --source Library/Preferences/com.dex.sliderlab.plist --destination prefs.plist`
2. Write REVERB, DELAY and GATER for Dex's engine (FILTER exists), and hear them.
3. Real tracks through Dex's own engine, so the sound, the trim and the meters are Dex's.
4. On the Mac: scroll wheel and arrow keys for fine moves.
5. Graft into DexConsole.
