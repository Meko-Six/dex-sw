import Combine

/// Frequent display updates never invalidate deck controls or static waveforms.
@MainActor
public final class DeckPlayhead: ObservableObject {
    @Published public private(set) var seconds = 0.0
    func set(_ value: Double) { if value != seconds { seconds = value } }
}
