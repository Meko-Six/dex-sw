import AVFoundation
import Darwin
import os

/// What the audio control plane has really been doing, so timing work rests on
/// measurements: `log stream --level info --predicate 'subsystem == "dex.native"'`.
/// Nothing here runs on the render thread.
enum AudioDiagnostics {
    static let log = Logger(subsystem: "dex.native", category: "audio")
}
