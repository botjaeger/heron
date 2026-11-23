// swift-tools-version: 6.2
// Heron — a menu bar system monitor for macOS (Apple silicon).
//
// Layout (each folder under Sources/ is one target):
//   CSystem       C code for the private macOS APIs (SMC, HID sensors, IOReport).
//                 C is used here because these APIs have no Swift headers.
//   HeronCore   Swift library: samplers, models, formatting, alerts. No UI.
//   Heron       The menu bar app (SwiftUI).
//   heron-probe Command-line tool that prints every reading once. Handy for debugging.
//   heron-snap  Renders the app's views to PNG files (light + dark) for design review.
import PackageDescription

let package = Package(
    name: "Heron",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Heron", targets: ["Heron"]),
        .executable(name: "heron-probe", targets: ["heron-probe"]),
        .executable(name: "heron-snap", targets: ["heron-snap"]),
    ],
    dependencies: [
        // Sparkle is the standard auto-update framework for apps distributed outside the App Store.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "CSystem",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "HeronCore",
            dependencies: ["CSystem"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(
            name: "HeronUI",
            dependencies: ["HeronCore"]
        ),
        .executableTarget(
            name: "Heron",
            dependencies: ["HeronCore", "HeronUI", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "heron-probe",
            dependencies: ["HeronCore"]
        ),
        .executableTarget(
            name: "heron-snap",
            dependencies: ["HeronCore", "HeronUI"]
        ),
        .testTarget(
            name: "HeronCoreTests",
            dependencies: ["HeronCore"]
        ),
        .testTarget(
            name: "HeronUITests",
            dependencies: ["HeronUI", "HeronCore"],
            // The views and settings under test live on the main actor.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ],
    // Swift 6 language mode: strict data-race checking. UI types are @MainActor; the samplers
    // run only on Monitor's serial queue (see `Samplers` in Monitor.swift).
    swiftLanguageModes: [.v6]
)
