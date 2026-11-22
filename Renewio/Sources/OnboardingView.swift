import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    @State private var teamID = ""
    @State private var discovered: [AppleDevice] = []
    @State private var isLoadingDevices = true
    @State private var errorMessage: String?
    @State private var xcodeOK = true
    @State private var sdks = AvailableSDKs(tvOS: true, iOS: true)
    @State private var isSaving = false
    @State private var manualName = ""
    @State private var manualID = ""
    @State private var manualPlatform: DevicePlatform = .tvos
    @State private var showManualDevice = false

    @State private var draftDevices: [TrackedDevice] = []
    @State private var draftInstalls: [TrackedAppInstall] = []
    @State private var selectedDeviceID: String?
    @State private var editingInstall: TrackedAppInstall?
    @State private var isScanningReleases = false
    @State private var sourceDraftURL = ""
    @State private var isRepoVerified = false
    @State private var isAddingNewApp = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(RenewioTheme.border)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    if !xcodeOK || (!sdks.tvOS && !sdks.iOS) {
                        environmentWarningCard
                    }
                    devicesSection
                    appsSection
                    teamSection
                    if let errorMessage {
                        errorBanner(errorMessage)
                    }
                }
                .padding(16)
            }
            .frame(height: 540)
            Divider().overlay(RenewioTheme.border)
            footer
        }
        .onAppear(perform: bootstrap)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            PopoverIconButton(
                systemImage: "chevron.left",
                iconSize: 13,
                iconWeight: .bold,
                hoverTint: RenewioTheme.accent,
                helpText: "Back to Renewio",
                action: { model.handleSetupClosed() }
            )

            VStack(alignment: .leading, spacing: 1) {
                Text("Settings")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(RenewioTheme.foreground)
                Text("Devices, apps & GitHub sources")
                    .font(.system(size: 11))
                    .foregroundStyle(RenewioTheme.mutedForeground)
            }

            Spacer(minLength: 6)

            XcodeStatusButton(ready: xcodeOK && (sdks.tvOS || sdks.iOS)) {
                DeviceDiscovery.openXcodeAccounts()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning for paired devices…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(RenewioTheme.mutedForeground)
                }
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
                        SelectableOptionRow(
                            title: device.name,
                            subtitle: "\(device.platform.displayName) · \(device.id)",
                            isSelected: selectedDeviceID == device.id,
                            subtitleTruncation: .middle
                        ) {
                            selectedDeviceID = device.id
                        }
                    }

                    let trackedIDs = Set(draftDevices.map(\.id))
                    let untracked = discovered.filter { !trackedIDs.contains($0.udid) && !trackedIDs.contains($0.id) }
                    if !untracked.isEmpty {
                        Text("Discovered — tap to add")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(RenewioTheme.mutedForeground)
                            .padding(.top, 4)
                        ForEach(untracked) { device in
                            Button {
                                addDevice(device.trackedDevice)
                            } label: {
                                HStack {
                                    Image(systemName: device.platform.systemImage)
                                        .foregroundStyle(RenewioTheme.accent)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(device.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(RenewioTheme.foreground)
                                        Text(device.displaySubtitle)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(RenewioTheme.mutedForeground)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(RenewioTheme.accent)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(CardSurface(fill: Color.white.opacity(0.03), cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showManualDevice.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showManualDevice ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text("Enter device manually")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(RenewioTheme.mutedForeground)
                }
                .buttonStyle(.plain)

                if showManualDevice {
                    VStack(spacing: 8) {
                        Picker("Platform", selection: $manualPlatform) {
                            ForEach(DevicePlatform.allCases) { platform in
                                Text(platform.displayName).tag(platform)
                            }
                        }
                        .pickerStyle(.segmented)
                        TextField("Device name", text: $manualName)
                            .textFieldStyle(RenewioTextFieldStyle())
                        TextField("Device UDID", text: $manualID)
                            .textFieldStyle(RenewioTextFieldStyle(monospaced: true))
                        Button("Add manual device") {
                            let id = manualID.trimmingCharacters(in: .whitespacesAndNewlines)
                            let name = manualName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !id.isEmpty else { return }
                            addDevice(TrackedDevice(
                                id: id,
                                name: name.isEmpty ? manualPlatform.displayName : name,
                                platform: manualPlatform
                            ))
                            showManualDevice = false
                            manualID = ""
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(manualID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                Text("No apps yet. Tap Add app and paste a GitHub HTTPS clone link.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(RenewioTheme.mutedForeground)
            } else if !isAddingNewApp || isRepoVerified {
                VStack(spacing: 6) {
                    ForEach(installsForSelected.filter { editingInstall?.id != $0.id }) { install in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(install.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(RenewioTheme.foreground)
                                Text("\(install.githubRepo) · \(install.bundleID)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(RenewioTheme.mutedForeground)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button {
                                beginEditApp(install)
                            } label: {
                                Text("Edit")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(RenewioTheme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(CardSurface(fill: Color.white.opacity(0.03), cornerRadius: 8))
                    }
                }
            }

            if isAddingNewApp && !isRepoVerified {
                sourcePasteStep
            } else if let editing = editingInstall, isRepoVerified {
                appEditor(editing)
            }
        }
    }

    private var installsForSelected: [TrackedAppInstall] {
        guard let selectedDeviceID else { return [] }
        return draftInstalls.filter { $0.deviceID == selectedDeviceID }
    }

    private var sourcePasteStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add app")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RenewioTheme.foreground)
            Text("Paste the GitHub HTTPS clone link to verify the repo.")
                .font(.system(size: 11))
                .foregroundStyle(RenewioTheme.mutedForeground)

            TextField("https://github.com/owner/repo.git", text: $sourceDraftURL)
                .textFieldStyle(RenewioTextFieldStyle(monospaced: true))
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
                    HStack(spacing: 6) {
                        if isScanningReleases {
                            ProgressView().controlSize(.small)
                        }
                        Text(isScanningReleases ? "Verifying…" : "Continue")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isScanningReleases || sourceDraftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(CardSurface(fill: RenewioTheme.accent.opacity(0.06), border: RenewioTheme.accent.opacity(0.25)))
    }

    private func appEditor(_ install: TrackedAppInstall) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(isAddingNewApp ? "New app" : "Edit app")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RenewioTheme.foreground)
                Spacer()
                Text(install.githubRepo)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(RenewioTheme.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            labeledField("Name") {
                TextField("App name", text: binding(\.name, in: install))
                    .textFieldStyle(RenewioTextFieldStyle())
            }

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

            labeledField("Bundle ID") {
                HStack(spacing: 8) {
                    TextField("com.renewio.app", text: binding(\.bundleID, in: install))
                        .textFieldStyle(RenewioTextFieldStyle(monospaced: true))
                    InlineActionLink(title: "Suggest", systemImage: "sparkles") {
                        let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
                        let name = editingInstall?.name ?? install.name
                        editingInstall?.bundleID = suggestedBundleID(team: team, appName: name)
                    }
                }
            }

            HStack(spacing: 8) {
                if !isAddingNewApp, draftInstalls.contains(where: { $0.id == install.id }) {
                    Button("Remove") {
                        draftInstalls.removeAll { $0.id == install.id }
                        cancelAppEditor()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Cancel") {
                        cancelAppEditor()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(width: 92)
                }
                Button("Done") {
                    finishEditingApp()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(10)
        .background(CardSurface(fill: RenewioTheme.accent.opacity(0.06), border: RenewioTheme.accent.opacity(0.25)))
    }

    private func beginAddApp() {
        guard let deviceID = selectedDeviceID else {
            errorMessage = "Select or add a device first."
            return
        }
        _ = deviceID
        isAddingNewApp = true
        isRepoVerified = false
        sourceDraftURL = ""
        editingInstall = nil
        model.availableVersions = []
        errorMessage = nil
    }

    private func beginEditApp(_ install: TrackedAppInstall) {
        isAddingNewApp = false
        isRepoVerified = true
        sourceDraftURL = "https://github.com/\(install.githubRepo).git"
        editingInstall = install
        model.refreshVersions(forRepo: install.githubRepo)
        errorMessage = nil
        Task { await scanReleases() }
    }

    private func cancelAppEditor() {
        isAddingNewApp = false
        isRepoVerified = false
        sourceDraftURL = ""
        editingInstall = nil
        model.availableVersions = []
        errorMessage = nil
    }

    // MARK: - Team

    private var teamSection: some View {
        SectionCard("TEAM ID") {
            InlineActionLink(title: "Auto-detect", systemImage: "wand.and.stars") {
                Task { await autoDetectTeam() }
            }
        } content: {
            TextField("e.g. 52L6R8UQZU", text: $teamID)
                .textFieldStyle(RenewioTextFieldStyle(monospaced: true))
            Text("Shared across all devices and apps. Apple ID stays in Xcode.")
                .font(.system(size: 10.5))
                .foregroundStyle(RenewioTheme.mutedForeground)
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
                HStack(spacing: 6) {
                    if isSaving { ProgressView().controlSize(.small) }
                    Text(isSaving ? "Saving…" : "Save")
                        .font(.system(size: 13, weight: .semibold))
                }
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

    private func refreshDevices() async {
        isLoadingDevices = true
        errorMessage = nil
        defer { isLoadingDevices = false }
        do {
            discovered = try await DeviceDiscovery.listDevices()
            // Auto-add first discovered device if none tracked yet.
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
            withAnimation(.easeOut(duration: 0.18)) {
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
        guard let normalized = GitHubSource.normalize(edited.githubRepo) else {
            errorMessage = "GitHub source is invalid. Cancel and paste the clone link again."
            return
        }
        edited.githubRepo = normalized
        edited.bundleID = edited.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.name = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if edited.name.isEmpty {
            edited.name = friendlyAppName(fromRepo: normalized)
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
            selectedDeviceID: selectedDeviceID ?? draftDevices.first?.id
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
    @State private var pushedCursor = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(ready ? RenewioTheme.success : RenewioTheme.accent)
                    .frame(width: 6, height: 6)
                    .shadow(color: (ready ? RenewioTheme.success : RenewioTheme.accent).opacity(0.6), radius: 4)
                Text(ready ? "Xcode OK" : "Xcode")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(
                        isHovered
                            ? RenewioTheme.foreground
                            : (ready ? RenewioTheme.mutedForeground : RenewioTheme.accent)
                    )
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(isHovered ? RenewioTheme.accent : RenewioTheme.mutedForeground.opacity(0.7))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isHovered ? RenewioTheme.accent.opacity(0.12) : Color.white.opacity(0.04))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        isHovered
                            ? RenewioTheme.accent.opacity(0.45)
                            : (ready ? RenewioTheme.border : RenewioTheme.accent.opacity(0.35)),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Open Xcode")
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
