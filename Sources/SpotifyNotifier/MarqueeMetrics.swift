import AppKit
import SwiftUI

/// Dimensions of the overlay panel – the single source for layout **and** text
/// measurement.
///
/// The measured text width decides on the marquee and on the display duration.
/// If one of these numbers drifts against the view, the text runs too far or
/// stops too early – which is why they live together here.
enum OverlayLayout {
    static let panelSize = NSSize(width: 320, height: 84)
    static let padding: CGFloat = 12
    static let artworkSize: CGFloat = 60
    static let spacing: CGFloat = 12

    /// Soft edge (12 pt) that the marquee fades out through. Its two sides do not
    /// sit in the same place. On the **right** it lies at the end of the text area
    /// and the tail comes to rest **before** it. On the **left** it lies *inside*
    /// the text area, right behind the head's rest position: while the line stands
    /// still it is 0 pt wide – the head has to be fully opaque and level with the
    /// second line, which carries no fade at all. It only grows with the run
    /// (`MarqueeMetrics.leftFadeRamp`), so nothing is ever drawn left of the head's
    /// rest position: the gap to the artwork stays empty in every phase.
    static let edgeFade: CGFloat = 12

    /// Width that is left for the two text lines inside the panel.
    static var textAreaWidth: CGFloat {
        panelSize.width - 2 * padding - artworkSize - spacing
    }
}

/// Works out how the two title lines have to run in the overlay.
///
/// A line that is too wide is no longer truncated but starts at the left edge of
/// the text area and runs to the left once, until its end has been fully visible
/// **before** the soft right edge. The panel's display duration comes from that
/// same measurement: short titles stay up for 3 s as before, long ones stay
/// exactly as long as the marquee needs.
struct MarqueeMetrics {

    /// The two text lines of the overlay.
    enum Style {
        case title
        case secondary

        /// Font used for rendering.
        var font: Font {
            switch self {
            case .title: return .system(size: 14, weight: .semibold)
            case .secondary: return .system(size: 12)
            }
        }

        /// The same font used for measuring. Must match `font`; that is why both
        /// variants deliberately sit right next to each other.
        var measurementFont: NSFont {
            switch self {
            case .title: return .systemFont(ofSize: 14, weight: .semibold)
            case .secondary: return .systemFont(ofSize: 12, weight: .regular)
            }
        }

        /// Truncation only happens when **not** scrolling (as before).
        var truncationMode: Text.TruncationMode {
            switch self {
            case .title: return .middle
            case .secondary: return .tail
            }
        }
    }

    /// The measurement result for one line.
    struct Line {
        let style: Style
        let text: String
        /// How far the line runs to the left (0 = it fits and stands still).
        /// The head starts at the left edge of the text area, so the travel is the
        /// overflow plus the soft edge it comes to rest before. The left fade does
        /// not count: it lies inside the text area and only catches letters that
        /// are already on their way out.
        let scrollDistance: CGFloat
        /// Duration of the scroll (0 = stands still).
        var scrollDuration: TimeInterval = 0

        var scrolls: Bool { scrollDistance > 0 }

        /// Total time of this line: hold, run, hold.
        var duration: TimeInterval {
            guard scrolls else { return 0 }
            return MarqueeMetrics.leadingHold + scrollDuration + MarqueeMetrics.trailingHold
        }
    }

    /// Scroll speed in points per second.
    static let speed: CGFloat = 40
    /// A short hold so the beginning can be taken in.
    static let leadingHold: TimeInterval = 0.8
    /// A short hold at the end so the last syllable stays readable.
    static let trailingHold: TimeInterval = 0.9
    /// How fast the exit fade on the left grows once the line starts running. Short
    /// on purpose: the beginning of the title should not sit in it for long.
    static let leftFadeRamp: TimeInterval = 0.2
    /// Display duration for short titles – unchanged, the usual 3 s.
    static let baseDuration: TimeInterval = 3.0
    /// Cap for very long titles.
    static let maximumDuration: TimeInterval = 12.0
    /// Buffer between "marquee done" and hiding: the animation only starts with
    /// the first frame of the new view, while the timer already runs from
    /// `present()`.
    static let teardownMargin: TimeInterval = 0.2
    /// Only scroll from here on: the AppKit and the SwiftUI metric are not equal
    /// to the point, so a 1-pt "overflow" would twitch for no reason.
    private static let overflowTolerance: CGFloat = 2

    let title: Line
    let secondary: Line

    /// Display duration of the panel for exactly this track.
    var visibleDuration: TimeInterval {
        let needed = max(title.duration, secondary.duration) + Self.teardownMargin
        return min(max(needed, Self.baseDuration), Self.maximumDuration)
    }

    init(track: Track) {
        var titleLine = Self.measure(track.name, style: .title)
        // Empty second line: a single space keeps the height, as before.
        var secondaryLine = Self.measure(
            track.secondaryText.isEmpty ? " " : track.secondaryText,
            style: .secondary
        )

        // If the maximum duration is not enough, both lines run a little faster
        // together: better complete and quick than slow and cut off.
        let available = Self.maximumDuration - Self.teardownMargin - Self.leadingHold - Self.trailingHold
        let longest = max(titleLine.scrollDuration, secondaryLine.scrollDuration)
        if longest > available {
            let factor = available / longest
            titleLine.scrollDuration *= factor
            secondaryLine.scrollDuration *= factor
        }

        title = titleLine
        secondary = secondaryLine
    }

    private static func measure(_ text: String, style: Style) -> Line {
        // "Reduce Motion": a marquee is exactly what bothers users here – so
        // truncation stays, as before.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return Line(style: style, text: text, scrollDistance: 0)
        }

        let width = (text as NSString).size(withAttributes: [.font: style.measurementFont]).width
        guard width - OverlayLayout.textAreaWidth > overflowTolerance else {
            return Line(style: style, text: text, scrollDistance: 0)
        }

        // The head starts at the left edge of the text area, where nothing is
        // faded: the left fade only grows once the line runs and lies inside the
        // text area, so the head is fully readable during the 0.8 s leading hold –
        // and level with the second line. The tail only comes to rest once its end
        // sits **before** the right fade – otherwise it would be half transparent
        // during the trailing hold.
        let distance = width - OverlayLayout.textAreaWidth + OverlayLayout.edgeFade
        return Line(
            style: style,
            text: text,
            scrollDistance: distance,
            scrollDuration: TimeInterval(distance / speed)
        )
    }
}
