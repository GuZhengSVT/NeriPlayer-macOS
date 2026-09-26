// swift-tools-version: 5.10
// NeriPlayer macOS —— SwiftPM 清单。
// M0-T2：引入 GRDB 作为数据库层依赖。SwiftLint 通过 Homebrew 二进制 + Tools/run-swiftlint.sh 集成，
// 不进入 SPM 依赖图（理由见 M0-T2 报告）。

import PackageDescription

let package = Package(
    name: "NeriPlayer",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "NeriPlayer", targets: ["NeriPlayer"]),
    ],
    dependencies: [
        // 数据库层：SQLite 封装，替代 Android 侧的 Room。
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "NeriPlayer",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "NeriPlayer"
        ),
        .testTarget(
            name: "NeriPlayerTests",
            dependencies: [
                "NeriPlayer",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests"
        ),
    ]
)
