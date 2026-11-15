# Library storage: where tracks live now, and a shared library

*Discussed with the user on 15 November 2026. A future project, not current work.
Nothing has been built or tested yet.* The short entry is in [IDEAS](IDEAS.md).

## Where Dex keeps tracks today

Dex **copies every imported track into its own folder** and plays only that copy.
The original file isn't used again after import.

- **Mac:** `~/Library/Application Support/DexNative/` (`DexNativePreview` for package
  runs from Xcode or the terminal).
  - `Audio/`: the copied tracks, renamed to the track's ID (`26729BA3-….mp3`).
  - `Analysis/`: waveform caches, analysis and covers (`<id>.cover.jpg`).
  - `Library.json` (with `Library.backup.json`), `playlists.json`, `sets.json`: the
    catalog, playlists and set history.
  - On 15 November this Mac held 10 tracks: 166 MB of audio, 8.6 MB of analysis.
- **iPad:** the same layout inside the app's private container. It isn't visible in the
  Files app (no file sharing is switched on), and nothing is shared with the Mac.
- An import that matches a file already in the library (by its identity, then by the
  audio's fingerprint) reuses the existing copy. **Remove from library** deletes Dex's
  copy and cover; the original stays.
- Code: `NativeLibrary.init` picks the folder; `LibraryStorage` owns the layout
  (`audioDirectory`, `cacheDirectory`, `catalogURL`) and the import
  (`importFile`: copy to a staging file, fingerprint, analyse, move into `Audio/`).

**Why copies:** the engine reads the file from disk while a track plays (the loader
retries a failed read every 250 ms; the engine waits for audio not there yet). A copy on
the device can't vanish mid-set the way an unplugged drive, a dropped network share or a
cloud file the system has evicted can. Whatever replaces this, **audio must be on the
device before a deck plays it.**

## What the user wants

A library that isn't locked inside the app, and **one library shared between the Mac and
the iPad**: prepare on one, play on the other. It must not depend on iCloud, because not
everyone uses it; Google Drive was the example.

## Options considered

1. **Reference files where they are.** Keep a lasting permission (a security-scoped
   bookmark) to each file or folder instead of copying: any folder, external drive or
   mounted share on the Mac; anything the Files app reaches on the iPad. This is how
   rekordbox and Traktor work on a Mac. No duplicate storage, but files can go missing or
   offline; Dex already has a "file missing" state.
2. **iCloud Drive library.** Dex's own iCloud folder holding the catalog, cues, grids,
   ratings, playlists and sets, with the audio synced or fetched on demand. iCloud has the
   best tools for two devices editing at once, but it's iCloud-only.
3. **A NAS or network share.** Not safe to play from over club Wi-Fi; it only works as a
   source that tracks are copied from before a set, so it's option 1 with a local copy.
4. **Streaming services (Beatport, SoundCloud, Tidal).** Each needs a partnership and the
   service's SDK, and their DJ licences restrict use; harder still for a free, GPL app.
   Not recommended as a starting point.
5. **Built-in Google Drive (or Dropbox) sign-in.** Talking to each service's API directly.
   Rejected for now: separate code and sign-in per service, and an open-source app would
   have to manage the services' developer keys in public.

## Recommended direction: a library folder you choose

Provider-neutral: **the user picks one folder on whatever cloud drive they use** (Google
Drive, iCloud Drive, Dropbox, OneDrive), as it appears in Finder on the Mac and in the Files
app on the iPad. Dex keeps the whole library there; each device picks the same folder; the
cloud app does the syncing. People who don't want the cloud keep the library on the device,
as now. Combine it with option 1 (tracks may stay where they are) and a local copy of
whatever is in the next set.

Problems it has to solve:

1. **Two devices editing at once.** Outside iCloud there is no shared coordination; Google
   Drive and Dropbox make "conflicted copy" files when two devices change one file. Answer:
   **each device writes its own change file**, and Dex merges them when it opens the
   library, so no file is ever written by two devices. The catalog already merges changes
   field by field (`LibraryMutation`), which is a start.
2. **Cloud-only placeholders.** Cloud drives often keep only a stub until a file is opened,
   so a track can be missing on the iPad at the venue. Needs a **"download this playlist /
   set for offline"** step before a gig, and a mark on each row showing what's on the device.
3. **Playback stays local.** The engine always plays from a copy on the device, never
   straight from the cloud.
4. **Keeping access to the folder on the iPad.** The permission must survive restarts.
   iCloud Drive and Dropbox are generally good at this; **Google Drive's Files support has
   been patchier, especially for keeping access to a whole folder.** Unverified: it's the
   first thing to test.

## The first step, when this is picked up

A **feasibility test** before any mockup work, on the Mac and the real iPad, with Google
Drive, iCloud Drive and Dropbox. For each, pick a library folder and check that Dex:

- still has access after the app restarts (and after the device restarts);
- can create and write its files there;
- can download a track that is only in the cloud, and see how long it takes;
- sees a change made on the other device, and how quickly;
- what happens when both devices change the library while one is offline.

The results decide which services can carry a shared library. Then: design it in the
mockup (folder choice, offline download, on-device marks), agree it with the user, and
build it.

## Things to decide later

- Whether tracks are always copied into the library folder, or may stay where the user
  keeps them (option 1), or both.
- How much offline space the iPad may use, and what gets cleared when space runs low.
- Moving an existing library from Application Support into a chosen folder.
- What the PC version (Electron, frozen) would do, if it is ever revived.
