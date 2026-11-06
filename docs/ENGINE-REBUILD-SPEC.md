# Deck engine rebuild: behaviour spec

Decided by the user, 5 November 2026. This replaces the plan's remaining W1, W2 and
W6 work if the prototype passes. Until the user signs it off, the current engine stays
in place as the fallback.

## Why

The user has played on many DJ apps and hardware units, and Dex doesn't behave the way
they do. They want the foundation changed, not more fixes. Dex schedules audio ahead on
Apple's players and predicts where playback is, which is behind:

- the time-pitch's hidden delay of about 85 ms, handled by a measured constant
- speed limited to steps of 1/512, which is why SYNC needs steering
- a deck settling 3–14 ms early, differently on each start, which can't be corrected
- two voices per deck, pre-rolls, and launch retries
- a possible 85 ms shift entering or leaving a jog, which bypasses the time-pitch
- faults that show only live, such as the distortion that was never isolated

## Clean-build rules

Dex must stay free to share or sell on any route, so these are absolute:

- **Don't read Mixxx's source, tests, wiki or developer docs,** or any other GPL DJ
  engine, including the Mixxx links in the audit and plan. Don't search for how they do
  something. This spec gives the requirements; design the code yourself.
- Don't copy or translate GPL code, and don't add a GPL dependency to the repo.
- Allowed stretchers: **Signalsmith Stretch** (MIT) and **Bungee** (MPL-2.0). Check each
  licence file, and its dependencies' licences, when vendoring. Keep required notices.
- Rubber Band's GPL version may be tried only in a private local listening build. Its
  code and any wrapper for it never get committed, and it never ships.
- Nothing paid: no licences or SDKs.
- Textbook DSP, Apple's documentation and the stretchers' own docs are fine.

The author of this spec read Mixxx's engine to evaluate it. The spec is limited to Dex's
own requirements and the general shape of a real-time audio engine, and it deliberately
carries no code, names or tuning values from Mixxx.

## What stays

- **The UI, exactly.** `DexConsole` doesn't change, and `npm run diff:native` stays
  within its unchanged budgets. No new controls without the user's agreement; new UI
  starts in the HTML mockup.
- **The interface the app uses.** `NativeDeck` and `NativeMixer` keep what `ConsoleModel`
  calls, so the app can't tell which engine is underneath. Minimal changes to
  `ConsoleModel` are allowed if they're needed, and you should list them.
- **Library, analysis, grids, cues and tags.** Don't retune analysis.
- **All agreed musical behaviour:** `native/README.md` "Behaviour", plan §4, and HANDOFF
  "Standing user decisions". The values below stay unless the user agrees a change.

| Behaviour | Agreed value |
| --- | --- |
| Tempo range | ±16%, key lock on by default |
| Fade on a playing seek, loop or cue change | 10 ms |
| Main CUE late window | 150 ms, capped at 30% of a beat |
| Hot-cue late window | 100 ms, capped at 20% of a beat |
| Late attacks | a missed attack is never replayed late |
| Loops | ½–64 beats; growing keeps loop-in; shrinking keeps the part the playhead is in |
| Bar jumps | keep the position in the bar; an active loop moves with the jump |
| Scrub | audible, ±8 source s/s, coast from `JogFling`; the platter stops where it lifts |
| SYNC | sticky; the master is never moved; follower steering within ±0.4%; an error over 20 ms is a real jump and re-lands the follower |
| Master rules | as in HANDOFF "Grid lock" |
| Waveform | shows what is heard; a locked follower's lane is scaled to the master |
| Lifecycle | iPad background audio; route loss never resumes on speakers; held previews don't auto-resume |
| Tone section | flat bands stay out of the signal; volume feeds the limiter; cue has a peak guard |

The old 30 ms and 120 ms pre-rolls were needed by the old engine. They are not behaviour
to keep. Report what replaces them, and any change in how quickly a press is heard.

## The new foundation

**One audio loop owns everything audible.** The device asks for a block of output, and
that one callback produces it for both decks, the master and the cue. Nothing audible
happens anywhere else.

1. **Position.** A deck's position, in source frames, changes only inside the loop. It
   is what was actually played, never a prediction.
2. **Commands.** The app sends commands through a bounded lock-free queue. The loop
   applies them at a block or an exact frame, and confirms them in what it publishes.
3. **Published state.** Each block publishes position, real speed, host time and
   confirmed state, without locks. The display extrapolates from the latest, then allows
   for the output device's reported delay. If the audio stalls, the display stops soon
   after. `FrameLink` and `WaveTiles` stay. `OutputLatency.stretchDelay` should go,
   replaced by delay the engine knows exactly.
4. **Audio data.** File reading and decoding happen on a background thread, into memory
   allocated in advance and within `AudioMemoryBudget`. The loop never waits on either.
   Keep ready what a DJ can reach instantly: around the playhead, the main cue, every hot
   cue, the loop points and bar-jump targets. Don't assume whole tracks fit in memory.
