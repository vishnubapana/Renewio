import AppKit
import SwiftUI

struct MenuPopoverView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            topBar
            if model.configStore.needsOnboarding {
                emptySetupPrompt
            } else if installs.isEmpty {
                emptyAppsPrompt
            } else {
                appList
                if case let .batchSummary(succeeded, failed) = model.renewRunner.status {
                    batchSummaryCard(succeeded: succeeded, failed: failed)
                }
                if installs.count > 1 {
                    renewAllRow
                }
            }
        }
        .padding(18)
    }

    private var devices: [TrackedDevice] {
        model.configStore.config?.devices ?? []
    }

    private var installs: [TrackedAppInstall] {
        model.installsForSelectedDevice
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 8) {
            if devices.isEmpty {
                Text("Renewio")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(RenewioTheme.foreground)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(devices) { device in
                            DevicePill(
                                device: device,
                                isSelected: model.selectedDevice?.id == device.id
                            ) {
                                model.selectDevice(device.id)
                            }
                        }
                    }
                    // Leave room for pill stroke / focus ring so icons aren’t clipped.
                    .padding(.vertical, 2)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                if !model.configStore.needsOnboarding, model.selectedDevice != nil {
                    PopoverIconButton(
                        systemImage: "plus",
                        iconSize: 11,
                        iconWeight: .bold,
                        hoverTint: RenewioTheme.accent,
                        helpText: "Add app",
                        action: { model.openOnboardingForAddApp() }
                    )
                }
                PopoverIconButton(
                    systemImage: "gearshape.fill",
                    iconSize: 11,
                    hoverTint: RenewioTheme.accent,
                    helpText: "Settings",
                    action: { model.openOnboarding() }
                )
                PopoverIconButton(
                    systemImage: "xmark",
                    iconSize: 10,
                    iconWeight: .bold,
                    hoverTint: RenewioTheme.danger,
                    helpText: "Quit Renewio",
                    action: { NSApp.terminate(nil) }
                )
            }
        }
    }

    private var emptySetupPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Setup needed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RenewioTheme.accent)
            Text("Add an Xcode Team ID, a paired device, and at least one app in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(RenewioTheme.mutedForeground)
            Button("Open Settings") { model.openOnboarding() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurface())
    }

    private var emptyAppsPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No apps on this device")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RenewioTheme.foreground)

            HStack(alignment: .top, spacing: 6) {
                Text("Tap")
                    .font(.system(size: 12))
                    .foregroundStyle(RenewioTheme.mutedForeground)
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(RenewioTheme.accent)
                    .frame(width: 16, height: 16)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: RenewioTheme.radiusSm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: RenewioTheme.radiusSm, style: .continuous)
                            .stroke(RenewioTheme.border, lineWidth: 1)
                    )
                Text("above to add a GitHub repo or local .ipa.")
                    .font(.system(size: 12))
                    .foregroundStyle(RenewioTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurface())
    }

    @ViewBuilder
    private var appList: some View {
        // MenuBarExtra window often proposes unbounded/zero height to ScrollView,
        // which collapses the list. Use a plain stack for a few apps; scroll only when needed.
        if installs.count > 2 {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(installs) { install in
                        AppInstallCard(install: install)
                            .environmentObject(model)
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 420)
        } else {
            VStack(spacing: 10) {
                ForEach(installs) { install in
                    AppInstallCard(install: install)
                        .environmentObject(model)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var renewAllRow: some View {
        HStack(spacing: 8) {
            Button {
                model.renewAllOnSelectedDevice()
            } label: {
                LoadingLabel(
                    title: model.renewRunner.isRunning ? "Renewing…" : "Renew all",
                    isLoading: model.renewRunner.isRunning
                )
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.renewRunner.isRunning)

            if model.renewRunner.isRunning {
                Button {
                    model.renewRunner.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RenewioTheme.danger)
                        .frame(width: 34, height: 34)
                        .background(RenewioTheme.danger.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: RenewioTheme.radiusMd, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: RenewioTheme.radiusMd, style: .continuous)
                                .stroke(RenewioTheme.danger.opacity(0.35), lineWidth: 1)
                        )
                }
                .buttonStyle(RenewioPressButtonStyle())
                .help("Cancel renew")
            }
        }
    }

    private func batchSummaryCard(succeeded: [String], failed: [BatchFailure]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    failed.isEmpty ? "All apps renewed" : "Renew all finished",
                    systemImage: failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(failed.isEmpty ? RenewioTheme.success : RenewioTheme.accent)
                Spacer()
                Button {
                    model.renewRunner.clearStatus()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(RenewioTheme.mutedForeground)
                }
                .buttonStyle(RenewioPressButtonStyle())
                .help("Dismiss")
            }

            if !succeeded.isEmpty {
                Text("Succeeded: \(succeeded.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(RenewioTheme.foreground)
            }
            ForEach(failed) { item in
                Text("Failed (\(item.appName)): \(item.message)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(RenewioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            CardSurface(
                fill: (failed.isEmpty ? RenewioTheme.success : RenewioTheme.accent).opacity(0.08),
                border: (failed.isEmpty ? RenewioTheme.success : RenewioTheme.accent).opacity(0.3),
                cornerRadius: RenewioTheme.radiusLg
            )
        )
        .transition(.renewioExpandCollapse)
    }
}

private struct DevicePill: View {
    let device: TrackedDevice
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private let pillHeight: CGFloat = 22

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: device.platform.systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(device.name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? RenewioTheme.accentForeground : RenewioTheme.accent)
            .padding(.horizontal, 8)
            .frame(height: pillHeight)
            .background(
                Capsule()
                    .fill(
                        isSelected
                            ? RenewioTheme.accent
                            : ((isHovered || isFocused) ? RenewioTheme.accent.opacity(0.12) : Color.clear)
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        RenewioTheme.accent.opacity(isSelected ? 0 : ((isHovered || isFocused) ? 1 : 0.85)),
                        lineWidth: isSelected ? 0 : 1.25
                    )
            )
            .shadow(
                color: RenewioTheme.accent.opacity(isFocused && !isSelected ? 0.25 : 0),
                radius: isFocused ? 6 : 0
            )
            .animation(RenewioMotion.hover, value: isSelected)
            .animation(RenewioMotion.hover, value: isHovered)
            .animation(RenewioMotion.hover, value: isFocused)
        }
        .buttonStyle(RenewioPressButtonStyle())
        .help("\(device.name) · \(device.platform.displayName)")
        .focused($isFocused)
        .interactiveHover($isHovered)
    }
}

