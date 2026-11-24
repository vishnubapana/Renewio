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
struct PendingSecurityReview {
    enum Mode {
        case single
        case batch(remaining: [TrackedAppInstall])
    }

    let install: TrackedAppInstall
    let device: TrackedDevice
    let teamID: String
    let result: SecurityScanResult
    /// Install passed to RenewRunner (verified original IPA path + tag).
    let resolvedInstall: TrackedAppInstall
    let mode: Mode
    /// True while a scan is still running for this install card.
    var isScanning: Bool = false
}

@MainActor
final class AppModel: ObservableObject {
    let configStore = ConfigStore()
    let renewRunner = RenewRunner()
    let securityClient = SecurityClient()
    let approvalStore = ApprovalStore()

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
    /// Pending security metadata to persist after a successful resign/install.
    private var pendingSecurityByInstall: [UUID: (sha: String, reportID: String?, reportSha: String?, assessment: String?)] = [:]
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
        let eligibility = pending.result.eligibility
        pendingSecurityReview = nil
        securityScanningInstallID = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let eligibility,
               let reportID = eligibility.reportID,
               eligibility.installEligibility == .allowWithApproval {
                do {
                    try await self.securityClient.recordApproval(
                        ipaSha256: eligibility.ipaSha256,
                        reportID: reportID,
                        findingIDs: eligibility.findings.map(\.id)
                    )
                    self.approvalStore.save(
                        LocalApprovalSnapshot(
                            artifactSha256: eligibility.ipaSha256,
                            reportID: reportID,
                            reportSha256: eligibility.reportSha256 ?? "",
                            findingIDs: eligibility.findings.map(\.id),
                            approvedAt: Date(),
                            expiresAt: Date().addingTimeInterval(30 * 24 * 60 * 60),
                            assessmentStatus: eligibility.assessmentStatus?.rawValue ?? "review_required"
                        )
                    )
                } catch {
                    self.renewRunner.surfacePreflightFailure(
                        install: install,
                        message: "Could not record approval: \(error.localizedDescription)"
                    )
                    return
                }
            }

            // Re-verify hash before resign.
            if let path = install.localIPAPath,
               let expected = self.pendingSecurityByInstall[install.id]?.sha
                ?? eligibility?.ipaSha256 {
                do {
                    let ok = try ArtifactHasher.matches(fileAt: URL(fileURLWithPath: path), expectedHex: expected)
                    if !ok {
                        self.renewRunner.surfacePreflightFailure(
                            install: install,
                            message: SecurityClientError.hashMismatch.localizedDescription
                        )
                        return
                    }
                } catch {
                    self.renewRunner.surfacePreflightFailure(
                        install: install,
                        message: error.localizedDescription
                    )
                    return
                }
            }

            self.renewRunner.renew(
                install: install,
                device: device,
                teamID: teamID,
                onSuccess: self.successCallback
            )

            guard !remaining.isEmpty else { return }
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

    /// Download original IPA → hash → shared security report → proceed / review / deny.
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

