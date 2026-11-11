// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VedransUtilities",
    platforms: [.macOS(.v14)],
    targets: [
        // Memory kernels are hand-written NEON, so results don't depend on the
        // Swift or C optimiser. -O2 still applies to the surrounding worker loop.
        .target(name: "CMemBench", cSettings: [.unsafeFlags(["-O2"])]),
        .target(name: "CPowerProbes", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "CStorageProbes", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .executableTarget(
            name: "VedransUtilities",
            dependencies: ["CMemBench", "CPowerProbes", "CStorageProbes"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VedransUtilitiesTests",
            dependencies: ["VedransUtilities", "CMemBench", "CStorageProbes"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
