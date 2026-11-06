/// Lowest RMS of two channels' combined energy over consecutive windows (96
/// frames = 2 ms at 48 kHz). Plain loops keep CI's older type checker fast.
func minimumCombinedRMS(_ a: [Float], _ b: [Float], window: Int = 96) -> Double {
    var minimum = Double.infinity
    for start in stride(from: 0, to: min(a.count, b.count) - window, by: window) {
        var total = 0.0
        for k in start..<(start + window) {
            let x = Double(a[k]), y = Double(b[k])
            total += x * x + y * y
        }
        minimum = min(minimum, (total / Double(window)).squareRoot())
    }
    return minimum
}
