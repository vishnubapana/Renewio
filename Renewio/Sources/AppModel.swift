import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications

enum MenuBarUrgency: Equatable {
    case normal
    case running
    case warning
    case expired

    var systemImage: String {
        switch self {
        // Keep these to SF Symbols that ship with macOS 14+ — invalid names blank the menu bar item.
        case .normal: return "arrow.triangle.2.circlepath"
        case .running: return "arrow.clockwise.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .expired: return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let configStore = ConfigStore()
    let renewRunner = RenewRunner()

    @Published var showOnboarding = false
    @Published var availableVersions: [ReleaseOption] = []
    @Published var editingInstallID: UUID?
    @Published var pendingLocalIPAURL: URL?
    /// Latest available GitHub release when newer than `lastInstalledVersion`.
    @Published var availableUpdates: [UUID: ReleaseOption] = [:]
    /// Simple published icon for MenuBarExtra — avoid TimelineView in the label (it often fails to render).
    @Published private(set) var menuBarSystemImage: String = MenuBarUrgency.normal.systemImage

    private var cancellables = Set<AnyCancellable>()
    private var backgroundTimer: Timer?
    private var menuBarTimer: Timer?
    private var lastUpdateCheckAt: Date?
    private var lastAutoRenewAttemptByInstall: [UUID: Date] = [:]

    init() {
        showOnboarding = configStore.needsOnboarding
        ExpiryNotifier.requestAuthorizationIfNeeded()
        ExpiryNotifier.reschedule(for: configStore.config)

        configStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.refreshMenuBarIcon()
            }
            .store(in: &cancellables)

        renewRunner.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.refreshMenuBarIcon()
            }
            .store(in: &cancellables)

        refreshMenuBarIcon()
        startMenuBarIconTimer()
        startBackgroundScheduler()
        Task { await checkForUpdatesIfNeeded() }
    }

    func refreshMenuBarIcon() {
        let next = menuBarUrgency().systemImage
        if menuBarSystemImage != next {
            menuBarSystemImage = next
        }
    }

