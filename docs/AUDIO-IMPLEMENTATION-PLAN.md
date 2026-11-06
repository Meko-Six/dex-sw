# Dex audio reliability and waveform implementation plan

Implementation handoff · 3 November 2026 · Mac and iPad equally important

## 1. Start here

This is the implementation brief resulting from a code audit, isolated failure probes, competitive research, and a product discussion with the user. The user is transferring the work to another agent because of credit limits. Do not spend the next session repeating the entire audit or stopping at another general plan. When given an implementation instruction, begin the first unfinished work package below, carry it through its checks, and maintain a concise record of remaining work.

Read this file, `HANDOFF.md`, `native/README.md`, and `docs/AUDIO-ARCHITECTURE-AUDIT.md`. Inspect any current agent instructions and git changes before editing. The audit examined production commit `b5ee5da9ffbefda46cdab7f7a778c0761e904be1`:

- `1d25036`: distortion/EQ/filter/gain-staging changes.
- `b5ee5da`: Bluetooth waveform-delay compensation.
- No production source or existing tests were changed during this chat. Documentation and isolated probes are the deliverables so far.
- At handoff, `HANDOFF.md` is modified and the audit/implementation documents are new, uncommitted files. Preserve them and any newer user work. Recheck HEAD; line numbers in the audit describe the reviewed revision.
- Standalone probe source and a compact evidence summary are in `docs/audio-audit/`. Full local logs are in ignored `out/audio-audit/`. The handoff ZIP includes those logs; another checkout will not have them unless transferred.

Current repository: `/Users/ando/dev/Dex`. Paths elsewhere in this document are repository-relative for portability. Temporary build directories from the audit are conveniences, not prerequisites.

## 2. User intent and scope

The user reported bass/EQ distortion and Bluetooth sound lagging the waveforms. Another agent's fixes sounded/looked correct to the user, but the user wants a reliable architecture rather than accumulating workarounds. Their explicit position was: **“If the entire audio system has to be rewritten, I don't care.”** The goal is reliability, efficient CPU/memory use, and appropriate reuse of established components—not a rewrite for its own sake.

Hardware and priorities:

- M3 MacBook Pro, macOS **27.0.1**.
- **Bose SoundLink Flex** Bluetooth speaker.
- **Mac and iPad have equal priority.** Existing project documentation names a 13-inch iPad Air M3 on iPadOS 27 as the primary tablet; verify the actual test device before claiming results.
- The user wants **full DJ functionality over Bluetooth**, including cue actions and scrubbing, with accurate visualizations. Preserve this product ambition while distinguishing physical response delay from software correctness and platform routing availability.
- The user reports that scrolling waveforms are a little **“jumpy.”** Smooth motion is explicitly in scope, alongside audio timing.
- The user wants to follow established DJ-app engineering rather than invent an unusual engine unnecessarily.
- This chat was authorized for audit/planning only. This plan contains no claim that the fixes have been implemented. A subsequent implementation request should use it as the working brief.

The implementation scope is native Swift in `native/`. Electron is frozen and retained as a reference/possible PC version. Do not delete or redesign it. Preserve the library, analysis data, and console unless a scoped change is necessary. New visible controls should first be represented in the HTML mockup, following the existing UI workflow. Internal performance improvements do not require redesigning the console.

## 3. Requirements versus proposed details

| Item | Status and handling |
| --- | --- |
| Reliability, resource efficiency, Mac/iPad parity, established engineering | Explicit user priorities. |
| Full DJ interaction and aligned waveforms on the Bose | Explicit goal. Measure behavior; do not promise removal of external-device buffering. |
| Smooth scrolling waveforms | Explicit user report and requested optimization plan. |
| Explicit split-output switch | User proposed a Traktor-like switch rather than automatic switching when CUE is pressed. This is the direction to develop. |
| Stereo / DJ split cable / multichannel output choices | Recommended concrete design from the discussion. Exact labels/placement are not a signed-off visual design. |
| Bluetooth recognition and notification | User proposed detecting Bluetooth and offering a mode. Recommended refinement: compensation automatic, with a discreet notice and per-output adjustment; do not require a prompt answer for basic alignment to work. Exact notice/controls remain design details. |
| Independent Bluetooth speaker plus separate headphone monitoring | Not demonstrated or established as universally available. It is an additional platform/output capability, not an automatic implication of Bluetooth playback. Investigate before promising it. |
| Keep AVAudioEngine and current playback nodes | Starting recommendation, conditional on meeting measured gates. No requirement to preserve a troublesome component at any cost. |
| Buy/license a DJ SDK | Not authorized or selected. A narrow technical evaluation can inform a later decision; do not commit to a purchase or dependency silently. |
| Whole-engine rewrite or immediate Metal renderer | Not the default. Replace a component if evidence shows that doing so is simpler/more reliable than further workarounds. |

There are no missing answers that prevent starting the regression, ownership, and profiling work. Ask focused questions later only when a material product tradeoff cannot be resolved from this brief. Do not repeatedly ask whether the user wants solid audio or equal iPad support—they have answered.

## 4. Preserve existing musical behavior

Read the complete behavior section in `native/README.md`. In particular:

