# Audit evidence index

Recorded 3 November 2026 on macOS 27.0.1 / Xcode 27.1, against production revision `b5ee5da9ffbefda46cdab7f7a778c0761e904be1`. No production source or existing tests were changed by the audit. The implementation plan contains the detailed conclusions and their limits.

## Durable diagnostic source

`AuditProbe.swift` is the exact standalone probe used for the final validated run. Its cases cover:

- Explicitly allocated custom AU resources, an impulse, reset, then silence.
- Failed router input pulls.
- A blocked player-control queue while offline rendering continues.
- Cue rendering across varied request sizes and exact-zero channel/master gain.

It is a print-based diagnostic, not an asserting regression suite. Its fixed temporary filename should be made unique if running concurrent copies. Internal APIs may change during implementation.

Final output:

```text
AUDIT reset residual after impulse+reset+silence: 0.013661941
AUDIT router input status=-50, returned status=0
AUDIT blocked schedule: display=0.31133333333333335, audio peak=0.0
AUDIT after queue release: display=0.6526666666666666, source time inferred from ramp=0.26464584
AUDIT variable quantum cue silent blocks=0/169
AUDIT cue with exact zero fader+master silent blocks=0/12
```

The silent-output/advancing-clock observation is the primary scheduling evidence. The subsequent ramp estimate is corroborating output at unity rate; do not generalize DC-ramp inference to non-unity time stretching.

## Full logs

In the originating workspace these are in ignored `out/audio-audit/`. The transfer ZIP includes them under the same path:

| Log | Meaning |
| --- | --- |
| `swift-tests.log` | Full existing suite: 199 discovered, 195 passed, four optional skips, zero failures. |
| `default-soak-and-live.log` | Default four-second endurance fixture has 26 invalid-loop assertion failures. Muted live clock test passes. |
| `long-fixture-soak.log` | Endurance passes for 100 cycles with a 60-second synthetic track; sampled footprint plateaus around 17.4–18.2 MiB. |
| `probes.log` | Final standalone diagnostic run above. |
| `mac-build.log` | Successful Mac app build, signing disabled. |
| `ipad-initial-build.log` | Initial build returns success but emits an inconsistent compiler diagnostic. |
| `ipad-build.log` | Follow-up iPad Simulator build explicitly succeeds. Structured result reported zero errors. |

Do not claim physical Bose synchronization, physical iPad runtime, smooth waveform motion, or split/USB listening was verified by these logs.

## Acoustic delay probe (4 November 2026)

`DelayProbe.swift` plays test clicks and records them with the built-in mic, both on host time. It opens the built-in mic explicitly, because opening the Bose's mic could change its Bluetooth mode. It keeps audio in memory and writes no recording. It needs the Mac's default output set to the Bluetooth speaker, Dex paused and a quiet room, and it's audible. To run it, put it in a package depending on `native`'s `DexAudio`, wrap the binary in a small ad hoc signed `.app` with `NSMicrophoneUsageDescription`, and start it with `open` so macOS asks for mic access for that app.

Its final "implied real delay" line ignores `stretchDelay`, so it reads too low since the fix. Use the "sound after waveform" figure. Results are in `HANDOFF.md`. The Mac speakers control read −3.7 ms against a reported 15.8 ms, so absolute figures may be up to about 20 ms low, though repeats agree to within 0.1 ms. This doesn't measure the screen's delay, and it hasn't run on an iPad.

The muted time-pitch comparison isn't kept as source. Its Dex-engine case is now `testLiveClockAllowsForTheStretchDelay`. That test, `stretchDelay` and the time-pitch itself went with the old engine on 6 November 2026; `DelayProbe.swift` now measures the replacement engine, whose figures are in [ENGINE-GATE3-RESULTS](../ENGINE-GATE3-RESULTS.md).

## Reproducing the standalone diagnostic

First build the original package with testing enabled. The original run used writable task-specific cache directories and required host/Core Audio access for Audio Unit registration:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/dex-audio-audit-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/dex-audio-audit-module-cache \
swift test --package-path native \
  --scratch-path /private/tmp/dex-audio-audit-build \
  --cache-path /private/tmp/dex-audio-audit-cache \
  --disable-sandbox
```

Then, for Xcode 27.1's build layout:

```sh
swiftc -parse-as-library -g \
  -module-cache-path /private/tmp/dex-audio-audit-module-cache \
  -I /private/tmp/dex-audio-audit-build/out/Products/Debug \
  -Xcc -fmodule-map-file=/private/tmp/dex-audio-audit-build/out/Intermediates.noindex/GeneratedModuleMaps/CDexDSP.modulemap \
  -L /private/tmp/dex-audio-audit-build/out/Products/Debug \
  -lDexAudio -lDexCore \
  /private/tmp/dex-audio-audit-build/out/Products/Debug/CDexDSP.o \
  docs/audio-audit/AuditProbe.swift \
  -o /private/tmp/dex-audio-architecture-probe

/private/tmp/dex-audio-architecture-probe
```

Module/object locations differ between toolchains/build systems. Do not hard-code this layout into the app or CI. Port the cases into the package's test suite instead. SwiftPM's `--disable-sandbox` does not grant operating-system service access inside an independently restricted agent environment.

The original standalone probe creates/removes a four-second ramp fixture. The longer soak used a generated 60-second stereo WAV; private music is unnecessary. The current default soak fixture should be corrected before treating that test's default invocation as an acceptance gate.
