import AVFoundation
import AudioToolbox
import CDexDSP
@testable import DexAudio
import DexCore

// The engine's tone section and output router are this same C code. These units wrap it for
// AVAudioEngine so its sound can be checked on its own, here in the tests.

private let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

/// The deck's trim, three-band isolator and sweep (`src/renderer/audio/eq.ts`). The
/// render block pulls its input in place and runs the allocation-free C bands.
final class IsolatorUnit: AUAudioUnit, @unchecked Sendable {
    private static let description = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: 0x64786973,
        componentManufacturer: 0x44657878, componentFlags: 0, componentFlagsMask: 0)
    private static let registration: Void = {
        AUAudioUnit.registerSubclass(IsolatorUnit.self, as: description, name: "Dex: Isolator", version: 1)
    }()
    static func makeNode() -> AVAudioUnitEffect {
        _ = registration
        return AVAudioUnitEffect(audioComponentDescription: description)
    }

    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private let storage = IsolatorStorage()
    /// The linear gains last sent to the render thread: LOW, MID, HIGH, trim.
    private(set) var gains: [Float] = [1, 1, 1, 1]
    /// The sweep knob last sent to the render thread.
    private(set) var sweep: Float = 0
    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: stereo)])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: stereo)])
        maximumFramesToRender = 8192
    }
    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var internalRenderBlock: AUInternalRenderBlock {
        let storage = storage
        return { flags, timestamp, frames, _, output, _, pull in
            guard frames <= 8192, let pull else { return kAudioUnitErr_TooManyFramesToProcess }
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            let scratch = UnsafeMutableAudioBufferListPointer(storage.scratch.mutableAudioBufferList)
            for index in buffers.indices where buffers[index].mData == nil {
                buffers[index].mData = scratch[index].mData
                buffers[index].mDataByteSize = frames * 4
            }
            let result = pull(flags, timestamp, frames, 0, output)
            if result == noErr {
                dex_isolator_process(storage.pointer, frames, output)
                dex_cue_tap_write(storage.cue, frames, output)
            } else { dex_cue_tap_reset(storage.cue) }
            return result
        }
    }
    func set(low: Float, mid: Float, high: Float, trim: Float) {
        gains = [low, mid, high, trim]
        dex_isolator_set(storage.pointer, low, mid, high, trim)
    }
    /// Plays this unit's latest block to the router. The router pulls the master
    /// first, so the unit has already rendered this cycle when this runs.
    nonisolated func makeCueSource() -> AVAudioSourceNode {
        let storage = storage
        return AVAudioSourceNode(format: stereo) { _, _, frames, output in
            dex_cue_tap_read(storage.cue, frames, output)
            return noErr
        }
    }
    func setSweep(knob: Float) {
        sweep = min(1, max(-1, knob.isFinite ? knob : 0))
        dex_isolator_set_sweep(storage.pointer, sweep)
    }
    /// Lands on the current gains at once: a fresh graph starts where the controls are.
    func snap() { dex_isolator_snap(storage.pointer) }
    /// Forgets the audio it has heard, keeping the controls. Safe while rendering.
    override func reset() {
        super.reset()
        dex_isolator_reset(storage.pointer)
        dex_cue_tap_reset(storage.cue)
    }
}

private final class IsolatorStorage: @unchecked Sendable {
    let pointer = dex_isolator_create(48_000, Isolator.lowHz, Isolator.highHz, FilterSetting.lowPassFlatHz, FilterSetting.lowPassFloorHz,
                                      FilterSetting.highPassFloorHz, FilterSetting.highPassCeilingHz)!
    let scratch = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 8192)!
    let cue = dex_cue_tap_create(8192)!
    deinit { dex_isolator_destroy(pointer); dex_cue_tap_destroy(cue) }
}

