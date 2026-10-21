import Foundation

/// Finds a Zoom, Google Meet or Microsoft Teams join link in event fields.
public enum ConferenceLink {
    static let hosts: [(suffix: String, pathPrefixes: [String])] = [
        ("zoom.us", ["/j/", "/my/", "/w/", "/s/"]),
        ("meet.google.com", ["/"]),
        ("teams.microsoft.com", ["/l/meetup-join/", "/meet/"]),
        ("teams.live.com", ["/meet/"]),
    ]

    static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    public static func find(in fields: [String]) -> URL? {
        for field in fields {
            let range = NSRange(field.startIndex..., in: field)
            for match in detector.matches(in: field, range: range) {
                if let url = match.url, isConference(url) { return url }
            }
        }
        return nil
    }

    static func isConference(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains { entry in
            (host == entry.suffix || host.hasSuffix("." + entry.suffix))
                && entry.pathPrefixes.contains { url.path.hasPrefix($0) && url.path.count > $0.count }
        }
    }
}
