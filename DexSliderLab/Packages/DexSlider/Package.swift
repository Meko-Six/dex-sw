// swift-tools-version: 6.0
import PackageDescription

// The expandable chip slider on its own: no audio, no Dex code, so it can be grafted
// into DexConsole later and judged here first.
let package = Package(
    name: "DexSlider",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "DexSlider", targets: ["DexSlider"])],
    targets: [
        .target(name: "DexSlider"),
        .testTarget(name: "DexSliderTests", dependencies: ["DexSlider"]),
    ]
)
