// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DexNative",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "DexCore", targets: ["DexCore"]),
        .library(name: "DexAudio", targets: ["DexAudio"]),
        .library(name: "DexConsole", targets: ["DexConsole"]),
        .executable(name: "DexMacPreview", targets: ["DexApp"]),
        .executable(name: "DexAnalysisBench", targets: ["DexAnalysisBench"]),
        .executable(name: "DexConsoleSnapshot", targets: ["DexConsoleSnapshot"]),
        .executable(name: "DexWaveProfile", targets: ["DexWaveProfile"]),
        .executable(name: "DexEngineBench", targets: ["DexEngineBench"]),
        .library(name: "DexEngineBenchKit", targets: ["DexEngineBenchKit"])
    ],
    dependencies: [
        // The chip sliders, tuned in DexSliderLab and shared as they are.
        .package(path: "../DexSliderLab/Packages/DexSlider")
    ],
    targets: [
        .target(name: "DexCore"),
        .target(name: "CDexDSP"),
        // The replacement deck engine (docs/ENGINE-REBUILD-SPEC.md), chosen at launch by
        // DeckEngineChoice. It stays optimised in Debug: a stretcher is far too slow to play otherwise.
        .target(
            name: "CBungee",
            exclude: ["LICENSE", "vendor/eigen/COPYING.MPL2", "vendor/eigen/COPYING.BSD", "vendor/eigen/COPYING.APACHE",
                      "vendor/eigen/COPYING.MINPACK", "vendor/eigen/COPYING.README"],
            cSettings: [.headerSearchPath("vendor/pffft"), .unsafeFlags(["-O2", "-ffast-math", "-fno-finite-math-only", "-w"])],
            cxxSettings: [
                .headerSearchPath("include"), .headerSearchPath("."), .headerSearchPath("vendor/eigen"), .headerSearchPath("vendor/pffft"),
                .define("BUNGEE_VERSION", to: "\"2.4.39\""), .define("BUNGEE_SELF_TEST", to: "0"),
                .define("BUNGEE_NO_LOG"), .define("EIGEN_MPL2_ONLY"), .define("EIGEN_DONT_PARALLELIZE", to: "1"), .define("eigen_assert", to: "BUNGEE_ASSERT1"),
                .unsafeFlags(["-O2", "-fwrapv", "-w"])
            ]
        ),
        .target(
            name: "CDexEngine",
            dependencies: ["CDexDSP", "CBungee"],
            exclude: ["vendor/README.md"],
            cxxSettings: [.unsafeFlags(["-O2"])]
        ),
        .target(name: "CDexEngineTestSupport"),
        .target(name: "DexEngineBenchKit", dependencies: ["CDexEngine"]),
        .executableTarget(name: "DexEngineBench", dependencies: ["DexEngineBenchKit"]),
        .target(name: "DexAudio", dependencies: ["DexCore", "CDexDSP", "CDexEngine"]),
        .target(name: "DexConsole", dependencies: ["DexCore", .product(name: "DexSlider", package: "DexSlider")], resources: [.copy("Art")]),
        .executableTarget(name: "DexApp", dependencies: ["DexCore", "DexAudio", "DexConsole"]),
        .executableTarget(name: "DexAnalysisBench", dependencies: ["DexAudio"]),
        .executableTarget(name: "DexConsoleSnapshot", dependencies: ["DexConsole"]),
        .executableTarget(name: "DexWaveProfile", dependencies: ["DexConsole", "DexCore", "DexAudio"]),
        .testTarget(name: "DexCoreTests", dependencies: ["DexCore"]),
        .testTarget(name: "DexAudioTests", dependencies: ["DexAudio", "CDexDSP", "CDexEngine"]),
        .testTarget(name: "DexConsoleTests", dependencies: ["DexConsole"]),
        .testTarget(name: "DexEngineTests", dependencies: ["CDexEngine", "CDexDSP", "CDexEngineTestSupport", "DexEngineBenchKit"])
    ],
    cxxLanguageStandard: .cxx20
)