private struct AppInstallCard: View {
    @EnvironmentObject private var model: AppModel
    let install: TrackedAppInstall

    @State private var isCardHovered = false
    @State private var copiedLog = false

    private var isActive: Bool {
        model.renewRunner.activeInstallID == install.id
    }

    private var isRunningThis: Bool {
        isActive && model.renewRunner.isRunning
    }

    private var availableUpdate: ReleaseOption? {
        model.availableUpdates[install.id]
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let state = RefreshCountdownState.make(
                expiresAt: install.expiresAt,
                signingDuration: install.signingDuration,
                now: context.date
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(install.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(RenewioTheme.foreground)
                                .lineLimit(1)
                            if let version = install.displayVersion {
                                Text(version)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(RenewioTheme.mutedForeground)
                            }
                            if let update = availableUpdate {
                                Button {
                                    model.renew(install: install)
                                } label: {
                                    Text("↑ \(update.displayVersion)")
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(RenewioTheme.accent)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(RenewioTheme.accent.opacity(0.14))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(RenewioPressButtonStyle())
                                .disabled(model.renewRunner.isRunning)
                                .help("Update available: \(update.displayVersion). Click to install.")
                            }
                            Spacer(minLength: 0)
                        }

                        HStack(spacing: 5) {
                            StatusDot(tint: state.tint)
                            Text(state.statusLabel)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(state.tint)
                            Text(state.countdownText)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RenewioTheme.foreground)
                            if let meta = state.rightMeta {
                                Text("· \(meta)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(RenewioTheme.mutedForeground)
                            }
                            Spacer(minLength: 0)
                        }

                        if state.showProgressBar {
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.06))
                                    Capsule()
                                        .fill(state.tint)
                                        .frame(width: max(0, proxy.size.width * state.progress))
                                }
                            }
                            .frame(height: 2)
                        } else if install.isLocalIPA {
                            Text("Local · \(install.sourceLabel)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(RenewioTheme.mutedForeground)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else if let tag = install.selectedTag, !tag.isEmpty {
                            Text("Pinned \(tag)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(RenewioTheme.accent)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isCardHovered && !isRunningThis {
                        TrailingCircleIconButton(
                            systemImage: "pencil.circle",
                            tint: RenewioTheme.accent,
                            helpText: "Edit \(install.name)",
                            action: { model.openOnboarding(editingInstallID: install.id) }
                        )
                        .transition(.opacity)
                    }

                    if isRunningThis {
                        CancelIconButton {
                            model.renewRunner.cancel()
                        }
                    } else {
                        RenewIconButton(
                            isRunning: isRunningThis,
                            disabled: model.renewRunner.isRunning
                        ) {
                            model.renew(install: install)
                        }
                    }
                }

                statusExtras
                    .animation(RenewioMotion.expand, value: isActive)
                    .animation(RenewioMotion.expand, value: statusIdentity)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(CardSurface())
            .onHover { hovering in
                withAnimation(RenewioMotion.hover) {
                    isCardHovered = hovering
                }
            }
        }
    }

    private var statusIdentity: String {
        guard isActive else { return "inactive" }
        switch model.renewRunner.status {
        case .idle: return "idle"
        case .running(let stage, _): return "running-\(stage?.rawValue ?? "none")"
        case .success: return "success"
        case .failure: return "failure"
        case .batchSummary: return "batch"
        }
    }

    @ViewBuilder
    private var statusExtras: some View {
        if isActive {
            switch model.renewRunner.status {
            case let .running(stage, detail):
                VStack(alignment: .leading, spacing: 6) {
                    if stage == .download, let dl = model.renewRunner.downloadProgress {
                        ProgressView(value: dl.fraction) {
                            HStack {
                                Text(detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(RenewioTheme.mutedForeground)
                                Spacer()
                                Text(dl.formattedLabel)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(RenewioTheme.accent)
                            }
                        }
                        .progressViewStyle(.linear)
                        .tint(RenewioTheme.accent)
                    } else {
                        ProgressView(value: progressValue(for: stage)) {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(RenewioTheme.mutedForeground)
                        }
                        .progressViewStyle(.linear)
                        .tint(RenewioTheme.accent)
                    }
                }
                .transition(.renewioExpandCollapse)
            case let .success(version, deviceName, detail, _, _, _):
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Success", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(RenewioTheme.success)
                        Spacer()
                        Button {
                            model.renewRunner.clearStatus()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(RenewioTheme.mutedForeground)
                        }
                        .buttonStyle(RenewioPressButtonStyle())
                        .help("Dismiss")
                    }
                    Text("\(version) on \(deviceName)")
                        .font(.system(size: 11))
                        .foregroundStyle(RenewioTheme.foreground)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(RenewioTheme.mutedForeground)
                }
                .transition(.renewioExpandCollapse)
            case let .failure(_, message):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Failed", systemImage: "xmark.octagon.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(RenewioTheme.danger)
                        Spacer()
                        Button {
                            model.renewRunner.clearStatus()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(RenewioTheme.mutedForeground)
                        }
                        .buttonStyle(RenewioPressButtonStyle())
                        .help("Dismiss")
                    }
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(RenewioTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    if !errorLog.isEmpty {
                        ScrollView {
                            Text(errorLog)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(RenewioTheme.mutedForeground)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 100)
                        .padding(6)
                        .background(Color.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: RenewioTheme.radiusMd, style: .continuous))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(errorLog, forType: .string)
                            withAnimation(RenewioMotion.hover) {
                                copiedLog = true
                            }
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                withAnimation(RenewioMotion.hover) {
                                    copiedLog = false
                                }
                            }
                        } label: {
                            Label(
                                copiedLog ? "Copied" : "Copy log",
                                systemImage: copiedLog ? "checkmark" : "doc.on.doc"
                            )
                            .font(.system(size: 10.5, weight: .medium))
                        }
                        .buttonStyle(RenewioPressButtonStyle())
                        .foregroundStyle(copiedLog ? RenewioTheme.success : RenewioTheme.mutedForeground)
                    }
                }
                .transition(.renewioExpandCollapse)
            case .idle, .batchSummary:
                EmptyView()
            }
        }
    }

    private var errorLog: String {
        let inMemory = model.renewRunner.logTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inMemory.isEmpty { return inMemory }
        return RenewRunner.recentErrorLogExcerpt()
    }

    private func progressValue(for stage: RenewStage?) -> Double {
        guard let stage, let idx = RenewStage.allCases.firstIndex(of: stage) else { return 0.08 }
        return Double(idx + 1) / Double(RenewStage.allCases.count)
    }
}

