import Foundation

// What can go wrong, as values. The audio layer says what happened; the words the DJ reads are
// made in the app (`ProblemText` in DexApp), so nothing here carries a sentence, and callers can
// branch on the cause.

/// Why an operation on audio or on the library failed.
public enum Failure: Error, Equatable, Sendable {
    case library(LibraryError)
    case playback(NativeDeck.PlaybackError)
    /// Analysis memory is all in use.
    case memoryBusy
    /// The file isn't audio this app can read.
    case unsupportedAudio
    /// Anything else, in the system's own words.
    case system(String)

    public init(_ error: Error) {
        switch error {
        case let failure as Failure: self = failure
        case let error as LibraryError: self = .library(error)
        case let error as NativeDeck.PlaybackError: self = .playback(error)
        case is AudioMemoryBudget.BudgetError: self = .memoryBusy
        case is WaveformReader.ReadError: self = .unsupportedAudio
        default: self = .system(error.localizedDescription)
        }
    }
}

/// A problem on one deck.
public enum DeckProblem: Error, Equatable, Sendable {
    /// What needs the track's BPM before it can work.
    public enum GridUse: Equatable, Sendable { case hotCues, barJump, beatLoop }

    case audioRecovering
    /// A track can't be loaded while the deck plays.
    case playingBlocksLoad
    /// Play started while a load was under way, so the load was dropped.
    case replacementCancelled
    case loadFailed(Failure)
    /// Reads of the loaded track's audio are failing.
    case unreadableAudio
    case noBPM(GridUse)
    case noBeatInTrack
    case invalidGridEntry
    case noBarToJump
    case loopOutsideTrack
    case scrubBusy
}

/// A problem with the audio output as a whole.
public enum MixerProblem: Error, Equatable, Sendable {
    case engineFailed(Failure)
}

/// Something the DJ should know about the audio output, that isn't a failure.
public enum MixerNotice: Equatable, Sendable {
    case interrupted
    case readyPressPlay
    case outputChangedStaysPaused
    case outputChangedPressPlay
    case servicesRestarting
    case pausedForSleep
    case restoredPressPlay
    case optionalWorkPaused
}

public enum PlaylistLock: Equatable, Sendable { case newerVersion, stuck }

/// A problem with the library or its playlists.
public enum LibraryProblem: Error, Equatable, Sendable {
    /// One file or track, and why it failed; imports and analyses report them together.
    public struct Item: Equatable, Sendable {
        public let name: String
        public let cause: Failure
        public init(name: String, cause: Failure) { self.name = name; self.cause = cause }
    }

    case openFailed(Failure)
    case batchFailed([Item])
    case removeFailed(Failure)
    case saveFailed(Failure)
    case playlistSaveFailed(Failure)
    case playlistsLocked(PlaylistLock)
    /// A track can't be removed while a deck holds it; the deck's label.
    case heldByDeck(String)
}

/// Something about the library the DJ should know, that isn't a failure.
public enum LibraryNotice: Equatable, Sendable {
    public enum Restoration: Equatable, Sendable {
        case catalog
        case playlists
        case playlistsLocked(PlaylistLock)
        case playlistsUnreadable(keptAs: String)
    }

    /// Found at start-up, in the order they were found.
    case restored([Restoration])
    case cacheNotSaved
}
