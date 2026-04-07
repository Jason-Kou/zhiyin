// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZhiYin",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "zhiyin", targets: ["ZhiYin"]),
        .executable(name: "zhiyin-stt", targets: ["ZhiYinSTT"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "ZhiYin",
            dependencies: [
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
            ],
            path: "ZhiYin/Sources",
            exclude: ["Info.plist"],
            resources: [
                .copy("../../models"),
                .process("Resources/icon-1024.png")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
                // Self-compile users: uncomment to remove usage limits
                // .define("DISABLE_USAGE_LIMIT"),
            ]
        ),
        .executableTarget(
            name: "ZhiYinSTT",
            path: "ZhiYin/CLI"
        )
    ]
)
