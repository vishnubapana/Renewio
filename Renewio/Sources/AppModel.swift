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

/// Pending pre-install security review awaiting Proceed / Reject in the menu popover.
struct PendingSecurityReview: Equatable {
    enum Mode: Equatable {
        case single
        case batch(remaining: [TrackedAppInstall])
    }

    let install: TrackedAppInstall
    let device: TrackedDevice
    let teamID: String
    let result: SecurityScanResult
    /// Install passed to RenewRunner (may pin the resolved eligible tag).
    let resolvedInstall: TrackedAppInstall
    let mode: Mode
    /// True while a scan is still running for this install card.
    var isScanning: Bool = false
}

@MainActor
final class AppModel: ObservableObject {
    let configStore = ConfigStore()
    let renewRunner = RenewRunner()

    @Published var showOnboarding = false
    @Published var availableVersions: [ReleaseOption] = []
    @Published var editingInstallID: UUID?
    @Published var pendingLocalIPAURL: URL?
    /// When true, Settings opens already in the Add app flow for the selected device.
    @Published var pendingAddApp = false
    /// Latest available GitHub release when newer than `lastInstalledVersion`.
    @Published var availableUpdates: [UUID: ReleaseOption] = [:]
    /// Pre-install security review awaiting user decision.
    @Published var pendingSecurityReview: PendingSecurityReview?
    /// Install currently being security-scanned (shows “Scanning…” in the card).
    @Published var securityScanningInstallID: UUID?
    /// Simple published icon for MenuBarExtra — avoid TimelineView in the label (it often fails to render).
    @Published private(set) var menuBarSystemImage: String = MenuBarUrgency.normal.systemImage

