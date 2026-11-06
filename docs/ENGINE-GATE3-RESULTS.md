# Engine rebuild: gate 3 results

For [ENGINE-REBUILD-SPEC](ENGINE-REBUILD-SPEC.md), gate 3: the replacement engine behind the current
interface. Gates 1 and 2 are in [ENGINE-STRETCHER-MEASUREMENTS](ENGINE-STRETCHER-MEASUREMENTS.md). Everything here
was measured on 6 November 2026, on branch `engine-rebuild`.

**Gate 4 is passed. On 6 November the user played both engines side by side and said: "New engine is amazing. It's
way better than the other one. Super tight, nice and responsive, easy cue lineup, just miles ahead. time to say goodbye
to the old engine". The old engine has been removed on their go-ahead: see the last section. What follows about
choosing an engine, and the test rewrites' "current engine" branches, is the record of gate 3.**

**Gate 3 is closed. On 6 November the user counted the Bose check as passed ("Pass, gate 4"), on the engine's own
error of 0.9–3.1 ms once the speaker's under-report is taken out. Gate 4, the user playing it, is next.**

**Where it stood.** The replacement engine (Bungee Basic) runs behind `NativeDeck` and `NativeMixer`, chosen at
launch with no change to the console. The current engine is still the default and still passes everything it did.
Every gate 3 check has now run, on the Mac and the iPad. All pass except one, which needs your judgement:

- **Waveform against sound on the Bose misses the spec's figure as read, and passes once the Bose's own delay is
  taken out.** Read straight, the replacement engine's sound came 21.0 and 23.2 ms after its waveform, against the
  13.6 ms recorded on 4 November. But the Bose itself, with no Dex code in the path, was 20.1 ms later than it told
  macOS today, against 4.1 ms on 4 November. Taking that out leaves the engine's own error: 0.9 and 3.1 ms on the
  replacement engine, against 9.5 ms for the current engine on 4 November (and 13.9 and −1.0 ms today). Whether that
  counts as passing is yours to say. Details below.

Then gate 4 is yours: play it, Mac and iPad, Bluetooth included, side by side with the current engine.

Devices are as in gates 1 and 2: the M3 MacBook Pro on its own speakers, and the 13-inch iPad Air M3.

## Choosing the engine

No console UI changes. Either:

- **In Xcode:** pick the scheme **DexNative (new engine)** next to the Run button, then Cmd-R. The scheme
  **DexNative** is the current engine. Switching back is picking the other scheme.
- **Anywhere else:** the launch argument `-dexEngine rebuilt`, or `DEX_ENGINE=rebuilt` in the environment (what the
  tests use). On the Mac, `defaults write com.dex.native dexEngine rebuilt` keeps it until
  `defaults delete com.dex.native dexEngine`.

## What you'll hear differently

The musical rules are the same code in `NativeDeck`; these are the places where the new engine lets them, or makes
them, behave differently. Each has a test.

- **Presses come out sooner.** A start from stopped comes out in 10 ms (the fade) plus the wait for the next block,
  against the current engine's 30 ms pre-roll. A seek, hot cue or bar jump while playing goes out on the next block,
  against its 120 ms pre-roll. Nothing is pre-rolled: priming the stretcher takes CPU, not time (gate 2: the attack
  is whole about 10 ms after the jump is due).
- **A quantized cue meets a beat still to come whole.** A CUE or hot cue pressed early enough lands that beat's
  attack on time, where the current engine, needing 120 ms, would join it partway. A beat that has already gone is
  joined 120 ms in, exactly as now, so you never get a clipped attack a few milliseconds late. In the tests, a main CUE
  pressed 80 ms before the bar now plays the downbeat itself, where it used to come in on beat two.
- **A start or seek that has to wait for the disk starts where you asked.** The outgoing audio keeps playing while it
  waits. Quantized cues, bar jumps and loops slide on instead, so the beat count holds.
- **Loops move at once,** and keep working if the file is deleted, because the engine holds the track open.
- **The end of a track shows when it's heard,** not when it's rendered, which on Bluetooth is a quarter-second later.

## Results

### Tests, both engines

