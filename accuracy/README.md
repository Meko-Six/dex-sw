# Accuracy bench

`npm run accuracy` runs Dex's **real** detector, key and loudness code over a
folder of tracks and compares each result against hand-checked answers, printing
a scoreboard. It is the layer the unit tests and the in-app self-test cannot be:

| Layer | Proves | Runs |
| --- | --- | --- |
| Unit tests (`npm test`) | the maths, on synthetic audio | everywhere |
| In-app self-test (`?selftest=1`) | playback: sync, loops, EQ, crossfader | in the app |
| **Accuracy bench** (`npm run accuracy`) | the *analysis* is right on real music | here |

The synth fixtures prove the maths; only real, hand-checked music can catch a
wrong BPM octave or a grid that drifts over the length of a track.

## Building the manifest from the files' own tags

```bash
npm run accuracy:manifest          # scan accuracy/audio → accuracy/manifest.json
```

Beatport-encoded files carry `TBPM` (tempo) and `TKEY` (key) in their tags, and
this builds the manifest from those plus an **independent** loudness measurement
(ffmpeg's `ebur128`, not Dex's own meter). Re-running preserves any `downbeatsSec`
and `notes` you have already filled in (`--force` drops them). Files missing a
`TBPM`/`TKEY` are listed as gaps to set by hand.

**Caveats on tag-sourced truth.** `TBPM` is integer-rounded, so "exact" allows
±`bpmToleranceBpm` (0.5 by default) and cannot prove sub-BPM precision — grid
*drift* from your marked downbeats is what catches that. `TKEY` comes in two
flavours (note names like `D#min`, and Camelot codes like `6A`; both are
handled), and it is itself an automated annotation, not ground truth: treat a
key miss as "disagrees with Beatport", not "Dex is wrong". Some entries are
plainly wrong (one file here is tagged `Unknown`, another lists 99 BPM for a
~148 BPM track).

## Adding a track

1. Put the audio in `accuracy/audio/` (git-ignored — copyrighted music is never
   committed) or anywhere, and point `file` at it (relative to this folder, or
   absolute).
2. Add an entry to `manifest.json`:

```json
{
  "id": "house-01",
  "file": "audio/house-01.flac",
  "genre": "house",
  "truth": {
    "bpm": 124.0,
    "key": "F# major",
    "camelot": "11B",
    "downbeatsSec": [0.483, 14.997, 29.516],
    "lufs": -6.4
  },
  "notes": "half-time intro; kick drops at 0:32"
}
```

- **`bpm`** — the true tempo. This is also how the bench tells an *octave* error
  (½× or 2×) from a genuine miss. When the tag is wrong or missing and the hand
  marks give the tempo, also set **`"bpmSource": "marks"`**: the manifest
  builder then keeps it instead of overwriting it with the tag.
- **`key` / `camelot`** — the true key. Either is enough; `camelot` is used for
  the "related key" test, and is derived from `key` if omitted.
- **`downbeatsSec`** — the time of a bar-1 **"one"**, hand-marked. Mark **at
  least three across the track** (start, middle, near the end) so the bench can
  measure drift as well as phase. One is enough to check phase alone.
- **`lufs`** *(optional)* — true integrated loudness from a reference meter
  (`ffmpeg -af ebur128=peak=true -i file -f null -`). Omit and the loudness row
  reads "not checked".
- **`genre`** — selects a `TEMPO_HINTS` preset; use `"auto"` when unsure.
- **`tempoChanging: true`** *(`truth` object)* — a DJ-mashed / tempo-changing
  track. It is printed but kept out of every aggregate, because a constant grid
  cannot fit it.

## Marking downbeats in Audacity

Grid and downbeat scoring need beat times marked by a person. The bench checks
each mark against the **nearest beat line** of Dex's grid, so any clear kick
will do; it does not have to be the "one" of a bar. What matters is
precision: a mark is a hit within 15 ms, so place it by eye on the waveform,
never by tapping along.

For each track:

1. Open the file from `accuracy/audio/…` in Audacity.
2. Mark **four kicks**. Zoom in until you can see the attack, the point where
   the waveform jumps from near-flat to big, click exactly there and press
   **⌘B** to add a label (it needs no text):
   - one near the start, after any intro, where the kick is clear;
   - a second **8 bars (32 kicks) after the first**: this lets the importer
     count the beats, which the start, middle and end alone cannot;
   - one in the middle;
   - one near the end.
   Aim each mark at the **"one"** of a bar (the start of a phrase is easiest):
   the bench then scores the bar phase too. A mark a beat out is tolerated.
3. **File → Export → Export Labels…** and save it as
   `accuracy/labels/<track id>.txt`, where the id is the audio file's name
   without `.mp3` (for example `8757915_Traffic_Original_Mix.txt`).
4. Run `npm run accuracy:labels`. It writes the times into that track's
   `downbeatsSec` and leaves everything else in the manifest alone.