- Two prepared streaming voices per deck; retain outgoing audio until a replacement is ready. Rapid input supersedes inaudible preparation; input during a fade is handled consistently. No audible gap or first-attack loss.
- Existing values are 30 ms paused-start lookahead, about 120 ms replacement pre-roll, and 10 ms fades. They are existing behavior, not proof of optimal latency. Benchmark them; do not arbitrarily change them while fixing queue correctness.
- Tempo range ±16%, key lock, sticky SYNC, master/follower tempo and beat phase, enabling SYNC mid-play.
- Main transport CUE: first-grid-beat default, paused cue snapping, hold audition, release return, PLAY latch, and the existing human timing windows. Main-CUE late tolerance is 150 ms capped at 30% of an output beat; hot-cue tolerance is 100 ms capped at 20%. Missed attacks must not replay late.
- Eight hot cues; recalling while playing preserves the deck's own 1–2–3–4 count. Capture positions against the audible timeline while rendering/sync calculations use an explicit render-time mapping.
- Loops ½–64 beats; growing keeps loop-in; shrinking keeps the subwindow containing the playhead. Invalid expansions preserve the old loop. Bar jumps preserve phase and move active loops.
- Audible vinyl scrubbing, up to ±8 source seconds/second, with inertia and appropriate play/pause restoration. A new transport action cancels stale jog work.
- Preserve three-band waveform appearance, shared centered playhead, cue/loop markers, and useful zoom behavior. Verify output-time zoom scales with deck rate as documented; `Screen.Lane` currently passes the common span directly, so do not assume the pure `WaveformViewport` helper is integrated everywhere.
- Keep the master-volume-before-limiter fix, flat-EQ passthrough, smoothed tone controls, and safe cue peak handling unless a measured replacement is introduced.
- Route loss must not unexpectedly resume music on speakers. Interruption resume remains conditional; held previews do not auto-resume. Preserve iPad background audio.
- Library persistence, grids, cues, tag work, and analysis accuracy must survive audio refactoring. Do not retune analysis to individual song failures.

**Existing split-output decision to revisit:** old documentation says “stereo until CUE, then mono split.” This is the behavior the current discussion identified as problematic. Preserve it as historical context, not as the desired new fixed split-cable contract. Update relevant documentation/tests when the explicit modes are implemented.

## 5. Evidence already obtained

### Confirmed defects

| Defect | Reproduction and implication |
| --- | --- |
| Playback commits before queued execution | Hold `AudioControlExecutor`, start a deck, continue offline rendering for 16 × 1,024 frames. The playhead reaches **0.311333 s while output peak is 0**. Gates/clock were committed before player startup. The injected stall is a failure-mode test, not a claim that ordinary queue delays are 341 ms. |
| Custom AU reset does not clear DSP history | Allocate isolator resources, set a low-pass sweep, render an impulse, call `reset()`, then render silence. Residual output peak **0.013661941**. Custom C filter state is not reset by the AU superclass. |
| Router reports success despite failed pulls | Return **−50** from its input pulls. Router render result is **0/noErr**. Failed inputs are silently replaced with zeros with no error indication through the render result. |
| Split-cable speaker feed changes with CUE | Current router produces stereo master without deck CUE, then folds to mono master/cue when CUE is selected. Through a physical split cable, the audience feed changes from master-left to an L/R mono sum. This is code-confirmed routing behavior, not a newly performed physical cable test. |

### Risks that were not reproduced as current audible failures

- Cue handoff identifies only a waiting frame count, not its timestamp/source range/generation. It assumes master-first pulling produced exactly the needed cue block. It is not a general cross-thread audio queue.
- Configuration notifications can be dropped during `startTask` or the startup quiet window. A genuine route change could be lost. This is a code-level race concern, not a reproduced device failure.
- Bluetooth compensation subtracts one cached hardware estimate from a predicted clock. It does not solve the startup defect, model every processing path, or explicitly represent buffered output draining after pause/stop.
- The original distortion explanation is not isolated. The user heard the fix, but multiple changes landed together. Apple supports one-to-many graph connections; “stateful units cannot fan out” is not a general framework rule.
- Waveform stutter was reported by the user. No physical frame-pacing measurement was made during the audit. The concrete code contributors are described below; identify their actual cost with Instruments.

### Passing checks and their limits

- Existing suite: **55 DexCore + 21 DexConsole + 123 DexAudio = 199 discovered, 195 passed, 4 optional checks skipped, zero failures.**
- Mac app and iPad Simulator builds succeeded, with signing disabled. They produced arm64/x86_64 binaries. One initial iPad build printed an inconsistent error while returning success; a subsequent structured build result reported success with zero errors.
- Optional muted live-clock check passed gate handover and jog resumption on the then-current default output. Reported delay was **15.83 ms**. This neither identifies the Bose as that output nor measures acoustic synchronization.
- Default 100-cycle endurance run failed **26 loop-bound assertions** with its four-second fixture. Treat this as a fixture/expectation problem; do not weaken valid loop-bound validation.
- Same 100-cycle endurance test passed with a **60-second synthetic track**. Physical-footprint samples: **17.89, 18.16, 17.42, 17.59, 17.69 MiB**. This is a short offline test process, not a full-app memory ceiling or multi-hour device certification.
- Additional cue probe varied 64/128/256/480/512/960/1,024-frame requests: no silent cue blocks among 169 observed after warm-up; exact-zero channel and master gains also passed. This does not prove all render-order/reset/error scenarios.
- Initial sandboxed audio tests could not register Audio Units, and one XCTest process aborted while handling errors. The unchanged suite passed with Core Audio access. Do not count that restricted-environment failure as an established app crash.
- Exploratory non-unity-rate DC-ramp “source position” estimates were rejected as unsuitable for conclusions. Do not reuse them as evidence of time-stretch latency. Use identifiable rendered attacks/content and proper timing measurements.

No physical Bose alignment, iPad audio/touch acceptance, split-cable/USB acceptance, multi-hour soak, or release-build CPU/thermal profiling passed during this chat. Static image tests do not certify smooth motion.

## 6. Code map

