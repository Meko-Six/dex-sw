import AVFoundation
import AudioToolbox

/// How the cue reaches the ears: SPLIT CUE or 4-CH CUE, falling back to split
/// when the output has fewer than four channels, as the Electron router does.
public enum CueRouting {
    public static func split(requested: Bool, outputChannels: Int) -> Bool { requested || outputChannels < 4 }
    /// The router's output layout for a device with `hardware` channels.
    public static func channels(hardware: Int) -> AVAudioChannelCount { hardware >= 4 ? 4 : 2 }
    public static func format(channels: AVAudioChannelCount) -> AVAudioFormat {
        channels <= 2 ? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
            : AVAudioFormat(standardFormatWithSampleRate: 48_000,
                            channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!)
    }
}
