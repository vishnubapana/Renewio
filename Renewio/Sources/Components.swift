import AppKit
import SwiftUI

// MARK: - Surfaces & Layout

struct AmbientBackdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            RenewioTheme.background
            RadialGradient(
                colors: [
                    RenewioTheme.accent.opacity(0.07),
                    RenewioTheme.accent.opacity(0.02),
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
    var fill: Color = RenewioTheme.cardSolid.opacity(0.75)
    var border: Color = RenewioTheme.border
    var cornerRadius: CGFloat = RenewioTheme.radiusXl

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
                    .foregroundStyle(RenewioTheme.mutedForeground)
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

// MARK: - Interaction Modifiers

private struct InteractiveHoverModifier: ViewModifier {
    @Binding var isHovered: Bool
    var enabled: Bool
    var showsHandCursor: Bool

    @State private var pushedCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard enabled else {
                    clearHover()
                    return
                }
                withAnimation(RenewioMotion.hover) {
                    isHovered = hovering
                }
                guard showsHandCursor else { return }
                if hovering && !pushedCursor {
                    NSCursor.pointingHand.push()
                    pushedCursor = true
                } else if !hovering && pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
            .onChange(of: enabled) { _, newValue in
                if !newValue { clearHover() }
            }
            .onDisappear { clearHover() }
    }

    private func clearHover() {
        if pushedCursor {
            NSCursor.pop()
            pushedCursor = false
        }
        isHovered = false
    }
}

extension View {
    func interactiveHover(
        _ isHovered: Binding<Bool>,
        enabled: Bool = true,
        showsHandCursor: Bool = true
    ) -> some View {
        modifier(InteractiveHoverModifier(
            isHovered: isHovered,
            enabled: enabled,
            showsHandCursor: showsHandCursor
        ))
    }

    func renewioFocusRing(
        isFocused: Bool,
        cornerRadius: CGFloat = RenewioTheme.radiusMd
    ) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(RenewioTheme.accent.opacity(isFocused ? 0.55 : 0), lineWidth: 1.5)
        )
        .shadow(
            color: RenewioTheme.accent.opacity(isFocused ? 0.22 : 0),
            radius: isFocused ? 8 : 0
        )
        .animation(RenewioMotion.hover, value: isFocused)
    }

    func renewioPressScale(isPressed: Bool) -> some View {
        scaleEffect(isPressed ? RenewioMotion.pressScale : 1)
            .animation(RenewioMotion.press, value: isPressed)
    }
}

// MARK: - Loading & Status

struct InlineSpinner: View {
    var tint: Color = RenewioTheme.accent
    var size: ControlSize = .small

    var body: some View {
        ProgressView()
            .controlSize(size)
            .tint(tint)
    }
}

struct LoadingLabel: View {
    let title: String
    var isLoading: Bool
    var tint: Color = RenewioTheme.accent

    var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                InlineSpinner(tint: tint)
                    .transition(.scale(scale: 0.7).combined(with: .move(edge: .leading)))
            }
            Text(title)
        }
        .animation(RenewioMotion.expand, value: isLoading)
    }
}

struct StatusDot: View {
    var tint: Color
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.55), radius: 3)
    }
}

// MARK: - Accordion (height expand / collapse, no fade)

private struct ExpandableHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Animates clipped height only — true accordion expand/collapse with no fade or slide.
struct ExpandablePanel<Content: View>: View {
    var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(alignment: .top) {
                // Intrinsic measure unconstrained by the clipped frame.
                content()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .accessibilityHidden(true)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ExpandableHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            .onPreferenceChange(ExpandableHeightKey.self) { height in
                guard height > 1, abs(height - measuredHeight) > 0.5 else { return }
                measuredHeight = height
            }
            .frame(
                height: isExpanded ? (measuredHeight > 1 ? measuredHeight : nil) : 0,
                alignment: .top
            )
            .clipped()
            .allowsHitTesting(isExpanded && measuredHeight > 1)
            .accessibilityHidden(!isExpanded)
            .animation(RenewioMotion.expand, value: isExpanded)
            .animation(RenewioMotion.expand, value: measuredHeight)
    }
}

// MARK: - Buttons

struct RenewioPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .renewioPressScale(isPressed: configuration.isPressed)
    }
}

