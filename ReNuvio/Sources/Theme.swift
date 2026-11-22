import AppKit
import SwiftUI

enum ReNuvioTheme {
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
}

// MARK: - Surfaces & Layout Primitives

struct AmbientBackdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            ReNuvioTheme.background
            RadialGradient(
                colors: [
                    ReNuvioTheme.accent.opacity(0.07),
                    ReNuvioTheme.accent.opacity(0.02),
                    Color.clear,
                ],
                center: .top,
                startRadius: 8,
                endRadius: 210
            )
            .allowsHitTesting(false)
        }
    }
}

struct CardSurface: View {
    var fill: Color = ReNuvioTheme.cardSolid.opacity(0.75)
    var border: Color = ReNuvioTheme.border
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
    }
}

struct SectionCard<Trailing: View, Content: View>: View {
    let title: String
    let spacing: CGFloat
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        spacing: CGFloat = 8,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.spacing = spacing
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(ReNuvioTheme.mutedForeground)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurface())
    }
}

extension SectionCard where Trailing == EmptyView {
    init(
        _ title: String,
        spacing: CGFloat = 8,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title, spacing: spacing, trailing: { EmptyView() }, content: content)
    }
}

struct SelectableOptionRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    var subtitleTruncation: Text.TruncationMode = .tail
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ReNuvioTheme.foreground)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ReNuvioTheme.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(subtitleTruncation)
                }
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        isSelected
                            ? ReNuvioTheme.accent
                            : ReNuvioTheme.mutedForeground.opacity(0.45)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                CardSurface(
                    fill: isSelected ? ReNuvioTheme.accent.opacity(0.12) : Color.white.opacity(0.03),
                    border: isSelected ? ReNuvioTheme.accent.opacity(0.45) : ReNuvioTheme.border,
                    cornerRadius: 8
                )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Interactive Controls & Styles

struct PopoverIconButton: View {
    let systemImage: String
    let iconSize: CGFloat
    let iconWeight: Font.Weight
    let hoverTint: Color
    let helpText: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var pushedCursor = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: iconWeight))
                .foregroundStyle(isHovered ? hoverTint : ReNuvioTheme.mutedForeground)
                .frame(width: 32, height: 32)
                .background(
                    isHovered ? hoverTint.opacity(0.15) : Color.white.opacity(0.05)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isHovered ? hoverTint.opacity(0.45) : ReNuvioTheme.border,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hovering in
            isHovered = hovering
            if hovering && !pushedCursor {
                NSCursor.pointingHand.push()
                pushedCursor = true
            } else if !hovering && pushedCursor {
                NSCursor.pop()
                pushedCursor = false
            }
        }
        .onDisappear {
            if pushedCursor {
                NSCursor.pop()
                pushedCursor = false
            }
            isHovered = false
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

struct InlineActionLink: View {
    let title: String
    let systemImage: String
    var disabled = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var pushedCursor = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(
                disabled
                    ? ReNuvioTheme.mutedForeground.opacity(0.5)
                    : (isHovered ? ReNuvioTheme.accent : ReNuvioTheme.mutedForeground)
            )
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered && !disabled ? ReNuvioTheme.accent.opacity(0.12) : Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in
            isHovered = hovering
            if hovering && !disabled && !pushedCursor {
                NSCursor.pointingHand.push()
                pushedCursor = true
            } else if (!hovering || disabled) && pushedCursor {
                NSCursor.pop()
                pushedCursor = false
            }
        }
        .onDisappear {
            if pushedCursor {
                NSCursor.pop()
                pushedCursor = false
            }
            isHovered = false
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(ReNuvioTheme.accent.opacity(isEnabled ? 1 : 0.4))
            .foregroundStyle(ReNuvioTheme.accentForeground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(
                color: isEnabled ? ReNuvioTheme.accent.opacity(configuration.isPressed ? 0.2 : 0.35) : .clear,
                radius: 12
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.04))
            .foregroundStyle(ReNuvioTheme.foreground)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ReNuvioTextFieldStyle: TextFieldStyle {
    var monospaced = false

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(ReNuvioTheme.background.opacity(0.75))
            .foregroundStyle(ReNuvioTheme.foreground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(ReNuvioTheme.border, lineWidth: 1)
            )
    }
}