| File / area | What to inspect or change |
| --- | --- |
| `native/Sources/DexAudio/NativeDeck.swift` | `schedule`, `serviceTransitions`, `positionAt`, `refreshPosition`, tempo changes, loop history, suspend/reanchor. Intended clock/gates are currently updated before queued player execution. |
| `AudioControlExecutor.swift` | FIFO executor, cancellation tickets, `PlayerSchedule.apply`. Keep blocking framework work off UI/render threads; introduce deadline/readiness-aware scheduling. |
| `TransitionGate.swift` | `DeckVoice.stop/schedule`, queued player operations, retained loop lifetime, gate AU render/reset behavior. |
| `NativeMixer.swift` | Graph construction, Apple limiter order, routing fallback, start/finish generations, `installObservers`, recovery, meter. |
| `MixerUnits.swift` | Isolator/cue source/router custom AUs, scratch management, bus/format validation, reset and pull-error handling. |
| `native/Sources/CDexDSP/DexMixer.c` | LR4/sweep DSP, `DexCueTap`, router, cue peak guard. The cue store only tracks `waiting` frames. |
| `DexRamp.c`, `DexJog.c` | Bounded command queues and render state. Add correct lifecycle behavior without breaking ownership acknowledgements. |
| `OutputLatency.swift`, `AudioLifecycle.swift` | macOS HAL/iPad session route adapters, estimate validity, change observation and lifecycle policy. |
| `AudioMemoryBudget.swift`, `LoopAudio.swift`, `DeckJog.swift`, `DeckLoopController.swift` | Retained-buffer leases, cancellation, optional work admission, bounded caches. Preserve working safeguards. |
| `native/Sources/DexCore/Transport.swift` | Scheduled transport integration, history, cue timing/math. History currently prunes around one second. |
| `native/Sources/DexApp/ConsoleModel.swift` | 33 ms sleeping task, separate writes for A/B positions, meter updates, console rebuilding, settings/actions bridge. |
| `native/Sources/DexConsole/Gestures.swift` | Shared `ConsoleClock: ObservableObject`, `Live`/`LiveMeter` wrappers; broad observation of both positions and meter. |
| `TrackWave.swift` | Canvas, envelope allocation, per-column rectangles, whole-column `first` floor without fractional translation. |
| `Screen.swift` | Waveform/grid/loop/cue positioning, clipping, gestures, pixel snapping and viewport scale. |
| `TrackWindows.swift`, `Stage.swift` | Overview/static waveform invalidation, readouts, full-console scale transform/display density. |
| `native/Tests/DexAudioTests/` | AudioControl, Hardening, MixerRender, LiveClock, Continuity, SyncMeasurement, StretchMeasurement, cues/loops/jog/bar-jump regressions. |
| `native/Tests/DexConsoleTests/GestureMathTests.swift` | Waveform envelope sampling tests; currently not frame-pacing tests. |
| `mockup/xdj-mixer-alt.html`, `mockup/console.css`, native diff scripts | New route/timing controls and appearance verification. |

## 7. Target architecture

### One render-authoritative transport, with a separate presentation mapping

Use explicit time domains:

1. **Source position:** frames/seconds in the audio file, including loop folding and seek discontinuities.
2. **Render time:** output sample frame and host timestamp at which the engine produces audio.
3. **Presentation time:** estimated time that audio reaches the selected output/listener, including supported downstream delay.
4. **Display time:** intended presentation timestamp of the frame being drawn.

Do not mix host ticks, uptime seconds, display-link timestamps, file frames, and output frames implicitly. Establish and test conversions on both platforms. A player's consumed input position is not automatically the listener's position after time-pitch and output processing.

The UI issues intentions. A control owner prepares resources and schedules viable operations. The render side acknowledges effective state and progress. The presentation service derives audible position from acknowledged history, and the display evaluates it for the upcoming frame. UI polling must not drive audio correctness.

Illustrative data, not mandated type names:

```text
LaunchRequest:
  graphGeneration, deckGeneration, commandSequence
  requestedSourcePosition, requestedMusicalBoundary, pressHostTime
  preparationState, proposedRenderTime, cancellationState

RenderSnapshot:
  graphGeneration, acceptedCommandSequence
  renderedHostTime, renderedSampleFrame, sampleRate
  sourceTimelineAnchor, rate, loop/discontinuity identity
  actual transport state, bounded diagnostics

PresentationEstimate:
  routeIdentity, graphGeneration, referencePoint
  reported/validated delay components, optional calibration
  validity/unknown state, history coverage
```

Prepare before committing an outgoing fade. If scheduling misses its deadline, retain valid outgoing sound and replan to a reachable time/beat; do not leave a stale clock segment active. Merely waiting for a UI acknowledgement is insufficient if the main actor then stalls. Keep the effective schedule and render transaction coherent regardless of UI delivery latency. Latest-intent cancellation must also win if it arrives during a blocking framework operation.

Preserve meaningful distinctions between prepared/scheduled/rendering/paused/jogging/draining/unavailable states. Do not mark a silent waiting voice as audibly playing. Represent output draining after stop/route loss where measurable; specify how transport controls, saved cue positions, and visible playhead behave rather than smoothing over the difference.

### Master and cue need explicit audio ownership

The conceptual path is conventional: source → tempo/key processing → tone/trim → independent program and pre-fader cue sends → output mapping.

The current latest-copy handoff must become a formal render contract. Prototype either:

- a render-once custom AU/shared core with explicit timestamped outputs/cache of sample ranges; or
- a consolidated mixer render owner that calculates both buses from identified deck inputs.

Choose the simplest design that passes the tests. Do not create an elaborate general plug-in host or restore the old fan-out alone. Both branches must agree on source ranges even if a downstream effect buffers/pulls differently. Cover partial/range requests, duplicate pulls, generation changes, errors, and resets. Keep buffering bounded; a cache miss cannot masquerade as old valid cue data.

Maintain Apple’s limiter or an equivalently tested limiter. Cue protection, master gain law, and limiter bypass/headroom are separate audio decisions from channel mapping. A generic Apple EQ is not automatically equivalent to the existing LR4 isolator.

### Two independent configuration axes

**Output routing:**

| Mode | Stable contract |
| --- | --- |
| Stereo | Stereo master. No independent headphone bus on that same two-channel speaker output. |
| DJ split cable | Left mono master, right mono cue for Dex's defined cable assignment. Remain split even with no deck selected for CUE. |
| Multichannel interface | Stereo master and stereo cue on separately assigned channel pairs; default existing 1/2 and 3/4 where supported. |

Keep requested routing preference distinct from effective hardware capability. Do not overwrite user intent merely because a temporary two-channel route cannot provide four channels. A route change should safely pause and explain the effective fallback; never unexpectedly put cue material onto the audience output. A passive split cable is not reliably detectable just because the route has two channels, so selection must be explicit.