struct PopoverIconButton: View {
    let systemImage: String
    var iconSize: CGFloat = 11
    var iconWeight: Font.Weight = .semibold
    var side: CGFloat = 24
    let hoverTint: Color
    let helpText: String
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var cornerRadius: CGFloat { RenewioTheme.radiusSm }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: iconWeight))
                .foregroundStyle(isHovered || isFocused ? hoverTint : RenewioTheme.mutedForeground)
                .frame(width: side, height: side)
                .background(
                    (isHovered || isFocused) ? hoverTint.opacity(0.15) : Color.white.opacity(0.05)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            (isHovered || isFocused) ? hoverTint.opacity(0.45) : RenewioTheme.border,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(RenewioPressButtonStyle())
        .help(helpText)
        .focused($isFocused)
        .interactiveHover($isHovered)
        .renewioFocusRing(isFocused: isFocused, cornerRadius: cornerRadius)
    }
}

struct InlineActionLink: View {
    let title: String
    let systemImage: String
    var disabled = false
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

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
                    ? RenewioTheme.mutedForeground.opacity(0.5)
                    : ((isHovered || isFocused) ? RenewioTheme.accent : RenewioTheme.mutedForeground)
            )
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: RenewioTheme.radiusSm, style: .continuous)
                    .fill(
                        (isHovered || isFocused) && !disabled
                            ? RenewioTheme.accent.opacity(0.12)
                            : Color.white.opacity(0.04)
                    )
            )
        }
        .buttonStyle(RenewioPressButtonStyle())
        .disabled(disabled)
        .focused($isFocused)
        .interactiveHover($isHovered, enabled: !disabled)
        .renewioFocusRing(isFocused: isFocused && !disabled, cornerRadius: RenewioTheme.radiusSm)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(
                RenewioTheme.accent.opacity(
                    isEnabled
                        ? (isHovered || configuration.isPressed ? 1 : 0.92)
                        : 0.4
                )
            )
            .foregroundStyle(RenewioTheme.accentForeground)
            .clipShape(RoundedRectangle(cornerRadius: RenewioTheme.radiusLg, style: .continuous))
            .shadow(
                color: isEnabled
                    ? RenewioTheme.accent.opacity(
                        configuration.isPressed ? 0.2 : (isHovered ? 0.45 : 0.35)
                    )
                    : .clear,
                radius: isHovered && isEnabled ? 14 : 12
            )
            .renewioPressScale(isPressed: configuration.isPressed && isEnabled)
            .brightness(isHovered && isEnabled && !configuration.isPressed ? 0.04 : 0)
            .interactiveHover($isHovered, enabled: isEnabled)
            .animation(RenewioMotion.hover, value: isHovered)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration)
    }
}

private struct SecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(
                Color.white.opacity(
                    configuration.isPressed
                        ? 0.1
                        : (isHovered && isEnabled ? 0.07 : 0.04)
                )
            )
            .foregroundStyle(
                isEnabled ? RenewioTheme.foreground : RenewioTheme.mutedForeground.opacity(0.6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RenewioTheme.radiusMd, style: .continuous)
                    .stroke(
                        isHovered && isEnabled
                            ? RenewioTheme.borderHover
                            : Color.white.opacity(0.15),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: RenewioTheme.radiusMd, style: .continuous))
            .renewioPressScale(isPressed: configuration.isPressed && isEnabled)
            .interactiveHover($isHovered, enabled: isEnabled)
            .animation(RenewioMotion.hover, value: isHovered)
    }
}

// MARK: - Fields & Rows

struct RenewioTextField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced = false

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RenewioTheme.background.opacity(0.75))
            .foregroundStyle(RenewioTheme.foreground)
            .clipShape(RoundedRectangle(cornerRadius: RenewioTheme.radiusMd, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RenewioTheme.radiusMd, style: .continuous)
                    .stroke(
                        isFocused
                            ? RenewioTheme.accent.opacity(0.5)
                            : RenewioTheme.border,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: RenewioTheme.accent.opacity(isFocused ? 0.12 : 0),
                radius: isFocused ? 10 : 0
            )
            .focused($isFocused)
            .animation(RenewioMotion.hover, value: isFocused)
    }
}

struct SelectableOptionRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    var subtitleTruncation: Text.TruncationMode = .tail
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RenewioTheme.foreground)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RenewioTheme.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(subtitleTruncation)
                }
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        isSelected
                            ? RenewioTheme.accent
                            : RenewioTheme.mutedForeground.opacity(0.45)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                CardSurface(
                    fill: isSelected
                        ? RenewioTheme.accent.opacity(0.12)
                        : Color.white.opacity((isHovered || isFocused) ? 0.06 : 0.03),
                    border: isSelected
                        ? RenewioTheme.accent.opacity(0.45)
                        : ((isHovered || isFocused) ? RenewioTheme.borderHover : RenewioTheme.border),
                    cornerRadius: RenewioTheme.radiusMd
                )
            )
        }
        .buttonStyle(RenewioPressButtonStyle())
        .focused($isFocused)
        .interactiveHover($isHovered)
        .animation(RenewioMotion.hover, value: isSelected)
        .renewioFocusRing(isFocused: isFocused, cornerRadius: RenewioTheme.radiusMd)
    }
}

