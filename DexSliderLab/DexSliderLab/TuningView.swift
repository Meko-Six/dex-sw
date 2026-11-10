import DexSlider
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Every number behind the look and feel, live. Settings are kept between launches;
/// COPY puts them on the clipboard to send back, and they become the defaults.
struct TuningView: View {
    @Binding var tuning: SliderTuning
    @State private var copied = false

    var body: some View {
        Form {
            Section("Open panel") {
                Picker("Opens", selection: $tuning.placement) {
                    ForEach(SliderTuning.Placement.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                row("Bar width", $tuning.barWidth, 50...160, "pt")
                row("Bar height (drag travel)", $tuning.barHeight, 120...400, "pt")
                row("Bar corners", $tuning.barCorner, 0...30, "pt")
                row("Gap from chip", $tuning.panelGap, 0...60, "pt")
                row("Number size", $tuning.numberSize, 24...80, "pt")
                row("Rung height", $tuning.rungHeight, 6...30, "pt")
                row("Rung gap", $tuning.rungGap, 2...16, "pt")
                Toggle("Backdrop", isOn: $tuning.backdrop)
            }
            Section("Feel") {
                row("Fine starts after", $tuning.fineStart, 20...150, "pt sideways")
                row("Each slower step", $tuning.fineStep, 20...150, "pt")
                row("Stretch resistance", $tuning.rubberBand, 0...1, "", decimals: 2)
                row("Open speed", $tuning.openResponse, 0.08...0.6, "s", decimals: 2)
                row("Open bounce", $tuning.openBounce, 0...0.6, "", decimals: 2)
                row("Stays up after release", $tuning.holdAfterRelease, 0...2, "s", decimals: 1)
                row("Double-tap window", $tuning.doubleTapWindow, 0.15...0.6, "s", decimals: 2)
            }
            Section("Meter") {
                row("Red rung at", $tuning.redDB, -9...3, "dBFS", decimals: 1, step: 0.5)
                row("Rung spacing", $tuning.rungStepDB, 0.5...6, "dB", decimals: 1, step: 0.5)
                row("Peak hold", $tuning.peakHold, 0...5, "s", decimals: 1)
                row("Fall", $tuning.releaseDBPerSecond, 5...60, "dB/s")
                Text(rungList)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Section("Chip at rest") {
                row("Width", $tuning.chipWidth, 60...140, "pt")
                row("Height", $tuning.chipHeight, 36...90, "pt")
                Toggle("Fill", isOn: $tuning.chipFill)
                row("Fill strength", $tuning.chipFillOpacity, 0.1...0.8, "", decimals: 2)
                Toggle("Number", isOn: $tuning.chipNumber)
                Toggle("Outline shows the meter", isOn: $tuning.chipStatus)
            }
            Section("Lab") {
                Toggle("Dex black background", isOn: $tuning.dexBackground)
                Button(copied ? "Copied" : "Copy settings") { copy() }
                Button("Reset to defaults", role: .destructive) { tuning = SliderTuning() }
            }
        }
        .formStyle(.grouped)
    }

    private var rungList: String {
        let rungs = tuning.rungs.thresholds.reversed().map { SliderSpec.decibels($0) }
        return "Rungs light at: " + rungs.joined(separator: "  ")
    }

    private func row(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ unit: String,
                     decimals: Int = 0, step: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.\(decimals)f", value.wrappedValue) + (unit.isEmpty ? "" : " \(unit)"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
        }
    }

    private func copy() {
        let text = TuningStore.json(tuning)
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