Only headphone-monitor CUE selection depends on available monitoring routing. The deck's main transport CUE retains its behavior. In split/multichannel mode, selecting a deck must affect the cue mix without changing master channel meaning/downmix. Preserve CUE MIX's meaning: 0 master, 1 selected pre-fader decks.

**Timing profile:** automatic route detection/compensation, with an optional per-output adjustment. Bluetooth is a route characteristic, not a second audio engine or a synonym for split output. Wired/USB paths also have nonzero latency and use the same correct timing infrastructure.

Suggested notice, not fixed UI copy: “Bose SoundLink Flex connected. Bluetooth timing compensation active.” Offer an adjustment/settings path. If the estimate is unknown, do not claim compensation is accurately active. Avoid repeated modal prompts. Any opt-in profile should select a deliberate interaction policy, not turn basic waveform correctness on/off.

Lookahead can prepare known file content or a future beat. It cannot foresee a user's next gesture or erase speaker buffering. For a press at `t`, preparation `P`, and downstream delay `L`, a new change cannot be promised audibly before roughly `t + P + L`. Choose the next reachable audible boundary; never replay a missed attack late. Immediate gesture feedback and delayed acoustic position can be separate, intentionally designed indicators.

## 8. Work packages and completion gates

### W0 — capture baseline and install meaningful regressions

1. Read current changes and instructions; use an isolated branch/worktree if appropriate. Do not undo the already successful audible fixes.
2. Reproduce the three confirmed defects from the supplied probe against the current revision, then turn them into maintained tests with real assertions and deterministic synchronization. Convert the probe; do not retain print-only output as a permanent pass criterion.
3. Fix endurance setup to use sufficient track length/valid regions or deliberately classify expected rejected requests. Preserve rejection behavior for invalid loops.
4. Add low-overhead generation/deadline/render-error diagnostics. Read/log them outside rendering. Record route, formats, OS/SDK, and estimate validity in test reports.
5. Capture a release-build waveform performance baseline on available devices before changing cadence or rendering.

**Gate:** the new tests expose the actual current defects, existing audio regressions remain understood, and there is a baseline recording of frame timing. Hardware absence should be recorded, not block deterministic work.

### W1 — fix scheduling ownership and effective-time transactions

1. Define ownership for graph/node control, preparation, render state, and UI observation. Consolidate conflicting framework calls, including remaining resets/graph construction on the main actor where they can block or race.
2. Ensure a voice is ready and the proposed launch remains reachable before committing clock/gate/fade state.
3. Define a deadline-miss policy for starts, continuous replacements, quantized cues, loops, and bar jumps. Keep outgoing audio and musical phase where appropriate.
4. Add acknowledged render snapshots/history. Reconcile time-pitch source-to-output mapping; do not assume AVAudioPlayerNode input consumption is final presentation position.
5. Preserve cancellation, retained-loop lifetimes, generation checks, and rapid supersession. Test mid-operation invalidation, not only cancellation before a queued closure starts.
6. Publish UI state from the resulting transport state, not merely the requested intent.

**Gate:** injected 10/30/120/350 ms control delays cannot falsely advance audible position or fade valid audio into a not-ready replacement. Tests continue rendering while the queue is stalled; they must not drain it first. Validate actual attacks/content through the production graph.

### W2 — implement custom AU lifecycle and formal master/cue buses

1. Add bounded reset operations for isolator filters/sweep, cue cache, router transient gain state, and gate queues/state as appropriate. Retain current target controls. Call superclass AU reset. Test resource allocation/deallocation/reallocation.
2. Invoke reset at deliberate discontinuity/lifecycle boundaries with safe ownership. Do not zero the shared active tone section on every normal crossfade.
3. Implement explicit master/cue range ownership using the chosen prototype. A `(frameCount)` check alone is insufficient.
4. Validate negotiated formats, supported buses/channel layouts, maximum frames, scratch bounds, and host-provided/nil output pointers. DSP currently assumes 48 kHz planar Float32 stereo; either enforce that contract or explicitly support other formats.
5. Define error behavior: safe output, no stale buffer replay, appropriate master render error propagation and/or diagnostic counters for optional branches. Do not swallow all errors as success. Combine silence flags correctly across inputs.
6. Keep the gain staging and smoothing changes unless listening/measurement warrants modification. Test hot two-deck material and both main/cue output peaks.

**Gate:** reset impulse→silence clears old history; error injection is observable; recovery does not emit old cue data; duplicate and changed-size pulls cannot process source state twice or select stale ranges. Existing frequency response, transient, cue, and limiter tests pass.

### W3 — explicit output modes and headphone-control behavior

1. Add typed routing state separating user preference, supported capabilities, and effective route. Remove CUE-selection-driven stereo/mono folding from split-cable mode.
2. Make split mode permanently mono master/cue on its assigned sides, independent of selected decks. Keep stereo mode permanently stereo.
3. Make multichannel mode available only with actual supported outputs and correct channel assignment; handle disconnect/reconnect safely.
4. Develop the small route-control changes in the HTML mockup first, then port them. Keep the console's style, spacing, touch targets, and help conventions.
5. Gate **headphone** CUE controls appropriately. Do not disable the transport CUE button or route a cue into speakers because headphones are unavailable. Define whether saved headphone selections are retained across route changes, with a safe effective-output policy.
6. Add left-only/right-only and uniquely identifiable deck fixtures. Verify that toggling headphone CUE never changes the master mix/downmix when channel faders and other master controls are unchanged.

**Gate:** fixed routing passes offline with no cues, each cue, both cues, master-only/cue-only/blends, exact-zero faders/master, 2/4-channel capability changes, and safe fallback. Physical split/USB checks remain explicitly pending until hardware exists.

### W4 — shared route-aware presentation and Bluetooth policy