| | Current engine | Replacement engine |
|---|---|---|
| `swift test`, all targets | 293 run, 0 failures, 10 optional skips | 293 run, 0 failures, 11 skips |
| Audio tests | 164, 0 failures, 9 optional skips | 164, 0 failures, 10 skips: 9 optional, 1 that only reads the current engine's graph |
| 100-cycle soak, two decks | passes, memory flat at 17.5–18.2 MiB | passes, memory 45 MiB, then flat at 52.7–53.8 MiB as the cache fills |
| Real-time checks | | no allocation over 489,000 frames through the device entry point; the loop imports nothing that could block |

The tests that read the current engine's insides have a branch for the replacement engine. Each one checks the same
sound at least as strictly; they're listed at the end.

### Muted live checks, Mac (the real output, silenced after the engine)

Two decks for five minutes, key lock on both, deck B at 126 BPM synced to deck A at 120, so B is stretched the whole
time. Output delay 17.8 ms.

| | |
|---|---|
| Missed blocks, starved decks, landings that waited | 0, 0, 0 |
| Waveform against sound, deck A | at most 0.73 ms; 99% within 0.03 ms (598 beats) |
| Waveform against sound, deck B (stretched, synced) | at most 0.87 ms; 99% within 0.21 ms (571 beats) |
| B against A | 0.07 ms apart on average; at most 0.25 ms |
| Drift between the decks | 0.006 ms over five minutes |
| Starts and seeks at 92%, 100% and 108%, key lock on | 36 clicks, worst 0.30 ms against the clock |
| Engine time per block (debug build) | 6.2% of a core; worst block 1.8 ms of 10.7 ms |

### CPU and memory, Mac, release build

The waveform profiler's `--audio` mode with no window: two real tracks playing, key lock on both, B synced, the EQ
moving on both decks the whole time, muted. 60 seconds, two rounds each; both rounds read the same.

| | Process CPU | Memory footprint |
|---|---|---|
| No audio | 0% | |
| Current engine | 4% of one core | 32 MiB |
| Replacement engine | 5% of one core | 100 MiB |

The 68 MiB is the replacement engine's cache: 32 MiB a deck, about 87 seconds of its audio around the playhead,
hot cues and jump targets. It's what lets a jump land on the next block. It's reserved from the 128 MiB audio budget.

### Builds and screens

- The app builds for the Mac and the iPad Simulator, with both schemes.
- `diff:native`: every screen within its budget. Nothing on screen changed.
- `ConsoleModel` and `DexConsole` are unchanged. `NativeDeck.heardPosition(ahead:)` is still the lanes' position
  source.

### How often a landing waits

In the five-minute live run, never: every landing found its audio ready. In the release profiler runs, one landing
of eight was late, and it waited no blocks for data: it was held for a fade still running. Offline, the tests that
stall the disk on purpose all pass, with the outgoing audio and the clock carrying on while the landing waits.

### Waveform lanes with audio, Mac, release build

`DexWaveProfile --audio 1`: the console on screen, two tracks playing through the engine, key lock on both, B synced,
the EQ moving, muted, output on the Bose. Three runs on each engine, 30–60 s.

| | Lane updates | Usual step | Uneven steps |
|---|---|---|---|
| Current engine | 60.0 a second | 2.91 px (A), 2.71 px (B) | 0%, 0.1%, 0.1% |
| Replacement engine | 60.0 a second | 2.91 px (A), 2.71 px (B) | 0.1%, 0.2%, 0.1% |

The uneven steps are the screen missing a frame now and then (gaps up to 70 ms on both engines), when the lane catches
up in one step of 10–13 px. Between them every step is the same to 0.01 px. The figure without audio was 2.91 px at
0% uneven.

### iPad, muted live, release build

The 13-inch iPad Air M3 on its own output (11.2 ms delay), three minutes on each engine, as on the Mac: key lock on
both decks, B synced, the EQ moving.

| | Current engine | Replacement engine |
|---|---|---|
| Missed blocks, starved decks, landings that waited | not counted | 0, 0, 0 |
| Waveform against sound, deck A | not measured (no tap on its output) | at most 0.03 ms (358 beats) |
| Waveform against sound, deck B, stretched | | at most 0.44 ms (337 beats) |
| Drift between the decks | | 0.018 ms over three minutes |
| Process CPU | 11.9% of one core | 12.5% of one core; the engine 8.6%, worst block 2.8 ms of 21.3 ms |
| Memory footprint | 20 MiB | 85 MiB |