private struct CancelIconButton: View {
    let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            ZStack {
                if isHovered || isFocused {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RenewioTheme.danger)
                } else {
                    InlineSpinner(tint: RenewioTheme.accentForeground)
                }
            }
            .frame(width: 32, height: 32)
            .background(
                (isHovered || isFocused)
                    ? RenewioTheme.danger.opacity(0.18)
                    : RenewioTheme.accent
            )
            .clipShape(RoundedRectangle(cornerRadius: RenewioTheme.radiusMd, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RenewioTheme.radiusMd, style: .continuous)
                    .stroke(
                        (isHovered || isFocused) ? RenewioTheme.danger.opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(RenewioPressButtonStyle())
        .help("Cancel renew")
        .focused($isFocused)
        .interactiveHover($isHovered)
        .renewioFocusRing(isFocused: isFocused, cornerRadius: RenewioTheme.radiusMd)
    }
}

private struct RenewIconButton: View {
    let isRunning: Bool
    let disabled: Bool
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRunning {
                    InlineSpinner(tint: RenewioTheme.accentForeground)
                        .transition(.scale.combined(with: .move(edge: .bottom)))
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RenewioTheme.accentForeground)
                        .rotationEffect(.degrees(isHovered ? 180 : 0))
                        .animation(RenewioMotion.iconSpin, value: isHovered)
                }
            }
            .frame(width: 32, height: 32)
            .background(
                RenewioTheme.accent.opacity(
                    disabled && !isRunning
                        ? 0.4
                        : ((isHovered || isFocused) ? 1 : 0.92)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: RenewioTheme.radiusMd, style: .continuous))
            .shadow(
                color: disabled
                    ? .clear
                    : RenewioTheme.accent.opacity((isHovered || isFocused) ? 0.45 : 0.25),
                radius: (isHovered || isFocused) ? 8 : 4
            )
        }
        .buttonStyle(RenewioPressButtonStyle())
        .disabled(disabled)
        .help("Renew")
        .focused($isFocused)
        .interactiveHover($isHovered, enabled: !disabled)
        .scaleEffect(isHovered && !disabled ? RenewioMotion.hoverScale : 1)
        .animation(RenewioMotion.hover, value: isHovered)
        .renewioFocusRing(isFocused: isFocused && !disabled, cornerRadius: RenewioTheme.radiusMd)
    }
}

