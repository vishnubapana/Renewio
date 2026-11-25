import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    private enum SourceKind {
        case github
        case localIPA
    }

    @State private var teamID = ""
    @State private var discovered: [AppleDevice] = []
    @State private var isLoadingDevices = true
    @State private var errorMessage: String?
    @State private var infoBanner: String?
    @State private var xcodeOK = true
    @State private var sdks = AvailableSDKs(tvOS: true, iOS: true)
    @State private var isSaving = false

    @State private var draftDevices: [TrackedDevice] = []
    @State private var draftInstalls: [TrackedAppInstall] = []
    @State private var selectedDeviceID: String?
    @State private var editingInstall: TrackedAppInstall?
    @State private var isScanningReleases = false
    @State private var sourceDraftURL = ""
    @State private var sourceKind: SourceKind = .github
    @State private var isRepoVerified = false
    @State private var isAddingNewApp = false

    // Preferences & Maintenance
    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled
    @State private var autoRenewEnabled = false
    @State private var securityReviewEnabled = true
    @State private var githubTokenInput = ""
    @State private var hasSavedGitHubToken = KeychainStore.hasGitHubToken
    @State private var cacheSizeBytes: Int64 = ConfigStore.cacheSizeBytes()
    @State private var securityEmail = ""
    @State private var securityPassword = ""
    @State private var securityBusy = false

    /// Scroll anchor to restore when the edit panel closes.
    @State private var scrollRestoreID: String?
    @State private var scrollToEditID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(RenewioTheme.border)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        if !xcodeOK || (!sdks.tvOS && !sdks.iOS) {
                            environmentWarningCard
                        }
                        devicesSection
                        appsSection
                        teamSection
                        preferencesSection
                        if let infoBanner {
                            successBanner(infoBanner)
                        }
                        if let errorMessage {
                            errorBanner(errorMessage)
                        }
                    }
                    .padding(16)
                }
                .frame(height: 540)
                .onChange(of: scrollToEditID) { _, target in
                    guard let target else { return }
                    scrollEditPanelIntoView(proxy: proxy, editID: target)
                }
                .onChange(of: editingInstall?.id) { _, newID in
                    if newID == nil {
                        restoreScrollAfterEditClose(proxy: proxy)
                    }
                }
            }
            Divider().overlay(RenewioTheme.border)
            footer
        }
        .onAppear(perform: bootstrap)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            PopoverIconButton(
                systemImage: "chevron.left",
                iconSize: 10,
                iconWeight: .bold,
                hoverTint: RenewioTheme.accent,
                helpText: "Back to Renewio",
                action: { model.handleSetupClosed() }
            )

            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(RenewioTheme.foreground)
                Text("Devices, apps & preferences")
                    .font(.system(size: 10))
                    .foregroundStyle(RenewioTheme.mutedForeground)
            }

            Spacer(minLength: 6)

            XcodeStatusButton(ready: xcodeOK && (sdks.tvOS || sdks.iOS)) {
                DeviceDiscovery.openXcodeAccounts()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var environmentWarningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            checklistRow(ok: xcodeOK, title: "Xcode", detail: xcodeOK ? "Available" : "Install Xcode from the App Store")
            checklistRow(ok: sdks.tvOS, title: "tvOS SDK", detail: sdks.tvOS ? "Found" : "Install tvOS platform in Xcode")
            checklistRow(ok: sdks.iOS, title: "iOS SDK", detail: sdks.iOS ? "Found" : "Install iOS platform in Xcode")
            Button("Open Xcode") { DeviceDiscovery.openXcodeAccounts() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(12)
        .background(CardSurface(fill: RenewioTheme.accent.opacity(0.08), border: RenewioTheme.accent.opacity(0.3)))
    }

    // MARK: - Devices

    private var devicesSection: some View {
        SectionCard("DEVICES", spacing: 10) {
            InlineActionLink(
                title: isLoadingDevices ? "Scanning…" : "Refresh",
                systemImage: "arrow.clockwise",
                disabled: isLoadingDevices
            ) {
                Task { await refreshDevices() }
            }
        } content: {
            if draftDevices.isEmpty && isLoadingDevices {
                LoadingLabel(title: "Scanning for paired devices…", isLoading: true)
                    .font(.system(size: 11.5))
                    .foregroundStyle(RenewioTheme.mutedForeground)
            } else if draftDevices.isEmpty && discovered.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No paired devices detected")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RenewioTheme.foreground)
                    Text("Pair an Apple TV, iPhone, or iPad in Xcode → Window → Devices and Simulators, then Refresh.")
                        .font(.system(size: 11))
                        .foregroundStyle(RenewioTheme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Xcode Devices") { DeviceDiscovery.openXcodeDevices() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(draftDevices) { device in
                        DeviceTileRow(
                            platformSystemImage: device.platform.systemImage,
                            title: device.name,
                            subtitle: "\(device.platform.displayName) · \(device.id)",
                            isSelected: selectedDeviceID == device.id,
                            trailingSystemImage: "xmark.circle",
                            trailingTint: RenewioTheme.danger,
                            trailingHelp: "Remove \(device.name)",
                            onSelect: { selectedDeviceID = device.id },
                            onTrailingAction: { removeDevice(device.id) }
                        )
                    }

                    let trackedIDs = Set(draftDevices.map(\.id))
                    let untracked = discovered.filter { !trackedIDs.contains($0.udid) && !trackedIDs.contains($0.id) }
                    if !untracked.isEmpty {
                        Text("Discovered — tap to add")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(RenewioTheme.mutedForeground)
                            .padding(.top, 4)
                        ForEach(untracked) { device in
                            DeviceTileRow(
                                platformSystemImage: device.platform.systemImage,
                                title: device.name,
                                subtitle: device.displaySubtitle,
                                trailingSystemImage: "plus.circle",
                                trailingTint: RenewioTheme.accent,
                                trailingHelp: "Add \(device.name)",
                                onSelect: { addDevice(device.trackedDevice) },
                                onTrailingAction: { addDevice(device.trackedDevice) }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Apps

    private var appsSection: some View {
        let deviceName = draftDevices.first(where: { $0.id == selectedDeviceID })?.name ?? "device"
        return SectionCard("APPS ON \(deviceName.uppercased())", spacing: 10) {
            if !(isAddingNewApp && !isRepoVerified) {
                InlineActionLink(title: "Add app", systemImage: "plus") {
                    beginAddApp()
                }
            }
        } content: {
            if selectedDeviceID == nil {
                Text("Select a device to manage its apps.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(RenewioTheme.mutedForeground)
            } else if installsForSelected.isEmpty && editingInstall == nil && !isAddingNewApp {
                Text("No apps yet. Tap Add app for a GitHub repo or local .ipa.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(RenewioTheme.mutedForeground)
            } else {
                VStack(spacing: 6) {
                    ForEach(installsForSelected) { install in
                        appRowCard(install)
                    }

                    ExpandablePanel(isExpanded: isAddingNewApp && !isRepoVerified) {
                        sourcePasteStep
                    }

                    if isAddingNewApp, isRepoVerified, let editing = editingInstall,
                       !installsForSelected.contains(where: { $0.id == editing.id }) {
                        newAppEditorCard(editing)
                    }
                }
            }
        }
    }

    private func appRowCard(_ install: TrackedAppInstall) -> some View {
        let isEditing = editingInstall?.id == install.id && isRepoVerified && !isAddingNewApp
        let display = isEditing ? (editingInstall ?? install) : install

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RenewioTheme.foreground)
                    Text("\(display.sourceLabel) · \(display.bundleID)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RenewioTheme.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                TrailingCircleIconButton(
                    systemImage: isEditing ? "xmark.circle" : "pencil.circle",
                    tint: isEditing ? RenewioTheme.mutedForeground : RenewioTheme.accent,
                    helpText: isEditing ? "Close" : "Edit \(install.name)",
                    action: {
                        if isEditing {
                            cancelAppEditor()
                        } else {
                            beginEditApp(install)
                        }
                    }
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            ExpandablePanel(isExpanded: isEditing) {
                appEditorFields(install, isNew: false)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .background(alignment: .bottom) {
                        Color.clear
                            .frame(height: 1)
                            .id(Self.appEditAnchorID(install.id))
                    }
            }
        }
        .id(Self.appRowAnchorID(install.id))
        .background(
            CardSurface(
                fill: isEditing ? RenewioTheme.accent.opacity(0.06) : Color.white.opacity(0.03),
                border: isEditing ? RenewioTheme.accent.opacity(0.25) : RenewioTheme.border,
                cornerRadius: RenewioTheme.radiusMd
            )
        )
    }

    private func newAppEditorCard(_ install: TrackedAppInstall) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(install.name.isEmpty ? "New app" : install.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RenewioTheme.foreground)
                    Text("\(install.sourceLabel) · \(install.bundleID)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RenewioTheme.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    cancelAppEditor()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RenewioTheme.mutedForeground)
                }
                .buttonStyle(RenewioPressButtonStyle())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            appEditorFields(install, isNew: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .background(alignment: .bottom) {
                    Color.clear
                        .frame(height: 1)
                        .id(Self.newAppEditAnchorID)
                }
        }
        .id(Self.newAppRowAnchorID)
        .background(
            CardSurface(
                fill: RenewioTheme.accent.opacity(0.06),
                border: RenewioTheme.accent.opacity(0.25),
                cornerRadius: RenewioTheme.radiusMd
            )
        )
        .onAppear {
            scrollRestoreID = Self.newAppRowAnchorID
            scrollToEditID = nil
            Task { @MainActor in
                scrollToEditID = Self.newAppEditAnchorID
            }
        }
    }

    private var installsForSelected: [TrackedAppInstall] {
        guard let selectedDeviceID else { return [] }
        return draftInstalls.filter { $0.deviceID == selectedDeviceID }
    }

    private var sourcePasteStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                sourceTabButton("GitHub Repo", kind: .github)
                sourceTabButton("Local .ipa", kind: .localIPA)
            }

            if sourceKind == .github {
                Text("Paste the GitHub HTTPS clone link to verify the repo.")
                    .font(.system(size: 11))
                    .foregroundStyle(RenewioTheme.mutedForeground)

                RenewioTextField(
                    placeholder: "https://github.com/owner/repo.git",
                    text: $sourceDraftURL,
                    monospaced: true
                )
                .onSubmit {
                    Task { await verifyAndResolveSource() }
                }

                HStack(spacing: 8) {
                    Button("Cancel") {
                        cancelAppEditor()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(width: 92)

                    Button {
                        Task { await verifyAndResolveSource() }
                    } label: {
                        LoadingLabel(
                            title: isScanningReleases ? "Verifying…" : "Continue",
                            isLoading: isScanningReleases,
                            tint: RenewioTheme.accentForeground
                        )
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isScanningReleases || sourceDraftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text("Choose an .ipa file on your Mac (or drop one onto Renewio).")
                    .font(.system(size: 11))
                    .foregroundStyle(RenewioTheme.mutedForeground)

                HStack(spacing: 8) {
                    Button("Cancel") {
                        cancelAppEditor()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(width: 92)

                    Button {
                        chooseLocalIPA()
                    } label: {
                        Label("Choose .ipa…", systemImage: "doc.badge.plus")
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .padding(10)
        .background(CardSurface(fill: RenewioTheme.accent.opacity(0.06), border: RenewioTheme.accent.opacity(0.25)))
    }

    private func sourceTabButton(_ title: String, kind: SourceKind) -> some View {
        let active = sourceKind == kind
        return Button {
            withAnimation(RenewioMotion.hover) {
                sourceKind = kind
                errorMessage = nil
            }
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(active ? RenewioTheme.accentForeground : RenewioTheme.mutedForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(active ? RenewioTheme.accent : Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: RenewioTheme.radiusSm, style: .continuous))
        }
        .buttonStyle(RenewioPressButtonStyle())
    }

    private func appEditorFields(_ install: TrackedAppInstall, isNew: Bool) -> some View {
        let isLocal = editingInstall?.isLocalIPA ?? install.isLocalIPA
        return VStack(alignment: .leading, spacing: 10) {
            labeledField("Name") {
                RenewioTextField(placeholder: "App name", text: binding(\.name, in: install))
            }

            if isLocal {
                labeledField("Local IPA") {
                    HStack(spacing: 8) {
                        Text(editingInstall?.sourceLabel ?? install.sourceLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(RenewioTheme.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(RenewioTheme.background.opacity(0.75))
                            .clipShape(RoundedRectangle(cornerRadius: RenewioTheme.radiusMd, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: RenewioTheme.radiusMd, style: .continuous)
                                    .stroke(RenewioTheme.border, lineWidth: 1)
                            )
                        InlineActionLink(title: "Change", systemImage: "folder") {
                            chooseLocalIPA(updatingExisting: true)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("VERSION")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RenewioTheme.mutedForeground)
                        Spacer()
                        InlineActionLink(
                            title: isScanningReleases ? "Scanning…" : "Scan",
                            systemImage: "arrow.clockwise",
                            disabled: isScanningReleases
                        ) {
                            Task { await scanReleases() }
                        }
                    }
                    SelectableOptionRow(
                        title: "Latest release",
                        subtitle: "Auto-fetch newest from GitHub",
                        isSelected: (editingInstall?.selectedTag ?? "").isEmpty
                    ) {
                        editingInstall?.selectedTag = nil
                    }
                    ForEach(model.availableVersions) { option in
                        let meta = option.isCached
                            ? (option.formattedSize.isEmpty ? "Cached" : "Cached · \(option.formattedSize)")
                            : (option.formattedSize.isEmpty ? "Download on install" : "GitHub · \(option.formattedSize)")
                        SelectableOptionRow(
                            title: option.displayVersion,
                            subtitle: meta,
                            isSelected: editingInstall?.selectedTag == option.tag
                        ) {
                            editingInstall?.selectedTag = option.tag
                        }
                    }
                }
            }

            labeledField("Bundle ID") {
                HStack(spacing: 8) {
                    RenewioTextField(
                        placeholder: "com.renewio.app",
                        text: binding(\.bundleID, in: install),
                        monospaced: true
                    )
                    InlineActionLink(title: "Suggest", systemImage: "sparkles") {
                        let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
                        let name = editingInstall?.name ?? install.name
                        editingInstall?.bundleID = suggestedBundleID(team: team, appName: name)
                    }
                }
            }

            if autoRenewEnabled {
                PreferenceToggleRow(
                    title: "Auto-update",
                    subtitle: "Include this app when Auto-renew runs nearby",
                    isOn: Binding(
                        get: {
                            editingInstall?.isAutoUpdateEnabled ?? install.isAutoUpdateEnabled
                        },
                        set: { newValue in
                            if editingInstall == nil { editingInstall = install }
                            editingInstall?.autoUpdateEnabled = newValue
                        }
                    )
                )
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    cancelAppEditor()
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 92)

                if !isNew {
                    Button("Remove") {
                        withAnimation(RenewioMotion.expand) {
                            draftInstalls.removeAll { $0.id == install.id }
                            cancelAppEditor()
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Button("Done") {
                    finishEditingApp()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.top, 2)
    }

    private static func appRowAnchorID(_ id: UUID) -> String { "app-row-\(id.uuidString)" }
    private static func appEditAnchorID(_ id: UUID) -> String { "app-edit-\(id.uuidString)" }
    private static let newAppRowAnchorID = "app-row-new"
    private static let newAppEditAnchorID = "app-edit-new"

    private func beginAddApp() {
        guard selectedDeviceID != nil else {
            errorMessage = "Select or add a device first."
            return
        }
        scrollToEditID = nil
        scrollRestoreID = nil
        withAnimation(RenewioMotion.expand) {
            sourceKind = .github
            isAddingNewApp = true
            isRepoVerified = false
            sourceDraftURL = ""
            editingInstall = nil
            errorMessage = nil
        }
        model.availableVersions = []
    }

    private func beginEditApp(_ install: TrackedAppInstall) {
        let rowID = Self.appRowAnchorID(install.id)
        let editID = Self.appEditAnchorID(install.id)
        scrollRestoreID = rowID
        withAnimation(RenewioMotion.expand) {
            isAddingNewApp = false
            isRepoVerified = true
            sourceKind = install.isLocalIPA ? .localIPA : .github
            sourceDraftURL = install.isLocalIPA ? "" : "https://github.com/\(install.githubRepo).git"
            editingInstall = install
            errorMessage = nil
        }
        if !install.isLocalIPA {
            model.refreshVersions(forRepo: install.githubRepo)
            Task { await scanReleases() }
        } else {
            model.availableVersions = []
        }
        scrollToEditID = nil
        Task { @MainActor in
            scrollToEditID = editID
        }
    }

    private func cancelAppEditor() {
        scrollToEditID = nil
        withAnimation(RenewioMotion.expand) {
            isAddingNewApp = false
            isRepoVerified = false
            sourceDraftURL = ""
            editingInstall = nil
            errorMessage = nil
        }
        model.availableVersions = []
    }

    private func scrollEditPanelIntoView(proxy: ScrollViewProxy, editID: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard scrollToEditID == editID else { return }
            withAnimation(RenewioMotion.expand) {
                proxy.scrollTo(editID, anchor: .bottom)
            }
        }
    }

    private func restoreScrollAfterEditClose(proxy: ScrollViewProxy) {
        guard let restoreID = scrollRestoreID else { return }
        scrollRestoreID = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            withAnimation(RenewioMotion.expand) {
                proxy.scrollTo(restoreID, anchor: .top)
            }
        }
    }

    // MARK: - Team

    private var teamSection: some View {
        SectionCard("TEAM ID") {
            InlineActionLink(title: "Auto-detect", systemImage: "wand.and.stars") {
                Task { await autoDetectTeam() }
            }
        } content: {
            RenewioTextField(placeholder: "e.g. 52L6R8UQZU", text: $teamID, monospaced: true)
            Text("Shared across all devices and apps. Apple ID stays in Xcode.")
                .font(.system(size: 10.5))
                .foregroundStyle(RenewioTheme.mutedForeground)
        }
    }

    // MARK: - Preferences & Storage

    private var preferencesSection: some View {
        SectionCard("PREFERENCES", spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                PreferenceToggleRow(
                    title: "Launch at login",
                    subtitle: "Stay in the menu bar after restart",
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { toggleLaunchAtLogin($0) }
                    )
                )

                PreferenceToggleRow(
                    title: "Auto-renew when nearby",
                    subtitle: "Renew within 24h of expiry when the device is awake",
                    isOn: $autoRenewEnabled
                )

                PreferenceToggleRow(
                    title: "Require security review",
                    subtitle: "Scan the IPA before install. Auto/Latest waits 14+ days; pin a tag to install sooner.",
                    isOn: $securityReviewEnabled
                )

                securityAccountSection

                Divider().overlay(RenewioTheme.border)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("GITHUB TOKEN (OPTIONAL)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RenewioTheme.mutedForeground)
                        Spacer()
                        if hasSavedGitHubToken {
                            Text("Saved in Keychain")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(RenewioTheme.success)
                        }
                    }
                    HStack(spacing: 6) {
                        SecureField(
                            hasSavedGitHubToken ? "•••••••••••• (replace token)" : "ghp_… for private repos / rate limits",
                            text: $githubTokenInput
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RenewioTheme.background.opacity(0.75))
                        .foregroundStyle(RenewioTheme.foreground)
                        .clipShape(RoundedRectangle(cornerRadius: RenewioTheme.radiusMd, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: RenewioTheme.radiusMd, style: .continuous)
                                .stroke(RenewioTheme.border, lineWidth: 1)
                        )

                        if !githubTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            InlineActionLink(title: "Save", systemImage: "key.fill") {
                                saveGitHubToken()
                            }
                        } else if hasSavedGitHubToken {
                            InlineActionLink(title: "Clear", systemImage: "trash") {
                                clearGitHubToken()
                            }
                        }
                    }
                }

                Divider().overlay(RenewioTheme.border)

                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(RenewRunner.logDirectoryURL)
                    } label: {
                        Label("Open Logs", systemImage: "doc.text.magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button {
                        clearCache()
                    } label: {
                        let formatted = ByteCountFormatter.string(fromByteCount: cacheSizeBytes, countStyle: .file)
                        Label(
                            cacheSizeBytes > 0 ? "Clear Cache (\(formatted))" : "Cache Empty",
                            systemImage: "trash"
                        )
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(cacheSizeBytes == 0)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Cancel") { model.handleSetupClosed() }
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 92)

            Button {
                Task { await save() }
            } label: {
                LoadingLabel(
                    title: isSaving ? "Saving…" : "Save",
                    isLoading: isSaving,
                    tint: RenewioTheme.accentForeground
                )
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isSaving || !canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RenewioTheme.backgroundAlt.opacity(0.9))
    }

    private var canSave: Bool {
        teamID.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
            && !draftDevices.isEmpty
            && !draftInstalls.isEmpty
            && editingInstall == nil
    }

    // MARK: - Actions

    private func bootstrap() {
        if let existing = model.configStore.config {
            teamID = existing.teamID
            draftDevices = existing.devices
            draftInstalls = existing.installs
            selectedDeviceID = existing.selectedDeviceID ?? existing.devices.first?.id
            autoRenewEnabled = existing.isAutoRenewEnabled
            securityReviewEnabled = existing.isSecurityReviewEnabled
        }
        launchAtLogin = LaunchAtLoginManager.isEnabled
        hasSavedGitHubToken = KeychainStore.hasGitHubToken
        cacheSizeBytes = ConfigStore.cacheSizeBytes()

        if let editID = model.editingInstallID,
           let target = draftInstalls.first(where: { $0.id == editID }) {
            selectedDeviceID = target.deviceID
            beginEditApp(target)
        } else if let droppedURL = model.pendingLocalIPAURL {
            model.pendingLocalIPAURL = nil
            prepareNewLocalIPA(url: droppedURL)
        } else if model.pendingAddApp {
            model.pendingAddApp = false
            if selectedDeviceID == nil {
                selectedDeviceID = draftDevices.first?.id
            }
            beginAddApp()
        }

        Task {
            let env = await Task.detached {
                (
                    xcode: DeviceDiscovery.xcodeAvailable(),
                    sdks: DeviceDiscovery.availableSDKs(),
                    teams: DeviceDiscovery.detectTeamHints()
                )
            }.value
            xcodeOK = env.xcode
            sdks = env.sdks
            if teamID.isEmpty, let first = env.teams.first {
                teamID = first.id
            }
        }
        Task { await refreshDevices() }
    }

    private func addDevice(_ device: TrackedDevice) {
        if let idx = draftDevices.firstIndex(where: { $0.id == device.id }) {
            draftDevices[idx] = device
        } else {
            draftDevices.append(device)
        }
        selectedDeviceID = device.id
        errorMessage = nil
    }

    private func removeDevice(_ deviceID: String) {
        withAnimation(RenewioMotion.expand) {
            draftDevices.removeAll { $0.id == deviceID }
            draftInstalls.removeAll { $0.deviceID == deviceID }
            if editingInstall?.deviceID == deviceID {
                cancelAppEditor()
            }
            if selectedDeviceID == deviceID {
                selectedDeviceID = draftDevices.first?.id
            }
        }
    }

    private func refreshDevices() async {
        isLoadingDevices = true
        errorMessage = nil
        defer { isLoadingDevices = false }
        do {
            discovered = try await DeviceDiscovery.listDevices()
            if draftDevices.isEmpty, let first = discovered.first {
                addDevice(first.trackedDevice)
            }
        } catch {
            discovered = []
            errorMessage = error.localizedDescription
        }
    }

    private func autoDetectTeam() async {
        errorMessage = nil
        let teams = await Task.detached { DeviceDiscovery.detectTeamHints() }.value
        if let first = teams.first {
            teamID = first.id
        } else {
            errorMessage = "No Xcode team found. Sign in under Xcode → Settings → Accounts."
        }
    }

    private func chooseLocalIPA(updatingExisting: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = "Choose an .ipa file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let ipaType = UTType(filenameExtension: "ipa") {
            panel.allowedContentTypes = [ipaType]
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if updatingExisting {
            editingInstall?.localIPAPath = url.path
            editingInstall?.githubRepo = ""
            editingInstall?.selectedTag = nil
        } else {
            prepareNewLocalIPA(url: url)
        }
    }

    private func prepareNewLocalIPA(url: URL) {
        guard let deviceID = selectedDeviceID ?? draftDevices.first?.id else {
            errorMessage = "Add or select a device before adding a local .ipa."
            return
        }
        selectedDeviceID = deviceID
        let rawName = url.deletingPathExtension().lastPathComponent
        let appName = friendlyAppName(from: GitHubRepoInfo(ownerRepo: "", name: rawName, fullName: rawName, description: nil))
        let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines)

        isAddingNewApp = true
        sourceKind = .localIPA
        model.availableVersions = []
        editingInstall = TrackedAppInstall(
            deviceID: deviceID,
            name: appName,
            githubRepo: "",
            bundleID: suggestedBundleID(team: team, appName: appName),
            localIPAPath: url.path
        )
        withAnimation(RenewioMotion.expand) {
            isRepoVerified = true
        }
    }

    private func verifyAndResolveSource() async {
        guard let deviceID = selectedDeviceID else {
            errorMessage = "Select or add a device first."
            return
        }
        let raw = sourceDraftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = GitHubSource.normalize(raw) else {
            errorMessage = "Paste a GitHub HTTPS clone link like https://github.com/owner/repo.git"
            return
        }

        isScanningReleases = true
        errorMessage = nil
        defer { isScanningReleases = false }

        do {
            let info = try await ConfigStore.fetchRepoInfo(repo: normalized)
            let appName = friendlyAppName(from: info)
            let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
            let releases = try await ConfigStore.fetchRecentReleases(repo: info.ownerRepo, limit: 3)
            model.availableVersions = releases

            editingInstall = TrackedAppInstall(
                deviceID: deviceID,
                name: appName,
                githubRepo: info.ownerRepo,
                bundleID: suggestedBundleID(team: team, appName: appName)
            )
            sourceDraftURL = "https://github.com/\(info.ownerRepo).git"
            withAnimation(RenewioMotion.expand) {
                isRepoVerified = true
            }
        } catch {
            isRepoVerified = false
            editingInstall = nil
            model.availableVersions = []
            errorMessage = "Could not verify repo: \(error.localizedDescription)"
        }
    }

    private func finishEditingApp() {
        guard var edited = editingInstall else { return }
        if edited.isLocalIPA {
            edited.githubRepo = ""
            edited.selectedTag = nil
        } else {
            guard let normalized = GitHubSource.normalize(edited.githubRepo) else {
                errorMessage = "GitHub source is invalid. Cancel and paste the clone link again."
                return
            }
            edited.githubRepo = normalized
        }
        edited.bundleID = edited.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.name = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if edited.name.isEmpty {
            edited.name = edited.isLocalIPA ? edited.sourceLabel : friendlyAppName(fromRepo: edited.githubRepo)
        }
        guard edited.bundleID.contains(".") else {
            errorMessage = "App needs a Bundle ID like com.renewio.app."
            return
        }
        if let idx = draftInstalls.firstIndex(where: { $0.id == edited.id }) {
            draftInstalls[idx] = edited
        } else {
            draftInstalls.append(edited)
        }
        cancelAppEditor()
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        errorMessage = nil
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
            launchAtLogin = LaunchAtLoginManager.isEnabled
        } catch {
            launchAtLogin = LaunchAtLoginManager.isEnabled
            errorMessage = "Launch at Login failed: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var securityAccountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Security account")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RenewioTheme.foreground)
            Text(
                SecurityConfig.isConfigured
                    ? "Email and password for shared security scans."
                    : "Set RenewioSupabaseURL / RenewioSupabaseAnonKey in Info.plist to enable shared scanning."
            )
            .font(.system(size: 11))
            .foregroundStyle(RenewioTheme.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)

            if model.securityClient.isSignedIn {
                HStack {
                    Text(model.securityClient.userEmail ?? "Signed in")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(RenewioTheme.success)
                    Spacer()
                    PopoverIconButton(
                        systemImage: "rectangle.portrait.and.arrow.right",
                        hoverTint: RenewioTheme.danger,
                        helpText: "Sign out",
                        action: { model.securityClient.signOut() }
                    )
                }
            } else if SecurityConfig.isConfigured {
                TextField("Email", text: $securityEmail)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                SecureField("Password", text: $securityPassword)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                HStack(spacing: 8) {
                    Button(securityBusy ? "Signing in…" : "Sign in") {
                        Task { await securitySignIn() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(securityBusy || securityEmail.isEmpty || securityPassword.isEmpty)

                    Button(securityBusy ? "Creating…" : "Create account") {
                        Task { await securitySignUp() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(securityBusy || securityEmail.isEmpty || securityPassword.isEmpty)
                }
            }
        }
        .padding(.top, 4)
    }

    private func securitySignIn() async {
        securityBusy = true
        defer { securityBusy = false }
        do {
            try await model.securityClient.signIn(email: securityEmail, password: securityPassword)
            securityPassword = ""
            showTemporaryInfo("Signed in for shared security scanning.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func securitySignUp() async {
        securityBusy = true
        defer { securityBusy = false }
        do {
            try await model.securityClient.signUp(email: securityEmail, password: securityPassword)
            securityPassword = ""
            showTemporaryInfo("Account created and signed in.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveGitHubToken() {
        let token = githubTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        if KeychainStore.saveGitHubToken(token) {
            githubTokenInput = ""
            hasSavedGitHubToken = true
            showTemporaryInfo("GitHub token saved in Keychain.")
        } else {
            errorMessage = "Could not save GitHub token to Keychain."
        }
    }

    private func clearGitHubToken() {
        _ = KeychainStore.deleteGitHubToken()
        githubTokenInput = ""
        hasSavedGitHubToken = false
        showTemporaryInfo("GitHub token removed from Keychain.")
    }

    private func clearCache() {
        errorMessage = nil
        do {
            let freed = try ConfigStore.clearIPACache()
            cacheSizeBytes = ConfigStore.cacheSizeBytes()
            let formatted = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
            showTemporaryInfo("Cleared IPA cache (\(formatted) freed).")
        } catch {
            errorMessage = "Could not clear cache: \(error.localizedDescription)"
        }
    }

    private func showTemporaryInfo(_ message: String) {
        infoBanner = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if infoBanner == message {
                infoBanner = nil
            }
        }
    }

    private func friendlyAppName(from info: GitHubRepoInfo) -> String {
        let raw = info.name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let spaced = raw.replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        )
        return spaced
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func friendlyAppName(fromRepo repo: String) -> String {
        let repoName = repo.split(separator: "/").last.map(String.init) ?? repo
        return friendlyAppName(from: GitHubRepoInfo(ownerRepo: repo, name: repoName, fullName: repo, description: nil))
    }

    private func scanReleases() async {
        guard let repo = editingInstall?.githubRepo, GitHubSource.normalize(repo) != nil else {
            errorMessage = "Verify a GitHub source first."
            return
        }
        isScanningReleases = true
        errorMessage = nil
        defer { isScanningReleases = false }
        do {
            model.availableVersions = try await ConfigStore.fetchRecentReleases(repo: repo, limit: 3)
        } catch {
            errorMessage = "Could not scan releases: \(error.localizedDescription)"
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let trimmedTeam = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTeam.count >= 8 else {
            errorMessage = "Team ID looks incomplete."
            return
        }
        guard !draftDevices.isEmpty else {
            errorMessage = "Add at least one device."
            return
        }
        guard !draftInstalls.isEmpty else {
            errorMessage = "Add at least one app."
            return
        }

        let config = RenewioConfig(
            teamID: trimmedTeam,
            devices: draftDevices,
            installs: draftInstalls,
            selectedDeviceID: selectedDeviceID ?? draftDevices.first?.id,
            autoRenewEnabled: autoRenewEnabled,
            securityReviewEnabled: securityReviewEnabled
        )
        do {
            try model.configStore.save(config)
            model.refreshExpiryNotifications()
            model.handleSetupClosed()
        } catch {
            errorMessage = "Could not save settings: \(error.localizedDescription)"
        }
    }

    private func suggestedBundleID(team: String, appName: String) -> String {
        let teamSlug = team.lowercased().isEmpty ? "team" : team.lowercased()
        let appSlug = appName
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .filter { $0.isLetter || $0.isNumber }
        let base = appSlug.isEmpty ? "app" : appSlug
        return "com.renewio.\(teamSlug).\(base)"
    }

    private func binding(
        _ keyPath: WritableKeyPath<TrackedAppInstall, String>,
        in install: TrackedAppInstall
    ) -> Binding<String> {
        Binding(
            get: { editingInstall?[keyPath: keyPath] ?? install[keyPath: keyPath] },
            set: { newValue in
                if editingInstall == nil { editingInstall = install }
                editingInstall?[keyPath: keyPath] = newValue
            }
        )
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(RenewioTheme.mutedForeground)
            content()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(RenewioTheme.danger)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(RenewioTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurface(fill: RenewioTheme.danger.opacity(0.12), border: RenewioTheme.danger.opacity(0.35), cornerRadius: 10))
    }

    private func successBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(RenewioTheme.success)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(RenewioTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurface(fill: RenewioTheme.success.opacity(0.12), border: RenewioTheme.success.opacity(0.35), cornerRadius: 10))
    }

    private func checklistRow(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(ok ? RenewioTheme.success : RenewioTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RenewioTheme.foreground)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(RenewioTheme.mutedForeground)
            }
        }
    }
}

private struct XcodeStatusButton: View {
    let ready: Bool
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var tint: Color {
        ready ? RenewioTheme.success : RenewioTheme.accent
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                StatusDot(tint: tint, size: 5)
                Text(ready ? "Xcode OK" : "Xcode")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(
                        (isHovered || isFocused)
                            ? RenewioTheme.foreground
                            : (ready ? RenewioTheme.mutedForeground : RenewioTheme.accent)
                    )
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(
                        (isHovered || isFocused)
                            ? RenewioTheme.accent
                            : RenewioTheme.mutedForeground.opacity(0.7)
                    )
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (isHovered || isFocused) ? RenewioTheme.accent.opacity(0.12) : Color.white.opacity(0.04)
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        (isHovered || isFocused)
                            ? RenewioTheme.accent.opacity(0.45)
                            : (ready ? RenewioTheme.border : RenewioTheme.accent.opacity(0.35)),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(RenewioPressButtonStyle())
        .help("Open Xcode")
        .focused($isFocused)
        .interactiveHover($isHovered)
        .shadow(
            color: RenewioTheme.accent.opacity(isFocused ? 0.2 : 0),
            radius: isFocused ? 6 : 0
        )
        .animation(RenewioMotion.hover, value: isHovered)
        .animation(RenewioMotion.hover, value: isFocused)
    }
}
