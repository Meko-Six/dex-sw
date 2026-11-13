import AppKit
import DexConsole
import ImageIO
import SwiftUI

/// Renders a demo console screen to PNG for diffing against the Electron app:
///
///   swift run --package-path native DexConsoleSnapshot [--screen home] [--scale 2] [--stretch 0] --out file.png
///
/// Screens mirror the renderer's `?demo=mockup&screen=` states. `--cover image`
/// puts a picture on deck A, to check how a track's own cover sits. `--clip 1`
/// drives deck A's meter to 0 dBFS. `--clip master` lights the master warning instead.
var options = ["--screen": "home", "--scale": "2", "--stretch": "0", "--waves": "1"]
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let key = arguments.next() {
    guard let value = arguments.next() else { break }
    options[key] = value
}
guard let out = options["--out"], var state = ConsoleState.demos[options["--screen"]!],
      let scale = Double(options["--scale"]!), let stretch = Double(options["--stretch"]!) else {
    FileHandle.standardError.write(Data("usage: DexConsoleSnapshot --out file.png [--screen \(ConsoleState.demos.keys.sorted().joined(separator: "|"))] [--scale 2] [--stretch 0] [--waves 0] [--clip 1|master] [--loop beats]\n".utf8))
    exit(2)
}

// --waves 0 leaves the demo waveforms out, to diff everything drawn over them.
if options["--waves"] == "0" { for index in state.decks.indices { state.decks[index].wave = nil } }
// --clip 1 takes deck A's meter to 0 dBFS, the level that draws the red cap and border.
if options["--clip"] == "1" { state.meters.level.a = MeterZones.clip; state.meters.hold.a = MeterZones.clip }
if options["--clip"] == "master" { state.meters.level.l = MeterZones.clip; state.meters.hold.l = MeterZones.clip }
// --loop 1 puts a loop of that many beats on deck A, starting on the beat under its playhead.
if let beats = options["--loop"].flatMap(Double.init), let grid = state.decks[0].grid {
    let beat = ((state.decks[0].position - grid.offsetMs / 1000) * grid.bpm / 60).rounded(.down)
    state.decks[0].loop = ConsoleState.Loop(startBeat: beat, lengthBeats: beats)
}
if let path = options["--cover"] {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write(Data("can't read \(path)\n".utf8))
        exit(2)
    }
    state.decks[0].art = .cover(ConsoleState.Cover(image))
}
let start = ConsoleState.demoLibraryStarts[options["--screen"]!] ?? LibraryView()
let renderer = ImageRenderer(content: ConsoleStage(state: state, stretch: stretch, libraryStart: start, snapshot: true))
renderer.scale = scale
guard let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("rendering failed\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: out))
print("\(out): \(image.width)×\(image.height)")
