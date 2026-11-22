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
                if installs.count > 1 {
                    renewAllButton
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
        HStack(alignment: .center, spacing: 10) {
            if devices.isEmpty {
                Text("ReNuvio")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(ReNuvioTheme.foreground)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(devices) { device in
                            DevicePill(
                                device: device,
                                isSelected: model.selectedDevice?.id == device.id
                            ) {
                                model.selectDevice(device.id)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                PopoverIconButton(
                    systemImage: "gearshape.fill",
                    iconSize: 14,
                    iconWeight: .semibold,
                    hoverTint: ReNuvioTheme.accent,
                    helpText: "Settings",
                    action: { model.openOnboarding() }
                )
                PopoverIconButton(
                    systemImage: "xmark",
                    iconSize: 12,
                    iconWeight: .bold,
                    hoverTint: ReNuvioTheme.danger,
                    helpText: "Quit ReNuvio",
                    action: { NSApp.terminate(nil) }
                )
            }
        }
    }

    private var emptySetupPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Setup needed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ReNuvioTheme.accent)
            Text("Add an Xcode Team ID, a paired device, and at least one app in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(ReNuvioTheme.mutedForeground)
            Button("Open Settings") { model.openOnboarding() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurface())
    }

    private var emptyAppsPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No apps on this device")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ReNuvioTheme.foreground)
            Text("Add a GitHub-sourced app in Settings to track and renew it here.")
                .font(.system(size: 12))
                .foregroundStyle(ReNuvioTheme.mutedForeground)
            Button("Add app in Settings") { model.openOnboarding() }
                .buttonStyle(SecondaryButtonStyle())
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

    private var renewAllButton: some View {
        Button {
            model.renewAllOnSelectedDevice()
        } label: {
            HStack(spacing: 8) {
                if model.renewRunner.isRunning {
                    ProgressView().controlSize(.small)
                }
                Text(model.renewRunner.isRunning ? "Renewing…" : "Renew all")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(model.renewRunner.isRunning)
    }
}

private struct DevicePill: View {
    let device: TrackedDevice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: device.platform.systemImage)
                    .font(.system(size: isSelected ? 11 : 12, weight: .semibold))
                if isSelected {
                    Text(device.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .foregroundStyle(isSelected ? ReNuvioTheme.accentForeground : ReNuvioTheme.accent)
            .padding(.horizontal, isSelected ? 10 : 0)
            .frame(width: isSelected ? nil : 32, height: 32)
            .background(
                Capsule()
                    .fill(isSelected ? ReNuvioTheme.accent : Color.clear)
            )
            .overlay(
                Capsule()
                    .stroke(ReNuvioTheme.accent, lineWidth: isSelected ? 0 : 1.5)
            )
        }
        .buttonStyle(.plain)
        .help("\(device.name) · \(device.platform.displayName)")
        .animation(.easeOut(duration: 0.18), value: isSelected)
    }
}

private struct AppInstallCard: View {
    @EnvironmentObject private var model: AppModel
    let install: TrackedAppInstall

    private var isActive: Bool {
        model.renewRunner.activeInstallID == install.id
    }

    private var isRunningThis: Bool {
        isActive && model.renewRunner.isRunning
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let state = RefreshCountdownState.make(expiresAt: install.expiresAt, now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(install.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ReNuvioTheme.foreground)
                                .lineLimit(1)
                            if let version = install.displayVersion {
                                Text(version)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(ReNuvioTheme.mutedForeground)
                            }
                            Spacer(minLength: 0)
                        }

                        HStack(spacing: 5) {
                            Circle()
                                .fill(state.tint)
                                .frame(width: 6, height: 6)
                                .shadow(color: state.tint.opacity(0.55), radius: 3)
                            Text(state.statusLabel)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(state.tint)
                            Text(state.countdownText)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ReNuvioTheme.foreground)
                            if let meta = state.rightMeta {
                                Text("· \(meta)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(ReNuvioTheme.mutedForeground)
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
                        } else if let tag = install.selectedTag, !tag.isEmpty {
                            Text("Pinned \(tag)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(ReNuvioTheme.accent)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    RenewIconButton(
                        isRunning: isRunningThis,
                        disabled: model.renewRunner.isRunning
                    ) {
                        model.renew(install: install)
                    }
                }

                statusExtras
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(CardSurface())
        }
    }

    @ViewBuilder
    private var statusExtras: some View {
        if isActive {
            switch model.renewRunner.status {
            case let .running(stage, detail):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progressValue(for: stage)) {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(ReNuvioTheme.mutedForeground)
                    }
                    .progressViewStyle(.linear)
                    .tint(ReNuvioTheme.accent)
                }
            case let .success(version, deviceName, detail, _, _):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Success", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ReNuvioTheme.success)
                    Text("\(version) on \(deviceName)")
                        .font(.system(size: 11))
                        .foregroundStyle(ReNuvioTheme.foreground)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(ReNuvioTheme.mutedForeground)
                }
            case let .failure(_, message):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Failed", systemImage: "xmark.octagon.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ReNuvioTheme.danger)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(ReNuvioTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    if !errorLog.isEmpty {
                        ScrollView {
                            Text(errorLog)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(ReNuvioTheme.mutedForeground)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 100)
                        .padding(6)
                        .background(Color.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(errorLog, forType: .string)
                        } label: {
                            Label("Copy log", systemImage: "doc.on.doc")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ReNuvioTheme.mutedForeground)
                    }
                }
            case .idle:
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

private struct RenewIconButton: View {
    let isRunning: Bool
    let disabled: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var pushedCursor = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .tint(ReNuvioTheme.accentForeground)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ReNuvioTheme.accentForeground)
                        .rotationEffect(.degrees(isHovered ? 180 : 0))
                }
            }
            .frame(width: 32, height: 32)
            .background(
                ReNuvioTheme.accent.opacity(disabled && !isRunning ? 0.4 : (isHovered ? 1 : 0.92))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(
                color: disabled ? .clear : ReNuvioTheme.accent.opacity(isHovered ? 0.45 : 0.25),
                radius: isHovered ? 8 : 4
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help("Renew")
        .onHover { hovering in
            guard !disabled else { return }
            withAnimation(.easeOut(duration: 0.28)) {
                isHovered = hovering
            }
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
        .scaleEffect(isHovered && !disabled ? 1.04 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovered)
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

    static func make(expiresAt: Date?, now: Date) -> RefreshCountdownState {
        guard let expiresAt else {
            return RefreshCountdownState(
                statusLabel: "Not installed",
                countdownText: "—",
                countdownSuffix: "Ready",
                rightMeta: nil,
                progress: 0,
                tint: ReNuvioTheme.mutedForeground,
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
                tint: ReNuvioTheme.danger,
                showProgressBar: true
            )
        }

        let fraction = min(1, max(0, remaining / TrackedAppInstall.signingLifetime))
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
            tint: renewSoon ? ReNuvioTheme.accent : ReNuvioTheme.success,
            showProgressBar: true
        )
    }

    private static func formattedShortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
