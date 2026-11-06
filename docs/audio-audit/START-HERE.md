# Paste this into the next agent's chat

Implement the native Dex audio reliability and waveform plan in this repository.

First read `docs/AUDIO-IMPLEMENTATION-PLAN.md`, `HANDOFF.md`, `native/README.md`, and `docs/AUDIO-ARCHITECTURE-AUDIT.md`, plus any current agent instructions. Inspect git status and preserve existing work. The plan is the consolidated implementation brief from my previous chat; do not stop at another general architecture audit.

My priorities are reliable audio with efficient CPU/memory use, smooth and accurately synchronized waveforms, equal Mac/iPad support, and established DJ-engine architecture. I use an M3 MacBook Pro on macOS 27.0.1 and a Bose SoundLink Flex. I am willing to replace the audio system if justified, but want useful native/proven components retained or reused where they meet the requirements.

The previous agent confirmed scheduling-before-playback, custom AU reset, and swallowed render-error defects. The exact original distortion cause remains unproven. The existing suite and a longer-fixture endurance run pass; they do not certify physical Bose/iPad/splitter behavior.

Use work packages W0–W6 and their acceptance gates. Make rendering authoritative for timing, give master/cue explicit ownership, develop explicit stereo/split-cable/multichannel output modes, and keep Bluetooth timing separate from channel routing. Address waveform frame pacing, fractional movement, caching, and view invalidation without creating a competing playback clock. Preserve existing musical behavior and keep Electron frozen.

Implement and verify in reviewable stages. Continue work that does not require unavailable hardware, and clearly separate tested results from pending physical acceptance. Ask focused questions only for material unresolved decisions; otherwise proceed using the intent and defaults documented in the plan. Do not purchase SDKs or silently select a paid dependency.

## If using the transfer ZIP

This packet contains the plan, original audit, context documents, validated standalone probe, evidence summary, and raw audit logs. It is **not a full source checkout**. Use it alongside the Dex repository. Reviewed production revision: `b5ee5da9ffbefda46cdab7f7a778c0761e904be1`; inspect newer changes rather than resetting to it.

`docs/audio-audit/AuditProbe.swift` is a standalone diagnostic source, not a test target. Convert its cases into maintained regression tests as part of W0. Temporary build products and private music are deliberately not included.