struct RefreshCountdownState {
    let statusLabel: String
    let countdownText: String
    let countdownSuffix: String?
    let rightMeta: String?
    let progress: Double
    let tint: Color
    let showProgressBar: Bool

    static func make(
        expiresAt: Date?,
        signingDuration: TimeInterval = TrackedAppInstall.signingLifetime,
        now: Date
    ) -> RefreshCountdownState {
        guard let expiresAt else {
            return RefreshCountdownState(
                statusLabel: "Not installed",
                countdownText: "—",
                countdownSuffix: "Ready",
                rightMeta: nil,
                progress: 0,
                tint: RenewioTheme.mutedForeground,
                showProgressBar: false
            )
        }

        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 {
            return RefreshCountdownState(
                statusLabel: "Expired",
                countdownText: "0h 0m",
                countdownSuffix: "refresh needed",
                rightMeta: formattedShortDate(expiresAt),
                progress: 0,
                tint: RenewioTheme.danger,
                showProgressBar: true
            )
        }

        let effectiveDuration = max(3600, signingDuration)
        let fraction = min(1, max(0, remaining / effectiveDuration))
        let totalMinutes = Int(remaining / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        let countdown: String
        if days > 0 {
            countdown = "\(days)d \(hours)h"
        } else if hours > 0 {
            countdown = "\(hours)h \(minutes)m"
        } else {
            countdown = "\(max(1, minutes))m"
        }
        let renewSoon = remaining <= 48 * 60 * 60
        return RefreshCountdownState(
            statusLabel: renewSoon ? "Renew soon" : "Active",
            countdownText: countdown,
            countdownSuffix: "until refresh",
            rightMeta: formattedShortDate(expiresAt),
            progress: fraction,
            tint: renewSoon ? RenewioTheme.accent : RenewioTheme.success,
            showProgressBar: true
        )
    }

    private static func formattedShortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
