// OnlinePlaybackHeaders.swift
// M5: validate request headers before passing them into libmpv.

import Foundation

public enum OnlinePlaybackHeaders {
    public static func validated(_ headers: [String: String]) throws -> [String: String] {
        guard headers.count <= 32 else { throw OnlineError.invalidInput("播放请求头数量过多") }
        let tokenCharacters = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t\r\n")
        return try headers.map { key, value in
            guard !key.isEmpty, key.utf8.count <= 128, key.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f && !tokenCharacters.contains($0) }),
                  value.utf8.count <= 8192, value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
                throw OnlineError.invalidInput("在线播放请求头无效")
            }
            return (key, value)
        }.reduce(into: [String: String]()) { $0[$1.0] = $1.1 }
    }

}
