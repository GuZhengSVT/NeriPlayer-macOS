// CrashReporter.swift
// M0-T4：全局未捕获异常（NSException）捕获 + 上次崩溃记录标记。
//
// 目标：进程因未捕获异常崩溃时，把 name / reason / 调用栈符号 / 时间戳 / App 版本
// 以 JSON 形式原子写入 Application Support/NeriPlayer/crash/last-crash.json；
// 下次启动读到该记录即可进入「安全模式」（降级启动）。
//
// 边界：本任务只做「记录 + 标记」，不建安全模式 UI 页。
//
// 用法：
//   CrashReporter.shared.install()          // App 启动最早处安装（仅一次）
//   CrashReporter.hasPendingCrashReport()   // 启动时探测
//   CrashReporter.markCrashHandled()        // 正常退出前消费记录
//   CrashReporter.clearPendingCrashReport() // 显式清除记录

import Foundation

/// 一次崩溃的结构化记录，字段与落盘 JSON 一一对应。
public struct CrashReport: Codable, Equatable {
    /// 异常名（NSException.name.rawValue）。
    public var name: String
    /// 异常描述。
    public var reason: String
    /// 调用栈符号（NSException.callStackSymbols）。
    public var callStackSymbols: [String]
    /// 崩溃发生时间。
    public var timestamp: Date
    /// App 版本（短版本 + build）。
    public var appVersion: String
    /// 记录被消费的时间；非空表示不再视为「待处理」。
    public var handledAt: Date?

    public init(
        name: String,
        reason: String,
        callStackSymbols: [String],
        timestamp: Date,
        appVersion: String,
        handledAt: Date? = nil
    ) {
        self.name = name
        self.reason = reason
        self.callStackSymbols = callStackSymbols
        self.timestamp = timestamp
        self.appVersion = appVersion
        self.handledAt = handledAt
    }
}

/// 崩溃捕获器：安装全局 handler，并负责写 / 读 / 标记 / 清除崩溃记录。
public final class CrashReporter {

    /// App 全局共享实例，落盘到真实 Application Support 目录。
    public static let shared = CrashReporter(directory: defaultDirectory())

    /// 崩溃记录文件名。
    public static let fileName = "last-crash.json"

    /// 崩溃记录所在目录（可注入，便于测试用临时目录）。
    public let directory: URL

    /// 崩溃记录文件的完整路径。
    public var reportURL: URL {
        directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// 指定目录的构造器；测试用临时目录，避免污染真实 Application Support。
    init(directory: URL) {
        self.directory = directory
    }

    // MARK: - 安装

    /// 安装全局未捕获异常处理器。C 回调无法捕获上下文，故统一路由到共享实例。
    public func install() {
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.shared.handleUncaught(exception: exception)
        }
    }

    // MARK: - 处理

    /// 处理一个未捕获异常：写出记录并返回写入内容。
    @discardableResult
    public func handleUncaught(exception: NSException) -> CrashReport {
        let report = CrashReport(
            name: exception.name.rawValue,
            reason: exception.reason ?? "",
            callStackSymbols: exception.callStackSymbols,
            timestamp: Date(),
            appVersion: Self.currentAppVersion()
        )
        store(report)
        Log.error("uncaught exception captured: \(report.name) - \(report.reason)", to: Log.ui)
        return report
    }

    // MARK: - 读写

    /// 原子写入一条记录（目录自动创建）。
    public func store(_ report: CrashReport) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(report)
            try data.write(to: reportURL, options: .atomic)
            Log.info("crash report stored at \(reportURL.path)", to: Log.ui)
        } catch {
            Log.error("failed to store crash report: \(error.localizedDescription)", to: Log.ui)
        }
    }

    /// 读取当前记录；不存在或无法解析时返回 nil。
    public func loadReport() -> CrashReport? {
        guard FileManager.default.fileExists(atPath: reportURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: reportURL)
            return try Self.decoder.decode(CrashReport.self, from: data)
        } catch {
            Log.error("failed to load crash report: \(error.localizedDescription)", to: Log.ui)
            return nil
        }
    }

    /// 是否存在「待处理」崩溃记录（文件存在且未被标记为已处理）。
    public func hasPendingCrashReport() -> Bool {
        guard FileManager.default.fileExists(atPath: reportURL.path) else { return false }
        guard let report = loadReport() else { return true }
        return report.handledAt == nil
    }

    /// 消费记录：标记为已处理（保留文件用于诊断），下次启动不再进入安全模式。
    public func markCrashHandled() {
        guard var report = loadReport(), report.handledAt == nil else { return }
        report.handledAt = Date()
        store(report)
    }

    /// 清除记录：删除崩溃记录文件。
    public func clearPendingCrashReport() {
        guard FileManager.default.fileExists(atPath: reportURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: reportURL)
            Log.info("crash report cleared", to: Log.ui)
        } catch {
            Log.error("failed to clear crash report: \(error.localizedDescription)", to: Log.ui)
        }
    }

    // MARK: - 静态便捷入口（作用于共享实例）

    /// 默认目录下是否存在待处理崩溃记录。
    public static func hasPendingCrashReport() -> Bool { shared.hasPendingCrashReport() }
    /// 消费默认目录下的崩溃记录。
    public static func markCrashHandled() { shared.markCrashHandled() }
    /// 清除默认目录下的崩溃记录。
    public static func clearPendingCrashReport() { shared.clearPendingCrashReport() }

    // MARK: - 辅助

    /// 导出一份适合附加到 issue 的诊断文本，不包含音频路径、令牌或用户库内容。
    public func diagnosticText() -> String {
        var lines = [
            "NeriPlayer diagnostics",
            "appVersion: \(AppInfo.versionString)",
            "osVersion: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "architecture: \(Self.machineArchitecture)",
            "safeModeRequired: \(hasPendingCrashReport())"
        ]
        if let report = loadReport() {
            lines += [
                "",
                "lastCrash:",
                "name: \(report.name)",
                "reason: \(report.reason)",
                "timestamp: \(Self.iso8601.string(from: report.timestamp))",
                "reportVersion: \(report.appVersion)",
                "handledAt: \(report.handledAt.map { Self.iso8601.string(from: $0) } ?? "pending")",
                "callStackSymbols:"
            ]
            lines.append(contentsOf: report.callStackSymbols.map { "  \($0)" })
        } else {
            lines += ["", "lastCrash: none"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 将诊断文本原子写入指定 URL，供分享面板或手动保存使用。
    public func exportDiagnostics(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try diagnosticText().write(to: url, atomically: true, encoding: .utf8)
    }

    /// Application Support/NeriPlayer/crash。
    static func defaultDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("NeriPlayer", isDirectory: true)
            .appendingPathComponent("crash", isDirectory: true)
    }

    /// 从统一版本契约读取版本，保证 SwiftPM 与打包应用的诊断一致。
    static func currentAppVersion() -> String { AppInfo.versionString }

    private static var machineArchitecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// 启动标记逻辑：读到崩溃记录即需要进入安全模式。
public enum CrashState {
    /// 是否需要进入安全模式（等价于存在待处理崩溃记录）。
    public static var isSafeModeRequired: Bool {
        CrashReporter.hasPendingCrashReport()
    }
}