1. Implement macOS Core Audio and iPadOS AVAudioSession adapters behind one presentation service. Identify the actual route/profile and use stable route identity where available, not a Bluetooth name heuristic.
2. Query documented node/device/session latency with explicit reference points and avoid double counting. Apple's `presentationLatency` contract includes device/stream latency; the old contrary comment is not sufficient reason to bypass it. Preserve HAL calculation only for a measured discrepancy with a documented fallback.
3. Handle unknown/partial/nonfinite reports as estimates with validity, not silent zero. Consider all relevant output streams for the active mapping rather than only the first stream.
4. Replace the arbitrary 750 ms cap/one-second history coupling with a supported delay/history budget and explicit out-of-range handling. Avoid unbounded history.
5. Refresh estimates on meaningful route/latency/graph changes on the control plane. No HAL queries inside each render callback or UI frame.
6. Coalesce configuration changes by generation/dirty state. Revalidate after startup instead of dropping changes during `startTask` or a time-based quiet window.
7. Define audio/presentation state during pause, stop, seek, cue return, output draining, interruption, and jog release. Correctness must not depend on a 30 Hz UI refresh.
8. Add remembered optional calibration for a stable residual. Clear/revalidate it on relevant route/profile changes. Calibration must not conceal queue drift or changing latency.
9. Add automatic Bluetooth status and a discreet notice/settings action. Do not require permission to maintain timing correctness on a recognized output. Do not enable split-cable routing just because a Bluetooth speaker has two channels.

**Gate:** a synthetic delayed-output model verifies acoustic-history mapping, boundaries, and controls; Bose acoustic acceptance separately verifies actual behavior on each platform. Unknown/variable latency is reported honestly. Route loss never causes unexpected speaker playback.

### W5 — smooth waveforms without sacrificing audio alignment

The user sees jumpy scrolling. The current code has three concrete contributors and one observation concern:

- `ConsoleModel.updateTicker()` does work then sleeps 33 ms. It is neither display-synchronized nor a precise fixed-rate timer. Around the default 12-second span, movement is approximately three stage points/update; at a four-second span, about nine points/update at unity rate.
- `TrackWave` computes `first = floor(start / perPixel)`, then draws at whole columns without carrying the fractional offset. Track-anchored samples are useful, but motion becomes quantized.
- Every Canvas draw allocates `columns * 3` floats and rebuilds three paths with one rectangle per nonzero column. At Retina widths this is thousands of rectangles per lane/update. The actual CPU cost has not been profiled.
- Shared `ConsoleClock: ObservableObject` emits changes for both deck positions and the meter. `Live`/`LiveMeter` may receive unrelated invalidations. SwiftUI can coalesce updates, so measure rather than asserting a fixed number of redundant draws.

Implementation sequence:

1. **Profile first.** Instrument frame interval distribution/hitches, actual presentation FPS, Canvas/envelope/path costs, allocations, and view updates in release builds. Include both decks, analysis, fader interactions, zoom, window scaling, and external-display/refresh changes where available.
2. **Display-linked cadence.** Introduce a platform adapter that supplies intended upcoming display timestamps. Use CADisplayLink or the applicable native display API; preserve macOS 13/iPadOS 16 floors with an appropriate fallback where APIs are newer. Evaluate the common presentation timeline for that display time. Do not turn up the existing sleeping task and declare the issue fixed.
3. **One coherent frame snapshot.** Sample both decks against one display timestamp. Keep observation local to moving content. Readouts and meters can update more slowly; static overview waveform geometry should not rebuild just because its progress marker moved.
4. **Continuous movement.** Keep track-anchored sampling/geometry, retain the fractional viewport remainder, and translate the waveform continuously. Include guard content at tile/column edges to avoid holes. Move beat/cue/loop overlays from the same transform; keep static borders/playhead crisp. Do not independently round each moving layer into inconsistent positions.
5. **Bounded render cache.** Reuse envelope/geometry or nearby image/texture tiles keyed by data identity, zoom/LOD, dimensions, effective display scale, amplitude/colors, and other relevant style. Rebuild only on invalidation or for newly entering content. Include the console's outer scale transform in density decisions. Cache nearby regions, not a full-resolution full-track bitmap.
6. **Prepare off the critical drawing path.** Use immutable completed cache entries; do not make drawing await decoding or background generation. Cap work in flight and discard stale requests on track/zoom changes. Maintain the existing compact waveform pyramid.
7. **Correct discontinuities.** A real seek, cue, loop wrap, pause, or rate change must follow its effective audio/presentation timestamp. Do not apply generic easing that drags the display behind the audio. Extrapolation between valid render anchors is useful; invented progress through a stalled engine is not. Bound extrapolation and handle stale snapshots explicitly.
8. **Measure again.** Start with stable 60 fps on supported displays; use higher refresh only where supported and sustainable. Respect low-power/thermal/inactive states. Do not assume every iPad is 120 Hz. Canvas can remain if it meets the gates; consider a small Metal renderer only if evidence still identifies drawing as the bottleneck.

Add deterministic tests for fractional movement, shared marker transforms, tempo-scaled viewports, discontinuities, and cache invalidation. Add runtime profiling/visual checks for smoothness. The existing snapshot/envelope tests cannot certify frame pacing.

**Gate:** on the M3 Mac and primary iPad, steady playback has even frame pacing at the chosen rate; no periodic freeze/catch-up, tile-boundary jump, or marker/waveform separation; correct audio alignment remains through Bluetooth and transport events. At 60 Hz the whole frame budget is about 16.7 ms; do not allocate it all to waveform drawing. Report measured percentiles/maxima and energy cost rather than only average FPS.

### W6 — compare components and certify the combined system