    private var cancellables = Set<AnyCancellable>()
    private var backgroundTimer: Timer?
    private var menuBarTimer: Timer?
    private var lastUpdateCheckAt: Date?
    private var lastAutoRenewAttemptByInstall: [UUID: Date] = [:]
    private var successCallback: RenewRunner.SuccessCallback {
        { [weak self] installID, version, tag, assetName, expiresAt in
            self?.recordSuccess(
                installID: installID,
                version: version,
                tag: tag,
                assetName: assetName,
                expiresAt: expiresAt
            )
        }
    }

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
        if renewRunner.isRunning || securityScanningInstallID != nil { return .running }
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
        pendingAddApp = false
        withAnimation(RenewioMotion.transition) {
            showOnboarding = true
        }
    }

    /// Opens Settings with the Add app panel expanded for the currently selected device.
    func openOnboardingForAddApp() {
        editingInstallID = nil
        pendingLocalIPAURL = nil
        pendingAddApp = true
        withAnimation(RenewioMotion.transition) {
            showOnboarding = true
        }
    }

    func openOnboardingWithLocalIPA(_ url: URL) {
        pendingLocalIPAURL = url
        editingInstallID = nil
        pendingAddApp = false
        withAnimation(RenewioMotion.transition) {
            showOnboarding = true
        }
    }

    func handleSetupClosed() {
        editingInstallID = nil
        pendingLocalIPAURL = nil
        pendingAddApp = false
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
        guard !renewRunner.isRunning, securityScanningInstallID == nil else { return }
        Task {
            await beginRenewWithSecurityGate(
                installs: [install],
                device: device,
                teamID: config.teamID,
                securityReviewEnabled: config.isSecurityReviewEnabled
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
        guard !renewRunner.isRunning, securityScanningInstallID == nil else { return }
        Task {
            await beginRenewWithSecurityGate(
                installs: installs,
                device: device,
                teamID: config.teamID,
                securityReviewEnabled: config.isSecurityReviewEnabled
            )
        }
    }

    func proceedSecurityReview() {
        guard let pending = pendingSecurityReview else { return }
        let install = pending.resolvedInstall
        let device = pending.device
        let teamID = pending.teamID
        let remaining: [TrackedAppInstall]
        if case let .batch(rest) = pending.mode {
            remaining = rest
        } else {
            remaining = []
        }
        pendingSecurityReview = nil
        securityScanningInstallID = nil

        renewRunner.renew(
            install: install,
            device: device,
            teamID: teamID,
            onSuccess: successCallback
        )

        guard !remaining.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Wait for this renew to start, then finish, before scanning the rest.
            try? await Task.sleep(nanoseconds: 150_000_000)
            while self.renewRunner.isRunning {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            await self.beginRenewWithSecurityGate(
                installs: remaining,
                device: device,
                teamID: teamID,
                securityReviewEnabled: self.configStore.config?.isSecurityReviewEnabled ?? true
            )
        }
    }

    func rejectSecurityReview() {
        guard let pending = pendingSecurityReview else { return }
        let device = pending.device
        let teamID = pending.teamID
        let remaining: [TrackedAppInstall]
        if case let .batch(rest) = pending.mode {
            remaining = rest
        } else {
            remaining = []
        }
        pendingSecurityReview = nil
        securityScanningInstallID = nil
        guard !remaining.isEmpty else { return }
        Task {
            await beginRenewWithSecurityGate(
                installs: remaining,
                device: device,
                teamID: teamID,
                securityReviewEnabled: configStore.config?.isSecurityReviewEnabled ?? true
            )
        }
    }

    func dismissSecurityReview() {
        pendingSecurityReview = nil
        securityScanningInstallID = nil
    }

    /// Resolve release → age + optional OSV scan (+ one-step unpinned vuln fallback) → proceed or prompt.
    private func beginRenewWithSecurityGate(
        installs: [TrackedAppInstall],
        device: TrackedDevice,
        teamID: String,
        securityReviewEnabled: Bool
    ) async {
        guard !installs.isEmpty else { return }
        var queue = installs
        let reviewEnabled = securityReviewEnabled

        while !queue.isEmpty {
            let install = queue.removeFirst()
            securityScanningInstallID = install.id
            pendingSecurityReview = nil

            let outcome = await evaluateInstallForGate(
                install: install,
                reviewEnabled: reviewEnabled,
                isAutoRenew: false
            )
            securityScanningInstallID = nil

            switch outcome {
            case let .failed(message):
                renewRunner.surfacePreflightFailure(install: install, message: message)
                continue
            case let .skip(reason):
                // Manual path should not skip silently — surface as failure.
                renewRunner.surfacePreflightFailure(install: install, message: reason)
                continue
            case let .review(resolvedInstall, result):
                pendingSecurityReview = PendingSecurityReview(
                    install: install,
                    device: device,
                    teamID: teamID,
                    result: result,
                    resolvedInstall: resolvedInstall,
                    mode: queue.isEmpty ? .single : .batch(remaining: queue)
                )
                return
            case let .proceed(resolvedInstall, _):
                if queue.isEmpty {
                    renewRunner.renew(
                        install: resolvedInstall,
                        device: device,
                        teamID: teamID,
                        onSuccess: successCallback
                    )
                    return
                }

                // Collect consecutive clean installs into one renewAll, stop at first that needs review.
                var cleanBatch = [resolvedInstall]
                while !queue.isEmpty {
                    let next = queue.removeFirst()
                    securityScanningInstallID = next.id
                    let nextOutcome = await evaluateInstallForGate(
                        install: next,
                        reviewEnabled: reviewEnabled,
                        isAutoRenew: false
                    )
                    securityScanningInstallID = nil
                    switch nextOutcome {
                    case let .failed(message):
                        renewRunner.surfacePreflightFailure(install: next, message: message)
                    case let .skip(reason):
                        renewRunner.surfacePreflightFailure(install: next, message: reason)
                    case let .review(nextResolved, nextResult):
                        pendingSecurityReview = PendingSecurityReview(
                            install: next,
                            device: device,
                            teamID: teamID,
                            result: nextResult,
                            resolvedInstall: nextResolved,
                            mode: queue.isEmpty ? .single : .batch(remaining: queue)
                        )
                        renewRunner.renewAll(
                            installs: cleanBatch,
                            device: device,
                            teamID: teamID,
                            onSuccess: successCallback
                        )
                        return
                    case let .proceed(nextResolved, _):
                        cleanBatch.append(nextResolved)
                    }
                }

                renewRunner.renewAll(
                    installs: cleanBatch,
                    device: device,
                    teamID: teamID,
                    onSuccess: successCallback
                )
                return
            }
        }
        securityScanningInstallID = nil
    }

    private enum GateOutcome {
        case proceed(install: TrackedAppInstall, result: SecurityScanResult)
        case review(install: TrackedAppInstall, result: SecurityScanResult)
        case failed(message: String)
        case skip(reason: String)
    }

    /// Scans and selects a release. Unpinned: newest eligible, then at most one older eligible on elevated OSV.
    /// Pinned: no silent fallback.
    private func evaluateInstallForGate(
        install: TrackedAppInstall,
        reviewEnabled: Bool,
        isAutoRenew: Bool
    ) async -> GateOutcome {
        if install.isLocalIPA {
            let result: SecurityScanResult
            if reviewEnabled {
                result = await SecurityScan.evaluate(install: install, release: nil)
            } else {
                result = SecurityScanResult(
                    findings: [],
                    ageStatus: .notApplicable,
                    notes: ["Local IPA — security review disabled."],
                    release: nil,
                    scannedTag: nil,
                    lockfilesFound: []
                )
            }
            if reviewEnabled && result.needsManualDecision {
                return .review(install: install, result: result)
            }
            return .proceed(install: install, result: result)
        }

        guard GitHubSource.normalize(install.githubRepo) != nil else {
            return .failed(message: "No valid GitHub repository configured.")
        }

        let pinned = (install.selectedTag ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !pinned.isEmpty {
            return await evaluatePinnedInstall(
                install: install,
                pinnedTag: pinned,
                reviewEnabled: reviewEnabled,
                isAutoRenew: isAutoRenew
            )
        }

        return await evaluateUnpinnedInstall(
            install: install,
            reviewEnabled: reviewEnabled,
            isAutoRenew: isAutoRenew
        )
    }

    private func evaluatePinnedInstall(
        install: TrackedAppInstall,
        pinnedTag: String,
        reviewEnabled: Bool,
        isAutoRenew: Bool
    ) async -> GateOutcome {
        let release: ReleaseOption
        do {
            if let fetched = try await ConfigStore.fetchRelease(repo: install.githubRepo, tag: pinnedTag) {
                release = fetched
            } else {
                release = ReleaseOption(
                    tag: pinnedTag,
                    version: pinnedTag,
                    assetName: "",
                    sizeBytes: 0,
                    isCached: false,
                    publishedAt: nil
                )
            }
        } catch {
            return .failed(message: "Could not resolve release \(pinnedTag): \(error.localizedDescription)")
        }

        let result: SecurityScanResult
        if reviewEnabled {
            result = await SecurityScan.evaluate(install: install, release: release)
        } else {
            result = SecurityScanResult(
                findings: [],
                ageStatus: ReleaseAgePolicy.ageStatus(publishedAt: release.publishedAt),
                notes: ["OSS scan skipped — security review disabled in Settings."],
                release: release,
                scannedTag: release.tag,
                lockfilesFound: []
            )
        }

        if isAutoRenew {
            switch SecurityScan.autoRenewDecision(result: result, securityReviewEnabled: reviewEnabled) {
            case .proceed:
                return .proceed(install: install, result: result)
            case let .skip(reason):
                return .skip(reason: reason)
            }
        }

        if reviewEnabled && result.needsManualDecision {
            return .review(install: install, result: result)
        }
        return .proceed(install: install, result: result)
    }

    private func evaluateUnpinnedInstall(
        install: TrackedAppInstall,
        reviewEnabled: Bool,
        isAutoRenew: Bool
    ) async -> GateOutcome {
        let eligible: [ReleaseOption]
        do {
            eligible = try await ConfigStore.fetchEligibleReleases(repo: install.githubRepo)
        } catch {
            return .failed(message: "Could not resolve eligible releases: \(error.localizedDescription)")
        }
        guard let newest = eligible.first else {
            return .failed(
                message: "No GitHub release with an .ipa is at least \(ReleaseAgePolicy.minimumAgeDays) days old."
            )
        }

        // Review off: age floor only — no OSV, no vuln fallback.
        if !reviewEnabled {
            var resolved = install
            resolved.selectedTag = newest.tag
            let result = SecurityScanResult(
                findings: [],
                ageStatus: ReleaseAgePolicy.ageStatus(publishedAt: newest.publishedAt),
                notes: ["OSS scan skipped — security review disabled in Settings."],
                release: newest,
                scannedTag: newest.tag,
                lockfilesFound: []
            )
            if isAutoRenew {
                switch SecurityScan.autoRenewDecision(result: result, securityReviewEnabled: false) {
                case .proceed:
                    return .proceed(install: resolved, result: result)
                case let .skip(reason):
                    return .skip(reason: reason)
                }
            }
            return .proceed(install: resolved, result: result)
        }

        let newestScan = await SecurityScan.evaluate(install: install, release: newest)
        var prior: ReleaseOption?
        var priorScan: SecurityScanResult?
        // Hard limit: only the single next-older eligible (index 1), never walk further.
        if newestScan.hasElevatedFindings, eligible.count > SecurityScan.maxVulnFallbackSteps {
            let candidate = eligible[SecurityScan.maxVulnFallbackSteps]
            prior = candidate
            priorScan = await SecurityScan.evaluate(install: install, release: candidate)
        }

        let decision = SecurityScan.decideUnpinnedVulnFallback(
            newestEligible: newest,
            newestScan: newestScan,
            priorEligible: prior,
            priorScan: priorScan,
            isAutoRenew: isAutoRenew
        )

        switch decision {
        case let .use(release, result, _):
            var resolved = install
            resolved.selectedTag = release.tag
            return .proceed(install: resolved, result: result)
        case let .needsReview(release, result, _):
            var resolved = install
            resolved.selectedTag = release.tag
            return .review(install: resolved, result: result)
        case let .skip(reason):
            return .skip(reason: reason)
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
            // Prefer newest IPA release that meets the 14-day age floor.
            if let eligible = try? await ConfigStore.fetchLatestEligibleRelease(repo: repo) {
                latestByRepo[repo] = eligible
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
            guard install.isAutoUpdateEnabled else { return false }
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

            var approved: [TrackedAppInstall] = []
            for inst in dueForDevice {
                lastAutoRenewAttemptByInstall[inst.id] = now
                let outcome = await evaluateInstallForGate(
                    install: inst,
                    reviewEnabled: config.isSecurityReviewEnabled,
                    isAutoRenew: true
                )
                switch outcome {
                case let .proceed(resolved, _):
                    approved.append(resolved)
                case let .skip(reason):
                    notifyAutoRenewSkip(install: inst, reason: reason)
                case let .failed(message):
                    notifyAutoRenewSkip(install: inst, reason: message)
                case let .review(_, result):
                    // Auto-renew never shows UI; treat residual review as skip.
                    let reason: String
                    if result.hasElevatedFindings {
                        reason = "\(result.elevatedFindings.count) elevated OSV finding(s) after one-step fallback"
                    } else {
                        reason = result.notes.first ?? "Security review required"
                    }
                    notifyAutoRenewSkip(install: inst, reason: reason)
                }
            }

            guard !approved.isEmpty else { continue }
            renewRunner.renewAll(
                installs: approved,
                device: device,
                teamID: config.teamID,
                onSuccess: successCallback
            )
            break
        }
    }

    private func notifyAutoRenewSkip(install: TrackedAppInstall, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Auto-renew skipped · \(install.name)"
        content.body = reason
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "renewio.security.skip.\(install.id.uuidString).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
