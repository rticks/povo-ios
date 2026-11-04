import Foundation

public enum WebPolicy {
    // Compatibility contract of the existing, traffic-tested Android API
    // adapter. This is the upstream protocol version, not this app's version.
    public static let protocolVersion = "1.69.0-JP"
    public static let purchaseReturn = URL(string: "https://povo.jp/success")!
    public static func isPovo(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return host == "povo.jp" || host.hasSuffix(".povo.jp")
    }
    public static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }
    public static func entry(page: PovoWebPage, token: String?, deviceID: String?) -> URL? {
        guard let base = URL(string: page.link), isPovo(base), WebPageKind.matching(page.link) == page.kind,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        // An unauthenticated page never inherits credentials, even if a cached
        // or server-supplied URL happens to contain them.
        var query = (components.queryItems ?? []).filter { !["auth_token", "device_id"].contains($0.name) }
        func add(_ key: String, _ value: String) {
            if !query.contains(where: { $0.name == key }) { query.append(URLQueryItem(name: key, value: value)) }
        }
        if page.needsXAuth {
            guard let token = token?.nilIfBlank, let device = deviceID?.nilIfBlank else { return nil }
            // Credentials MUST come from this session, never from a stale URL.
            add("auth_token", token); add("device_id", device)
            add("webview", "1"); add("native", "1"); add("reset", "true")
            add("use_native_ekyc_api", "1"); add("app_version", protocolVersion)
        }
        if let exit = page.exitURL?.nilIfBlank { add("return_url", exit) }
        components.queryItems = query
        return components.url
    }
    public static func matchesReturn(_ url: URL, expected: URL = purchaseReturn) -> Bool {
        isHTTPS(url) && url.host?.lowercased() == expected.host?.lowercased()
            && (url.port ?? 443) == (expected.port ?? 443) && url.path == expected.path
    }
    public static func matchesExit(_ url: URL, path: String?) -> Bool {
        guard isPovo(url), let path = path?.nilIfBlank else { return false }
        let expected = path.hasPrefix("/") ? path : "/" + path
        return url.path == expected
    }
    public static func isSignedOut(_ url: URL) -> Bool {
        isPovo(url) && ["/web/login", "/logged_out"].contains { url.path == $0 || url.path.hasPrefix($0 + "/") }
    }
    public static func rotatedToken(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "webfront" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "auth_token" })?.value?.nilIfBlank
    }
    public static func externalURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "browser", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "https"
        // Never send session material to a browser/history or another host.
        guard !(c.queryItems ?? []).contains(where: { ["auth_token", "device_id", "token"].contains($0.name.lowercased()) }),
              let result = c.url, isHTTPS(result) else { return nil }
        return result
    }
    public static func isContact(_ url: URL) -> Bool { ["tel", "mailto", "sms", "smsto"].contains(url.scheme?.lowercased() ?? "") }
    public static func safeCallback(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_$][A-Za-z0-9_$]{0,63}$", options: .regularExpression) != nil
    }
    public static func quotedJS(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

/// Explicitly redacts credential fields before a debug response is displayed or
/// shared. Does not claim to anonymise personal information in arbitrary JSON.
public enum DiagnosticRedactor {
    private static let sensitive: Set<String> = [
        "authtoken", "pintoken", "sessiontoken", "accesstoken", "refreshtoken", "xauth", "authorization", "token",
        "otpcode", "authid", "deviceid", "devicetoken", "password", "pin"
    ]
    private static func isSensitive(_ key: String) -> Bool {
        sensitive.contains(key.lowercased().filter { $0.isLetter || $0.isNumber })
    }
    public static func redact(_ raw: String) -> String {
        if let data = raw.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            func clean(_ value: Any) -> Any {
                if let dict = value as? [String: Any] {
                    return dict.mapValuesWithKeys { key, value in isSensitive(key) ? "[REDACTED]" : clean(value) }
                }
                if let array = value as? [Any] { return array.map(clean) }
                if let text = value as? String { return scrub(text) }
                return value
            }
            if let encoded = try? JSONSerialization.data(withJSONObject: clean(value), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) {
                return String(decoding: encoded, as: UTF8.self)
            }
        }
        return scrub(raw)
    }
    private static func scrub(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"(?i)((?:auth_?token|pin_?token|session_?token|access_?token|refresh_?token|device_?id|otp_?code|auth_?id)\s*["']?\s*[:=]\s*["']?)([^&\s"'<>,}]+)"#,
                                           with: "$1[REDACTED]", options: .regularExpression)
        text = text.replacingOccurrences(of: "[A-Za-z0-9_-]{12,}\\.[A-Za-z0-9_-]{12,}\\.[A-Za-z0-9_-]{8,}",
                                         with: "[REDACTED JWT]", options: .regularExpression)
        return text
    }
}

private extension Dictionary where Key == String, Value == Any {
    func mapValuesWithKeys(_ transform: (String, Any) -> Any) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}
