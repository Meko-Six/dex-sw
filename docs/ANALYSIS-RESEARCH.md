# Audio analysis research: BPM, key, power and beat grids

Research compiled October 2026, grounded in Dex's existing pipeline
([detector.ts](../src/shared/detector.ts), [grid.ts](../src/shared/grid.ts),
[key.ts](../src/shared/key.ts), [loudness.ts](../src/shared/loudness.ts),
[camelot.ts](../src/shared/camelot.ts)).
Goal: the accuracy frontier for each analysis, what Dex already does well,
and concrete upgrade paths. Sources cited inline.

---

## Executive summary

| Analysis | Where Dex is | Accuracy frontier | Biggest wins available |
| --- | --- | --- | --- |
| Beat grid | Global comb fit over (period, phase) — right model for DJ use | ML systems hit 95–98 % beat F1 on easy/genre-matched sets but ~63 % on hard sets (±70 ms tolerance is NOT grid grade) | Separate bar/downbeat phase; honest ×½/×1/×2 hypotheses; masked evidence regions; sub-frame phase refit; piecewise-grid fallback |
| BPM | Autocorrelation + log-Gaussian prior, octave folding | 82–87 % ACC1 on GiantSteps (EDM) for SOTA CNNs | Run three independent tempo hyptheses, don't let the prior silently pick; freeze a whole-track period with quadratic/higher interpolation |
| Key | Spectral-peak chroma + Krumhansl–Kessler | 67.9 % exact / 74.6 % weighted (CNN) vs KeyFinder's 45.4 % exact baseline on GiantSteps | Tuning-frequency estimation (biggest single classical win); genre-appropriate profiles; energy-weighted frame voting; HPSS ablation |
| Power | Integrated LUFS, sample peak, PLR | Standard = add max 3 s short-term LUFS, true peak, LRA, and a bar-level energy curve | True peak (oversampled), short-term max, LRA, loudness/energy time series with section cues |

Cross-cutting conclusion: **the standard MIR scores (beat F1 at ±70 ms, ACC2
tempo, MIREX weighted key) do not measure DJ-grid quality.** For Dex, measure:
exact BPM/octave correctness, downbeat/bar-phase accuracy, median and 95th
percentile grid timing error, and drift over track duration — against hand-
checked grids. Synth fixtures prove the maths, not the accuracy on real music.

---

## 1. Beat grids (the crux)

### 1.1 What the accuracy numbers actually say

Beat F1 in the literature counts a hit within **±70 ms** — useful for MIR
comparisons, useless as proof that a grid stays tight for a long mix. In 2025
time, a 70 ms miss at 128 BPM is nearly a 15 % beat error; sync at 0 ms median
(the existing selftest target) sits far below what F1 can see.

