// OnlineProxySettings.swift
// M5: bridge macOS explicit system HTTP proxies into libmpv's independent network stack.
import CFNetwork
import Foundation

public enum OnlineProxySettings {
    public static func systemProxy(for url: URL) -> String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]],
              let proxy = proxies.first else { return nil }
        let type = proxy[kCFProxyTypeKey as String] as? String
        guard type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String,
              let host = proxy[kCFProxyHostNameKey as String] as? String,
              let port = proxy[kCFProxyPortNumberKey as String] as? Int, (1...65535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = "http"; components.host = host; components.port = port
        return components.url?.absoluteString
    }
}