### Waveform against sound on the Bose, with the mic

`docs/audio-audit/DelayProbe.swift`, as in [EVIDENCE](audio-audit/EVIDENCE.md), now running each engine twice,
alternating, in one sitting: 13 clicks a run, heard by the Mac's own mic, against when the waveform's position reached
each click. Output BlueBoseBaby at 44.1 kHz, reported delay 253.2 ms. Positive means the sound comes after the waveform.

| | Run 1 | Run 2 |
|---|---|---|
| Current engine | 34.0 ms (29.2 to 37.8) | 19.1 ms (16.7 to 20.9) |
| Replacement engine | 23.2 ms (19.9 to 25.9) | 21.0 ms (18.1 to 23.4) |
| Recorded 4 November, current engine | 13.6 ms | |

The control is a plain Apple engine on the Bose, scheduled to a host time, with no Dex code in it. It heard its clicks
20.1 ms after the Bose's reported 253.2 ms today; on 4 November the same control read 4.1 ms (257.3 ms). So the Bose
under-reports its delay by an amount that changes between connections, and Dex can only show what it's told. Both
measurements use the same mic, so its error cancels when one is taken from the other, which leaves each engine's own
error:

| Engine's own error (sound after waveform, less the Bose's under-report that day) | |
|---|---|
| Current engine, 4 November | 9.5 ms |
| Current engine today | 13.9 ms, −1.0 ms |
| Replacement engine today | 3.1 ms, 0.9 ms |

The current engine's spread is its time-pitch: Apple's holds audio back by a delay Dex has to assume (85 ms), which the
muted live tests of 4 November put between 75 and 90 ms depending on tempo. The replacement engine knows its own delay
exactly, and what's left is the Bose.

macOS reports nothing else for the Bose that Dex could add: its safety offset is 0 and its stream latency 0. Within
each run the clicks drift by about 0.5 ms each (8 ms over 18 s), on every engine and on the plain control too: the
Bose's own clock against the Mac's.

What you see on the Bose, then, is the waveform early by however much the speaker under-reports that day: about 20 ms
in the probe's terms today, and more in absolute terms (below). Only a per-speaker offset could take that out, measured
or set by hand, and none exists or has been agreed.

The mic's figures read low in absolute terms, as EVIDENCE warns: the Mac-speaker control read −2.9 ms against a
reported 15.8 ms, so about 19 ms low if the Mac speakers report truly (the mic says its own delay is 50 ms). That's
the same for every row, so the rows compare with each other, and the engines' own errors above don't depend on it.
In absolute terms the Bose under-reported by about 39 ms today, so on it the waveform ran about 40 ms ahead of the
sound on the replacement engine. That's an estimate, resting on the speakers' report.

## Test rewrites

Every test change, and what it checks on the replacement engine. Where a test kept its old branch, the current engine
runs exactly what it ran before.

| Test | Read on the current engine | On the replacement engine |
|---|---|---|
| Jog tests' wait (`JogAudio`, `Hardening`, `LiveClock`, `MusicRender`) | the jog's read window | `jog.ready`: the engine takes the platter on its next block. A wait, not a check: every sound check is unchanged |
| `JogAudio` full command queue | jog moves filling the jog's queue | the other deck's tempo fills the shared 1024-command queue; then also the engine has let go of the platter, is stopped, and sits on the cue |
| `AudioAuditRegression` stalled control lane | a held control lane | unread audio; the same silence and position checks, and then the start comes from the cue once the audio is there |
| `AudioControl` queued stops | a held control lane, voices playing | unread audio; the same 880 Hz against 220 Hz check and memory check |
| `BarCue` early and late presses | bar starting 30 ms in | bar starting at the deck's own start delay; the same counts, accents and 15 ms tolerance |
| `BarJump` loop move failure | a loop read that fails or is cancelled | no read to fail: the move is exact, once, plays the moved bar, and survives the file being deleted |
| `BarJump` queued jump room | a press inside the 120 ms wait | the press on the first block where the bar no longer fits at the landing frame, the tightest case; the same refusal checks |
| `GridLock` played rates | Apple's 1/512 step | the exact tempo, which is what the engine plays; also no landing while out of range |
| `Hardening` playhead and loop memory | | the engine's 2 ms limiter delay counted in; a loop holds no memory at all |
| `LaunchTransaction`, every stall | a held control lane | unread audio, on a 40 s ramp so a seek lands somewhere unread; the same sound, clock and count checks. The ramp restarts at 20 s, because the tone section is flat only to 0.1%, which would read as 28 ms 28 s up a single ramp |
| `LaunchTransaction` slow lane | launches always late | a disk that gives a chunk every 60 ms: it waits, starts where pressed, clock agrees |
| `LiveClock` (4) | the current engine's players | skipped; `RebuiltLiveTests` covers them, minutes long |
| `LoopResize` failed expansion | a resize read that fails | no read to fail: the resize happens and the loop plays on, continuous |
| `MixerRender` tone feeds only its fader | the AVAudioEngine graph | skipped: there's no graph; the cue and EQ sound checks cover it |
| `Playback` seek waveform | at most 1.2 s, the 120 ms wait | never ahead of the sound at all |
| `SyncMeasurement` CUE alignment and window | 120 ms preparation, bar starting 30 ms in | a beat still to come is met whole at the engine's lead; a beat gone is joined 120 ms in; the same 15 ms tolerance and accent checks |