5. **If a target isn't ready,** the outgoing audio keeps playing until it is. There are
   no gaps and no lost attacks. Report how often this happens.
6. **Position through the stretcher.** The reported position describes the audio leaving
   the stretcher, not what went in, including across loop wraps and speed changes. A
   position must be right to the millisecond at any tempo, with key lock on or off.
7. **Jumps.** Seeks, loops, hot cues and bar jumps land on a chosen output frame, with
   the 10 ms fade. A loop wrap is frame-accurate at any length, including under a beat.
8. **Speed.** Key lock on uses the stretcher. Key lock off and scrubbing use a good
   resampler. Moving between them must not shift time or click. Source files at any
   sample rate must play at the right speed on any output rate.
9. **SYNC.** Both decks' positions are known in the same block, so phase is measured
   there and corrected in the loop. Keep the agreed rules. Don't carry over 1/512 steps
   unless a stretcher really needs them.
10. **Tone and mix.** Reuse `DexMixer.c`'s isolator, sweep, gains and cue logic as plain
    calls in the loop, not a graph of audio units. Keep their tests' expectations.
11. **Devices.** Apple's APIs stay for the output device, the audio session and route
    changes. Engine state lives outside any graph, so it survives a rebuild.
12. **Effects later.** Effects are the next feature the user wants. Don't build them,
    but leave room for each deck to run effects that know the beat length and position.

The real-time code is C or C++ and is called from Swift. In the loop there's no
allocation, locking, logging, file access or Swift runtime work. Plan a way to check that.

## Order and gates

Stop and report at any gate that can't be met. Never weaken a measure to pass it.

**1. Engine on its own, with no device.** Test the same callback offline with click
tracks at known positions.

- Clock against sound within 1 ms, at 84, 92, 100, 108 and 116%, key lock on and off.
- Two decks stay within 1 ms for 180 s, through jumps, loops and master changes.
- Seeks and hot cues land within 1 ms of the chosen frame.
- Loops have no click and no drift at ½, 1, 4 and 64 beats.

**2. Stretchers.** Measure Signalsmith Stretch and Bungee, and Apple's time-pitch as the
baseline: CPU with two decks with key lock on, delay, response to speed changes, and
time to first correct audio after a jump. Make render-to-file comparison clips from the
user's music at several tempos, without playing anything aloud, and keep the clips out of
git. Measure on the Mac, and on the iPad if connected; say plainly if the iPad wasn't.

**Gate: the user listens.** Give them short, plain instructions for A/B listening. If no
free stretcher sounds at least as good as Apple's to them, stop. This is the biggest risk
in the rebuild. They may also try Rubber Band privately, as a comparison.

**3. Behind the current interface.** Put the engine behind `NativeDeck` and `NativeMixer`,
selectable at build or launch time with no console UI. The current engine must remain
buildable and runnable until the user signs off.

- Existing tests pass. Where one inspects old internals, rewrite it against behaviour
  and list every rewrite, showing the musical check is at least as strict.
- `swift test`, the Mac and iPad Simulator builds, `diff:native`, the 100-cycle soak and
  the muted live checks all pass, with results reported.
- Live and muted: clock against sound through the real output, no underruns over several
  minutes of two decks with key lock on, and no fixed drift between decks.
- Compare CPU and memory with the current engine in a release build.
- Waveforms, in a release build with real audio on two decks and EQ moving: lanes still
  update at 60 a second with even steps. The current figures (60.0 updates a second, 0%
  uneven, 2.91 px per update) were measured without audio by `DexWaveProfile`, which
  doesn't use the engine, so add a run that does. Say plainly if the iPad wasn't measured.
- Waveform against sound, with clicks and the mic on the Bose, as in
  `docs/audio-audit/EVIDENCE.md`: no worse than the current 13.6 ms sound after waveform.
  This is audible, so it needs the user's say-so first.

**4. The user plays it,** on the Mac and the iPad, Bluetooth included, side by side with
the current engine: hot cues, loops, bar jumps, scrubbing, SYNC and key lock. This is the
real test, because the goal is that Dex behaves as a DJ expects. Only their verdict signs
it off. Ask them what still feels wrong.

Removing the old engine is a separate step, after sign-off and with the user's go-ahead.

## Out of scope

Effects, output modes and route UI (W3), the shared presentation service (W4) beyond what
the new position needs, analysis changes, new UI, and merging to `main`.

## Working rules

- Audible tests need the user's say-so, and live checks stay muted. `HANDOFF.md`
  "Keep in mind" and "Not checked" still apply: never report something unmeasured as
  passed, and say which device each number came from.
- Native code must compile on both this Mac's Xcode and CI's older one.
- The user is a DJ, not a developer. Report in terms of what they'll hear and do, with
  numbers as evidence. Decisions go to them in plain words.
- Update `HANDOFF.md` at closeout with where this stands and what's next.
