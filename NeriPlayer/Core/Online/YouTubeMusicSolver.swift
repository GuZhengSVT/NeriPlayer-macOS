// YouTubeMusicSolver.swift
// M5-T6: JavaScriptCore bridge for yt-dlp/ejs player signature and throttling challenges.
import Foundation
import JavaScriptCore

public struct YouTubeMusicSolverAssets: Sendable {
    public let library: String
    public let core: String
    public init(library: String, core: String) { self.library = library; self.core = core }

    public static func bundled() -> Self? {
        guard let libraryURL = Bundle.module.url(forResource: "yt.solver.lib.min", withExtension: "js", subdirectory: "YouTubeMusic"),
              let coreURL = Bundle.module.url(forResource: "yt.solver.core.min", withExtension: "js", subdirectory: "YouTubeMusic"),
              let library = try? String(contentsOf: libraryURL, encoding: .utf8),
              let core = try? String(contentsOf: coreURL, encoding: .utf8) else { return nil }
        return Self(library: library, core: core)
    }
}

public struct YouTubeMusicSolver: Sendable {
    public let assets: YouTubeMusicSolverAssets
    public init(assets: YouTubeMusicSolverAssets) { self.assets = assets }

    public func solve(signature: String?, throttling: String?, playerJavaScript: String) throws -> (signature: String?, throttling: String?) {
        guard signature != nil || throttling != nil else { return (nil, nil) }
        guard playerJavaScript.utf8.count <= 8 * 1024 * 1024,
              (signature?.utf8.count ?? 0) <= 8192, (throttling?.utf8.count ?? 0) <= 8192,
              let context = JSContext() else { throw OnlineError.invalidInput("YouTube player challenge 过大") }
        var errors: [String] = []
        context.exceptionHandler = { _, exception in if let exception { errors.append(exception.toString()) } }
        _ = context.evaluateScript(assets.library)
        _ = context.evaluateScript("if (typeof lib !== 'undefined') { var meriyah = lib.meriyah; var astring = lib.astring; }")
        _ = context.evaluateScript(assets.core)
        if !errors.isEmpty {
            throw OnlineError.unavailable("YouTube solver 初始化失败：\(errors.prefix(2).joined(separator: "; "))")
        }
        guard let jsc = context.objectForKeyedSubscript("jsc"), !jsc.isUndefined else {
            throw OnlineError.unavailable("YouTube solver 缺少 jsc")
        }
        let input: [String: Any] = ["type": "player", "player": playerJavaScript, "requests": [], "output_preprocessed": true]
        guard let preprocessed = jsc.call(withArguments: [input])?.toDictionary() as? [String: Any],
              let source = preprocessed["preprocessed_player"] as? String else {
            throw OnlineError.unavailable("YouTube player challenge 预处理失败")
        }
        let sourceJSON = json(source)
        let script = """
        (() => {
          const _f = { n: null, sig: null };
          Function("_result", \(sourceJSON))(_f);
          const _out = {};
          if (\(signature == nil ? "false" : "true")) {
            if (typeof _f.sig !== "function") throw new Error("missing sig");
            _out.signature = _f.sig(\(json(signature ?? "")));
          }
          if (\(throttling == nil ? "false" : "true")) {
            if (typeof _f.n !== "function") throw new Error("missing n");
            _out.throttling = _f.n(\(json(throttling ?? "")));
          }
          return JSON.stringify(_out);
        })();
        """
        guard let result = context.evaluateScript(script)?.toString(),
              let data = result.data(using: .utf8),
              let output = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw OnlineError.unavailable("YouTube player challenge 求解失败")
        }
        if output["signature"] == nil && signature != nil || output["throttling"] == nil && throttling != nil {
            throw OnlineError.unavailable("YouTube player challenge 返回空结果")
        }
        return (output["signature"], output["throttling"])
    }

    private func json(_ value: String) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "\"\""
    }
}
