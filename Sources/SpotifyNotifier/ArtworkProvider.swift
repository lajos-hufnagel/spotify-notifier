import AppKit

/// Fetches the artwork image for a track.
///
/// Order – every successful step fills the cache for the next round:
///  1. Cache: track ID or album already known → instantly, no network and no
///     AppleScript. Covers repeats and skipping inside the same album.
///  2. Artwork URL from the Spotify notification (if that Spotify version sends
///     one at all – current versions do not).
///  3. AppleScript query for the current Spotify track via
///     `SpotifyScriptRunner`: inside this process, ~100 ms instead of ~330 ms.
///     Returns the exact artwork, but triggers the one-time system dialog
///     "SpotifyNotifier wants to control Spotify" (Automation).
///  4. iTunes Search API as a silent fallback: no login, no API keys, no
///     prompt – in exchange the hit can, in theory, be the wrong one.
enum ArtworkProvider {

    /// Fully loaded artwork, keyed by track ID.
    private static let images = NSCache<NSString, NSImage>()
    /// Known artwork URLs, keyed by track ID and by album.
    private static let urlStrings = NSCache<NSString, NSString>()

    /// Call this at app start: pulls the currently playing artwork into the
    /// caches and builds the HTTP connection to i.scdn.co on the way, so the
    /// first real artwork download skips the DNS/TLS handshake.
    static func warmUp() {
        Task.detached(priority: .utility) {
            guard let info = await SpotifyScriptRunner.shared.currentTrack(),
                  let track = track(from: info) else { return }
            _ = await image(for: track)
        }
    }

    /// Returns the artwork, or `nil` when nothing usable was found.
    static func image(for track: Track) async -> NSImage? {
        // The placeholder track (empty ID) must not trigger anything.
        guard !track.id.isEmpty else { return nil }

        if let cached = images.object(forKey: track.id as NSString) { return cached }

        // 1. Straight from the notification (if present).
        if let url = track.artworkURL, let image = await ArtworkLoader.load(from: url) {
            return store(image, url: url, track: track, albumIsExact: true)
        }

        // 2. Exact artwork via AppleScript.
        if let url = await artworkURL(for: track), let image = await ArtworkLoader.load(from: url) {
            return store(image, url: url, track: track, albumIsExact: true)
        }

        // 3. Last resort: the iTunes search. The hit is deliberately not
        //    remembered as album artwork, it can be the wrong one.
        if let url = await iTunesArtworkURL(for: track), let image = await ArtworkLoader.load(from: url) {
            return store(image, url: url, track: track, albumIsExact: false)
        }

        return nil
    }

    // MARK: - Cache

    @discardableResult
    private static func store(_ image: NSImage, url: URL, track: Track, albumIsExact: Bool) -> NSImage {
        images.setObject(image, forKey: track.id as NSString)
        urlStrings.setObject(url.absoluteString as NSString, forKey: track.id as NSString)
        if albumIsExact, let key = albumKey(for: track) {
            urlStrings.setObject(url.absoluteString as NSString, forKey: key)
        }
        return image
    }

    /// Same album + same artist → same artwork.
    ///
    /// Deliberately `nil` for podcast episodes: although Spotify stores the show
    /// name in the `Album` field, every episode has artwork of its own. A shared
    /// show key would briefly show the artwork of the previous episode of that
    /// show. Episodes are therefore cached by their ID only.
    private static func albumKey(for track: Track) -> NSString? {
        guard !track.isEpisode else { return nil }
        guard !track.album.isEmpty else { return nil }
        return (normalize(track.album) + "|" + normalize(track.artist)) as NSString
    }

    // MARK: - AppleScript

    private static func artworkURL(for track: Track) async -> URL? {
        // Cache: same track or same album already resolved?
        if let cached = urlStrings.object(forKey: track.id as NSString), let url = URL(string: cached as String) {
            return url
        }
        if let key = albumKey(for: track),
           let cached = urlStrings.object(forKey: key), let url = URL(string: cached as String) {
            return url
        }

        guard let info = await SpotifyScriptRunner.shared.currentTrack() else { return nil }

        // Safety net: only accept it when it really is the reported track.
        guard matches(track: track, name: info.name, artist: info.artist) else { return nil }
        guard let url = info.artworkURL else { return nil }

        // Exact hit → the album mapping may be remembered.
        if let key = albumKey(for: track) {
            urlStrings.setObject(url.absoluteString as NSString, forKey: key)
        }
        return url
    }

    /// Builds the same track from the AppleScript reply that the notification
    /// delivers (same "spotify:track:…" ID) – that way both paths share one
    /// cache.
    private static func track(from info: SpotifyScriptRunner.TrackInfo) -> Track? {
        guard !info.id.isEmpty, !info.name.isEmpty else { return nil }
        return Track(id: info.id, name: info.name, artist: info.artist, album: info.album, artworkURL: info.artworkURL)
    }

    // MARK: - iTunes-Fallback

    private static func iTunesArtworkURL(for track: Track) async -> URL? {
        let term = [track.artist, track.name].filter { !$0.isEmpty }.joined(separator: " ")
        guard !term.isEmpty else { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components?.url else { return nil }

        struct Response: Decodable {
            struct Result: Decodable {
                let trackName: String?
                let artistName: String?
                let artworkUrl100: String?
            }
            let results: [Result]
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(Response.self, from: data)
            let hit = response.results.first {
                matches(track: track, name: $0.trackName ?? "", artist: $0.artistName ?? "")
            }
            guard let raw = hit?.artworkUrl100 else { return nil }
            // 100x100 → 600x600 (same motif, high enough for the overlay)
            let bigger = raw.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            return URL(string: bigger)
        } catch {
            return nil
        }
    }

    // MARK: - Vergleich

    /// Compares title/artist tolerantly (brackets, dashes, accents, letter case).
    private static func matches(track: Track, name: String, artist: String) -> Bool {
        let wantedName = normalize(track.name)
        let gotName = normalize(name)
        guard !wantedName.isEmpty, !gotName.isEmpty else { return false }

        if wantedName == gotName { return true }

        let wantedArtist = normalize(track.artist)
        let gotArtist = normalize(artist)
        let artistMatches = !wantedArtist.isEmpty && !gotArtist.isEmpty
            && (wantedArtist == gotArtist
                || wantedArtist.contains(gotArtist)
                || gotArtist.contains(wantedArtist))

        return artistMatches && (gotName.contains(wantedName) || wantedName.contains(gotName))
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

/// Loads the artwork image asynchronously (https and file://).
enum ArtworkLoader {
    static func load(from url: URL?) async -> NSImage? {
        guard let url else { return nil }
        if url.isFileURL {
            return NSImage(contentsOf: url)
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return NSImage(data: data)
        } catch {
            return nil
        }
    }
}
