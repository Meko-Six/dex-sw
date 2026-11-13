import DexAudio

/// The words for what the audio layer reports. Everything the DJ reads about a problem is here;
/// the audio layer only says what happened.
enum ProblemText {
    static func words(_ failure: Failure) -> String {
        switch failure {
        case .library(let error): words(error)
        case .playback(.unsupportedChannels): "Only mono and stereo files are supported in this checkpoint."
        case .playback(.engineBusy): "The audio engine is busy. Load the track again."
        case .memoryBusy: "Audio preparation memory is busy. Wait for the current operation or choose a shorter loop."
        case .unsupportedAudio: "This audio file could not be read."
        case .system(let description): description
        }
    }

    static func words(_ error: LibraryError) -> String {
        switch error {
        case .damagedCatalog: "The library and its recovery copy could not be read. Your audio has been kept."
        case .newerVersion: "This library was saved by a newer Dex version. Update Dex to open it."
        case .missingAudio: "This library track's audio is missing. Import the original file again to restore it."
        case .missingTrack: "This track is no longer in the library."
        case .importFailed: "The audio file could not be imported."
        case .sourceChanged: "The source changed while importing. Try importing it again."
        }
    }

    static func words(_ problem: DeckProblem) -> String {
        switch problem {
        case .audioRecovering: "Audio is recovering. Load the deck again when audio is ready."
        case .playingBlocksLoad: "Pause this deck before loading a track."
        case .replacementCancelled: "Playback started; replacement was cancelled."
        case .loadFailed(let failure): words(failure)
        case .unreadableAudio:
            "Part of this track's audio could not be read. Check the file or drive, then load the track again."
        case .noBPM(.hotCues): "Set the track BPM before using hot cues."
        case .noBPM(.barJump): "Set the track BPM before using bar jumps."
        case .noBPM(.beatLoop): "Set the track BPM before using a beat loop."
        case .noBeatInTrack: "The beat grid has no beat inside this track. Correct its BPM and offset."
        case .invalidGridEntry: "Enter a valid positive BPM and grid offset."
        case .noBarToJump: "The track has no playable bar for this jump."
        case .loopOutsideTrack: "The selected loop does not fit inside the track."
        case .scrubBusy: "Scrub control is busy. Try the gesture again."
        }
    }

    static func words(_ problem: MixerProblem) -> String {
        switch problem {
        case .engineFailed(let failure): words(failure)
        }
    }

    static func words(_ notice: MixerNotice) -> String {
        switch notice {
        case .interrupted: "Playback interrupted."
        case .readyPressPlay: "Audio is ready. Press PLAY to continue."
        case .outputChangedStaysPaused: "Audio output changed. Playback will remain paused."
        case .outputChangedPressPlay: "Audio output changed. Press PLAY to continue."
        case .servicesRestarting: "Audio services are restarting."
        case .pausedForSleep: "Playback paused for sleep."
        case .restoredPressPlay: "Audio was restored. Press PLAY to continue."
        case .optionalWorkPaused: "Optional audio preparation paused to free memory. Playback continues."
        }
    }

    static func words(_ lock: PlaylistLock) -> String {
        switch lock {
        case .newerVersion: "These playlists were saved by a newer Dex version. Update Dex to change them."
        case .stuck: "The playlists file could not be read or set aside, so playlists can't be changed."
        }
    }

    static func words(_ problem: LibraryProblem) -> String {
        switch problem {
        case .openFailed(let failure): words(failure)
        case .batchFailed(let items): items.map { "\($0.name): \(words($0.cause))" }.joined(separator: "\n")
        case .removeFailed(let failure): "The track could not be removed: " + words(failure)
        case .saveFailed(let failure): "Library changes could not be saved: " + words(failure)
        case .playlistSaveFailed(let failure): "Playlists could not be saved: " + words(failure)
        case .playlistsLocked(let lock): words(lock)
        case .heldByDeck(let deck): "Deck \(deck) holds this track. Load another track there, then remove it."
        }
    }

    static func words(_ notice: LibraryNotice) -> String {
        switch notice {
        case .restored(let restorations): restorations.map { words($0) }.joined(separator: " ")
        case .cacheNotSaved: "Audio is available. Its waveform cache could not be saved and will be rebuilt next time."
        }
    }

    private static func words(_ restoration: LibraryNotice.Restoration) -> String {
        switch restoration {
        case .catalog: "Library restored from its previous save. Check your most recent edits."
        case .playlists: "Playlists restored from their previous save. Check your most recent changes."
        case .playlistsLocked(let lock): words(lock)
        case .playlistsUnreadable(let kept): "The playlists file could not be read. It was kept as \(kept), and playlists start empty."
        }
    }
}
