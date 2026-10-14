# 元数据库选型记录（M2-T1）

- 编号：M2-T1
- 状态：已接受（Accepted）
- 日期：2026-09-27
- 范围：只定「读音频元数据用哪个库」，并记录落库的版本锁定；不含扫描器（M2-T2）、不含写库（M2-T3/T4）
- 关联任务：M2-T1（本任务）、M2-T2（扫描器）、M2-T5（媒体库 UI 的格式角标）

> 本文与 `Package.swift` 中 TagLibSwift 依赖的注释互相引用：实现若换库，先改本文件。

---

## 1. 任务要读什么

`AudioMetadataReader` 需要从本机文件读出：title / artist / album / duration / 内嵌封面字节 /
文件体积 / 容器格式标识。规划 M2-T1 的验收要求对 mp3 / flac / m4a / ogg / wav 五种格式
断言字段。这是纯读取场景，本阶段不需要写回标签（M2-T3 只建表，写标签即便后续要做也另有入口）。

## 2. 候选与结论

任务给出的首选是 `kitlangton/SwiftTaglib` 或 `ddppftw/SwiftTaglib`。**这两个仓库在
2026-09-27 核查时均已不存在（GitHub API 返回 404）**，无法作为依赖引入。于是在
「TagLib 的 Swift 封装」与「MIT 的 taglib C++ 绑定」两条路线里实测了下列候选：

| 候选 | 协议 | 维护状态（核查日） | SPM 集成 | API 覆盖 | 结论 |
|---|---|---|---|---|---|
| jeonghi/TagLibSwift 0.2.0-rc.1 | MIT | 活跃（0.1.0：2025-05；0.2.0-rc.1：2026-07） | **vendor TagLib 2.3.1 源码，SwiftPM 直接编译**，无 CMake 前置 | title/artist/album、毫秒级时长、PICTURE 封面字节、bitrate/sampleRate/bitsPerSample | **采用** |
| Anywhere-Music-Player/SwiftTagLib.cpp | MPL-2.0 | 活跃（2026-01） | 二进制 XCFramework，平台下限 macOS 14 | 覆盖同类 | 未采用：MPL-2.0 与项目偏好不符，且二进制包不可审阅 |
| sbooth/CXXTagLib | MPL-1.1（`LICENSE.txt`） | 活跃（2026-09） | vendored 源码 | 直接暴露 TagLib C++ 类 | 未采用：无 Swift 封装层，需自写 C++ 互操作样板；MPL 许可 |
| ryanfrancesconi/spfk-metadata | MIT | 活跃 | 依赖 `spfk-taglib`（**LGPL-2.1**）等 8 个包 | 很全（含读写、BEXT） | 未采用：传递依赖是 LGPL-2.1 且依赖图庞大 |
| Phisto/swift-taglib | LGPL-3.0 | 低频 | — | — | 未采用：LGPL-3.0 与静态链接到闭源发布冲突风险 |

**结论：引入 `https://github.com/jeonghi/TagLibSwift.git`，锁定 `0.2.0-rc.1`
（revision `a36e48f43a4cea1fd41baa0c90acdb6f35444800`，见 `Package.resolved`）。**

## 3. 选它的理由

**协议**：MIT。TagLib 本体是 LGPL-2.1/MPL-2.0 双许可，TagLibSwift 选择了 MPL 一侧的
「静态链接无传染」路径，并以 MIT 发布自己的封装层；本仓库直接编译其 vendored 源码，
没有 LGPL 的静态链接问题。

**维护状态**：是本组候选里唯一同时满足「有版本 tag」「近期有提交」「README 明确写出
测试覆盖」的 MIT 选项。0.2.0-rc.1 虽为 pre-release，但其 `Package.swift` 已把 TagLib
2.3.1 源码纳入仓库、由 SwiftPM 编译，不依赖任何预编译产物或 CMake 步骤。

**集成成本**：0.1.0 走二进制 XCFramework（`TagLib.xcframework`，仅含 macos-arm64 切片），
在 Intel Mac 与 CI 上会缺切片；0.2.0-rc.1 改为 vendored 源码，本机与 arm64 runner
都能直接编。代价是首次构建要编译大量 C++（本仓库冷编译实测约数分钟，增量构建无感），
并**要求消费 target 打开 C++ 互操作**（`swiftSettings: [.interoperabilityMode(.Cxx)]`），
已同步改到 `NeriPlayer` 与 `NeriPlayerTests` 两个 target。

**API 覆盖（对照本任务字段）**：

- title / artist / album：`file.tag.title` 等，读取即返回 `String`，空标签为空串；
- duration：`file.audioProperties.lengthInMilliseconds` 给毫秒精度（另有整秒字段）；
- 封面：`file.pictures` 返回 `[Picture]`，其 `.data` 即原始图片字节，`.mimeType` 给
  `image/png` 或 `image/jpeg` —— 满足「封面的 artwork 格式」要求；
- 音质信息：`bitrate / sampleRate / channels / bitsPerSample` 均在 `audioProperties` 内，
  本任务未落进模型，M2-T5 需要角标时可直接取。

**格式支持**：TagLib 的 FLAC / MPEG(ID3v1/v2) / MP4(M4A) / Ogg(Vorbis/Opus/FLAC) /
RIFF(WAV/AIFF) 解析器全部编进产物；运行时对 mp3/flac/m4a/ogg/wav 五格式的实测断言见
`Tests/AudioMetadataReaderTests.swift`。

## 4. 落库与锁定

`Package.resolved` 已固定：

```
identity: taglibswift
location: https://github.com/jeonghi/TagLibSwift.git
version:  0.2.0-rc.1
revision: a36e48f43a4cea1fd41baa0c90acdb6f35444800
```

依赖声明用 `from: "0.2.0-rc.1"`：SwiftPM 对预先存在的 pre-release tag 语法上是
「包含该版本及其之后版本」，因该仓库目前没有 0.2.0 正式版，实际锁定在 0.2.0-rc.1。
后续若出 0.2.0 正式版，需要重新跑一轮验收（重点是 pictures 与 audioProperties 的字段语义）。

## 5. 已知限制与后续风险

- **pre-release 依赖**：0.2.0-rc.1 非正式版，API 有变动可能。缓解：本仓库对 TagLibSwift
  的调用被收敛在 `AudioMetadataReader` 一个文件里，换版只改这一处。
- **C++ 互操作非 ABI 稳定**：TagLibSwift 的 README 明确提示这一点，工具链升级后需重跑构建。
  本仓库 `Package.swift` 的 swift-tools-version 保持 5.10，消费 target 打开 Cxx 互操作。
- **冷编译成本**：vendored TagLib 源码量大，CI 依赖 `.build` 缓存（`ci.yml` 已按
  `Package.resolved` 哈希缓存）。首次冷缓存构建时间明显长于此前，属预期。
- **本任务未覆盖**：写标签（只读场景不需要）、CUE/内嵌章节、DSD/APE/WavPack 等
  TagLib 支持但规划未要求的格式。