## Measure it again

```
cd native
DEX_ENGINE=rebuilt swift test
DEX_NATIVE_LIVE_CHECKS=1 DEX_LIVE_MINUTES=5 DEX_ENGINE=rebuilt swift test --filter RebuiltLiveTests
DEX_NATIVE_SOAK_CYCLES=100 DEX_ENGINE=rebuilt swift test --filter HardeningTests/testTwoDeckEndurance
swift run -c release DexWaveProfile --window 0 --audio 1 --seconds 60
DEX_ENGINE=rebuilt swift run -c release DexWaveProfile --window 0 --audio 1 --seconds 60
swift run -c release DexWaveProfile --audio 1 --seconds 60            # screen on
DEX_ENGINE=rebuilt swift run -c release DexWaveProfile --audio 1 --seconds 60
```

The Bose check is audible: build `docs/audio-audit/DelayProbe.swift` as EVIDENCE describes, with the Bose as the
default output and a quiet room.

## The old engine removed (6 November)

On the user's go-ahead after gate 4. Gone from the app: the AVAudioEngine players and time-pitches, the transition
gates (`TransitionGate.swift`, `DexRamp.c`), the old jog renderer (`DexJog.c`, `JogAudio`), loop reading
(`LoopAudio.read`), launch tickets and their timing log, `OutputLatency.stretchDelay`, `MixMath.playedRate` (Apple's
1/512 speed steps), the engine switch (`DeckEngineChoice`) and the scheme **DexNative (new engine)**. The tone section
and output router stay, because the engine runs them: their AVAudioEngine wrappers moved into the tests
(`Tests/DexAudioTests/Support`), which still check their sound against Electron's maths.

The tests lost their current-engine branches and keep the replacement's, which are the checks listed above. Removed
with the old engine, because they only read it: the four `LiveClockTests` (replaced by `LiveOutputTests`), the two
`LoopAudioTests`, the launch ticket and launch timing tests, the tone graph test, Apple's speed-step test and the
shared loop buffer test.

One bug turned up and is fixed. The engine's 64 MiB cache was counted inside the 128 MiB preparation budget. Memory
pressure halves that budget, so after a memory warning nothing could have loaded for 30 s, and two engines alive at
once (a test closing one as the next opens) left loads failing. It's now fixed memory, counted on top of the limit
(`AudioMemoryBudget.reserveFixed`); `MemoryBudgetTests` checks both cases. It had shown up as the live
starts-and-seeks check failing in 3 of 9 runs on the Bose; after the fix it passed 4 of 4.

| After the removal | |
|---|---|
| `swift test` | 284 tests (39 + 58 + 32 + 155), 0 failures, 6 optional skips |
| App builds | Mac, iPad Simulator and iPad |
| `diff:native` | every screen within its budget |
| 100-cycle soak | passes; memory flat at 52.6–52.7 MiB after the cache fills |
| Live, muted, on the Bose, one minute, twice | no missed blocks; decks 0.002–0.005 ms apart; starts and seeks within 0.31 ms of the click |
