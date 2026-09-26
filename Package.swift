// swift-tools-version: 5.10
// NeriPlayer macOS —— SwiftPM 清单。
// 当前仅包含 App 可执行目标与测试目标；第三方依赖在 M0-T2 引入。

import PackageDescription

let package = Package(
    name: "NeriPlayer",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "NeriPlayer", targets: ["NeriPlayer"]),
    ],
    targets: [
        .executableTarget(
            name: "NeriPlayer",
            path: "NeriPlayer"
        ),
        .testTarget(
            name: "NeriPlayerTests",
            dependencies: ["NeriPlayer"],
            path: "Tests"
        ),
    ]
)
