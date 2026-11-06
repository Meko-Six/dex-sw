# Engine rebuild: gates 1 and 2 results

For [ENGINE-REBUILD-SPEC](ENGINE-REBUILD-SPEC.md). Everything here was measured on 5 November 2026.

**Where it stands:** gates 1 and 2 are done and the user has listened. **Their verdict, 5 November 2026, on the
blind A/B against Apple's: "without doubt, bungee".** Bungee Basic stays and Signalsmith Stretch has been removed, so
Signalsmith's numbers below are the record of the comparison, not code that still exists. With Bungee alone, gate 1
reruns clean, and the one stricter check Signalsmith missed reads 0.17 ms.

**Devices.** "Mac" is the M3 MacBook Pro (Mac15,7, macOS 27, output set to its own speakers). "iPad" is the
13-inch iPad Air M3 (iPad15,5, iPadOS 27.0.1, its own speaker, 1024-frame output buffer). Gate 1 ran on the Mac only.

## What the design does

One callback makes all the audio, and a deck's position is read back from whatever is producing its sound.

Every jump is one thing, a **landing**: a voice starts on a chosen output frame and source frame, and a 10 ms
fade hands over to it. Seeks, hot cues, bar jumps, loop wraps, changing key lock and entering or leaving a scrub
all work this way.

A file is there to read ahead of the output, so a stretcher can be fully primed inside one block. That's what
replaces the old 30 ms and 120 ms pre-rolls: **there's no waiting at all, only the CPU to prime it.**

A deck still has two voices, because a fade needs something to fade from. Both are plain calls in the one loop,
so there's no launch to confirm, no retries and no hidden delay.

## Gate 1: the engine on its own, offline, clicks found in the sound (Mac)

The limit is 1 ms throughout. "Worst" is the largest error over every click in the run. Key lock off is the same
for both, because neither stretcher is involved.

| Measure | Signalsmith, key lock on | Bungee, key lock on | Key lock off |
| --- | --- | --- | --- |
| Clock against sound, 84% | 0.15 ms | 0.19 ms | 0.04 ms |
| Clock against sound, 92% | 0.65 ms | 0.09 ms | 0.11 ms |
| Clock against sound, 100% | 0.01 ms | 0.01 ms | 0.01 ms |
| Clock against sound, 108% | 0.76 ms | 0.11 ms | 0.06 ms |
| Clock against sound, 116% | 0.52 ms | 0.13 ms | 0.05 ms |
| Two decks, 180 s, through jumps, loops and master changes (443 beats) | 0.74 ms | 0.09 ms | 0.04 ms |
| Seeks and hot cues against the chosen frame, all tempos | 0.47 ms | 0.15 ms | 0.08 ms |
| Loop drift, ½, 1, 4 and 64 beats, at 92, 100 and 116% | 0.94 ms | 0.09 ms | 0.07 ms |
| Clock inside loops | 0.65 ms | 0.14 ms | 0.11 ms |
| Clock through tempo moves in small steps | 0.47 ms | 0.05 ms | 0.04 ms |
| Clock through instant jumps across the whole fader | **1.004 ms, a miss** | 0.17 ms | 0.10 ms |
| Changing key lock while playing, 28 changes | 0.79 ms | 0.14 ms | n/a |
| Entering and leaving a scrub, at 92, 100 and 108% | 0.81 ms | 0.10 ms | 0.06 ms |

**The miss:** the spec's own gate rows all pass. The row in bold is a stricter check added here, because the spec's point 6
asks for the position to hold through speed changes. Signalsmith reads 1.004 ms at worst when the speed leaps across the
fader in one step, up to 84% to 116%. A DJ's fader doesn't do that, and small steps read 0.47 ms. The limit stays at 1 ms:
the test records this as a known miss rather than passing it.

Also on the Mac, all passing:

- **No clicks on loops.** A join of two out-of-phase tones reads no more than 1.6 times the steady tone's roughness
  at ½, 1, 4 and 64 beats, on both stretchers, where a jump of 1% of full scale would be about 5 times it.
- **Any sample rate.** Files at 44.1, 48 and 96 kHz on 44.1 and 48 kHz outputs play at the right speed, within
  0.05%, with the clock within 0.47 ms.
- **Any block size.** 32 to 4096 frames land on the same frame.
- **Tracks bigger than memory.** 600 s of audio played frame-exact, every frame checked over 120 s, with room for
  44 s. Everything a DJ can reach stayed ready with 87 s of room on a 900 s track, and no jump waited.
- **A target not ready.** The outgoing audio plays on with no gap, then the landing comes in on the beat, attack
  whole. Over gate 1's runs this happened 0 times, except where a test held the loader back on purpose. Live
  rates are unknown until gate 3.
- **Real time.** Zero allocations in the loop through seeks, loops, scrubs, key lock changes, re-landings and
  unloading, with a control test proving the counter sees one. The loop's compiled code imports nothing that locks, logs
  or touches a file. PFFFT's `printf` is the one exception, and it's only in a self-test nothing calls.