1. Run a narrow identical-task comparison against djay or another available reference on the same device and supported output: prepared cue recalls, short loops, scrub/release, key-lock tempo extremes, audiovisual alignment, CPU, memory, and sustained interaction.
2. Benchmark the current Apple player/time-pitch candidate before committing to a large custom transport rewrite. Fixed 30/120 ms preparation is not automatically an unavoidable Apple limit.
3. If meeting the gates requires increasing workarounds, prototype a proven DJ playback/DSP component (for example an established SDK) behind the same transport interface. Review compatibility, licensing, formats, memory, timing observability, and sound quality before selecting it. Do not rebuild a mature time-stretch algorithm unnecessarily.
4. Retain the same behavioral/recorded-audio tests around any replacement. A different engine must not silently redefine cues, loops, sync, or saved positions.
5. Profile release builds on both devices with two active decks, key lock, EQ/filter movement, loops/jog, library work, memory pressure, and a representative multi-hour session.

**Gate:** no unresolved correctness failure in the supported matrix; no continuing memory growth after warm-up; no render deadline misses in the controlled acceptance session; existing offline pitch/beat/continuity tolerances preserved; measured audiovisual alignment within the agreed display/route budget. These are proposed acceptance goals, not claims that current hardware already meets them. Establish sustainable CPU/thermal targets from measurements rather than inventing a universal percentage.

## 9. Validation matrix

| Dimension | Minimum coverage |
| --- | --- |
| Platform | Local Mac tests/build; iPad Simulator build; physical primary iPad audio, touch, lifecycle, and performance. |
| Output | Built-in/wired stereo; Bose Bluetooth stereo; DJ split cable; four-channel USB interface. Record unavailable hardware rather than simulating a physical pass. |
| Files | Mono/stereo, source-rate/output-rate mismatch (at least 44.1/48 kHz), representative supported compressed music. Include asymmetric channels and identifiable content, not identical clicks alone. |
| Rendering | Small/large/non-power-of-two quanta within contract; changed requests, repeated same-range pulls, nil output memory, injected pull errors, reset/reallocation. |
| Transport | Start/pause/stop, first attack, repeated seek, main-CUE hold/latch/release, hot-cue capture/recall, sync/master changes, tempo/key-lock, loop enter/resize/exit, bar jumps, jog/release/cancel. |
| Concurrency | Queue stalled while rendering continues; cancellation during blocking work; rapid supersession; two decks; UI busy; background preparation. |
| Lifecycle | Route change during startup/play/pause, disconnect/reconnect, sleep/wake, iPad background lock, interruptions and permitted resumption, services reset, memory pressure. |
| Visuals | All useful zooms, two decks, slow/fast tempo, fractional scale, resize/display changes, markers/loops, Bluetooth delay, seek/loop discontinuities, long steady motion. |
| Resources | Preparation leases + total process physical footprint, release-build CPU/render deadlines, drawing allocations, cache plateau, energy/thermal, inactive view behavior. |

Use source-tagged pulses or distinguishable beats to verify content and absolute output timing. Interdeck alignment alone can pass if both decks share the same offset. Acoustic verification needs a known reference/capture method and display timing measurement; do not label a muted gate test “Bluetooth synchronized.”

Existing snapshot budgets must not be raised just to pass. Preserve appearance where possible; intentional new controls or subpixel behavior need a documented reference update through the mockup workflow.

## 10. Commands, environment, and evidence portability

Normal required checks (run those relevant to each change; finish the native matrix at integration):

```sh
swift test --package-path native
xcodebuild -project native/DexNative.xcodeproj -scheme DexNative -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project native/DexNative.xcodeproj -scheme DexNative -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The project uses Swift 6, macOS 13/iPadOS 16 compile floors. Local audit SDK was Xcode 27.1; existing CI documentation says its SDK is older. Preserve cross-SDK Sendable handling and availability checks rather than raising floors accidentally.

Node is managed by **fnm**, pinned to major 24. Read `CLAUDE.md`; do not install another Node runtime or work around the project's Node setup. Use `npm run diff:native` for changed native/mockup visuals. Electron checks are necessary if shared/Electron files change; avoid unrelated Electron work.

If sandbox caches are unwritable, use task-specific writable scratch/cache locations. Example from the audit:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/dex-audio-audit-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/dex-audio-audit-module-cache \
swift test --package-path native \
  --scratch-path /private/tmp/dex-audio-audit-build \
  --cache-path /private/tmp/dex-audio-audit-cache \
  --disable-sandbox
```

`--disable-sandbox` here disables SwiftPM's package sandbox; it does not provide host/Core Audio service permissions. Use the environment's legitimate permission mechanism if Audio Unit registration/services are unavailable. Do not reinterpret those failures as signal defects without rerunning with proper access.

Optional live and soak checks:

```sh
DEX_NATIVE_LIVE_CHECKS=1 swift test --package-path native --filter LiveClockTests

DEX_NATIVE_SOAK_CYCLES=100 \
DEX_NATIVE_REFERENCE_AUDIO=/path/to/a/suitable/long/synthetic-or-local-track.wav \
swift test --package-path native \
  --filter HardeningTests/testTwoDeckEnduranceWithLibrarySyncLoopsCuesAndRecovery
```

The existing live check mutes master output. Confirm it remains muted before running a modified version. Private music is not included in the handoff and is not needed for deterministic regressions. Listening exports use `DEX_NATIVE_REFERENCE_AUDIO` and `DEX_NATIVE_AUDIO_OUTPUT`; never commit music or recordings of private files.

The supplied standalone `docs/audio-audit/AuditProbe.swift` uses internal testable APIs and prints evidence; it is not wired into the package test suite. Its compiler/link command for the audit's Xcode build layout is retained in the evidence README. Other Xcode versions may place modules/objects differently. Prefer porting its cases to proper XCTest/Swift Testing tests rather than depending on temporary object paths. The probe uses a fixed temporary fixture filename; do not run multiple copies concurrently without changing it to a unique task path.

## 11. Research basis and boundaries

Use these primary sources as references. Detailed comparisons and citations are also in the audit. Research was read on 3 November 2026; recheck if implementation happens materially later.