    private func startMenuBarIconTimer() {
        menuBarTimer?.invalidate()
        menuBarTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMenuBarIcon()
            }
        }
    }

    var selectedDevice: TrackedDevice? {
        configStore.config?.selectedDevice
    }

    var installsForSelectedDevice: [TrackedAppInstall] {
        guard let config = configStore.config else { return [] }
        guard let deviceID = selectedDevice?.id else {
            return config.installs
        }
        let matched = config.installs(forDeviceID: deviceID)
        if matched.isEmpty, config.devices.count == 1, !config.installs.isEmpty {
            return config.installs
        }
        return matched
    }

    func menuBarUrgency(now: Date = Date()) -> MenuBarUrgency {
        if renewRunner.isRunning { return .running }
        guard let installs = configStore.config?.installs, !installs.isEmpty else {
            return .normal
        }
        var hasWarning = false
        for install in installs {
            guard let expiresAt = install.expiresAt else { continue }
            let remaining = expiresAt.timeIntervalSince(now)
            if remaining <= 0 {
                return .expired
            }
            if remaining <= ExpiryNotifier.renewSoonLeadTime {
                hasWarning = true
            }
        }
        return hasWarning ? .warning : .normal
    }

    func openOnboarding(editingInstallID: UUID? = nil) {
        self.editingInstallID = editingInstallID
        withAnimation(RenewioMotion.transition) {
            showOnboarding = true
        }
    }

    func openOnboardingWithLocalIPA(_ url: URL) {
        pendingLocalIPAURL = url
        editingInstallID = nil
        withAnimation(RenewioMotion.transition) {
            showOnboarding = true
        }
    }

    func handleSetupClosed() {
        editingInstallID = nil
        pendingLocalIPAURL = nil
        withAnimation(RenewioMotion.transition) {
            showOnboarding = false
        }
        Task { await checkForUpdatesIfNeeded(force: true) }
    }

    func selectDevice(_ deviceID: String) {
        guard var config = configStore.config else { return }
        config.selectDevice(deviceID)
        try? configStore.save(config)
        ExpiryNotifier.reschedule(for: config)
    }

    func renew(install: TrackedAppInstall) {
        guard let config = configStore.config, config.isComplete else {
            openOnboarding()
            return
        }
        guard let device = config.devices.first(where: { $0.id == install.deviceID })
            ?? config.selectedDevice
        else {
            openOnboarding()
            return
        }
        renewRunner.renew(
            install: install,
            device: device,
            teamID: config.teamID
        ) { [weak self] installID, version, tag, assetName, expiresAt in
            self?.recordSuccess(
                installID: installID,
                version: version,
                tag: tag,
                assetName: assetName,
                expiresAt: expiresAt
            )
        }
    }

    func renewAllOnSelectedDevice() {
        guard let config = configStore.config,
              let device = config.selectedDevice
        else {
            openOnboarding()
            return
        }
        let installs = config.installs(forDeviceID: device.id)
        guard !installs.isEmpty else { return }
        renewRunner.renewAll(
            installs: installs,
            device: device,
            teamID: config.teamID
        ) { [weak self] installID, version, tag, assetName, expiresAt in
            self?.recordSuccess(
                installID: installID,
                version: version,
                tag: tag,
                assetName: assetName,
                expiresAt: expiresAt
            )
        }
    }

    private func recordSuccess(
        installID: UUID,
        version: String,
        tag: String?,
        assetName: String?,
        expiresAt: String?
    ) {
        guard var config = configStore.config else { return }
        config.markInstallSuccess(
            installID: installID,
            version: version,
            tag: tag,
            assetName: assetName,
            expiresAt: expiresAt
        )
        try? configStore.save(config)
        ExpiryNotifier.reschedule(for: config)
        // Clear update badge if installed version matches latest.
        if let update = availableUpdates[installID],
           Self.normalizedVersion(version) == Self.normalizedVersion(update.version) {
            availableUpdates.removeValue(forKey: installID)
        }
    }

    func refreshExpiryNotifications() {
        ExpiryNotifier.reschedule(for: configStore.config)
    }

    func refreshVersions(forRepo repo: String) {
        let cached = ConfigStore.listCachedVersions(forRepo: repo, limit: 3)
        availableVersions = cached.map {
            ReleaseOption(
                tag: nil,
                version: $0.version,
                assetName: $0.filename,
                sizeBytes: $0.sizeBytes,
                isCached: true
            )
        }
    }

    // MARK: - Update Checking & Background Auto-Renew

    func checkForUpdatesIfNeeded(force: Bool = false) async {
        guard let config = configStore.config, !config.installs.isEmpty else { return }
        if !force, let last = lastUpdateCheckAt, Date().timeIntervalSince(last) < 6 * 60 * 60 {
            return
        }
        lastUpdateCheckAt = Date()

        let candidates = config.installs.filter {
            !$0.isLocalIPA && ($0.selectedTag ?? "").isEmpty && !$0.githubRepo.isEmpty
        }
        let uniqueRepos = Set(candidates.map(\.githubRepo))
        var latestByRepo: [String: ReleaseOption] = [:]

        for repo in uniqueRepos {
            if let releases = try? await ConfigStore.fetchRecentReleases(repo: repo, limit: 1),
               let first = releases.first {
                latestByRepo[repo] = first
            }
        }

        var nextUpdates: [UUID: ReleaseOption] = [:]
        for install in candidates {
            guard let latest = latestByRepo[install.githubRepo],
                  let installed = install.lastInstalledVersion, !installed.isEmpty
            else { continue }
            if Self.isNewerVersion(latest.version, than: installed) {
                nextUpdates[install.id] = latest
            }
        }
        availableUpdates = nextUpdates
    }

    static func normalizedVersion(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        let lhs = normalizedVersion(candidate)
        let rhs = normalizedVersion(current)
        guard !lhs.isEmpty, !rhs.isEmpty, lhs != rhs else { return false }
        return lhs.compare(rhs, options: .numeric) == .orderedDescending
    }

    private func startBackgroundScheduler() {
        backgroundTimer?.invalidate()
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runBackgroundMaintenance()
            }
        }
    }

    private func runBackgroundMaintenance() async {
        await checkForUpdatesIfNeeded()
        await autoRenewIfNeeded()
    }

    private func autoRenewIfNeeded() async {
        guard let config = configStore.config,
              config.isComplete,
              config.isAutoRenewEnabled,
              !renewRunner.isRunning
        else { return }

        let now = Date()
        let threshold: TimeInterval = 24 * 60 * 60
        let cooldown: TimeInterval = 4 * 60 * 60

        let dueInstalls = config.installs.filter { install in
            guard let expiresAt = install.expiresAt else { return false }
            guard expiresAt.timeIntervalSince(now) <= threshold else { return false }
            if let lastAttempt = lastAutoRenewAttemptByInstall[install.id],
               now.timeIntervalSince(lastAttempt) < cooldown {
                return false
            }
            return true
        }
        guard !dueInstalls.isEmpty else { return }

        guard let liveDevices = try? await DeviceDiscovery.listDevices(), !liveDevices.isEmpty else {
            return
        }
        let reachableIDs = Set(
            liveDevices
                .filter { !$0.state.localizedCaseInsensitiveContains("unpaired") && !$0.state.localizedCaseInsensitiveContains("unavailable") }
                .flatMap { [$0.id, $0.udid] }
        )

        for device in config.devices {
            guard reachableIDs.contains(device.id) else { continue }
            let dueForDevice = dueInstalls.filter { $0.deviceID == device.id }
            guard !dueForDevice.isEmpty else { continue }
            for inst in dueForDevice {
                lastAutoRenewAttemptByInstall[inst.id] = now
            }
            renewRunner.renewAll(
                installs: dueForDevice,
                device: device,
                teamID: config.teamID
            ) { [weak self] installID, version, tag, assetName, expiresAt in
                self?.recordSuccess(
                    installID: installID,
                    version: version,
                    tag: tag,
                    assetName: assetName,
                    expiresAt: expiresAt
                )
            }
            break
        }
    }
}