// MARK: - Trailing Circle Action

/// Shared glyph used for device add/remove and app edit (`plus.circle`, `xmark.circle`, `pencil.circle`).
struct TrailingCircleIconButton: View {
    let systemImage: String
    var tint: Color = RenewioTheme.accent
    var helpText: String = ""
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(
                    isHovered || isFocused
                        ? tint
                        : tint.opacity(0.85)
                )
        }
        .buttonStyle(RenewioPressButtonStyle())
        .help(helpText)
        .accessibilityLabel(helpText.isEmpty ? systemImage : helpText)
        .focused($isFocused)
        .interactiveHover($isHovered)
        .animation(RenewioMotion.hover, value: isHovered)
        .animation(RenewioMotion.hover, value: isFocused)
    }
}

// MARK: - Device Tile

/// Shared Settings device row for tracked (remove) and discovered (add) devices.
struct DeviceTileRow: View {
    let platformSystemImage: String
    let title: String
    let subtitle: String
    var isSelected: Bool = false
    let trailingSystemImage: String
    var trailingTint: Color = RenewioTheme.accent
    var trailingHelp: String = ""
    let onSelect: () -> Void
    let onTrailingAction: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: platformSystemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RenewioTheme.accent)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RenewioTheme.foreground)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RenewioTheme.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                TrailingCircleIconButton(
                    systemImage: trailingSystemImage,
                    tint: trailingTint,
                    helpText: trailingHelp,
                    action: onTrailingAction
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                CardSurface(
                    fill: isSelected
                        ? RenewioTheme.accent.opacity(0.12)
                        : Color.white.opacity((isHovered || isFocused) ? 0.06 : 0.03),
                    border: isSelected
                        ? RenewioTheme.accent.opacity(0.45)
                        : ((isHovered || isFocused) ? RenewioTheme.borderHover : RenewioTheme.border),
                    cornerRadius: RenewioTheme.radiusMd
                )
            )
        }
        .buttonStyle(RenewioPressButtonStyle())
        .focused($isFocused)
        .interactiveHover($isHovered)
        .animation(RenewioMotion.hover, value: isSelected)
        .renewioFocusRing(isFocused: isFocused, cornerRadius: RenewioTheme.radiusMd)
    }
}

// MARK: - Preference Toggle (rectangular light switch)

struct PreferenceToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RenewioTheme.foreground)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(RenewioTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(RenewioLightSwitchStyle())
                .accessibilityLabel(title)
        }
    }
}

/// Rectangular light-switch style toggle (not a capsule).
struct RenewioLightSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        RenewioLightSwitchBody(configuration: configuration)
    }
}

private struct RenewioLightSwitchBody: View {
    let configuration: ToggleStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private let trackWidth: CGFloat = 36
    private let trackHeight: CGFloat = 20
    private let knobWidth: CGFloat = 14
    private let knobHeight: CGFloat = 14
    private let inset: CGFloat = 3

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: RenewioTheme.radiusSm, style: .continuous)
                    .fill(
                        configuration.isOn
                            ? RenewioTheme.accent.opacity(isEnabled ? 1 : 0.4)
                            : Color.white.opacity(isEnabled ? 0.06 : 0.03)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RenewioTheme.radiusSm, style: .continuous)
                            .stroke(
                                configuration.isOn
                                    ? RenewioTheme.accent.opacity(0.55)
                                    : RenewioTheme.border,
                                lineWidth: 1
                            )
                    )

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        configuration.isOn
                            ? RenewioTheme.accentForeground
                            : RenewioTheme.foreground.opacity(isEnabled ? 0.85 : 0.4)
                    )
                    .frame(width: knobWidth, height: knobHeight)
                    .padding(inset)
                    .shadow(color: Color.black.opacity(0.25), radius: 1, y: 0.5)
            }
            .frame(width: trackWidth, height: trackHeight)
            .brightness(isHovered && isEnabled ? 0.04 : 0)
        }
        .buttonStyle(RenewioPressButtonStyle())
        .disabled(!isEnabled)
        .focused($isFocused)
        .interactiveHover($isHovered, enabled: isEnabled)
        .renewioFocusRing(isFocused: isFocused && isEnabled, cornerRadius: RenewioTheme.radiusSm)
        .animation(RenewioMotion.hover, value: configuration.isOn)
        .animation(RenewioMotion.hover, value: isHovered)
    }
}
