# Architecture audit — 12 November 2026

The user asked for an architectural review of the codebase against four measures: clean
boundaries, predictable state, fault tolerance, and code that can be tested in pieces. This
is the record of what it found and what has been done since. [HANDOFF](../HANDOFF.md) has
the current state in short; this file has the findings in enough detail to act on.

**Scope.** The native app in `native/` only. Electron is frozen and was left out, as were the
mockups. The review read the code; it measured nothing on a device.

## Verdict

The audio engine (`Sources/CDexEngine`) is production-grade in discipline: no locks or
allocation on the audio thread, bounded lock-free queues, and tests that hold it to that. The
app around it (`NativeDeck`, `NativeMixer`, the library, `ConsoleModel`) is a well-tested late
prototype. Overall, about two-thirds of the way from prototype to finished.

The biggest structural risk is finding 1 below, and it is still open.

## Findings and status

| # | Finding | Status |
| --- | --- | --- |
| 1 | Two copies of the transport state | **Done.** All five stages heard and passed, 13 November |
| 2 | Unreadable audio cached as silence | Fixed, `17b76b0` |
| 3 | Playlists without the catalog's protection | Fixed, `17b76b0`, then moved into storage |
| 4 | The audio layer carries screen state, copy and persistence | Open |
| 5 | Errors are sentences | Fixed: alerts, then typed errors |
| 6 | Whole screen state rebuilt on any change | Fixed for library rows |
| 7 | Audio lifecycle is an implicit state machine | Partly: dropped changes fixed, the machine itself open |
| 8 | A full command queue loses a track load | Fixed |
| 9 | Catalog reloaded and rewritten on every edit | Reload fixed; the double write is deliberate |
| 10 | Five unsynchronised polling loops on the main thread | Partly: the two transport loops are one |
| 11 | The engine is one 1,200-line struct, two decks hard-wired | Open, low value |
| 12 | Landing cost on the audio thread has no budget | Open, unmeasured |
| 13 | Smaller: engine creation not null-safe; `48_000` literals | Literals fixed; null safety dropped |

### 1. Two copies of the transport state — done

The engine's header says a deck's position is "what was played, never a prediction". But
`NativeDeck.land()` schedules a predicted `TransportClock` and `loopClock`, and
`EngineDeck.sync` (in `EngineCore.swift`) then re-anchors them to what the engine reports.
So position, loop bounds, tempo and master each exist twice:

- Loop folding is done in Swift (`positionAt`, `boundsAt`) and in the engine (`scheduleWrap`).
- ~~The SYNC tempo ratio is worked out in `followMasterTempo` (`MixMath.tempoRate`) and again
  in the engine's `updateLocks`.~~ Only the engine's now (stage 2, below).
- ~~Master election runs in `NativeMixer.holdSync`, a 50 ms poll, while the engine holds its
  own `master`.~~ Moved into the engine (stage 1, below).
- Seven flags exist only to reconcile the two: `playing`, `hasStreamingVoice`, `startDueAt`,
  `endHeardAt`, `plan`, `transportAt`, `dropped`. Since stage 4 only `playing` (what the
  screen shows) and `dropped` (a full queue) are left on the deck; the deck's requests the
  engine hasn't confirmed live in `DeckTimeline`.

It works and is well tested. The cost is that every new transport feature (loop dragging,
ROLL, keyboard shortcuts) must be right in both places.

**Direction:** make the engine's published state the only transport state. The deck sends
intents and derives what it shows from the published block plus the intents not yet
confirmed. Move master election into the engine beside the lock it already owns.

**How to do it:** in stages, each with the existing offline tests as the gate, and with the
user listening after each, because it changes timing. Not a job for unattended agents.

**Stages:**

1. **Master election in the engine — built 13 November 2026, heard and passed.** The engine's
   `electMaster` runs each block before the locks: when what's heard playing changes (a held
   CUE doesn't count) and one deck is left playing, it leads. A MASTER holds until then.
   `NativeDeck.isMaster` is now what the
   engine publishes, or a MASTER sent that it hasn't confirmed (`EngineCore.masterCommand`);
   MASTER, SYNC on the master and a start beside the leader stay intents sent from the deck
   (`takeMaster`). `NativeMixer.holdSync` no longer elects; it only brings the clocks up to
   date. The hand-off now happens on the block the deck stops, not up to 50 ms later.
   Test: `EngineBehaviourTests.testTheDeckLeftPlayingAloneLeads`.