- **Threads.** A render, loader and control thread flat out together show 0 reports under the Thread Sanitizer.

Tone, sweep, gains, routing and the cue's peak guard are `DexMixer.c`, unchanged, as plain calls. Apple's peak
limiter can't be called without a graph, so **the limiter is new**: a look-ahead design with a 2 ms look-ahead, which the engine
publishes so the position allows for it. Its sound against Apple's hasn't been compared by ear.

## Gate 2: the stretchers

### CPU, two decks with key lock on

One core is 100%. A deck jumps every 3 s on average. Decoding is left out of the timings, because the loader
does that on another thread. The worst single block is what could cause a dropout. Apple's rows have no landing,
because it can't prime: its cost shows up as delay instead.

| Mac, synthetic music, 256-frame blocks (5.3 ms each) | CPU | Typical block | Worst block | Blocks with a landing, worst |
| --- | --- | --- | --- | --- |
| Signalsmith Stretch | 1.5% | 23 µs | 1.80 ms | 1.22 ms |
| Signalsmith, cheaper preset | 1.3% | 66 µs | 1.23 ms | 0.75 ms |
| Bungee Basic | 1.4% | 72 µs | 0.46 ms | 0.33 ms |
| Apple time-pitch | 0.7% | 52 µs | 0.32 ms | n/a |

| Mac, real techno track at 44.1 kHz (Terra), 256-frame blocks | CPU | Typical block | Worst block | Blocks with a landing, worst |
| --- | --- | --- | --- | --- |
| Signalsmith Stretch | 1.9% | 37 µs | 2.44 ms | 1.71 ms |
| Signalsmith, cheaper preset | 1.6% | 84 µs | 2.15 ms | 1.22 ms |
| Bungee Basic | 3.3% | 170 µs | 1.32 ms | 0.88 ms |
| Apple time-pitch | 0.7% | 4 µs | 0.36 ms | n/a |

| iPad, synthetic music | Blocks | CPU | Typical block | Worst block | Blocks with a landing, worst |
| --- | --- | --- | --- | --- | --- |
| Signalsmith Stretch | 256 | 1.8% | 29 µs | 4.21 ms | 1.39 ms |
| Signalsmith, cheaper preset | 256 | 1.4% | 69 µs | 1.37 ms | 0.78 ms |
| Bungee Basic | 256 | 1.5% | 80 µs | 0.53 ms | 0.32 ms |
| Apple time-pitch | 256 | 0.6% | 49 µs | 2.01 ms | n/a |
| Signalsmith Stretch | 1024, its usual buffer | 1.5% | 383 µs | 1.68 ms | 1.20 ms |
| Signalsmith, cheaper preset | 1024 | 1.2% | 244 µs | 1.32 ms | 0.85 ms |
| Bungee Basic | 1024 | 1.4% | 289 µs | 0.61 ms | 0.51 ms |
| Apple time-pitch | 1024 | 0.6% | 119 µs | 0.35 ms | n/a |

All are small. The free stretchers cost about 2 to 5 times Apple's, on a figure that's tiny either way. The one
reading to watch is the iPad's 4.21 ms, against a 5.3 ms block. It was once, with no landing in it, and Apple
showed a 2.01 ms outlier in the same conditions, so the machine may have been busy. The iPad normally uses 1024-frame
blocks, where a block lasts 21 ms. These timings are of offline work, not a live audio thread.

Memory for four voices and the loop's scratch, on the Mac: Signalsmith 6.7 MiB, cheaper preset 6.4 MiB, Bungee 5.7 MiB.
The audio chunks are on top: 64 MiB by default, within `AudioMemoryBudget`'s 128 MiB once gate 3 reserves it there.

### Delay

| | Mac | iPad |
| --- | --- | --- |
| Apple, sound after its schedule, live and muted, at 84 / 92 / 100 / 108 / 116% | 91.0 / 88.1 / 85.4 / 83.1 / 80.8 ms | 90.9 / 88.0 / 85.4 / 83.0 / 81.0 ms |
| Signalsmith or Bungee in this engine, offline | none to allow for: the position is read from what's coming out (gate 1) | same design, gate 1 not run here |

Apple's three runs at each tempo agreed within 0.2 ms, on both devices. The constant the current engine uses
(`stretchDelay`) therefore holds on the iPad's own speaker, which hadn't been read before.

### Response to a change of speed

How long after a tempo change the sound's speed really changes, found by tracking a frequency sweep through the
stretcher. Offline. The clock allows for this delay, so what's shown stays with what's heard, and it only sets how soon a
tempo move or SYNC correction is heard.

| | Mac | iPad |
| --- | --- | --- |
| Bungee Basic | 21.5 ms | 21.3–21.5 ms |
| Apple time-pitch | 47–49 ms | 47–49 ms |
| Signalsmith Stretch | 65–68 ms | 65 ms |
| Signalsmith, cheaper preset | 95–97 ms | 95 ms |

### Time to first correct audio after a jump

