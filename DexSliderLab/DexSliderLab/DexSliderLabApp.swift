import SwiftUI

@main
struct DexSliderLabApp: App {
    var body: some Scene {
        WindowGroup {
            LabView()
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        #endif
    }
}
