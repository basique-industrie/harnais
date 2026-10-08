// swift-tools-version: 6.2
import PackageDescription
import Foundation

let nativeOAuthCatalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/Infrastructure/Resources/official-oauth-clients.json")
let nativeOAuthResources: [Resource] = FileManager.default.fileExists(atPath: nativeOAuthCatalog.path)
    ? [.copy("Resources/official-oauth-clients.json")] : []

let package = Package(
    name: "Harnais",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        // GUI product cannot be named "Harnais": APFS is case-insensitive, so it
        // collides with the `harnais` CLI and the last build overwrites the app.
        .executable(name: "HarnaisApp", targets: ["HarnaisApp"]),
        .executable(name: "harnais", targets: ["HarnaisCLI"]),
        .executable(name: "HarnaisTests", targets: ["HarnaisTests"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "Domain",
            path: "Sources/Domain",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "Infrastructure",
            dependencies: [
                "Domain",
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            path: "Sources/Infrastructure",
            resources: [
                .copy("Resources/iles-extension"),
            ] + nativeOAuthResources,
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "HarnaisCore",
            dependencies: [
                "Domain",
                "Infrastructure",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/HarnaisCore",
            exclude: [
                "Info.plist",
                "Harnais.entitlements",
                "Resources/PrivacyInfo.xcprivacy",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "HarnaisApp",
            dependencies: [
                "HarnaisCore",
            ],
            path: "Sources/HarnaisApp",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "HarnaisCLI",
            dependencies: [
                "Domain",
                "Infrastructure",
            ],
            path: "Sources/HarnaisCLI",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "HarnaisTests",
            dependencies: [
                "Domain",
                "Infrastructure",
                "HarnaisCore",
            ],
            path: "Tests/HarnaisTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
