// LibraryDirectoryStore.swift
// NeriPlayer macOS —— 媒体库扫描目录的持久化管理（移植规划 M3-T5）。
//
// 解决什么问题：M2-T2 的扫描器是「调用方给一个目录 URL，扫完就完了」—— 关掉应用就忘了用户
// 把音乐放在哪。本文件把「用户加入过哪些目录」记下来，让扫描目录可以在设置页里查看、增删、
// 重新扫描，而不是每次都要重新去文件选择器里翻一遍。
//
// 存储形态：整份列表 JSON 编码后存进设置层的一个 Data 键。为什么不建库表：目录是「用户偏好」
// 量级的数据（个位数到几十条），且没有跨表关系与并发写入；放进设置里可以跟着设置一起备份/重置，
// 也避免为一张几行的表再走一次迁移。
//
// 安全作用域书签：沙盒构建下，应用重启后要重新访问用户选过的目录，必须靠
// security-scoped bookmark。本仓库当前不是沙盒构建（M2 验收记录已注明书签待 M9 打包定型时
// 复核），因此书签是「能拿到就存、拿不到就只存路径」的可选字段：
//   - 创建：优先带 .withSecurityScope，失败则退回普通书签，再失败就留空；
//   - 解析：有书签用书签（解析成功后 startAccessingSecurityScopedResource），没有或解析失败
//     回落到路径。
// 这样在非沙盒环境行为与「只存路径」完全一致，M9 打开沙盒后不需要改数据结构。

import Foundation

// MARK: - 目录项

/// 一条已加入媒体库的音乐目录。
public struct LibraryDirectory: Codable, Equatable, Identifiable, Sendable {

    /// 稳定标识。之所以用独立 id 而不是拿路径当 id：路径可能因为重命名/移动而变化，
    /// 用路径当 id 会让 SwiftUI 列表在路径变化时把整行当成新行（丢失选中态与动画）。
    public let id: UUID
    /// 标准化后的绝对路径。去重与相等判断都以它为准。
    public var path: String
    /// 安全作用域书签；拿不到时为 nil。
    public var bookmark: Data?
    /// 加入时间，用于稳定排序。
    public var addedAt: Date

    public init(id: UUID = UUID(), path: String, bookmark: Data? = nil, addedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.addedAt = addedAt
    }

    /// 目录路径对应的 URL（不含书签解析；需要访问权限时用 LibraryDirectoryStore.resolve）。
    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 列表里显示的名称（最后一段路径）。
    public var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? path : name
    }

    /// 两份目录项是否指向同一个位置。用于去重：同一目录被加入两次应视为同一个。
    public func pointsToSameLocation(as other: LibraryDirectory) -> Bool {
        path == other.path
    }
}

// MARK: - 存储

/// 扫描目录列表的读写。所有方法都是「读全量 → 改 → 写全量」：
/// 列表规模是个位数到几十条，整份改写比增量维护简单得多，也不会出现半更新的中间态。
public struct LibraryDirectoryStore: Sendable {

    private let settings: SettingsStore

    public init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    // MARK: 读取

    /// 已加入的目录，按加入时间升序（先加的在前面，列表顺序稳定）。
    public func all() -> [LibraryDirectory] {
        decode(settings.value(for: SettingsKeys.libraryDirectories))
            .sorted { $0.addedAt < $1.addedAt }
    }

    /// 该路径是否已在列表里（按标准化路径比较）。
    public func contains(_ url: URL) -> Bool {
        let path = Self.normalize(url)
        return all().contains { $0.path == path }
    }

    // MARK: 写入

    /// 加入一个目录。
    ///
    /// 幂等：已经在列表里时返回既有项且不改动任何字段 —— 重复加入不该刷新加入时间，
    /// 否则列表顺序会在一次重复导入后突然变化。
    ///
    /// - Parameter bookmark: 调用方已创建好的书签；默认由本方法尝试创建。
    @discardableResult
    public func add(_ url: URL, bookmark: Data? = nil, at date: Date = Date()) -> LibraryDirectory {
        let path = Self.normalize(url)
        var directories = all()
        if let existing = directories.first(where: { $0.path == path }) {
            return existing
        }
        let resolvedBookmark = bookmark ?? Self.makeBookmark(for: url)
        let directory = LibraryDirectory(path: path, bookmark: resolvedBookmark, addedAt: date)
        directories.append(directory)
        persist(directories)
        Log.ui.info("媒体库目录已加入：\(path, privacy: .public)")
        return directory
    }

    /// 按 id 移除。不存在时是 no-op。
    public func remove(id: UUID) {
        var directories = all()
        let before = directories.count
        directories.removeAll { $0.id == id }
        guard directories.count != before else { return }
        persist(directories)
        Log.ui.info("媒体库目录已移除：id=\(id.uuidString, privacy: .public)")
    }

    /// 清空列表。
    public func removeAll() {
        persist([])
    }

    // MARK: 解析

    /// 解析出一条目录当前可用的 URL，并（在需要时）取得安全作用域访问权。
    ///
    /// 返回 nil 表示解析不出可用目录（书签与路径都不可用，或目录已被删除）。
    ///
    /// 关于访问权的释放：这里刻意不配对提供 `stopAccessing`。媒体库目录是应用长期需要访问的资源，
    /// 按「进程存活期间持有访问权」处理最简单也最不容易出错（在沙盒下提前释放会让后台重新扫描
    /// 突然失败，而这类 bug 只在打包后才暴露）。非沙盒构建下这两个调用都是 no-op。
    public func resolve(_ directory: LibraryDirectory) -> URL? {
        if let bookmark = directory.bookmark {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = resolved.startAccessingSecurityScopedResource()
                return resolved
            }
            // 书签解析失败（常见于库文件被移动、或应用标识变化）时不直接失败：
            // 回落到路径，让「只存了路径」与「书签过期」两种情形都还能用。
            Log.ui.debug("目录书签解析失败，回落到路径：\(directory.path, privacy: .public)")
        }
        let url = directory.url
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: 内部

    /// 路径标准化：去掉尾部斜杠、解析 `..`、统一大小写敏感盘上的表示。
    /// 去重与相等都以标准化结果为准，避免「同一目录两种写法」产生两行。
    static func normalize(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// 尝试创建书签。带安全作用域优先，失败退回普通书签，再失败留空（只存路径）。
    static func makeBookmark(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func persist(_ directories: [LibraryDirectory]) {
        if directories.isEmpty {
            // 空列表写回默认值（空 Data），而不是 JSON 的 "[]"：
            // 让「从未配置」与「配置过但清空了」在存储里是同一种状态，读取侧少一个分支。
            settings.set(Data(), for: SettingsKeys.libraryDirectories)
            return
        }
        do {
            let data = try JSONEncoder().encode(directories)
            settings.set(data, for: SettingsKeys.libraryDirectories)
        } catch {
            // 编码失败不该让调用方崩掉，但也不能静默：记日志并保持原值不变。
            Log.ui.error("媒体库目录列表保存失败（保留原值）：\(error.localizedDescription)")
        }
    }

    /// 解码列表。空 Data 或解码失败都返回空列表 —— 目录列表是「锦上添花」的配置，
    /// 坏一份数据不该让设置页打不开。
    private func decode(_ data: Data) -> [LibraryDirectory] {
        guard !data.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([LibraryDirectory].self, from: data)
        } catch {
            Log.ui.error("媒体库目录列表解析失败（按空处理）：\(error.localizedDescription)")
            return []
        }
    }
}
