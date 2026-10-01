// AppURLRouter.swift
// M8-T9: macOS URL Scheme routing for the four common playback actions.
import Foundation

public enum AppURLAction: Equatable, Sendable {
    case play
    case pause
    case next
    case previous
}

public enum AppURLRouter {
    public static func action(for url: URL) -> AppURLAction? {
        guard url.scheme?.lowercased() == AppInfo.urlScheme else { return nil }
        let command = (url.host ?? url.path.split(separator: "/").first.map(String.init))?.lowercased()
        switch command {
        case "play": return .play
        case "pause": return .pause
        case "next": return .next
        case "previous", "prev": return .previous
        default: return nil
        }
    }
}