/// The output stage (`src/renderer/audio/routing.ts`): bus 0 is the master,
/// busses 1 and 2 are decks A and B's cue sources, after their tone section and
/// before the fader. Bus 0 must be pulled first: it is what renders the decks. The output takes the hardware's layout, two or four channels.
final class OutputRouterUnit: AUAudioUnit, @unchecked Sendable {
    private static let description = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: 0x64787274,
        componentManufacturer: 0x44657878, componentFlags: 0, componentFlagsMask: 0)
    private static let registration: Void = {
        AUAudioUnit.registerSubclass(OutputRouterUnit.self, as: description, name: "Dex: Output Router", version: 1)
    }()
    static func makeNode() -> AVAudioUnitEffect {
        _ = registration
        return AVAudioUnitEffect(audioComponentDescription: description)
    }

    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private let storage = RouterStorage()
    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input,
                                     busses: try (0..<3).map { _ in try AUAudioUnitBus(format: stereo) })
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: stereo)])
        maximumFramesToRender = 8192
    }
    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    /// Stereo in, any channel count out.
    override var channelCapabilities: [NSNumber]? { [-1, -2] }
    override var internalRenderBlock: AUInternalRenderBlock {
        let storage = storage
        return { flags, timestamp, frames, _, output, _, pull in
            guard frames <= 8192, let pull else { return kAudioUnitErr_TooManyFramesToProcess }
            var master = noErr
            for bus in 0..<3 {
                let list = dex_router_input(storage.pointer, Int32(bus), frames)!
                let result = pull(flags, timestamp, frames, bus, list)
                storage.pulled[bus] = result == noErr
                if result != noErr {
                    dex_router_count_pull_failure(storage.pointer, Int32(bus))
                    if bus == 0 { master = result }
                }
            }
            // One silent input says nothing about the others, which share these flags.
            flags.pointee.remove(.unitRenderAction_OutputIsSilence)
            dex_router_prepare_output(storage.pointer, frames, output)
            dex_router_process(storage.pointer, frames, storage.pulled, output)
            // The master is what the room hears, so its failure is the render's. A cue
            // branch only goes quiet, and shows in the count.
            return master
        }
    }
    func set(split: Bool, cueMix: Float, cueA: Float, cueB: Float) {
        dex_router_set(storage.pointer, Int32(split ? DEX_ROUTE_SPLIT : DEX_ROUTE_MULTICHANNEL), cueMix, cueA, cueB)
    }
    func snap() { dex_router_snap(storage.pointer) }
    /// Forgets the transient peak guard, keeping the controls. Safe while rendering.
    override func reset() {
        super.reset()
        dex_router_reset(storage.pointer)
    }
    /// Failed pulls of the master, then decks A and B's cue. Read off the render thread.
    var pullFailures: [UInt32] { (0..<3).map { dex_router_pull_failures(storage.pointer, Int32($0)) } }
}

private final class RouterStorage: @unchecked Sendable {
    let pointer = dex_router_create(48_000, 8192)!
    let pulled = UnsafeMutablePointer<Bool>.allocate(capacity: 3)
    init() { pulled.initialize(repeating: false, count: 3) }
    deinit { dex_router_destroy(pointer); pulled.deallocate() }
}


/// A deck for checking the tone section on its own: its settings are what the engine is sent.
@MainActor
enum ToneTest {
    /// An engine with a one-chunk cache: these decks never play, so it holds almost no memory.
    static let core = EngineCore(chunksPerDeck: 1)
    static func deck() -> NativeDeck { NativeDeck(label: "A", core: core, index: 0) }
}

extension NativeDeck {
    /// The tone section's gains as the deck sends them: low, mid, high, trim.
    var toneGains: [Float] { let t = tone; return [t.low, t.mid, t.high, t.trim] }
}

extension IsolatorUnit {
    /// Takes the deck's tone and sweep, gliding to them as the engine does.
    @MainActor func follow(_ deck: NativeDeck) {
        let tone = deck.tone
        set(low: tone.low, mid: tone.mid, high: tone.high, trim: tone.trim)
        setSweep(knob: deck.sweep)
    }
}
