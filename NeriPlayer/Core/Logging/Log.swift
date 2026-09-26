// Log.swift
// 统一日志入口。M0-T3：封装 os.log（Logger），全应用共用 subsystem "moe.ouom.NeriPlayer"，
// 按业务域划分 category（player/db/net/ui/usb），避免各处散落 `Logger(subsystem:category:)`
// 造成 subsystem 写错、category 命名不统一。
//
// 用法：
//   Log.player.info("...")            // 直接用对应 category 的 Logger
//   Log.net.error("...")
//   Log.info("...", to: Log.db)       // 按级别分发的便捷入口

import os

/// 全应用统一日志入口。subsystem 固定，category 分五个业务域。
public enum Log {

    /// 固定 subsystem，全局唯一，便于在 Console.app / `log stream` 中按子系统过滤。
    public static let subsystem = "moe.ouom.NeriPlayer"

    /// 播放内核与播放队列。
    public static let player = Logger(subsystem: subsystem, category: "player")
    /// 数据库与持久化（GRDB / 设置存储）。
    public static let db = Logger(subsystem: subsystem, category: "db")
    /// 网络请求（API、下载、同步）。
    public static let net = Logger(subsystem: subsystem, category: "net")
    /// 界面与交互。
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    /// USB 设备与底层传输。
    public static let usb = Logger(subsystem: subsystem, category: "usb")

    /// 按级别把消息转发到指定 category 的 Logger（debug）。
    public static func debug(_ message: String, to logger: Logger) {
        logger.debug("\(message, privacy: .public)")
    }

    /// 按级别把消息转发到指定 category 的 Logger（info）。
    public static func info(_ message: String, to logger: Logger) {
        logger.info("\(message, privacy: .public)")
    }

    /// 按级别把消息转发到指定 category 的 Logger（error）。
    public static func error(_ message: String, to logger: Logger) {
        logger.error("\(message, privacy: .public)")
    }
}
