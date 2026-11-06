# Audio analysis research — executive summary

Condensed, action-oriented companion to the full report
([ANALYSIS-RESEARCH.md](ANALYSIS-RESEARCH.md)), which carries all source URLs
and the complete benchmark tables. Compiled October 2026.

**Why this matters:** Dex itself already runs an accuracy-first selftest that
measures real audio through the real deck engine. Nothing here replaces that
methodology — these findings are about extending it to analysis accuracy.

---

## TL;DR per analysis

| Analysis | Verdict on current Dex pipeline | Top three actions, ranked by expected accuracy gain |
| --- | --- | --- |
| **Beat grid** | Model (global comb fit) is the right one; gaps are in evidence handling and downbeat | 1. Mask silence/low-energy regions out of the fit. 2. Ship downbeat as a separate grid field. 3. Report ranked ½×/×1/×2 hypotheses instead of silent commitment |
| **BPM** | Autocorrelation + prior works, but octave choice is the known #1 failure everywhere | Same three as beat grid — they are the same problem. Add sub-frame period/phase interpolation (~11.6 ms → 1–2 ms) |
| **Key** | Peak-chroma + Krumhansl is baseline territory (~45–63 % exact) | 1. Per-track tuning-frequency estimation. 2. Genre-tuned profiles added alongside Krumhansl. 3. Energy-weighted frame voting |
| **Power** | Integrated LUFS + sample peak + PLR already done | 1. True peak (4× oversampled). 2. Max 3 s short-term LUFS. 3. LRA + bar-level energy curve |

---

## Full detail summaries

### 1. Beat grids — the priority

- **Standard beat F1 (±70 ms) is not DJ-grid quality.** The strongest open
  model ("Beat This", 2024, MIT licence) scores 97–98 % on easy/genre-matched
  sets (Ballroom, HJDB hardcore/jungle/DnB) but **62.7 % on hard audio
  (SMC)**. Published numbers cannot guarantee that a grid stays tight across a
  long mix; they don't measure phase offset, drift, or downbeat phase at all.
- **Grid ≠ beat sequence.** Continuous beat trackers produce local sequences;
  a DJ needs the *straight constant-tempo fit* that Dex already builds via
  comb fit + robust line refit. Commercial editors (djay Straight/Dynamic,
  Traktor, Serato) all treat the grid as the product and the tracker's beats
  as evidence. Dex's structural choice is validated by all of them.
- **The six concrete upgrade steps** (ranked, in the full report §1.6):
  1. `barPhaseBeats` (0–3) as a first-class grid field, estimated separately
     from beat phase.
  2. Energy/loudness mask — silence and DJ intros must not vote for tempo or
     phase; grid origin at the track's rhythmic start, not t=0.
  3. Ranked ½×/×1/×2 BPM hypotheses in the analysis result, flagged in
     library/UI rather than silently committed by the prior.
  4. Sub-frame phase + parabolic refinement on the comb-fit period and offset.
  5. Residual-trend segmentation → propose piecewise anchors for real tempo
     changes (never distort one global fit across them).
  6. Optional ML second opinion via ONNX Runtime Web (Beat This small ~8 MB,
     MIT). madmom is BSD code but non-commercial weights; Essentia is AGPL.
- **Breakdown rule:** never re-derive phase from a dropout or a sparse
  breakdown — keep the established grid, exactly as Traktor/Serato advise.
- **Caveat:** no published proof that kick-band emphasis or HPSS alone
  improves DJ-grid grade accuracy on house/techno/psytrance/DnB — treat both
  as ablations against Dex's own hand-checked grids.

### 2. BPM

- Tempo works through the same comb evidence as the grid; independent tempo
  algorithms are not needed for correctness — ranked hypotheses are. The
  GiantSteps tempo benchmark (664 Beatport EDM previews) shows SOTA methods
  hitting 96–97 % when metrical alternatives are accepted (ACC2) but only
  50–87 % when the exact octave must be right (ACC1). Octave discipline is
  the whole game, which is what TEMPO_HINTS presets currently handle manually
  per crate.
- Essentia's TempoCNN (~1.3 MB model, tempo only, no phase) is a compact
  external hypothesis source if an ML cross-check is ever wanted; its local
  estimates arrive roughly every 6 seconds, so it is slow-change advice, not
  a grid.

### 3. Key

- Baselines on the GiantSteps key benchmark (604 EDM excerpts): KeyFinder
  45.4 % exact; profile-based QM detector 39.6 %; genre-tuned templates
  (EDMM) 63.7 % exact / 70.1 % weighted; EDM-trained CNN 67.9 % / 74.3 %;
  2026 frontier (KeyMyna) 72 % / 75.9 %. **Genre fit dominates architecture** —
  the same CNN trained on pop/rock drops to 47–57 % on EDM.
- Highest-value changes to Dex's chroma pipeline, all framework-free:
  - **Per-track tuning-frequency estimation** — detuned (non-A440) material
    smears pitch energy between bins; this is the most defensible single win.
  - **Add Essentia's Shaath (Mixed In Key-lineage) and EDMA/EDM profiles**
    alongside Krumhansl instead of replacing it; report disagreement.
  - **Energy/confidence-weighted frame voting** instead of equal weights;
    rate stable sections rather than hard-coding "the drop decides" (no
    published evidence supports a fixed section rule).
  - **Ablate the 110 Hz–2 kHz band**: the kick-rejection rationale stands, but
    bass fundamentals that define the root are also being discarded
    (reference points in the literature: 20 Hz–3.5 kHz and 65 Hz–2.1 kHz
    with 24 bins/octave).
