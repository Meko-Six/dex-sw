import AVFoundation
#if os(macOS)
import CoreAudio
#endif

/// How long a sample takes to reach the listener after the engine's output time: what the
/// device reports. The engine's own delay (its limiter) is known exactly and added by the mixer.
/// Bluetooth is the large one: a speaker can take a few hundred ms, and one that under-reports
/// cannot be seen from here. `presentationLatency` leaves out the stream's share, so ask the device.
enum OutputLatency {
    /// `TransportClock` keeps about a second of history to look back through.
    private static let longest = 0.75

    static func seconds(for engine: AVAudioEngine) -> Double {
        let seconds = reported(by: engine)
        return seconds.isFinite ? min(longest, max(0, seconds)) : 0
    }

    /// One line on the output in use, for the diagnostics log.
    static func describe(_ engine: AVAudioEngine) -> String {
        let raw = reported(by: engine), used = seconds(for: engine)
        let format = engine.outputNode.outputFormat(forBus: 0)
        var line = "\(route(of: engine)) \(format.channelCount) ch \(Int(format.sampleRate)) Hz"
        line += String(format: ", delay reported %.1f ms, used %.1f ms, presentation %.1f ms",
                       raw * 1000, used * 1000, engine.outputNode.presentationLatency * 1000)
        if !raw.isFinite { line += " (estimate unusable)" } else if raw > longest { line += " (estimate over the \(Int(longest * 1000)) ms cap)" }
        return line
    }

    #if os(macOS)
    private static func route(of engine: AVAudioEngine) -> String {
        let device = engine.outputNode.auAudioUnit.deviceID
        var name: Unmanaged<CFString>?
        var transport = UInt32(0)
        _ = read(kAudioObjectPropertyName, of: device, into: &name)
        _ = read(kAudioDevicePropertyTransportType, of: device, into: &transport)
        let kind: String
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: kind = "bluetooth"
        case kAudioDeviceTransportTypeBuiltIn: kind = "built-in"
        case kAudioDeviceTransportTypeUSB: kind = "usb"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: kind = "display"
        default: kind = "other"
        }
        return "\(name?.takeRetainedValue() as String? ?? "unknown") (\(kind))"
    }
    private static func reported(by engine: AVAudioEngine) -> Double {
        let device = engine.outputNode.auAudioUnit.deviceID
        var rate = Float64(0)
        guard read(kAudioDevicePropertyNominalSampleRate, of: device, into: &rate), rate > 0 else { return 0 }
        var frames = UInt32(0), streamFrames = UInt32(0)
        _ = read(kAudioDevicePropertyLatency, of: device, into: &frames)
        var streamsSize = UInt32(0)
        var streams = address(kAudioDevicePropertyStreams)
        if AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamsSize) == noErr, streamsSize > 0 {
            var ids = [AudioObjectID](repeating: 0, count: Int(streamsSize) / MemoryLayout<AudioObjectID>.size)
            if AudioObjectGetPropertyData(device, &streams, 0, nil, &streamsSize, &ids) == noErr, let first = ids.first {
                _ = read(kAudioStreamPropertyLatency, of: first, into: &streamFrames)
            }
        }
        return (Double(frames) + Double(streamFrames)) / rate
    }
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }
    private static func read<Value>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID,
                                    into value: inout Value) -> Bool {
        var property = address(selector)
        if !AudioObjectHasProperty(object, &property) { property.mScope = kAudioObjectPropertyScopeGlobal }
        var size = UInt32(MemoryLayout<Value>.size)
        return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr
    }
    #else
    private static func route(of engine: AVAudioEngine) -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: " + ")
    }
    private static func reported(by engine: AVAudioEngine) -> Double {
        AVAudioSession.sharedInstance().outputLatency
    }
    #endif
}
