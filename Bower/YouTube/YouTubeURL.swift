import Foundation

/// Two readings of YouTube URLs: what the user pasted into the Add sheet
/// (`classify`) and what a clicked link names (`videoLink`), which plays in
/// the app instead of opening the browser.
nonisolated enum YouTubeURL {
    enum Kind: Equatable {
        case playlist(id: String)
        case channel
        case video(id: String)
        case unsupported(String)
    }

    /// A clicked link that names one playable video.
    struct VideoLink: Equatable {
        var id: String
        /// Seconds from a `t`/`start` parameter, when the link has one.
        var start: Double?
    }

    // Single-segment paths under youtube.com that are pages, not legacy
    // vanity channel URLs.
    private static let reservedPaths: Set<String> = [
        "watch", "playlist", "shorts", "live", "embed", "v", "results",
        "feed", "hashtag", "post", "source", "clip", "attribution_link", "oembed",
    ]

    static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
            ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.host() != nil else { return nil }
        return url
    }

    private static func isYouTubeHost(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtu.be" || host.hasSuffix(".youtu.be")
    }

    private static func segments(_ url: URL) -> [String] {
        url.path().split(separator: "/").map(String.init)
    }

    private static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static func classify(_ text: String) -> Kind? {
        guard let url = parse(text), isYouTubeHost(url) else { return nil }
        let parts = segments(url)
        let first = parts.first?.lowercased() ?? ""

        if (first == "shorts" || first == "live"), parts.count >= 2 {
            return .unsupported("Shorts and live streams aren't supported.")
        }
        if let list = query(url, "list") {
            return .playlist(id: list)
        }
        if let id = videoID(url) {
            return .video(id: id)
        }
        if isChannel(parts) {
            return .channel
        }
        return nil
    }

    private static func videoID(_ url: URL) -> String? {
        let parts = segments(url)
        if url.host()?.lowercased().hasSuffix("youtu.be") == true {
            return parts.first
        }
        if parts.count >= 2, ["embed", "v"].contains(parts[0].lowercased()) {
            return parts[1]
        }
        return query(url, "v")
    }

    private static func isChannel(_ parts: [String]) -> Bool {
        guard let first = parts.first else { return false }
        if ["channel", "c", "user"].contains(first) { return parts.count >= 2 }
        if first.hasPrefix("@") { return true }
        return parts.count == 1 && !reservedPaths.contains(first.lowercased())
    }

    // MARK: Clicked links

    /// Parses a URL the user clicked into the video it names, so it can play
    /// in the app. Unlike `classify` (the Add sheet, where the playlist
    /// wins), the video wins even when a `list` is on the same URL, and
    /// shorts, live, and embed pages name playable videos too. Anything
    /// else — other YouTube pages (channels, playlists, search), other
    /// sites, anything not http(s) — returns nil and stays in the browser.
    static func videoLink(_ url: URL) -> VideoLink? {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https", isYouTubeHost(url),
              let id = clickedVideoID(url), isVideoID(id) else { return nil }
        return VideoLink(id: id, start: startTime(url))
    }

    private static func clickedVideoID(_ url: URL) -> String? {
        let parts = segments(url)
        if url.host()?.lowercased().hasSuffix("youtu.be") == true { return parts.first }
        let first = parts.first?.lowercased() ?? ""
        if first == "watch", parts.count == 1 { return query(url, "v") }
        if ["shorts", "live", "embed", "v"].contains(first), parts.count >= 2 { return parts[1] }
        return nil
    }

    /// Video IDs are exactly 11 characters of ASCII letters, digits, `-`, `_`.
    private static func isVideoID(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy { videoIDCharacters.contains($0) }
    }

    private static let videoIDCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// `t=90`, `t=90s`, `t=1m30s`, `t=1h2m3s` — or `start=`, which embeds use.
    private static func startTime(_ url: URL) -> Double? {
        guard let raw = (query(url, "t") ?? query(url, "start"))?.lowercased() else { return nil }
        if let seconds = Double(raw) { return max(seconds, 0) }
        guard let match = raw.firstMatch(of: /^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$/) else { return nil }
        let seconds = (Double(match.1 ?? "0") ?? 0) * 3600
            + (Double(match.2 ?? "0") ?? 0) * 60
            + (Double(match.3 ?? "0") ?? 0)
        return seconds > 0 ? seconds : nil
    }

    /// The `UC…` id when the URL names it directly, so no lookup is needed.
    static func directChannelID(_ text: String) -> String? {
        guard let url = parse(text) else { return nil }
        let parts = segments(url)
        guard parts.count >= 2, parts[0] == "channel", parts[1].hasPrefix("UC") else { return nil }
        return parts[1]
    }

    /// Strips tab suffixes so `/@name/videos` resolves to the channel itself.
    static func cleanedChannelURL(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.lowercased().hasPrefix("http") { value = "https://\(value)" }
        while value.hasSuffix("/") { value.removeLast() }
        for suffix in ["/featured", "/videos", "/streams", "/playlists", "/shorts"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return value
    }
}