- MIREX weighted score gives partial credit for related-key mistakes; for
  Camelot use, always report exact tonic+mode accuracy separately.
- Commercial accuracy claims (Mixed In Key 76.5 % / Traktor 73.8 % /
  rekordbox 69.2 %, from a 2020 crowd comparison) are informal and
  method-undisclosed; treat as rough context only.

### 4. Power (three separate things — never one number)

**Implementation update, 2026-10-30:** `shared/power.ts` now provides a versioned,
bar-level musical intensity estimate. Normal imports/re-analysis and the crate
importer save it with integrated LUFS, suggested gain and sample-peak PLR;
older entries are backfilled on load. ENERGY colors both scrolling lanes and
track overviews on the same palette, with a 0–100 current-section readout.
The default 3BAND view instead overlays blue bass, orange mids and white highs;
both display modes use equal brightness before and after the playhead.
The implemented features are relative RMS band power, band-envelope attack
density, bass share and treble share, not short-term LUFS or a learned
classifier. Synthetic tests cover gain invariance, density, section contrast,
stereo phase and sample rates; supplied-track checks are sanity checks with
no human energy labels. True peak, LRA, max short-term LUFS and editable
phrase suggestions below remain future work.


- **Level** = integrated LUFS (already in loudness.ts, correct BS.1770-4
  implementation with the single-offset fix). Add **true peak** (≥4×
  oversampled inter-sample estimate) and label sample-vs-true-peak PLR
  distinctly.
- **Dynamics** = **LRA (EBU Tech 3342, 10th–95th percentile of gated 3 s
  short-term loudness)** plus **max 3 s short-term LUFS** ("how loud does the
  drop get"). Avoid DR/TDR/crest factor without a specified method — they are
  not standards-comparable.
- **Musical energy** = separate, versioned, mastering-normalised score built
  from a **bar-level energy curve** (beat-aligned short-term loudness + onset
  density + low-frequency energy share + spectral flux), aggregated to a
  track score. Spotify's energy feature (deprecated API) and Mixed In Key's
  patented 1–10 level are concept precedents only; no formula is public.
- **Structure:** loudness curves are not section detection. Sections can
  change with no loudness change; limiters flatten curves. Even SOTA learned
  cue detection (CUE-DETR, 4,710 EDM tracks) reaches only ~0.46 F1 at one-beat
  tolerance — so ship section markers (intro/build/drop/breakdown/outro) as
  **editable suggestions**, the way rekordbox's phrase analysis does.

### 5. Licensing (blocks several shortcuts)

| Dependency | Code | Models/weights | Usable as shipped dependency? |
| --- | --- | --- | --- |
| Essentia / Essentia.js | AGPLv3 | CC BY-NC (pages disagree on ND vs SA) | No — needs commercial licence from MTG |
| madmom | BSD | CC BY-NC-SA | Weights need permission |
| KeyFinder | GPLv3 | — | No |
| Beat This | MIT | MIT | **Yes** (ONNX export needed) |
| BeatNet | CC BY 4.0 | implicit | Review before product use |

Conclusion: the dependency-free classical upgrades are also the lowest-risk
shippable path; use Essentia.js only as a local prototyping/benchmark tool.

---

## Suggested metadata schema additions (§3.4 of full report)

```
true_peak_dbtp           (≥4× oversampled)
max_short_term_lufs_3s
lra_lu
bar_energy_curve[]       (bar/beat-aligned energy + loudness + onset + bass share)
track_energy_score       (versioned, normalised, separate from loudness)
section_markers[]        (editable candidate cue points)
barPhaseBeats            (grid field — which beat is the downbeat, 0–3)
```

Priority: true peak → max short-term → LRA → energy curve → section markers.

---

## What was checked but could NOT be verified (do not cite as fact)

- Same-set standalone accuracy for RhythmExtractor2013, librosa
  beat_track/PLP or aubio as *grid* generators.
- Proprietary internals of Serato / rekordbox / Traktor / djay.
- Published proof that HPSS or kick-band emphasis improves DJ-grid-grade
  accuracy on house/techno/psytrance/DnB.
- A controlled GiantSteps comparison of Krumhansl vs Temperley vs
  Bellman–Budge vs Albrecht–Shanahan as pure template matchers.
- A per-subgenre GiantSteps key accuracy table.
- Current MIREX leaderboards (unreadable at research time).

---

## The decision that outranks all upgrades

**Build the accuracy evaluation harness first** (full report §4): hand-checked
real-music test set (house, techno, psytrance incl. 145/half-time, hard
trance, DnB 174-vs-87, plus one DJ-mashed variant), measuring exact BPM +
octave correctness, downbeat/bar-phase accuracy, median and 95th-percentile
grid-line error, drift over track length, key exact + top-3 accuracy, and
confidence calibration. Synthetic fixtures prove the maths; they do not prove
accuracy on real music, and every change above should be scored with it.

---

## Raw research transcripts

The three underlying researcher reports (all source URLs, full tables, and
details on every paper read) are in the conversation that produced
[ANALYSIS-RESEARCH.md](ANALYSIS-RESEARCH.md); that file is the archival copy
worth keeping, and this summary is the working copy.
