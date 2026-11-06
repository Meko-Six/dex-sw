# Dex ideas — later goals and maybe-laters

Ideas worth keeping that are not part of the current goal, highest priority
first. Each one says
where it came from, what it is, what to watch out for, and the cheapest way
to try it. Add to an entry as thinking moves on; move it into a handoff's
"Next" list when it becomes real work.

## Deferred transport additions — ROLL, loop dragging and monitoring hardware

*Scope clarified by the user, 31 October 2026. Not current build requirements.*

- **ROLL** was removed earlier. Keep a possible momentary/slip-loop ROLL as a
  future addition, not an unfinished control to restore during native parity.
- **Loop dragging** is also deferred. Current anchored resize and bar-jump loop
  movement remain supported; moving the region by dragging can be revisited.
- **Physical headphone routing checks** need a splitter cable or suitable USB
  audio output, neither of which the user currently has. Defer those hardware
  checks; standard stereo transport work continues without them.

## A native Swift app for Mac and iPad — now active work

*Raised 2026-10-29, started 2026-10-30.* No longer an idea: scope, behaviour and
parity gates live in [native/README](../native/README.md).

## Panels instead of one crowded screen

*Raised 2026-10-29. Not started.*

Most iPad DJ apps put every control on one screen, copying Pioneer-style
hardware. Dex could break from that: keep a calm overview, and open **areas
on demand** (a tap on the mixer, a button, a key) where the controls for one
job are large. Hide them again when the job is done. Some jobs need two
areas side by side, so a DJ's workflow decides what opens together.

Dex already does this in places: the LOW popover (both decks' lows with
300 pt of travel, and LINK LOWS for the bass swap), trim, the hot cue bank,
the beat grid sheet and the library.

**Group controls by when they are needed, not by the hardware layout.**

- *Always on screen, never covered:* play and cue on both decks, the
  waveforms (beat and phase), time remaining, master level.
- *During a transition:* EQ, filter, channel faders, crossfader. These gain
  most from being big, because a 16- or 32-bar ride is long and precise.
- *Between tracks:* library, beat grid, trim, setting hot cues, key. These
  can take the whole screen.

The test for any panel: can everything in the first group still be reached
while it is open?

**Name panels after the stage of the mix, not the hardware section.** The
mixing cycle is: pick the next track → cue it in the headphones → start it on
the playing track's phrase → ride the transition over 16 or 32 bars → let the
old track go. A "transition" panel holding both decks' EQ, filter and level
(with the waveforms still above it) covers most side-by-side needs in one
place. The LOW popover is already shaped like this.

**Watch out for:**

- **Fixed positions.** A knob was ruled out because glass gives no tactile
  feel; on glass, muscle memory has to stand in for it, so a panel opens in
  the same place every time with its controls in the same places.
- **No automatic switching mid-mix.** It is tempting to open the transition
  panel when the incoming deck starts, but a layout that changes by itself is
  how the wrong thing gets hit. One tap or one key instead.
- **Hold-to-peek and tap-to-stay-open.** A panel shown only while held can't
  be forgotten open (good for quick checks); long rides need one that stays.
- **One way back.** A single gesture or key (Esc already does this) always
  returns to the overview.
- **Several fingers at once.** A big panel must still allow a fader drag while
  a kill is held, as the mixer does today.
- **Never hide the outgoing track.** Time remaining and the playing waveform
  stay above every panel, so a track can't run out unseen.

**Prior art:** djay on iPad (several switchable layouts) and the iPad Traktor
apps (panels that slide in) are worth trying with this in mind.

**Cheapest way to try it:** a "transition view" screen in the mockup, with
both decks' EQ, filter and level at the LOW popover's 300 pt travel and the
waveform band kept on top. Compare it with the full console on a real bass
swap. If MIDI hardware is ever added, the case gets stronger: the controller
carries the mixer and the screen shows only what the hardware can't.
