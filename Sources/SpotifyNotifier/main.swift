import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let observer = SpotifyObserver()
    private let overlay = OverlayController()

    /// Inactive = the observer is detached and no overlay shows up.
    /// Deliberately memory-only: after a restart the app is always active,
    /// otherwise "why is nothing showing up?" turns into a long hunt for a
    /// cause.
    private var isActive = true

    /// Menu rows whose text and state mirror the active flag.
    private var statusLine: NSMenuItem!
    private var activeToggle: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, menu bar only.
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()

        observer.onTrackChanged = { [weak self] track in
            // Second safety net: a call that is already on its way must not
            // present anything once the app was deactivated.
            guard let self, self.isActive else { return }
            self.overlay.present(track)
        }

        // Puts observer, menu and icons into one consistent start state.
        applyActiveState()

        // Warm up artwork fetching: compile the AppleScript once, build the
        // AppleEvent connection to Spotify and put the running artwork into the
        // caches. That makes the first overlay ~3× faster.
        SpotifyScriptRunner.shared.warmUp()
        ArtworkProvider.warmUp()
    }

    func applicationWillTerminate(_ notification: Notification) {
        observer.stop()
    }

    // MARK: - Active / Paused

    @objc private func toggleActive() {
        isActive.toggle()
        applyActiveState()
    }

    /// The single place that applies the active state – menu, icon and observer
    /// can therefore not drift apart.
    private func applyActiveState() {
        if isActive {
            observer.start()
            statusLine.title = "SpotifyNotifier active"
        } else {
            observer.stop()
            // An overlay that is visible right now must not linger as a ghost.
            overlay.dismissImmediately()
            statusLine.title = "SpotifyNotifier paused"
        }

        activeToggle.state = isActive ? .on : .off

        let description = isActive ? "SpotifyNotifier active" : "SpotifyNotifier paused"
        statusItem.button?.toolTip = description

        // A struck-through note as a clear signal; `appearsDisabled` dims the
        // icon as well, in case that symbol should ever go missing.
        let symbol = isActive ? "music.note" : "music.note.slash"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !isActive
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "SpotifyNotifier")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "SpotifyNotifier"
        }

        let menu = NSMenu()

        statusLine = NSMenuItem(title: "SpotifyNotifier active", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(.separator())

        // The check mark shows whether notifications currently get through.
        activeToggle = NSMenuItem(title: "Active", action: #selector(toggleActive), keyEquivalent: "")
        activeToggle.target = self
        activeToggle.state = .on
        menu.addItem(activeToggle)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
