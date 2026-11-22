import SwiftUI

enum RenewioTheme {
    static let background = Color(red: 10 / 255, green: 10 / 255, blue: 15 / 255) // #0A0A0F
    static let backgroundAlt = Color(red: 18 / 255, green: 18 / 255, blue: 26 / 255) // #12121A
    static let card = Color(red: 26 / 255, green: 26 / 255, blue: 36 / 255).opacity(0.6)
    static let cardSolid = Color(red: 26 / 255, green: 26 / 255, blue: 36 / 255)
    static let foreground = Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255)
    static let mutedForeground = Color(red: 113 / 255, green: 113 / 255, blue: 122 / 255)
    static let accent = Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255) // #F59E0B
    static let accentForeground = Color(red: 10 / 255, green: 10 / 255, blue: 15 / 255)
    static let border = Color.white.opacity(0.08)
    static let borderHover = Color.white.opacity(0.15)
    static let danger = Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)
    static let success = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255)

    static let popoverWidth: CGFloat = 360

    static let radiusSm: CGFloat = 6
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 10
    static let radiusXl: CGFloat = 12
}

enum RenewioMotion {
    static let hover = Animation.easeOut(duration: 0.18)
    static let press = Animation.easeOut(duration: 0.15)
    static let transition = Animation.easeInOut(duration: 0.32)
    static let expand = Animation.easeOut(duration: 0.26)
    static let iconSpin = Animation.easeOut(duration: 0.28)

    static let pressScale: CGFloat = 0.98
    static let hoverScale: CGFloat = 1.04
}

extension AnyTransition {
    /// Horizontal push between main ↔ Settings.
    static func renewioSlide(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading),
            removal: .move(edge: forward ? .leading : .trailing)
        )
    }

    /// Kept for status/panels that still use insertion transitions (height accordion preferred).
    static var renewioExpandCollapse: AnyTransition {
        .modifier(
            active: VerticalExpandCollapseModifier(progress: 0),
            identity: VerticalExpandCollapseModifier(progress: 1)
        )
    }
}

/// Animates vertical scale from the top. No opacity ramp.
private struct VerticalExpandCollapseModifier: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let clamped = min(1, max(0, progress))
        content
            .scaleEffect(x: 1, y: max(clamped, 0.001), anchor: .top)
            .clipped()
            .allowsHitTesting(clamped > 0.9)
    }
}
