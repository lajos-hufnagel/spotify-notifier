import AppKit

/// Asks Spotify via AppleScript – **inside this very process**.
///
/// This used to run `/usr/bin/osascript` as a separate process; measured, that
/// costs 315–374 ms per query (process start + AppleScript compile +
/// AppleEvent). The same script through `NSAppleScript` needs 94–106 ms once it
/// is compiled and the connection to Spotify is up – which is exactly what
/// `warmUp()` takes care of when the app starts.
/// `@unchecked Sendable`: all mutable state is protected either by the serial
/// `queue` (script) or by `state`/`NSLock` (`unavailable`), so access from
/// several threads is safe.
final class SpotifyScriptRunner: @unchecked Sendable {

    static let shared = SpotifyScriptRunner()

    /// ASCII 31 as separator, so titles containing "|" cannot interfere.
    private static let separator = "\u{1F}"

    /// Returns: name ␟ artist ␟ album ␟ id ␟ artwork url
    private static let source = """
    with timeout of 10 seconds
        tell application "Spotify"
            set t to current track
            return (name of t) & (ASCII character 31) & (artist of t) & (ASCII character 31) & (album of t) & (ASCII character 31) & (id of t) & (ASCII character 31) & (artwork url of t)
        end tell
    end timeout
    """

    struct TrackInfo {
        let name: String
        let artist: String
        let album: String
        /// "spotify:track:…" – identical to the "Track ID" of the notification.
        let id: String
        let artworkURL: URL?
    }

    /// NSAppleScript is not thread-safe, and only one query should ever run at
    /// a time. This serial queue takes care of both.
    private let queue = DispatchQueue(label: "SpotifyNotifier.applescript", qos: .userInitiated)
    private let state = NSLock()
    private var compiled: NSAppleScript?
    private var unavailable = false

    /// Emergency brake: the overlay must never wait longer than this for Spotify.
    private let watchdog: TimeInterval = 4

    private init() {}

    /// Call this at app start. Without Spotify running the script is at least
    /// compiled, so a later query no longer pays the compile time.
    func warmUp() {
        Task.detached(priority: .utility) { [self] in
            await prepare()
            _ = await currentTrack()
        }
    }

    /// Current track or `nil` (no Spotify, missing permission, timeout).
    func currentTrack() async -> TrackInfo? {
        guard !state.withLock({ unavailable }) else { return nil }

        // Without Spotify running, AppleScript would launch the app first.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else {
            return nil
        }
        guard let raw = await execute() else { return nil }

        let parts = raw.components(separatedBy: Self.separator)
        guard parts.count >= 5 else { return nil }

        return TrackInfo(
            name: parts[0],
            artist: parts[1],
            album: parts[2],
            id: parts[3].trimmingCharacters(in: .whitespacesAndNewlines),
            artworkURL: URL(string: parts[4].trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    // MARK: - Running the script

    /// Compiles the script up front (~70 ms, sends no AppleEvents yet).
    private func prepare() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                _ = ensureCompiled()
                continuation.resume()
            }
        }
    }

    private func execute() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = Once()

            queue.async { [self] in
                let text = run()
                if once.claim() { continuation.resume(returning: text) }
            }

            // If Spotify or a permission dialog hangs: better to carry on
            // without artwork than to wait forever.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + watchdog) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Runs on `queue`.
    private func ensureCompiled() -> NSAppleScript? {
        if let compiled = state.withLock({ compiled }) { return compiled }

        var error: NSDictionary?
        guard let script = NSAppleScript(source: Self.source), script.compileAndReturnError(&error) else {
            return nil
        }
        state.withLock { compiled = script }
        return script
    }

    /// Runs on `queue`.
    private func run() -> String? {
        guard let script = ensureCompiled() else { return nil }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)

        if let error {
            // -1712 = timeout. This happens, for example, when the user has not
            // answered the permission dialog yet: discard this attempt only,
            // do not give up for good.
            if (error[NSAppleScript.errorNumber] as? Int) != -1712 {
                // e.g. -1743 "Not authorized to send Apple events" →
                // do not ask again on every single track change.
                state.withLock { unavailable = true }
            }
            return nil
        }

        let text = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }
}

/// Lets exactly one of two paths (the real result or the watchdog) finish the
/// continuation.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
