import AppKit
import QuartzCore
import SwiftUI

/// The actual overlay content: artwork + title + artist.
struct NowPlayingView: View {
    let track: Track
    /// Marquee and display duration for exactly this track.
    let metrics: MarqueeMetrics
    /// Number of this presentation: for the same track twice in a row
    /// (A → B → A) SwiftUI would reuse the same view and not restart the
    /// marquee.
    let presentation: Int

    @State private var artwork: NSImage?

    var body: some View {
        HStack(spacing: OverlayLayout.spacing) {
            artworkView

            VStack(alignment: .leading, spacing: 3) {
                MarqueeText(line: metrics.title)
                MarqueeText(line: metrics.secondary)
            }
            .id(presentation)

            Spacer(minLength: 0)
        }
        .padding(OverlayLayout.padding)
        .frame(width: OverlayLayout.panelSize.width, alignment: .leading)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .task(id: track.id) {
            // White area first, then fade the artwork in softly.
            artwork = nil
            let image = await ArtworkProvider.image(for: track)
            withAnimation(.easeOut(duration: 0.2)) {
                artwork = image
            }
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        ZStack {
            // Plain white while loading, no symbol.
            Color.white
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .frame(width: OverlayLayout.artworkSize, height: OverlayLayout.artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One line of the overlay. If the text fits, it behaves as before (single line,
/// truncated with an ellipsis if need be). If it is too wide, it runs to the left
/// once, from the left edge of the text area to just before the soft right edge –
/// so the beginning and the end are fully readable, the head stays level with the
/// second line, and nothing is ever drawn left of that head position.
private struct MarqueeText: View {
    let line: MarqueeMetrics.Line

    @State private var offset: CGFloat = 0
    /// Width of the exit fade on the left: 0 while the line stands still (the head
    /// is fully opaque), grows to `edgeFade` with the run.
    @State private var leftFade: CGFloat = 0

    var body: some View {
        if line.scrolls {
            scrollingLine
        } else {
            fittingLine
        }
    }

    /// Short text (or "Reduce Motion"): truncate exactly as before.
    private var fittingLine: some View {
        Text(line.text)
            .font(line.style.font)
            .lineLimit(1)
            .truncationMode(line.style.truncationMode)
            .frame(width: OverlayLayout.textAreaWidth, alignment: .leading)
    }

    /// Text that is too wide: starts at the left edge of the text area and runs
    /// through – the exit fade on the left only appears while it does.
    private var scrollingLine: some View {
        Text(line.text)
            .font(line.style.font)
            .lineLimit(1)
            // Without fixedSize SwiftUI squeezes the text into the frame – and
            // then there would be nothing left to scroll.
            .fixedSize()
            // The head rests at the left edge of the text area – that is where the
            // mask is opaque: the exit fade lies inside the text area and is 0 pt
            // wide at rest. `offset` stays the pure travel: 0 → -scrollDistance.
            .offset(x: offset)
            .frame(width: OverlayLayout.textAreaWidth, alignment: .leading)
            // The mask is exactly the text area, so nothing is ever drawn left of
            // it – the 12 pt gap to the artwork stays empty. The exit fade on the
            // left sits behind that edge and grows with the run, so the letters
            // dissolve there instead of next to the artwork.
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: leftFade)
                    Color.black
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: OverlayLayout.edgeFade)
                }
            )
            .task {
                offset = 0
                leftFade = 0
                try? await Task.sleep(nanoseconds: UInt64(MarqueeMetrics.leadingHold * 1_000_000_000))
                guard !Task.isCancelled else { return }
                // Deliberately a finite animation and no endless loop: the panel
                // lives on in memory after being hidden, and a loop would keep
                // computing there forever.
                withAnimation(.linear(duration: line.scrollDuration)) {
                    offset = -line.scrollDistance
                }
                // The exit fade on the left appears with the run.
                withAnimation(.easeOut(duration: MarqueeMetrics.leftFadeRamp)) {
                    leftFade = OverlayLayout.edgeFade
                }
            }
    }
}

/// The system's standard frosted glass (adapts to light/dark automatically).
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Shows and hides the floating overlay in the top right corner.
final class OverlayController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<NowPlayingView>?
    private var hideWorkItem: DispatchWorkItem?
    /// Counts every presentation. Serves only as view identity, so the marquee
    /// restarts even for the same track twice in a row.
    private var presentationCount = 0

    private let screenMargin: CGFloat = 16

    func present(_ track: Track) {
        // Measure once and derive **both** the marquee and the display duration
        // from it – that way the two cannot drift apart.
        let metrics = MarqueeMetrics(track: track)

        let panel = self.panel ?? makePanel()
        self.panel = panel

        presentationCount += 1
        hosting?.rootView = NowPlayingView(
            track: track,
            metrics: metrics,
            presentation: presentationCount
        )

        position(panel)
        hideWorkItem?.cancel()

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + metrics.visibleDuration, execute: item)
    }

    /// Hides a currently visible overlay **at once** – without animation and
    /// without waiting for the running 3-second clock.
    ///
    /// Needed when the app is paused: a panel that stays up until its display
    /// duration expires would be a ghost overlay even though nothing is supposed
    /// to be reported any more.
    func dismissImmediately() {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        // alpha first: the WindowServer does not always apply `orderOut` in the
        // same frame – this way the panel is invisible immediately. `present`
        // sets the value anew on the next round anyway.
        panel?.alphaValue = 0
        panel?.orderOut(nil)
    }

    private func dismiss() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: OverlayLayout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let placeholder = Track(id: "", name: "", artist: "", album: "", artworkURL: nil)
        let hosting = NSHostingView(rootView: NowPlayingView(
            track: placeholder,
            metrics: MarqueeMetrics(track: placeholder),
            presentation: 0
        ))
        hosting.frame = NSRect(origin: .zero, size: OverlayLayout.panelSize)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.hosting = hosting

        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = targetScreen() else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.maxX - OverlayLayout.panelSize.width - screenMargin,
            y: frame.maxY - OverlayLayout.panelSize.height - screenMargin
        )
        panel.setFrame(NSRect(origin: origin, size: OverlayLayout.panelSize), display: false)
    }

    /// Prefers the screen under the pointer (that is where the user is looking),
    /// otherwise the main screen.
    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
