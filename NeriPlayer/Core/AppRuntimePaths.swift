import Foundation

/// 独立验证包可指定临时数据根；正式包继续使用用户原有目录与 Keychain。
/// 仅 validation bundle 接受该字段，避免一次验证污染真实媒体库或触发凭据授权。
enum AppRuntimePaths {
    static let validationRoot: URL? = {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".validation") == true,
              let path = Bundle.main.object(forInfoDictionaryKey: "NeriPlayerValidationRoot") as? String,
              path.hasPrefix("/"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    static var applicationSupport: URL {
        if let validationRoot { return validationRoot.appendingPathComponent("ApplicationSupport", isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("NeriPlayer", isDirectory: true)
    }

    static var caches: URL {
        if let validationRoot { return validationRoot.appendingPathComponent("Caches", isDirectory: true) }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("NeriPlayer", isDirectory: true)
    }
}