    /// Shared security gate: download → hash → request/poll report → eligibility.
    private func evaluateInstallForGate(
        install: TrackedAppInstall,
        reviewEnabled: Bool,
        isAutoRenew: Bool,
        preferSameVersion: Bool = false
    ) async -> GateOutcome {
        // Same-version renew: keep current tag when possible (Phase 4).
        let preferTag: String?
        if preferSameVersion || isAutoRenew {
            preferTag = install.selectedTag ?? install.lastInstalledTag
        } else if let pinned = install.selectedTag?.trimmingCharacters(in: .whitespacesAndNewlines), !pinned.isEmpty {
            preferTag = pinned
        } else {
            preferTag = nil
        }

        let downloaded: DownloadedIPA
        do {
            if let preferTag, !preferTag.isEmpty, !install.isLocalIPA {
                downloaded = try await IPADownloader.downloadTag(install: install, tag: preferTag)
            } else {
                downloaded = try await IPADownloader.downloadForSecurityGate(install: install, preferTag: preferTag)
            }
        } catch {
            return .failed(message: error.localizedDescription)
        }

        var resolved = install
        resolved.selectedTag = downloaded.tag
        // Force resign from the exact assessed original IPA (not a re-fetch).
        resolved.localIPAPath = downloaded.localURL.path

        if !reviewEnabled {
            let result = SecurityScanResult(
                findings: [],
                ageStatus: install.isLocalIPA
                    ? .notApplicable
                    : ReleaseAgePolicy.ageStatus(publishedAt: downloaded.publishedAt),
                notes: ["Shared security scan skipped — Require security review is off."],
                release: nil,
                scannedTag: downloaded.tag,
                lockfilesFound: [],
                eligibility: nil
            )
            if isAutoRenew, result.ageStatus.blocksAutomaticInstall {
                return .skip(reason: result.ageStatus.summary)
            }
            pendingSecurityByInstall[install.id] = (downloaded.sha256, nil, nil, "skipped_review_disabled")
            return .proceed(install: resolved, result: result)
        }

        // Offline grace for same-artifact renew when backend unreachable.
        if isAutoRenew || preferSameVersion,
           let sha = install.lastIpaSha256?.lowercased(),
           sha == downloaded.sha256.lowercased(),
           let assessmentRaw = install.lastAssessmentStatus,
           let assessment = AssessmentStatus(rawValue: assessmentRaw),
           let checkedAt = TrackedAppInstall.parseISO8601(install.lastSecurityCheckedAt),
           OfflineRenewPolicy.allowsSameArtifactRenew(localAssessment: assessment, localCheckedAt: checkedAt) {
            if assessment == .checksPassed || approvalStore.approval(forSha: sha) != nil {
                let elig = EligibilityResult(
                    scanStatus: .succeeded,
                    assessmentStatus: assessment,
                    installEligibility: .allow,
                    reportID: install.lastReportId,
                    reportSha256: install.lastReportSha256,
                    ipaSha256: sha,
                    limitations: ["offline_grace"],
                    findingsSummary: [:],
                    findings: [],
                    reasons: ["offline_grace"],
                    reportJSON: nil,
                    userApprovalState: approvalStore.approval(forSha: sha) != nil ? "valid" : nil,
                    offlineGrace: true
                )
                pendingSecurityByInstall[install.id] = (sha, install.lastReportId, install.lastReportSha256, assessmentRaw)
                return .proceed(install: resolved, result: .fromEligibility(elig, publishedAt: downloaded.publishedAt))
            }
        }

        guard SecurityConfig.isConfigured else {
            return .failed(message: SecurityClientError.notConfigured.localizedDescription)
        }
        guard securityClient.isSignedIn else {
            return .failed(message: SecurityClientError.notSignedIn.localizedDescription)
        }

        do {
            if !install.isLocalIPA {
                let pub: String?
                if let d = downloaded.publishedAt {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime]
                    pub = f.string(from: d)
                } else {
                    pub = nil
                }
                let req = ScanRequestBody(
                    ipaSha256: downloaded.sha256,
                    githubOwner: downloaded.owner,
                    githubRepo: downloaded.repo,
                    releaseTag: downloaded.tag,
                    sourceCommit: nil,
                    assetId: downloaded.assetID,
                    assetName: downloaded.assetName,
                    publishedAt: pub,
                    policyVersion: SecurityConfig.policyVersion
                )
                let scanResp = try await securityClient.requestScan(req)
                if let status = scanResp.scanStatus ?? scanResp.status,
                   status == "queued" || status == "scanning" {
                    _ = try await securityClient.pollUntilComplete(
                        jobID: scanResp.jobId,
                        ipaSha256: downloaded.sha256
                    )
                }
            }

            let eligibility = try await securityClient.checkEligibility(
                ipaSha256: downloaded.sha256,
                isAutoRenew: isAutoRenew,
                localReportSha256: install.lastReportSha256,
                localAssessmentStatus: install.lastAssessmentStatus,
                localCheckedAt: TrackedAppInstall.parseISO8601(install.lastSecurityCheckedAt)
            )

            // Fail closed on incomplete / failed / denied.
            let result = SecurityScanResult.fromEligibility(eligibility, publishedAt: downloaded.publishedAt)
            pendingSecurityByInstall[install.id] = (
                downloaded.sha256,
                eligibility.reportID,
                eligibility.reportSha256,
                eligibility.assessmentStatus?.rawValue
            )

            switch eligibility.installEligibility {
            case .allow:
                // Final hash check before resign.
                guard try ArtifactHasher.matches(fileAt: downloaded.localURL, expectedHex: downloaded.sha256) else {
                    return .failed(message: SecurityClientError.hashMismatch.localizedDescription)
                }
                return .proceed(install: resolved, result: result)
            case .allowWithApproval:
                if isAutoRenew {
                    return .skip(reason: "Review required — auto-renew will not proceed without prior approval.")
                }
                return .review(install: resolved, result: result)
            case .deny:
                let reason = eligibility.reasons.joined(separator: "; ")
                if isAutoRenew {
                    return .skip(reason: reason.isEmpty ? "Security policy denied install." : reason)
                }
                return .failed(message: reason.isEmpty ? "Security policy denied install." : reason)
            case .pending:
                if isAutoRenew {
                    return .skip(reason: "Security scan still pending.")
                }
                return .failed(message: "Security scan did not complete.")
            }
        } catch {
            // Backend outage: same-artifact renew may use offline grace; upgrades fail closed.
            if (isAutoRenew || preferSameVersion),
               let sha = install.lastIpaSha256?.lowercased(),
               sha == downloaded.sha256.lowercased(),
               let assessmentRaw = install.lastAssessmentStatus,
               let assessment = AssessmentStatus(rawValue: assessmentRaw),
               let checkedAt = TrackedAppInstall.parseISO8601(install.lastSecurityCheckedAt),
               OfflineRenewPolicy.allowsSameArtifactRenew(localAssessment: assessment, localCheckedAt: checkedAt),
               (assessment == .checksPassed || approvalStore.approval(forSha: sha) != nil) {
                let elig = EligibilityResult(
                    scanStatus: .succeeded,
                    assessmentStatus: assessment,
                    installEligibility: .allow,
                    reportID: install.lastReportId,
                    reportSha256: install.lastReportSha256,
                    ipaSha256: sha,
                    limitations: ["offline_grace_backend_error"],
                    findingsSummary: [:],
                    findings: [],
                    reasons: ["offline_grace", error.localizedDescription],
                    reportJSON: nil,
                    userApprovalState: nil,
                    offlineGrace: true
                )
                pendingSecurityByInstall[install.id] = (sha, install.lastReportId, install.lastReportSha256, assessmentRaw)
                return .proceed(install: resolved, result: .fromEligibility(elig, publishedAt: downloaded.publishedAt))
            }
            return .failed(message: error.localizedDescription)
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
        if let sec = pendingSecurityByInstall.removeValue(forKey: installID),
           let idx = config.installs.firstIndex(where: { $0.id == installID }) {
            config.installs[idx].lastIpaSha256 = sec.sha
            config.installs[idx].lastReportId = sec.reportID
            config.installs[idx].lastReportSha256 = sec.reportSha
            config.installs[idx].lastAssessmentStatus = sec.assessment
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            config.installs[idx].lastSecurityCheckedAt = f.string(from: Date())
            // Do not persist the temporary localIPAPath used for verified resign of GitHub apps.
            if !(config.installs[idx].githubRepo).isEmpty {
                // Keep original localIPAPath only when install was truly local.
            }
        }
        try? configStore.save(config)
        ExpiryNotifier.reschedule(for: config)
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
                    let reason = result.notes.first
                        ?? result.eligibility?.reasons.first
                        ?? "Security review required"
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
