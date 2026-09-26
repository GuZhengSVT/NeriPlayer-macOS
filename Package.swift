// swift-tools-version: 5.10
// NeriPlayer macOS —— SwiftPM 清单。
// M0-T2：引入 GRDB 作为数据库层依赖。SwiftLint 通过 Homebrew 二进制 + Tools/run-swiftlint.sh 集成，
// 不进入 SPM 依赖图（理由见 M0-T2 报告）。
// M1-T2：新增 CMpv（libmpv C API 桥接）target，并为 NeriPlayer/NeriPlayerTests 补 rpath。

import PackageDescription
import Foundation

// Vendor 路径计算。
// 为什么不用相对路径：SwiftPM 求值清单时的 cwd 不是包根目录（实测为本进程 cwd），
// 用 #filePath 反推包根才能保证从任意目录调用 swift build 都成立。
// 已知限制：绝对路径含空格时 SPM 的 -I/-L/-rpath 参数无法转义；本仓库路径不含空格。
let packageRootDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendorMpvDir = packageRootDir + "/Vendor/mpv"
let vendorMpvIncludeDir = vendorMpvDir + "/include"
let vendorMpvLibDir = vendorMpvDir + "/lib"

// 供 CMpv 及其消费方共用的头文件搜索路径。
// 为什么消费方也要加：CMpv.h 里 #include <mpv/client.h>，而 SwiftPM 不会把某个 target
// cSettings 里的 unsafeFlags 传递给依赖它的 target，所以 import CMpv 的 Swift 目标
// 必须自己再声明一次这个 -I，否则 clang 模块构建时报 "'mpv/client.h' file not found"。
let vendorMpvCSettings: [CSetting] = [.unsafeFlags(["-I", vendorMpvIncludeDir])]

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
        // M1-T2：libmpv 的 C 桥接模块。
        // 选「C target + publicHeadersPath」而非「给 NeriPlayer 直接加 cSettings.headerSearchPath」的理由：
        //   1) mpv/client.h 只在 CMpv 一处被 include，Swift 侧统一 import CMpv，
        //      业务目标不必再感知 Vendor 目录；
        //   2) include/库/链接三处细节收敛在 vendorMpv* 常量，换 vendor 布局只改一处；
        //   3) C 源文件能在编译期拿到 MPV_CLIENT_API_VERSION 做头文件/动态库版本自检。
        .target(
            name: "CMpv",
            path: "NativeModules/CMpv",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I", vendorMpvIncludeDir]),
            ],
            linkerSettings: [
                .linkedLibrary("mpv"),
                .unsafeFlags(["-L", vendorMpvLibDir]),
            ]
        ),
        .executableTarget(
            name: "NeriPlayer",
            dependencies: [
                "CMpv",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "NeriPlayer",
            swiftSettings: [
                // 把 mpv 头文件搜索路径透传给 Swift 编译器的 clang importer，
                // 否则 import CMpv 时构建 CMpv 模块会因为找不到 mpv/client.h 失败。
                // 必须连成一个 "-I<path>" 字符串：拆成三个元素时 swiftc 会把路径当成独立输入文件。
                .unsafeFlags(["-Xcc", "-I" + vendorMpvIncludeDir]),
            ],
            linkerSettings: [
                // 运行期加载：可执行文件以 @rpath/libmpv.2.dylib 引用 dylib，
                // 必须把自己的 vendor 目录写进 LC_RPATH，否则 dyld 启动即报找不到库。
                // 仅覆盖本地 swift build/run；M9 打包改走 .app 内 Frameworks。
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", vendorMpvLibDir]),
            ]
        ),
        .testTarget(
            name: "NeriPlayerTests",
            dependencies: [
                "NeriPlayer",
                "CMpv",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests",
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I" + vendorMpvIncludeDir]),
            ],
            linkerSettings: [
                // 不在这里声明 -rpath：testTarget 依赖 CMpv，CMpv 的 linkedLibrary("mpv")
                // 已经把 Vendor/mpv/lib 作为 LC_RPATH 传给了 xctest（实测 otool -l 可见）。
                // 再加一次会触发 ld 的 "duplicate -rpath ... ignored" 警告。
            ]
        ),
    ]
)