From a press with no warning to the attack coming out, with the fade finishing on it.

| | Mac | iPad |
| --- | --- | --- |
| This engine, either stretcher, offline: press to attack | 9.5–10.4 ms, plus the wait for the next block | same |
| Apple time-pitch, live and muted: press to attack, median | 132–139 ms | 173–178 ms |

The wait for the next block is at most one block: 11 ms at 512 frames and 21 ms on the iPad's 1024. So a press could be heard
roughly 110–125 ms sooner on the Mac and 140–165 ms sooner on the iPad, before each output's own delay, which applies to all of
them. Hot cues and CUE that wait for a beat still wait for that beat, as agreed.

The Apple figure is a bare player and time-pitch pressed as fast as possible. The current engine's fixed 120 ms lead
is a separate design choice and wasn't measured here. One Mac press at 100% read 16.8 ms, most likely the outgoing
audio's own click still inside the time-pitch, so use the median.

An attack straight after a jump comes out at this level against the same click played through normally:

| Mac and iPad read the same | 92% | 100% | 108% |
| --- | --- | --- | --- |
| Signalsmith Stretch | 94% | 100% | 83% (about −1.6 dB) |
| Signalsmith, cheaper preset | 99% | 100% | 102% |
| Bungee Basic | 101% | 100% | 101% |

## What the numbers say, and don't

Bungee has the steadiest timing, the quickest response and the smallest CPU spikes, but costs the most CPU on real
music. Signalsmith is lightest on real music, but slowest to respond, closest to the 1 ms limit, and softens an attack
slightly straight after a jump at 108%.

**None of this says how they sound, and that decides it.** All three pass on the numbers that matter for a go-ahead.

Not checked, so don't report as passed:

- The engine on a real output, live. That's gate 3.
- Gate 1 on the iPad. Only gate 2's measurements ran there, and the engine's CPU, speed and jump timings there were offline.
- Bluetooth. The measurements used each device's own speakers.
- CI's older Xcode. Nothing was pushed, so the C++20 in Bungee and the new test target haven't met it.
- One thing unexplained: the first full iPad run was stopped by the system (signal 9) as it reached the live checks,
  with no crash log. The live checks then ran cleanly alone, using Apple's engine only.

## Clips

84 clips, 554 MiB, in `out/engine-clips/` (ignored by git), with a page to compare them, `listen.html`. Four tracks: two
psytrance (Goa-style and Eden), two techno (Terra, I Use To Dance In The Rain). Each has 24 s at 84, 92, 96, 100, 104, 108
and 116%, through Signalsmith Stretch (default preset), Bungee Basic and Apple's time-pitch. All have key lock on, 48 kHz,
24-bit, with no EQ, fader or limiter.

Each set starts on the same source frame and is matched in loudness to Apple's. Two things are worth knowing. Apple's speed
is rounded to steps of 1/512, so at 96% it runs slightly fast, and that set's versions read up to 15 ms apart overall; at
the other tempos they read within about 8 ms, on loudness shapes that differ anyway. And each set was pulled down together
to avoid clipping, so don't compare level between tempos.

Rebuild them with:

```sh
swift run -c release --package-path native DexEngineBench clips --out out/engine-clips <files>
swift run -c release --package-path native DexEngineBench checkclips --out out/engine-clips
```

## The listening gate

Done: the user chose Bungee. These were the instructions:

1. Open `out/engine-clips/listen.html` in your browser. Use good headphones or the speakers you'd trust for a mix.
2. Pick a track and a tempo, press PLAY, and switch between A, B and C with the keys 1, 2, 3 while it plays. They're in
   a random order and the names are hidden.
3. Listen for what stretching damages: kicks and hats going soft or doubled, bass wobbling, pads and vocals turning
   watery or metallic. 92% and 108% are the most useful. 84% and 116% are the worst cases.
4. Press THIS ONE IS BEST for each set you try, then REVEAL.
5. Tell me: does Signalsmith or Bungee sound **at least as good as Apple's**? Which do you prefer, and is anything wrong
   with it?

If neither does, the rebuild stops here, as the spec says. Rubber Band's GPL version can be tried as a private
comparison if you want a third opinion: it would never be committed or shipped.

The clips in `out/engine-clips/` are from before Signalsmith was removed. Rebuilding them now gives Bungee and Apple's only.

## Measure it again

```sh
swift test --package-path native --filter DexEngineTests                    # gate 1, about 4.5 minutes
swift test --package-path native --sanitize=thread --filter testThreadsTogether
swift run -c release --package-path native DexEngineBench cpu --music <file>
swift run -c release --package-path native DexEngineBench speed
swift run -c release --package-path native DexEngineBench jump
swift run -c release --package-path native DexEngineBench live               # Apple's time-pitch, muted
swift run -c release --package-path native DexEngineBench memory
```

The iPad figures came from a throwaway app that calls `DeviceBench.run` (`Sources/DexEngineBenchKit`), since Xcode can't
run package tests on a device. It was removed from the iPad afterwards.