The importer checks the marks against the tagged BPM, which is independent of
Dex too. It counts the beats from the first mark outwards (the tag counts the
32-kick gap, that gap refines the tempo, which counts the next gap) and fits a
steady grid through all four:

- When every mark sits on that grid it prints the tempo the marks give, to
  three decimals, which the whole-number tag cannot.
- A mark more than 15 ms off it is named: it is on the wrong sound, or the
  tempo changes. A mark 90 ms or more off (a hat or snare instead of the
  kick) is caught almost every time. One 20-60 ms early or late often is not,
  because four marks can fit a slightly different tempo, so zooming in on the
  onset is what keeps the marks honest.
- A tempo more than half a BPM from the tag means the tag is wrong.

`--dry-run` checks without writing.

The label files are small and are your work, so they are committed.

### The shortlist

Ten tracks, picked to cover the cases the bench has to tell apart:

| Track | Why |
| --- | --- |
| `8757915_Traffic_Original_Mix` | Dex reads 83.34 BPM against the tagged 125: a 3:2 lock |
| `343063_Life_Is_A_Progressbar_Original_Mix` | tagged 99, Dex reads 148: the marks settle which is wrong |
| `4161659_Frequency_Original_Mix` | no BPM tag at all: the marks are the only reference |
| `8746648_Warehouse_Trip_Original_Mix` | techno, Dex's most confident grid (0.96): the control |
| `4281349_I_Use_To_Dance_In_The_Rain_Original_Mix` | techno, Dex's least confident grid (0.23) |
| `8752322_Our_Lights_Shine_Original_Mix` | Dex reads 125.97 for a tagged 126: does its grid drift? |
| `4109307_Generic_Drugs_Original_Mix` | psytrance, 134.94 for 135, and the lowest confidence (0.20) |
| `9085057_Colliding_Orbits_Ital_Remix` | psytrance, 143.05 for 143: drift the other way |
| `8867740_The_Raven_Original_Mix` | psytrance with a confident grid (0.76): the control |
| `741105_Drugs_and_Stuff_D_Nox___Beckers_Remix` | progressive at 127, between the techno and psytrance tempos |

A drift of a few hundredths of a BPM matters: 0.05 BPM over six minutes slips
the grid by about 120 ms, eight times the hit window.

## Reading the scoreboard

```
house-01             124.0/124.010 exact   grid 4.0ms/7.0ms  drift 9.0ms  beat ✓    key 11B✓  conf 0.96  LUFS -6.4 Δ+0.1
psy-halftime-01      145.0/145.020 exact   grid 9.0ms/22.0ms  drift 41.0ms  beat ✗ 28ms key 11A✓  conf 0.71  LUFS — 
```

- **BPM `truth/dex`** then the verdict: `exact`, `half`, `double`, `off` (close
  but past tolerance) or `other`.
- **grid `median`/`p95`** — distance from the detector's grid lines to your
  marked downbeats. A small median with a large **drift** means the tempo is
  slightly wrong and the grid slips along the track.
- **beat ✓/✗** — every marked downbeat lands within 15 ms.
- **bar ✓/✗** — Dex's "one" is right: more of your marks fall on the beat Dex
  calls bar 1 than on any other beat of the bar (so one mark a beat out does
  not fail it). A miss prints how many marks fell on each beat of Dex's bar,
  `0310` meaning three on Dex's beat 2 and one on its beat 3.
- **`? also …`** — Dex flagged the tempo as uncertain, and the readings it
  would offer instead, each with the share of kick salience it holds.
- **key** — `✓` exact, `~` in the top three, `≈` a harmonic neighbour
  (Camelot ±1 or the relative major/minor — mixable but not the same key), `✗`
  missed. Dex prints the Camelot code it chose.
- **conf** — Dex's own beat confidence, for the calibration check.

Dex's `offsetMs` is a downbeat (it is folded at the bar), so the bench scores
both whether your marks land on the grid and whether Dex's bar 1 is yours. The
summary adds a `bar` row and a count of tracks flagged uncertain.

`--marked` scores only the tracks with marks (about a minute instead of two);
`--no-hint` ignores each track's `genre`, which is how the app analyses today.

## Targets and failing

`targets` in `manifest.json` are the pass limits. The bench always prints the
scoreboard; it exits non-zero only when an aggregate breaches a target, so it
can gate a change once the numbers are good. Tighten them as the accuracy work
lands.

## Self-check

`npm run accuracy -- --self` scores the synthetic fixtures from
`npm run fixtures` (known-exact BPM and offset) — no music required, and the
only mode CI can run. Run it first: if the bench cannot score those, it is broken
before any real track is involved.

## Reference set

Aim for ~8–12 tracks covering what the analysis docs call out: constant-tempo
house (~124) and techno (~128); psytrance ~145 including one half-time
arrangement; hard trance ~146; drum & bass as both a true 174 and the 87 reading;
one tempo-changing / DJ-mashed track (`tempoChanging: true`); optionally one
non-A440 (detuned) track and one with a long silent intro.

Reports are written to `out/accuracy-report.json`.