- [Mixxx engine guide](https://github.com/mixxxdj/mixxx/wiki/Developer-Guide-Engine): callback-driven processing and real-time constraints.
- [Mixxx mixer](https://github.com/mixxxdj/mixxx/blob/main/src/engine/enginemixer.cpp) and [deck](https://github.com/mixxxdj/mixxx/blob/main/src/engine/enginebuffer.cpp): inspectable master/headphone processing and processed-source position. Reference engineering principles, not an assumption that every competitor has identical code.
- [djay split-cable documentation](https://www.algoriddim.com/hardware/precueing): mono split output and multichannel alternatives.
- [NI Traktor cable setup](https://support.native-instruments.com/support/solutions/articles/69000879493-how-to-use-the-traktor-dj-cable-with-traktor): explicit mono master/monitor routing. The exact iPad Traktor switch recalled by the user was not independently established.
- [djay iPad audio manual](https://help.algoriddim.com/user-manual/djay-ios/getting-started/audio) and [NI Bluetooth guidance](https://support.native-instruments.com/support/solutions/articles/69000880004-notes-on-using-bluetooth-speakers-headphones-with-ni-products): documented Bluetooth pre-cue/real-time limitations. This does not prove all possible app/hardware combinations are incapable of more.
- [Algoriddim/zplane interview](https://products.zplane.de/blog/karim-morsy-interview-algoriddim): licensed algorithm reuse; not a complete proprietary engine specification.
- [Superpowered AdvancedAudioPlayer](https://docs.superpowered.com/reference/latest/advanced-audio-player/): an example of a purpose-built DJ player contract and possible benchmark, not a selected dependency or proof that djay uses it.
- [Apple audio engine](https://developer.apple.com/documentation/AVFAudio/audio-engine), [AU reset](https://developer.apple.com/documentation/audiotoolbox/auaudiounit/reset%28%29), [output presentation latency](https://developer.apple.com/documentation/avfaudio/avaudionode/outputpresentationlatency), and [I/O presentation latency](https://developer.apple.com/documentation/avfaudio/avaudioionode/presentationlatency): framework contracts.
- [Apple display link](https://developer.apple.com/documentation/quartzcore/cadisplaylink) and [SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance): frame pacing and measured optimization.

Do not claim commercial apps all use AVAudioEngine, or all use custom C++ engines. Public material supports common architectural principles and some component disclosures. It does not expose every proprietary implementation. Swift versus C++ is not the decision criterion.

## 12. Delivery and stopping criteria

- Implement in reviewable work packages, with meaningful regression checks. Do not turn the whole plan into one unverified rewrite.
- Share concise progress: what is confirmed, what changed, what passed, and what remains dependent on hardware. Avoid repeatedly narrating unchanged test output or redoing research without a new uncertainty.
- Keep CPU-intensive analysis, cache generation, file I/O, and blocking framework calls away from the audio callback. No allocation, mutex wait, logging, async dispatch, or uncontrolled work in custom render code.
- Keep cache/command bounds, cancellation and buffer ownership explicit. Do not solve a timing problem by retaining full-track PCM or an unbounded waveform image.
- Finish software work that does not need hardware, then provide a concrete short physical acceptance checklist for the Bose/iPad/splitter/interface. The user previously had no splitter or USB interface; do not invent a pass or stall all development on their absence.
- Do not buy SDKs, install unrelated tools, alter personal audio routing, or launch audible tests without the relevant task authorization. Routine reversible code/test work should proceed within the implementation request.
- Update `HANDOFF.md`, `native/README.md`, and this plan's completion record as behavior changes. Separate completed implementation from remaining recommendations.
- Final report should state changed behavior, test/build results, measured resource/frame results, remaining physical checks, and any intentional musical/visual behavior change. Do not use “rock solid,” “optimal,” or “faultless” as a substitute for the measured scope.

### Initial implementation order

W0 → W1 → W2 → W3/W4 → W5 integration → W6. Waveform baseline profiling can happen during W0; its display integration should consume the shared presentation service from W1/W4 rather than creating a competing clock. AU reset/error fixes may be delivered early as an isolated W2 subset if they preserve active-render ownership. Explicit route UI can be designed while transport work proceeds, but final behavior must use the common routing state.

### Completion record

Sections 1–11 are the brief as written at transfer and stay as the record of that moment. Where they describe code or test state, this record is newer.

**At transfer:** all W0–W6 implementation packages were open, baseline audit, research and probes were complete, production code was unchanged, and this plan, the audit, the probe and evidence, and the entry in `HANDOFF.md` were ready for the next agent.

Order changed by the user on 3 November 2026: W0, the early W2 subset, the first W5 work, then a physical iPad pass before W1 and W2 change the engine.

**Done (branch `audio-reliability`):**

- **W0.** The probes are now `AudioAuditRegressionTests`. They reproduced the reset residual (0.013661941) and the swallowed router error before the fixes. The stalled-queue test stays as an expected failure until W1; it will fail loudly once W1 fixes the defect, as the reminder to remove the marker. The soak's default fixture is 60 seconds and passes 100 cycles at about 17.3–18.1 MiB. `AudioDiagnostics` logs the output, its reported delay, each launch's margin and failed pulls.
- **Early W2.** Isolator, cue tap and router `reset()` clear history and keep controls; the render thread does the clearing, so it is safe while rendering. It runs when the engine restarts. A failed master pull is now the render's error; a failed cue pull is counted and leaves the master playing. One input's silence flag no longer marks the whole output silent.
- **W5 steps 2–6, Mac.** Display link, per-deck clocks, fractional movement with markers on the same offset, bounded tiles. Tiles are built on the main thread when first needed (at most about 6 ms, once every few seconds per lane); step 6's off-thread preparation was not needed on the M3, so recheck it on the iPad.

**Waveform measurements** (`DexWaveProfile`, release build, M3 MacBook Pro at 120 Hz, two lanes, no audio; these time drawing, not light leaving the screen):

| 12 s zoom | Before | Display link, no tiles | Display link and tiles |
| --- | --- | --- | --- |
| Lane updates per second | 28.6 | about 51 | 60.0 |
| Update interval p50 / p95 / max | 35 / 37 / 38 ms | 17 / 34 / 52 ms | 16.7 / 20 / 25 ms |
| Movement per update | about 6 px (derived) | 2.9 px, up to 11 px | 2.91 px, at most 2.93 px |
| Uneven steps | not measured | 14–17% | 0.0% |
| Process CPU, one core = 100% | 21–28% | 27–29% | 30–32% |

The cause of the middle column's dropped frames: rebuilding thousands of rectangles a frame held up the main thread, so the display link itself fired late. SwiftUI's `TimelineView(.animation)` was tried first and gave the same uneven pacing for the same reason. Most of the remaining CPU is SwiftUI's view graph, not drawing.

A data point for W4: on the built-in speakers the HAL path reports 15.8 ms and `presentationLatency` 1.5 ms. On the Bose both report 253.2 ms.

**The user's listening check (3 November 2026, Mac on its built-in speakers):** the user reported no issues with waveform smoothness, waveform and sound sync, or transport and sound. This doesn't cover the Bose, an iPad, or a release build under measurement, and which transport actions were tried wasn't itemised. The W5 gate stays open.

**The user's Bose check (4 November 2026, Mac and physical iPad):** the waveform looked really good on both, smooth with no real jumps, with a slight offset under half a beat, similar on both. They accepted the fractional movement, which slides playing lanes and markers at 60 Hz, a deviation from the mockup's whole-pixel movement at 30 Hz; at rest they snap as before.

**Time-pitch delay found and allowed for (part of W1 step 4 and W4 step 2).** Measured acoustically on the Bose, the speaker's report was close: 257.5 ms heard against 253.2 ms reported. Through Dex's engine, the sound came 92.8 ms after the waveform. Muted live graphs traced that to `AVAudioUnitTimePitch`: about 85 ms (4096 frames) even when bypassed, 0 reported, and on any output; 75–90 ms across ±16% and key lock. Offline renders don't show it, so §5's passing timing checks couldn't. Dex's replacement pre-roll of about 90 ms already keeps recalled audio flowing when its gate opens, so the delay is uniform and the fix only moves the clock: `OutputLatency.stretchDelay` joins the delay used for what is heard. After it, the sound comes 13.6 ms after the waveform by mic, possibly up to about 20 ms more given the mic's control offset, and the muted `testLiveClockAllowsForTheStretchDelay` reads 0.9 ms. The user hasn't yet seen the fix, the iPad's delay hasn't been read, and jog audio, which skips the time-pitch, wasn't tested. It's a constant, so W1 or W4 should replace it with an acknowledged render position. See `docs/audio-audit/EVIDENCE.md`.

**The user's next pass (4 November 2026, Mac and physical iPad):** the waveform performs very well on both, and the iPad list was quite good with nothing really bad. They asked for far more scrub inertia. The app had been discarding the engine's coast by releasing with velocity 0, copying Electron, so a lane now flings on release, and a touch catches a coast at once. A first version used damping 1.2 instead of 4 at every zoom. On the iPad the user found it good but a little too much, and asked for half, scaled by zoom like a platter seen close up or far away. `JogFling` now gives one hand speed the same track distance at any zoom, with damping 2.4 at the 12 s default, the hardest flick at 3.33 s of track, and the lane's own speed starting the coast so pitch doesn't jump. §4's ±8 s/s limit still holds. The user tried the scaled coast and loves it, and the platter still stops where it lifts.

**W1's launch transaction (gate met on the Mac, 4 November 2026).** The user asked for W1 after their pass. Their Mac had logged no missed launches, so this is a scoped fix rather than a rewrite. Steps 2, 3 and 5 are done: gate ramps are held in the render until the control lane has started the player in time and armed them through a `LaunchTicket`, what is shown follows the old timeline until then, a miss changes nothing audible and is planned again from the original press, and a later press wins even mid-operation. `LaunchTransactionTests` covers starts, seeks, hot cues, bar jumps and loops at 10/30/120/350 ms with rendering continuing, and the old expected failure now passes. `testLiveLaunchesStayOnTheClockThroughControlStalls` really stalls the lane on a live output: medians within about 4 ms over three runs at 100%, 92% and 108%, with one unexplained 9 ms run at 92%. Step 1 is partly done: `stretch.reset` moved to the control lane, but graph construction and recovery rebuilds remain on the main actor. Step 4 is partly done: rendering now confirms how far it has got, which bounds what is shown when an engine stalls, but no source position is acknowledged, so `stretchDelay` stays a constant. Step 6 is partly done: position follows the effective transport, while PLAY stays lit from the press for button feedback. Not checked: the iPad, listening by the user, or Bluetooth with the stalls.

**Grid lock (added at the user's request, 4 November 2026).** The user's rule: the grid is the truth and the master is the truth; sound and display follow it. `AVAudioUnitTimePitch` rounds speed to steps of 1/512, so SYNC's follower slipped up to about 1 ms a second, unseen by clocks running on the asked speed. Clocks now run on the real speed (`playRate`), `holdLock` steers the follower between neighbouring steps and re-lands it on a real jump, Electron's master rules are ported, and a locked follower's lane is scaled to the master (mockup first). Offline, the sound holds within about 0.5 ms for 180 s through loops, jumps and master changes; live and muted on the Mac it doesn't drift over 2 minutes. Known limit: live, a deck off unity settles 3–14 ms early, differently per start, inside the time-pitch. It's steady and can't be read from outside, so it feeds W6's stretcher comparison. Not yet heard by the user; not measured on a physical iPad. Details in HANDOFF "Grid lock".

**The iPad's silence on the Bose (4 November 2026):** not W1. The Mac's Dex held the speaker with its idle output open; with the Mac's Bluetooth off the iPad connected well. This belongs with W4's route work.

**Open:** the rest of W1 listed above; the rest of W2, including formal cue ownership and format validation; W3; W4; W5's iPad measurement and its measured release-build run with real audio; W6. `Screen.Lane` still passes the common span, so tempo-scaled zoom remains unchecked.