Published results, all with ±70 ms tolerance, from
[Beat This (2024)](https://arxiv.org/html/2407.21658v1),
[BeatFM (2025)](https://arxiv.org/html/2508.09790v1),
[BEAST](https://arxiv.org/html/2312.17156v2) and
[BeatNet](https://arxiv.org/abs/2108.03576):

| System | Dataset | Beat F1 | Downbeat F1 |
| --- | --- | ---: | ---: |
| Beat This (CV) | HJDB (hardcore/jungle/DnB) | **98.2** | 96.6 |
| Beat This (CV) | Ballroom | 97.5 | 95.3 |
| Beat This (CV) | Harmonix | 95.8 | 90.7 |
| Beat This (CV) | RWC Pop | 96.1 | 93.7 |
| Beat This (CV) | **SMC (hard)** | **62.7** | — |
| Beat This | GTZAN (test) | 89.1 | 78.3 |
| BeatFM (MERT backbone) | GTZAN | 89.5 | 79.6 |
| BeatNet (online, causal) | GTZAN | 75.4 | 46.5 |

Readings:
- High scores on genre-matched, regular-signal sets (Ballroom, HJDB) do not
  transfer to a full modern house/techno/psytrance catalogue — no published
  benchmark exists for that.
- SMC at 62.7 % even for the strongest open model is a reminder that the task
  is not "solved" on hard audio (live/ambient/odd tempos).
- No apples-to-apples published accuracy exists for
  Essentia `RhythmExtractor2013`, librosa `beat_track`/PLP or aubio as DJ grid
  generators; docs describe algorithms, not measured grid accuracy.

### 1.2 The structural insight: grids and beat sequences are different products

For sync/loop/quantise, a **straight constant-tempo grid** is the deliverable —
which Dex already builds via global comb fit plus robust line refit. That is
the right model and matches how djay Pro ships its Straight/Dynamic grid
types. Continuous trackers' local beat sequence is *evidence*, not output.
Forcing every locally-detected beat into the exported grid encodes detector
jitter and worsens long-range sync.

Policy from the commercial editors
([djay](https://help.algoriddim.com/user-manual/djay-pro-mac/dj-tools/beatgrids-bpm-sync/beatgrid-editor),
[Traktor](https://support.native-instruments.com/support/solutions/articles/69000879457-how-to-set-beatgrids-in-traktor),
[Serato](https://support.serato.com/hc/en-us/articles/227627008-Adjust-Incorrect-Beatgrid)):

- Straight grid by default; piecewise anchors only for real tempo changes.
- Beat phase and **bar/downbeat phase stay separate** — beat position can be
  right while the bar numbering is wrong.
- Breakdowns/sparse kicks: keep the established grid, never re-derive phase
  from a dropout.
- Silence and long DJ intros must be **masked out** of tempo/phase evidence.
- Grid origin belongs at the track's true rhythmic start, not t=0.

### 1.3 Tempo: octave handling is the #1 practical failure

Published GiantSteps (664 Beatport EDM previews) tempo numbers, from
[the self-supervised tempo paper](https://arxiv.org/html/2401.08891v1):

| Method | ACC1 | ACC2 |
| --- | ---: | ---: |
| Böck model | 87.0 % | 96.5 % |
| Schreiber CNN | 82.1 % | 97.1 % |
| Percival | 50.6 % | 95.6 % |

ACC1 = within 4 % of annotated tempo; ACC2 additionally accepts metrical
alternatives. The huge ACC1↔ACC2 gap says: everyone finds *a* pulse, many
choose the wrong **octave** — the same trap Dex's TEMPO_HINTS presets exist
for. Conclusion: never let one prior silently decide. Keep ≥3 ranked hypotheses
(½×, 1×, 2×), score them on kick periodicity, clap/snare placement,
subdivision density and envelope agreement, and expose the alternative.

### 1.4 Phase estimation best practice

For candidate period P, grid tₙ = φ + nP; estimate φ modulo P by circular
statistics:

  φ = (P/2π) · arg( Σᵢ wᵢ · e^(j·2π·tᵢ/P) )

with onset candidates trusted, weighted, and outliers rejected via a wrapped
robust loss (Huber on distance to nearest grid point). Procedure:
1. Period candidates first (incl. half/double).
2. Phase search over one beat period per candidate; score a repeated comb.
3. Robust, confidence-weighted phase fit over **trusted regions only**.
4. Refit period+phase alternating; inspect residuals vs time:  a trend means
   BPM error, a step means an edit/tempo change, scatter means onset noise.
5. **Bar phase estimated separately modulo 4P** — the loudest kick is not
   necessarily bar 1.
6. Keep a user-editable grid origin.

Dex already implements the core of this (global comb fit, circular-mean phase
estimate inside `fitGrid`). The gaps vs this literature: no separate downbeat
decision, no evidence masking, no residual-trend segmentation, coarse 1-frame
(11.6 ms) phase granularity, no ×½/×2 ranked proposition.

### 1.5 Kick emphasis and HPSS — test, don't assume

Maintain parallel evidence rather than collapsing to one detector:
full-band flux; low/bass-band flux (already partly present as `lowFlux`);
mid/high percussive flux; optionally an HPSS (harmonic/percussive separated)
envelope. Kick emphasis is a weighted cue, never the sole detector —
sidechain pumping, sub energy and syncopated kicks mislead. No published proof
that HPSS or low-frequency emphasis alone improves DJ-grid grade accuracy
([librosa HPSS example](https://librosa.org/librosa_gallery/auto_examples/plot_hprss.html));
bench against Dex's own hand-checked grids.

### 1.6 Upgrade path for Dex (ranked)

1. **Downbeat as a first-class field.** Store `barPhaseBeats` (0–3) in the
   grid; estimate it separately from beat phase. Without it, bar-aligned
   loops/sections on tracks whose "grid line 0" isn't a downbeat are wrong.
2. **Evidence masking.** Compute an energy/loudness mask; exclude silence and
   below-threshold regions from the comb fit; place grid origin at rhythmic
   start. This is likely the single biggest real-world grid win in the
   existing dependency-free pipeline.
3. **Ranked BPM hypotheses.** Report ½×/1×/2× predictions with scores in the
   analysis result, so UI/library can flag ambiguity instead of committing.
4. **Sub-frame phase + higher-period interpolation.** The quadratic
   interpolation on the autocorrelation peak is a start; do the same for the
   comb-fit period/offset (parabola over the fine scan scores) to push grid
   resolution from ~11.6 ms toward ~1–2 ms.
5. **Residual-trend segmentation.** After the global fit, look for
   piecewise-tempo sections; propose anchors (djay/Traktor style) rather than
   distorting one global fit.
6. **Optional ML second opinion.** `Beat This` (MIT licence, ~78 MB main /
   8.1 MB small weights, [repo](https://github.com/CPJKU/beat_this)) is the
   strongest open candidate for an ONNX/fixed-point comparison inside a
   worker; treat its output as another hypothesis, not an oracle.
   ONNX Runtime Web works in Electron ([docs](https://onnxruntime.ai/docs/tutorials/web/)).
   madmom is BSD code but its pretrained weights are CC BY-NC-SA 4.0 —
   commercial use needs permission
   ([licence](https://github.com/CPJKU/madmom/blob/main/LICENSE)).

---

## 2. Key detection

### 2.1 Benchmark (GiantSteps = 604 EDM excerpts)

From [the 2017 EDM-CNN paper](https://arxiv.org/html/1706.02921),
[KeyMyna (2026)](https://arxiv.org/html/2604.10021v1),
[S-KEY](https://arxiv.org/html/2501.12907v1):

| System | Exact key | MIREX weighted |
| --- | ---: | ---: |
| KeyFinder baseline | 45.4 % | 59.3 % |
| QM key detector (profile-based) | 39.6 % | 50.4 % |
| EDM template EDMA / EDMM / EDMT | 57.8 / 63.7 / 33.6 % | 65.6 / 70.1 / 44.6 % |
| EDM-trained CNN (2017) | 67.9 % | 74.3 % |
| All-conv genre-agnostic CNN | 67.9 % | 74.6 % |
| madmom CNN (replicated) | — | 71.0 % |
| S-KEY self-supervised (1 M songs) | — | 72.1 % |
| InceptionKeyNet | — | 75.68 % |
| KeyMyna (2026) | 72.0 % | 75.9 % |

Two lessons:
- **Genre fit matters enormously.** The EDM-trained CNN gets 74.3 weighted on
  GiantSteps while the same architecture trained on pop/rock gets 57.3 —
  and within profiles, EDM-derived EDMM (70.1) beats classical-profile EDMT
  (44.6). Krumhansl–Kessler's ~50–63 % zone is baseline territory.
- MIREX weighted score gives partial credit for related-key mistakes —
  for Camelot use, report exact tonic+mode accuracy separately.

Cross-check caveat: a 2020 crowd comparison put Mixed In Key 76.5 %,
Traktor 73.8 %, rekordbox 69.2 %
([Digital DJ Tips piece](https://www.digitaldjtips.com/best-dj-key-detection-2020/) —
informal, methodology not published). Commercial internals are undisclosed.

### 2.2 High-value improvements to the existing peak-chroma pipeline

1. **Tuning-frequency estimation.** Detuned (or 430 Hz-referenced) music
   smears energy between chroma bins and weakens profile correlation.
   Essentia's `TuningFrequency` does exactly this from spectral peaks
   ([ref](https://essentia.upf.edu/reference/std_TuningFrequency.html));
   estimate once per track, then correct the chroma mapping. This is the
   most defensible classical-pipeline gain.
2. **Genre-appropriate profiles.** Dex can cheaply add Essentia's documented
   profile set — the Shaath (Mixed In Key-style, pop/electronic-tuned) and
   EDMA/EDMM/Bgate EDM profiles ([Essentia Key](https://essentia.upf.edu/reference/std_Key.html))
   alongside Krumhansl–Kessler, choosing per-correlation or reporting the
   disagreement. Note: swapping to Temperley/Albrecht–Shanahan alone has no
   verified GiantSteps gain.
3. **Energy-weighted frame voting.** Equal per-frame normalisation gives
   quiet, weakly-tonal frames too much influence. Weight frames by harmonic
   energy/confidence; consider section-aware voting (rate stable::confident
   sections, don't hard-code "the drop decides" — no published evidence
   supports that).
4. **Band review.** Current 110 Hz–2 kHz has a defensible kick-rejection
   rationale (documented in key.ts), but the low cut also discards bass
   fundamentals that often define the root; reference points from the
   literature: Essentia's HPCP example uses peaks from 20 Hz–3.5 kHz; the
   CNN work uses 65 Hz–2.1 kHz with 24 bins/octave
   ([2018 CNN paper](https://arxiv.org/html/1808.05340)). Treat as an ablation.
5. **HPSS before chroma** as an ablation: harmonic-enhanced chroma is
   textbook ([FMP tutorial](https://www.audiolabs-erlangen.de/resources/MIR/FMP/C8/C8S1_HPS-Application.html))
   but unproven on heavily sidechained/distorted EDM.
6. **Top-3 candidates** (already implemented) is the right product shape.

### 2.3 Licensing notes

Essentia/Essentia.js is **AGPLv3** (commercial licence via MTG); pre-trained
models are CC **BY-NC** (ND or SA — the two Essentia pages disagree)
[licensing](https://essentia.upf.edu/licensing_information.html),
[models](https://essentia.upf.edu/models.html). KeyFinder is GPLv3.
For Dex (proprietary), the AGPL/NC paths require a commercial licence — so
the dependency-free pipeline plus classical upgrades above is also the
lowest-risk one.

---

## 3. "Power": loudness, dynamics and energy

Treat as **three separate things** (level, dynamics, musical energy) — never
one number.

### 3.1 Measurement set (what Dex has vs the standard)

| Measure | Status in Dex | What it gives the DJ |
| --- | --- | --- |
| Integrated LUFS (BS.1770-4) | ✅ [loudness.ts](../src/shared/loudness.ts) | Best playback-level comparator; basis of the ±12 dB gain suggestion |
| Sample peak | ✅ | Clipping detection; sample-based PLR |
| **True peak (≥4× oversample)** | ❌ add | Headroom safety; true-peak PLR. ITU-R BS.1770-4 annex; [Essentia true-peak](https://essentia.upf.edu/tutorial_audioproblems_truepeakdetector.html) |
| **Max short-term LUFS (3 s)** | ❌ add | "How loud does the drop get" — pairs with integrated for library-level loud comparison |
| Max momentary (400 ms) | (optional) | Diagnostics; too transient-sensitive for ranking |
| **LRA (EBU Tech 3342)** | ❌ add | Macro loudness spread (10th–95th pct of gated 3 s values); label it "loudness range", not "dynamic range" ([Essentia LoudnessEBUR128](https://essentia.upf.edu/reference/std_LoudnessEBUR128.html)) |
| PLR (peak − integrated) | ✅ (sample-peak based) | Label sample vs true-peak PLR distinctly |
| Crest factor | — | Only meaningful with a specified averaging window; prefer per-window peak−RMS curve |
| DR/TT-DR/TDR | avoid | Product-specific, not standards-comparable ([MAAT DR Meter](https://www.maat.digital/drmeter/)) |

### 3.2 Perceptual energy (the Spotify/Mixed In Key sense)

- Spotify's legacy `energy` (0–1) mixed dynamic range, loudness, timbre, onset
  rate, entropy — no formula published, and the endpoint is **deprecated**
  ([Spotify API change](https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api)).
- Mixed In Key ships a proprietary patented 1–10 Energy Level
  ([guide](https://mixedinkey.com/harmonic-mixing-guide/sorting-playlists-by-energy-level/)) —
  useful precedent for the UI, not a reproducible model.
- Essentia's learned danceability classifiers (790 k-parameter MusiCNN;
  0.93 normalised accuracy MSD / 0.91 MTT) are practical cheap candidates
  ([release notes](https://mtg.github.io/essentia-labs/news/tensorflow/2020/01/16/tensorflow-models-released/)),
  again under NC licences.
- A defensible dependency-free energy score: **bar-level energy curve** from
  beat-aligned short-term loudness + onset density + low-frequency energy
  share + spectral flux, aggregated into a track-level score. Keep it
  mastering-normalised and stored separately from raw loudness; store
  version/confidence with the score.

### 3.3 Structure: loudness curve ≠ section detection

Sections can change with zero loudness change (harmonic/instrumentation), and
a limiter can flatten a loudness curve. Proper structural segmentation uses
homogeneity/novelty/repetition over bar-aligned feature sequences
([FMP C4](https://www.audiolabs-erlangen.de/resources/MIR/FMP/C4/C4.html),
[barwise SSM paper](https://transactions.ismir.net/articles/10.5334/tismir.167)).
rekordbox phrase analysis (Intro/Up/Down/Chorus/Bridge/Verse/Outro) is the
commercial precedent and, importantly, its results are **editable**
([faq](https://rekordbox.com/en/support/faq/operation-hint/)).

Research frontier for DJ cue markers: CUE-DETR
([paper](https://arxiv.org/html/2407.06823v1)) — 4,710 EDM tracks, 380 h,
21,461 annotated cue points; best F1 **0.46** at one-beat tolerance. Even
SOTA learned cue detection is mediocre: propose cues as editable markers, do
not ship them as truth.

### 3.4 Suggested metadata schema

```
integrated_lufs          (existing)
sample_peak_db           (existing)
plr_sample_db            (existing, label "sample")
true_peak_dbtp           (new, ≥4× oversampled)
max_short_term_lufs_3s   (new)
lra_lu                   (new)
bar_energy_curve[]       (new — beat/bar-aligned energy + loudness + onset + bass share)
track_energy_score       (new — versioned, normalised, separate from loudness)
section_markers[]        (new — editable candidate intro/build/drop/breakdown/outro cues)
```

Priority: true peak → max short-term → LRA → energy curve. Keep integrated
LUFS as the gain-staging number; keep perceptual energy fully separate.

### 3.5 Run/wasm feasibility

Essentia.js (WASM backend, browser/Node/Electron) is viable for prototyping
[floats documented here](https://mtg.github.io/essentia.js/) and
[paper](https://transactions.ismir.net/articles/10.5334/tismir.111)) — but
AGPL + NC model licences make it a short-term benchmark tool, not a shippable
dependency for Dex. ONNX Runtime Web is the shippable path for specific
models (e.g. small Beat This) if one is added later; use CPU/WASM first,
quantise, and **re-test accuracy after quantisation** — it is not lossless.

---

## 4. Recommended evaluation harness (more important than any single upgrade)

Fix the metric before changing the detector:
1. Hand-check a musical test set: one constant-tempo house, techno, psytrance
   (145 BPM, half-time trap), hard trance, DnB (174 vs 87), plus one
   DJ-mashed/tempo-changing track; verified BPM, downbeat, drifted edges.
2. Metrics: exact BPM & octave correctness; downbeat/bar-phase accuracy;
   median + 95th-percentile grid-line error; drift (max deviation) over
   track length; key exact accuracy + top-3 hit; loudness cross-check
   against a reference meter (SoX/yohours/nayuki).
3. Every proposed change keeps the constant-budget pipeline: median-level
   stationarity, masked regions count, and confidence calibration checked
   (does low confidence actually predict user corrections?).

---

## 5. What was evaluated but could NOT be verified

- Standalone, same-set accuracy for `RhythmExtractor2013`, librosa
  `beat_track`/PLP or aubio as beat-grid generators.
- rekordbox/CDJ editor internals (manual is a PDF) and proprietary
  algorithms of Serato/Traktor/djay/rekordbox.
- A published proof that kick-band emphasis or HPSS improves DJ-grid-grade
  accuracy on house/techno/psytrance/DnB.
- A robust published per-subgenre GiantSteps key accuracy table.
- A controlled GiantSteps comparison of Krumhansl vs Temperley vs
  Bellman–Budge vs Albrecht–Shanahan profiles exactly as template matchers.
- Current MIREX leaderboards (pages unrendable at research time); paper-table
  numbers above are the best comparable results available.
