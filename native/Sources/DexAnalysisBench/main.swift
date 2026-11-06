import Foundation
import DexAudio

/// Local-only parity bench. Accepts WAV/MP3/etc paths, or an accuracy manifest.
/// No audio bytes or provenance are uploaded or embedded in the output.
struct Manifest: Decodable {
    struct Track: Decodable {
        struct Truth: Decodable { let bpm: Double?; let downbeatsSec: [Double]? }
        let id: String
        let file: String
        let truth: Truth?
    }
    let tracks: [Track]
}

@main
struct DexAnalysisBench {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            print("Usage: swift run --package-path native -c release DexAnalysisBench audio-files…")
            print("   or: … --manifest accuracy/manifest.json [--marked]")
            return
        }
        var tracks: [(String, URL, Double?, [Double])] = []
        if arguments[0] == "--manifest", arguments.count >= 2 {
            let source = URL(fileURLWithPath: arguments[1])
            let data = try Data(contentsOf: source)
            // Existing accuracy manifests may be a document or a plain track array.
            let decoder = JSONDecoder()
            let entries: [Manifest.Track]
            if let document = try? decoder.decode(Manifest.self, from: data) { entries = document.tracks }
            else { entries = try decoder.decode([Manifest.Track].self, from: data) }
            for entry in entries {
                let marks = entry.truth?.downbeatsSec ?? []
                if arguments.contains("--marked") && marks.isEmpty { continue }
                let url = entry.file.hasPrefix("/") ? URL(fileURLWithPath: entry.file)
                    : source.deletingLastPathComponent().appendingPathComponent(entry.file)
                tracks.append((entry.id, url, entry.truth?.bpm, marks))
            }
        } else {
            tracks = arguments.map { ($0, URL(fileURLWithPath: $0), nil, []) }
        }
        var failures = 0
        for (id, url, expected, marks) in tracks {
            let start = Date()
            do {
                let result = try WaveformReader.read(url: url, analyzeKey: true)
                var record: [String: Any] = ["id": id, "seconds": Date().timeIntervalSince(start),
                                            "uncertain": result.detection.uncertain, "duration": result.duration]
                if let key = result.key {
                    record["key"] = key.name ?? NSNull(); record["camelot"] = key.camelot ?? NSNull()
                    record["keyConfidence"] = key.confidence
                }
                if let waveform = result.waveform {
                    record["waveformBins"] = waveform.data.levels[0].count
                    record["waveformResidentKiB"] = Double(waveform.data.residentBytes) / 1024
                }
                if let grid = result.detection.grid {
                    record["bpm"] = grid.bpm; record["offsetMs"] = grid.offsetMs; record["confidence"] = grid.confidence
                    if let expected {
                        record["expectedBpm"] = expected; record["bpmError"] = abs(grid.bpm - expected)
                        if abs(grid.bpm - expected) > 0.5 { failures += 1 }
                    }
                    record["markErrorsMs"] = marks.map { mark in
                        let beat = (mark - grid.offsetMs / 1000) / grid.beatSeconds
                        return abs(beat - beat.rounded()) * grid.beatSeconds * 1000
                    }
                    record["barErrorsMs"] = marks.map { mark in
                        let bar = (mark - grid.offsetMs / 1000) / (4 * grid.beatSeconds)
                        return abs(bar - bar.rounded()) * 4 * grid.beatSeconds * 1000
                    }
                    if let errors = record["markErrorsMs"] as? [Double], errors.contains(where: { $0 > 25 }) { failures += 1 }
                } else { record["error"] = "No usable grid"; failures += 1 }
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                failures += 1
                let data = try JSONSerialization.data(withJSONObject: ["id": id, "error": error.localizedDescription], options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            }
        }
        if arguments.contains("--verify") && failures > 0 { exit(1) }
    }
}
