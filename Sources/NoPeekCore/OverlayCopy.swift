import Foundation

/// All the snark shown on the overlay, in one place.
public enum OverlayCopy {
    public static func tagline(for theme: OverlayThemeID) -> String {
        switch theme {
        case .googlyEyes, .shuffle: return "Nice try. I see you 👀"
        case .bouncer: return "Your name's not on the list, buddy."
        case .peekaboo: return "This one's private ✨"
        }
    }

    public static func roasts(theme: OverlayThemeID, appName: String, ownerName: String) -> [String] {
        switch theme {
        case .peekaboo:
            return [
                "Nothing to see here, promise.",
                "Psst… this isn't your laptop.",
                "Still peeking? Bold choice.",
                "\(appName) is shy around strangers.",
                "\(ownerName) will hear about this 💌",
                "Okay, now you're just being nosy.",
                "Curiosity is cute. This isn't.",
            ]
        default:
            return [
                "Nope.",
                "Still nope. 🙅",
                "Seriously? \(appName) isn't yours.",
                "Hands off, please.",
                "Go message from your own laptop.",
                "This incident will be reported to \(ownerName).",
                "Cardio is good for you. This isn't cardio.",
                "I can do this all day.",
            ]
        }
    }

    public static func caption(
        theme: OverlayThemeID,
        attempts: Int,
        capturesLeft: Int?,
        hasCaught: Bool,
        isCapturing: Bool,
        appName: String,
        ownerName: String
    ) -> String {
        if isCapturing { return "Smile! 📸" }
        if hasCaught { return "I already have your photo 😏 \(ownerName) will see it." }
        if capturesLeft == 1 { return "One more try and I'm taking your photo 📸" }
        if attempts <= 0 { return tagline(for: theme) }
        let lines = roasts(theme: theme, appName: appName, ownerName: ownerName)
        return lines[(attempts - 1) % lines.count]
    }
}
