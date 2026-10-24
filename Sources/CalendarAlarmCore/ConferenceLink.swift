import Foundation

/// Finds a Zoom, Google Meet, Microsoft Teams or Webex join link in event fields.
public enum ConferenceLink {
    static let zoomPaths = ["/j/", "/my/", "/w/", "/s/"]
    static let teamsPaths = ["/l/meetup-join/", "/meet/"]
    static let hosts: [(suffix: String, pathPrefixes: [String])] = [
        ("zoom.us", zoomPaths),
        ("zoom.com", zoomPaths),
        ("zoom.de", zoomPaths),
        ("zoomgov.com", zoomPaths),
        ("meet.google.com", ["/"]),
        ("teams.microsoft.com", teamsPaths),
        ("teams.microsoft.us", teamsPaths),
        ("teams.cloud.microsoft", teamsPaths),
        ("teams.live.com", ["/meet/"]),
        ("webex.com", ["/meet/", "/join/"]),
    ]

    static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    public static func find(in fields: [String]) -> URL? {
        for field in fields {
            // HTML invitation bodies escape the query separator.
            let text = field.replacingOccurrences(of: "&amp;", with: "&")
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                if let url = match.url.map(unwrapped), isConference(url) { return url }
            }
        }
        return nil
    }

    static func isConference(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        func on(_ suffix: String) -> Bool { host == suffix || host.hasSuffix("." + suffix) }
        // Webex site links: https://<site>.webex.com/<site>/j.php?MTID=...
        if on("webex.com"), url.path.hasSuffix("/j.php"), url.query?.contains("MTID=") == true { return true }
        return hosts.contains { entry in
            on(entry.suffix) && entry.pathPrefixes.contains { url.path.hasPrefix($0) && url.path.count > $0.count }
        }
    }

    // MARK: Link protection

    /// The link inside any mail-security or redirect wrappers (Microsoft Safe
    /// Links, Proofpoint, Barracuda, Google), decoded locally without a request.
    static func unwrapped(_ url: URL) -> URL {
        var url = url
        // Mail that crosses two organizations can be wrapped twice.
        for _ in 0..<3 {
            guard let inner = unwrapOnce(url) else { break }
            url = inner
        }
        return url
    }

    static func unwrapOnce(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func query(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        let inner: String?
        if [".safelinks.protection.outlook.com", ".safelinks.protection.office365.us", ".safelinks.protection.outlook.de"]
            .contains(where: host.hasSuffix) {
            inner = query("url")
        } else if host == "urldefense.com" || host == "urldefense.proofpoint.com" {
            if let start = url.absoluteString.range(of: "/v3/__") {
                inner = proofpointV3(String(url.absoluteString[start.upperBound...]))
            } else if url.path.hasPrefix("/v2/url") {
                // v2 encodes "%" as "-" and "/" as "_".
                inner = query("u")?.replacingOccurrences(of: "-", with: "%")
                    .replacingOccurrences(of: "_", with: "/").removingPercentEncoding
            } else {
                inner = query("u")
            }
        } else if host == "linkprotect.cudasvc.com" {
            inner = query("a")
        } else if (host == "google.com" || host == "www.google.com"), url.path == "/url" {
            inner = query("q") ?? query("url")
        } else {
            inner = nil
        }
        guard let inner, let result = URL(string: inner), ["http", "https"].contains(result.scheme?.lowercased()) else { return nil }
        return result
    }

    /// Proofpoint v3 links look like `<url>__;<base64url>!!<signature>`. Each `*`
    /// in `<url>` stands for the next character of the decoded base64, and `**X`
    /// stands for the next n of them, where n is X's index in the base64url
    /// alphabet plus 2.
    static func proofpointV3(_ rest: String) -> String? {
        guard let split = rest.range(of: "__;") else { return nil }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var encoded = rest[split.upperBound...].prefix { $0 != "!" }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let replaced = String(data: data, encoding: .utf8) else { return nil }
        var pool = Array(replaced)[...]
        var chars = Array(rest[..<split.lowerBound])[...]
        var out = ""
        while let c = chars.popFirst() {
            guard c == "*" else { out.append(c); continue }
            var count = 1
            if chars.first == "*", chars.count >= 2, let n = alphabet.firstIndex(of: chars[chars.startIndex + 1]) {
                count = n + 2
                chars = chars.dropFirst(2)
            }
            guard pool.count >= count else { return nil }
            out += pool.prefix(count)
            pool = pool.dropFirst(count)
        }
        return out
    }
}
