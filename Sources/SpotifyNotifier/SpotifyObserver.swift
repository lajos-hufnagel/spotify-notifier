import AppKit

/// A single, currently playing track – song **or** podcast episode.
struct Track: Equatable {
    let id: String
    let name: String
    let artist: String
    let album: String
    let artworkURL: URL?

    /// Podcast episode? Spotify hands out a `spotify:episode:…` ID for those
    /// (songs carry `spotify:track:…`).
    var isEpisode: Bool { id.hasPrefix("spotify:episode:") }

    /// Second line of the overlay: the artist for songs, the show name for
    /// podcasts.
    ///
    /// For episodes Spotify stores the podcast name in the `Album` field and
    /// leaves `Artist` empty. Without this special case only the episode title
    /// would be visible.
    var secondaryText: String {
        guard isEpisode else { return artist }
        return album.isEmpty ? artist : album
    }
}

/// Listens to Spotify's system-wide distributed notifications.
/// No login, no Spotify API, no special permissions required.
final class SpotifyObserver {
    private static let notificationName = Notification.Name("com.spotify.client.PlaybackStateChanged")

    private var observer: NSObjectProtocol?
    private var lastTrackID: String?

    /// Called only on a real track change while playing.
    var onTrackChanged: ((Track) -> Void)?

    /// Registers the observer – calling it repeatedly is harmless.
    ///
    /// Important for pausing and resuming from the menu: without this guard a
    /// second `start()` would overwrite the first registration and orphan it,
    /// so every notification would arrive twice.
    func start() {
        guard observer == nil else { return }

        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handle(notification)
        }
    }

    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observer = nil
    }

    private func handle(_ notification: Notification) {
        guard let info = notification.userInfo else { return }

        let state = info["Player State"] as? String ?? ""
        let trackID = info["Track ID"] as? String ?? ""

        // Show real track changes during playback only (play/pause and resumes
        // of the same track trigger nothing).
        guard state == "Playing", !trackID.isEmpty, trackID != lastTrackID else { return }
        lastTrackID = trackID

        let track = Track(
            id: trackID,
            name: info["Name"] as? String ?? "Unknown Track",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            artworkURL: Self.artworkURL(from: info["Artwork"] as? String)
        )
        onTrackChanged?(track)
    }

    /// Depending on its version, Spotify delivers the artwork as an https URL,
    /// a file URL or a `spotify:image:<hash>` URI.
    private static func artworkURL(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("spotify:image:") {
            let hash = raw.replacingOccurrences(of: "spotify:image:", with: "")
            return URL(string: "https://i.scdn.co/image/\(hash)")
        }
        return URL(string: raw)
    }
}