2. **SYNC's tempo from the engine — built 13 November 2026, heard and passed.** A locked
   follower's TEMPO is the engine's published `DexDeckState.tempo`, taken in
   `NativeDeck.followLockedTempo` once the engine has had everything the deck sent;
   `followMasterTempo` and `MixMath.tempoRate` are gone. Out of the ±16% range the engine now
   puts the follower at the limit (what Swift's clamp did) and still chases nothing. The
   readout moves one block (about 10 ms) after a change, not at once. Tests:
   `GridLockTests.testTheFollowersTempoFollowsTheMasters`,
   `EngineBehaviourTests.testNoLockBeyondTheTempoRange`.
3. **Loops from the engine — built 13 November 2026, heard and passed,** on top of stage 1.
   `DeckTimeline` (`DexCore/Transport.swift`) replaces `TransportClock` and the Swift
   `loopClock`: each segment carries the loop in force, and every block the engine plays takes
   the engine's published loop, not Swift's. Swift still folds, but only between blocks and
   only by bounds the engine published or a change it hasn't played yet. Tests:
   `TransportTests` (loop, rate and landing cases).
4. Position: what's shown comes from the published block plus any landing not yet
   confirmed. **Done in part with stage 3:** the timeline lives on `EngineDeck`, the rule for a
   landing not yet heard is `DeckTimeline.follow`, and `plan` and `transportAt` are gone.
   **4a — built 13 November 2026, heard and passed:** `startDueAt` and `endHeardAt` are gone. A
   start not yet heard is `DeckTimeline.pendingStart`, which takes the engine's own time for
   the landing, so a start held up waiting for audio still counts as a start. The end is heard
   when the engine says `ended` and the timeline, stopped at the end, reaches it a device's
   delay later. Tests: `TransportTests.testAStartIsPendingUntilTheEngineHasPlayedIt`,
   `EndOfTrackTests` (the stop lands on the same frame as before).
   **4b — done 13 November 2026, by the user's choice:** `hasStreamingVoice` became
   `DeckTimeline.soundRequested`, beside the other requests not yet confirmed. It is the
   deck's own intent and can't be read from the engine: after a jog the engine plays again on
   its own while the deck means its next press as a fresh start, so the published `playing`
   would change how that press sounds. The user chose to keep it as an intent; nothing heard
   changes. Test: `TransportTests.testSoundRequestedFollowsTheDecksOwnRequests`.
5. **One transport heartbeat — built 13 November 2026, heard and passed.** The poll couldn't
   simply go: it is what keeps the decks up to date with the engine when nothing on screen
   asks (the end of a track, the master and SYNC tempo the engine chose, a resend after a full
   queue), so the app in the background still needs it. Instead the mixer's 50 ms loop and the
   console's 33 ms readout loop, which did the same catching up, are one: `NativeMixer.runLock`
   moves both decks' positions at 30 Hz while anything plays, and `ConsoleModel` no longer
   runs a loop of its own. Making the engine push its changes instead of being asked would
   remove the last of it, and is a larger piece of work.

### 2. Unreadable audio cached as silence — fixed

A failed file read returned "0 frames", and the loader zero-filled the chunk and published
it as valid. A drive unplugged mid-set played silence under a moving waveform.

Now `DexSourceRead` returns a negative number on failure. The loader (`Source.cpp`) keeps
nothing from a failed read, tries that chunk again every 250 ms, and counts it in
`DexDeckState.readFailures`, which starts again with each track. The engine needed no new
behaviour: an empty chunk already makes a landing wait, or fades a playing deck out and
holds its position. `NativeDeck` raises "Part of this track's audio could not be read…",
once per spell of trouble (failures less than `readTroubleGap`, 2 s, apart are one spell).

Limits: the error shows only while a deck plays, since that is when the deck reads the
engine's state. A file that simply ends short of its stated length is still padded with
silence.

### 3. Playlists without the catalog's protection — fixed

A `playlists.json` that failed to decode was treated as empty and written over by the next
edit. Now:

- The file carries a version: `{"version":1,"playlists":[…]}`. The older bare list still loads.
- An unreadable file is copied aside as `playlists.damaged-<uuid>.json` before anything is
  written, and the previous save comes back from `playlists.backup.json`.
- A newer version's file is never written; edits are refused, at open and again at save.
- Each save keeps the save it replaces as the backup.
- Nothing is written before the saved playlists have been read.
- Reading and writing live in `LibraryStorage`, under `.Library.lock`, off the main thread.
  Edits that land together become one write.

Left open: a failed playlist save is not retried until the next playlist edit, and an
unreadable file is copied aside again at each launch until a playlist is edited.

### 4. The audio layer carries screen state, copy and persistence — open

`NativeDeck` (about 870 lines) is a SwiftUI observable, the transport rule book, the file
loader, the analysis launcher and a library writer, and holds user-facing sentences.
`DexAudio` also contains the whole library and its storage. There are no protocols in the
Swift code, so every deck-rule test builds a real mixer, an offline `AVAudioEngine` and a
file on disk, then sleeps until loading finishes. `Tags.read(url:)` does file reading inside
`DexCore`, which is otherwise pure.

**Direction:** a pure `DeckRules` value type in `DexCore` (intents in, engine commands
out), a thin engine port protocol, a separate `DexLibrary` module, and the observable
wrapper in `DexApp`. Best done with or after finding 1, since both reshape `NativeDeck`.

### 5. Errors are sentences — fixed

Every layer reports failure as `String?`, and the screen model used to dismiss alerts by
comparing text, so a problem raised again with the same words stayed hidden.

Fixed: each source now counts its raisings (`errorRevision`, `noticeRevision` on
`NativeDeck`, `NativeMixer` and `NativeLibrary`), and `ConsoleModel` identifies an alert by
source and count (`Problem`). A problem raised again shows again and gets a fresh seven
seconds. A notice that stands is not raised again by each track prepared.

Fixed, 13 November: the errors are values. `Problems.swift` in `DexAudio` holds them, and
none carries a sentence:

- `Failure`, the cause of an operation: a `LibraryError`, a `PlaybackError`, memory busy,
  unsupported audio, or the system's own words. `Failure(error)` is the one place a caught
  `Error` is sorted.
- `DeckProblem` (a deck's `error`), `MixerProblem` and `MixerNotice` (the mixer's `error` and
  `notice`), `LibraryProblem` and `LibraryNotice` (the library's), each a closed enum.
- `ProblemText` in `DexApp` turns each into words, with exhaustive switches, so a new case
  without wording does not compile. `ConsoleModel` is the only caller.

Changed on the way: a failed batch (imports, FIND KEYS, reanalyse) is `.batchFailed` with a
name and cause per file; start-up recoveries are `.restored([…])`; `library.report` takes a
`LibraryProblem`. The wording is the same, except a file that isn't audio now says so rather
than showing a Cocoa error code.

Not done: the text itself has no test (`DexApp` is an executable); the compiler checks that
every case has words, not what they say.

### 6. Whole screen state rebuilt on any change — fixed for library rows

Any change from the mixer, a deck or the library rebuilt the whole `ConsoleState`,
including a row for every library track (a regular expression, a hash and date formatting
each). `ConsoleModel` now keeps the rows in `LibraryRows`, remade only for tracks that
changed, and looks a deck's track up by id. Measured by the agent in a debug build at 5,000
tracks: a rebuild the library didn't cause went from about 28 ms to about a microsecond.

Open: a change to one track still walks the whole library once (about 11 ms at 5,000), so
FIND KEYS and the background tag and loudness fills pay that per track. Fixing it properly
needs the library to say which track changed. `ConsoleModel` has no test target; the row
cache was checked against the old mapping in a throwaway harness, not in the app.

### 7. Audio lifecycle is an implicit state machine — partly fixed

`NativeMixer` runs its lifecycle on loose flags (`enabled`, `observing`, `servicesMissing`,
`startTask`, `startTicket`, `audioState`, `configurationQuietUntil`, `resumeIntent`). A
configuration change arriving during a start was dropped, as was any in the quarter-second
after one.

Fixed: a change during a start is held (`configurationPending`) and judged when the start
finishes: it is acted on if the engine has stopped again or is feeding a different output
(`OutputLatency.Signature`: device, channel count, sample rate) from the one the start
found. Just after a start, a change is let go only if the engine is still running into the
same output. The rule is `ConfigurationChange.decide`, tested; the wiring only runs against
a real output and is **unchecked**.

Open: the flags are still loose flags. A start that fails outright with a change pending
still ends as "no audio" until the app comes to the foreground; an automatic retry was left
out because a failing start that retries on its own notifications could loop.

### 8. A full command queue loses a track load — fixed

With the engine's 1,024-command queue full, `dex_engine_load` had already moved the loader
to the new track before finding the command couldn't be sent, so the loader and the loop
disagreed, and the deck's full resend (`resendEngineState`) didn't cover loads. Now a load
or unload checks for room first and takes nothing without it; the deck keeps its track and
says "The audio engine is busy. Load the track again."

### 9. Catalog reloaded and rewritten on every edit — reload fixed

Every transaction re-read and decoded the whole catalog; one import did five. Now
`LibraryStorage` keeps the catalog file it last read or wrote open and skips the re-read
only while the file at that path is that same file (device, inode, size, modification and
change times). Holding it open stops the system reusing the inode number. An import of a new
track into an open library now decodes nothing; another store's commit costs one decode.

The two writes per commit (backup, then catalog) are the recovery guarantee and stay.
Checked with two stores in one process, not with two real processes.

### 10 to 13

- **Polling (10):** 50 ms sync, 33 ms readouts, 16 ms meters, 16 ms jog and the display
  link each poll on the main thread. End-of-track and master hand-over depend on it staying
  healthy. Partly fixed by finding 1's stage 5: sync and readouts are one 33 ms heartbeat in
  the mixer. Meters, jog and the display link are each their own job and stay.
- **Engine monolith (11):** one struct holds the voice state machine, sync, mixing and
  metering; two decks are hard-wired from `decks[2]` to `"A"`/`"B"` strings. Open, and pure
  restructuring.
- **Landing cost (12):** priming a key-locked voice runs up to 24 stretcher grains inside
  one audio callback, with a worst-case counter but no budget. Unmeasured as a risk.
- **Smaller (13):** the engine's rate is one constant now (`EngineCore.sampleRate`).
  Making engine creation null-safe was dropped: it fails only if memory can't be had at launch.

## Suggested order from here

1. Try what's unchecked on real devices (see HANDOFF).
2. One transport truth (finding 1), in stages, with the user listening.
3. The lifecycle state machine (finding 7), once its fix has been tried.
4. The rest of finding 4, then 10 and 11, if wanted at all.
