import Foundation
import XCTest

final class RenewioTests: XCTestCase {

    // MARK: - GitHubSource.normalize

    func testGitHubSourceNormalize() {
        XCTAssertEqual(GitHubSource.normalize("bobsupra/NuvioTVOS"), "bobsupra/NuvioTVOS")
        XCTAssertEqual(GitHubSource.normalize("https://github.com/bobsupra/NuvioTVOS.git"), "bobsupra/NuvioTVOS")
        XCTAssertEqual(GitHubSource.normalize("https://www.github.com/bobsupra/NuvioTVOS/releases/tag/v1.0.0"), "bobsupra/NuvioTVOS")
        XCTAssertEqual(GitHubSource.normalize("git@github.com:bobsupra/NuvioTVOS.git"), "bobsupra/NuvioTVOS")
        XCTAssertEqual(GitHubSource.normalize("  github.com/owner/repo/  "), "owner/repo")
        XCTAssertNil(GitHubSource.normalize(""))
        XCTAssertNil(GitHubSource.normalize("just-one-segment"))
        XCTAssertNil(GitHubSource.normalize("https://github.com/onlyowner"))
        XCTAssertNil(GitHubSource.normalize("owner with space/repo"))
    }

    // MARK: - RefreshCountdownState

    func testRefreshCountdownStateNilAndExpired() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let notInstalled = RefreshCountdownState.make(expiresAt: nil, now: now)
        XCTAssertEqual(notInstalled.statusLabel, "Not installed")
        XCTAssertEqual(notInstalled.countdownText, "—")
        XCTAssertFalse(notInstalled.showProgressBar)

        let expired = RefreshCountdownState.make(expiresAt: now.addingTimeInterval(-60), now: now)
        XCTAssertEqual(expired.statusLabel, "Expired")
        XCTAssertEqual(expired.countdownText, "0h 0m")
        XCTAssertEqual(expired.progress, 0)
        XCTAssertTrue(expired.showProgressBar)
    }

    func testRefreshCountdownStateRenewSoonAndActive() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let soon = RefreshCountdownState.make(
            expiresAt: now.addingTimeInterval(24 * 3600),
            signingDuration: 7 * 24 * 3600,
            now: now
        )
        XCTAssertEqual(soon.statusLabel, "Renew soon")
        XCTAssertEqual(soon.countdownText, "1d 0h")
        XCTAssertEqual(soon.progress, 1.0 / 7.0, accuracy: 0.01)

        // Paid 365-day profile with 182.5 days left
        let paidDuration: TimeInterval = 365 * 24 * 3600
        let paid = RefreshCountdownState.make(
            expiresAt: now.addingTimeInterval(paidDuration / 2),
            signingDuration: paidDuration,
            now: now
        )
        XCTAssertEqual(paid.statusLabel, "Active")
        XCTAssertEqual(paid.progress, 0.5, accuracy: 0.01)
    }

    // MARK: - TrackedAppInstall real profile expiry

    func testTrackedAppInstallRealExpiryOverridesSevenDayFallback() {
        let installedISO = "2026-11-01T00:00:00Z"
        let expiresISO = "2027-11-01T00:00:00Z"

        let withRealExpiry = TrackedAppInstall(
            deviceID: "dev-1",
            name: "PaidApp",
            bundleID: "com.example.paid",
            lastInstalledAt: installedISO,
            lastExpiresAt: expiresISO
        )
        XCTAssertEqual(withRealExpiry.expiresAt, TrackedAppInstall.parseISO8601(expiresISO))
        XCTAssertEqual(withRealExpiry.signingDuration, 365 * 24 * 3600, accuracy: 60)

        let fallback = TrackedAppInstall(
            deviceID: "dev-1",
            name: "FreeApp",
            bundleID: "com.example.free",
            lastInstalledAt: installedISO,
            lastExpiresAt: nil
        )
        let expectedFallback = TrackedAppInstall.parseISO8601(installedISO)?.addingTimeInterval(7 * 24 * 3600)
        XCTAssertEqual(fallback.expiresAt, expectedFallback)
        XCTAssertEqual(fallback.signingDuration, 7 * 24 * 3600)
    }

    // MARK: - Config migration & mutation

    @MainActor
    func testLegacyV1Migration() {
        let legacy = LegacyRenewioConfig(
            teamID: "52L6R8UQZU",
            bundleID: "com.example.nuvio",
            deviceID: "UDID-1234",
            deviceName: "Living Room",
            lastInstalledVersion: "3.5.2",
            lastInstalledTag: "v3.5.2",
            lastInstalledAt: "2026-11-20T12:00:00Z",
            lastAssetName: "NuvioTV-3.5.2.ipa"
        )

        let migrated = ConfigStore.migrateLegacy(legacy)
        XCTAssertNotNil(migrated)
        XCTAssertEqual(migrated?.schemaVersion, RenewioConfig.currentSchemaVersion)
        XCTAssertEqual(migrated?.teamID, "52L6R8UQZU")
        XCTAssertEqual(migrated?.devices.count, 1)
        XCTAssertEqual(migrated?.devices.first?.name, "Living Room")
        XCTAssertEqual(migrated?.devices.first?.platform, .tvos)
        XCTAssertEqual(migrated?.installs.count, 1)
        XCTAssertEqual(migrated?.installs.first?.lastInstalledVersion, "3.5.2")
    }

    func testRemoveDeviceCascadesToInstalls() {
        let d1 = TrackedDevice(id: "d1", name: "Apple TV", platform: .tvos)
        let d2 = TrackedDevice(id: "d2", name: "iPhone", platform: .ios)
        let i1 = TrackedAppInstall(deviceID: "d1", name: "TV App", bundleID: "com.a.tv")
        let i2 = TrackedAppInstall(deviceID: "d2", name: "iOS App", bundleID: "com.a.ios")
        var config = RenewioConfig(teamID: "TEAM123456", devices: [d1, d2], installs: [i1, i2], selectedDeviceID: "d1")

        config.removeDevice("d1")
        XCTAssertEqual(config.devices, [d2])
        XCTAssertEqual(config.installs, [i2])
        XCTAssertEqual(config.selectedDeviceID, "d2")
    }

    func testMarkInstallSuccessStoresRealExpiry() {
        let install = TrackedAppInstall(deviceID: "d1", name: "App", bundleID: "com.a.app")
        var config = RenewioConfig(teamID: "TEAM123456", devices: [], installs: [install])

        config.markInstallSuccess(
            installID: install.id,
            version: "2.1.0",
            tag: "v2.1.0",
            assetName: "App-2.1.0.ipa",
            expiresAt: "2026-11-28T10:00:00Z"
        )
        XCTAssertEqual(config.installs.first?.lastInstalledVersion, "2.1.0")
        XCTAssertEqual(config.installs.first?.lastExpiresAt, "2026-11-28T10:00:00Z")
    }

    // MARK: - Version comparison

    @MainActor
    func testVersionComparison() {
        XCTAssertTrue(AppModel.isNewerVersion("3.6.0", than: "3.5.2"))
        XCTAssertTrue(AppModel.isNewerVersion("v3.10.0", than: "v3.9.9"))
        XCTAssertFalse(AppModel.isNewerVersion("3.5.2", than: "v3.5.2"))
        XCTAssertFalse(AppModel.isNewerVersion("3.4.0", than: "3.5.2"))
    }

    // MARK: - DeviceDiscovery.parseDevices

    func testParseDevicesFiltersAndDetectsPlatforms() throws {
        let json = """
        {
          "result": {
            "devices": [
              {
                "identifier": "core-tv",
                "hardwareProperties": { "platform": "tvOS", "deviceType": "appleTV", "udid": "UDID-TV" },
                "deviceProperties": { "name": "Living Room" },
                "connectionProperties": { "tunnelState": "connected" }
              },
              {
                "identifier": "core-iphone",
                "hardwareProperties": { "platform": "iOS", "deviceType": "iPhone", "udid": "UDID-IPHONE" },
                "deviceProperties": { "name": "My iPhone" },
                "connectionProperties": { "pairingState": "paired" }
              },
              {
                "identifier": "core-ipad",
                "hardwareProperties": { "platform": "iOS", "deviceType": "iPad", "udid": "UDID-IPAD" },
                "deviceProperties": { "name": "iPad Pro" },
                "connectionProperties": { "tunnelState": "disconnected" }
              },
              {
                "identifier": "core-mac",
                "hardwareProperties": { "platform": "macOS", "deviceType": "mac", "udid": "UDID-MAC" },
                "deviceProperties": { "name": "MacBook Pro" }
              }
            ]
          }
        }
        """

        let devices = try DeviceDiscovery.parseDevices(jsonText: json)
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices.map(\.name), ["iPad Pro", "Living Room", "My iPhone"])
        XCTAssertEqual(devices.first(where: { $0.udid == "UDID-TV" })?.platform, .tvos)
        XCTAssertEqual(devices.first(where: { $0.udid == "UDID-IPHONE" })?.platform, .ios)
        XCTAssertEqual(devices.first(where: { $0.udid == "UDID-IPAD" })?.platform, .ipados)
    }

    // MARK: - Release age eligibility

    func testReleaseAgeEligibilityExactFourteenDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let published = now.addingTimeInterval(-14 * 24 * 60 * 60)
        let status = ReleaseAgePolicy.ageStatus(publishedAt: published, now: now)
        XCTAssertEqual(status, .eligible(ageDays: 14))
        XCTAssertTrue(ReleaseAgePolicy.isEligible(publishedAt: published, now: now))
    }

    func testReleaseAgeEligibilityYoungerThanFourteenDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let published = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let status = ReleaseAgePolicy.ageStatus(publishedAt: published, now: now)
        XCTAssertEqual(status, .tooNew(ageDays: 3, requiredDays: 14))
        XCTAssertFalse(ReleaseAgePolicy.isEligible(publishedAt: published, now: now))
        XCTAssertTrue(status.blocksAutomaticInstall)
    }

    func testReleaseAgeEligibilityOlderThanFourteenDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let published = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let status = ReleaseAgePolicy.ageStatus(publishedAt: published, now: now)
        XCTAssertEqual(status, .eligible(ageDays: 30))
        XCTAssertTrue(ReleaseAgePolicy.isEligible(publishedAt: published, now: now))
    }

    func testReleaseAgeEligibilityMissingDate() {
        let status = ReleaseAgePolicy.ageStatus(publishedAt: nil)
        XCTAssertEqual(status, .unknown)
        XCTAssertFalse(ReleaseAgePolicy.isEligible(publishedAt: nil))
        XCTAssertTrue(status.blocksAutomaticInstall)
    }

    func testLatestEligibleSkipsTooNewReleases() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tooNew = ReleaseOption(
            tag: "v9.9.9",
            version: "9.9.9",
            assetName: "App-9.9.9-unsigned.ipa",
            sizeBytes: 100,
            isCached: false,
            publishedAt: now.addingTimeInterval(-2 * 24 * 60 * 60)
        )
        let eligible = ReleaseOption(
            tag: "v9.8.0",
            version: "9.8.0",
            assetName: "App-9.8.0-unsigned.ipa",
            sizeBytes: 100,
            isCached: false,
            publishedAt: now.addingTimeInterval(-20 * 24 * 60 * 60)
        )
        let older = ReleaseOption(
            tag: "v9.7.0",
            version: "9.7.0",
            assetName: "App-9.7.0-unsigned.ipa",
            sizeBytes: 100,
            isCached: false,
            publishedAt: now.addingTimeInterval(-40 * 24 * 60 * 60)
        )
        let releases = [tooNew, eligible, older]
        let latestEligible = releases.first {
            ReleaseAgePolicy.isEligible(publishedAt: $0.publishedAt, now: now)
        }
        XCTAssertEqual(latestEligible?.tag, "v9.8.0")
        XCTAssertFalse(ReleaseAgePolicy.isEligible(publishedAt: tooNew.publishedAt, now: now))
        XCTAssertTrue(ReleaseAgePolicy.isEligible(publishedAt: eligible.publishedAt, now: now))
    }

    // MARK: - Shared security eligibility / hashing

    func testArtifactHasherRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("renewio-hash-test.bin")
        let payload = Data("renewio-security-hash".utf8)
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let hex = try ArtifactHasher.sha256Hex(ofFileAt: url)
        XCTAssertEqual(hex.count, 64)
        XCTAssertTrue(try ArtifactHasher.matches(fileAt: url, expectedHex: hex))
        XCTAssertFalse(try ArtifactHasher.matches(fileAt: url, expectedHex: String(repeating: "0", count: 64)))
    }

    func testEligibilityAllowsAutoOnlyWhenChecksPassed() {
        let passed = EligibilityResult(
            scanStatus: .succeeded,
            assessmentStatus: .checksPassed,
            installEligibility: .allow,
            reportID: "r1",
            reportSha256: nil,
            ipaSha256: String(repeating: "a", count: 64),
            limitations: [],
            findingsSummary: [:],
            findings: [],
            reasons: ["checks_passed"],
            reportJSON: nil,
            userApprovalState: nil,
            offlineGrace: false
        )
        XCTAssertTrue(passed.allowsAutoRenew)
        XCTAssertFalse(passed.needsManualDecision)

        let review = EligibilityResult(
            scanStatus: .succeeded,
            assessmentStatus: .reviewRequired,
            installEligibility: .allowWithApproval,
            reportID: "r2",
            reportSha256: nil,
            ipaSha256: String(repeating: "b", count: 64),
            limitations: [],
            findingsSummary: ["medium": 1],
            findings: [
                RemoteFinding(
                    id: "f1",
                    scanner: "osv_scanner",
                    severity: "medium",
                    title: "dep issue",
                    summary: "test",
                    overrideEligible: true
                )
            ],
            reasons: ["review_required"],
            reportJSON: nil,
            userApprovalState: nil,
            offlineGrace: false
        )
        XCTAssertFalse(review.allowsAutoRenew)
        XCTAssertTrue(review.needsManualDecision)

        let blocked = EligibilityResult(
            scanStatus: .succeeded,
            assessmentStatus: .blocked,
            installEligibility: .deny,
            reportID: "r3",
            reportSha256: nil,
            ipaSha256: String(repeating: "c", count: 64),
            limitations: [],
            findingsSummary: [:],
            findings: [],
            reasons: ["blocked"],
            reportJSON: nil,
            userApprovalState: nil,
            offlineGrace: false
        )
        XCTAssertFalse(blocked.allowsAutoRenew)
        let mapped = SecurityScanResult.fromEligibility(blocked, publishedAt: nil)
        XCTAssertFalse(mapped.allowsProceedAnyway)
    }

    func testOfflineRenewPolicyGraceWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(
            OfflineRenewPolicy.allowsSameArtifactRenew(
                localAssessment: .checksPassed,
                localCheckedAt: now.addingTimeInterval(-24 * 3600),
                now: now
            )
        )
        XCTAssertFalse(
            OfflineRenewPolicy.allowsSameArtifactRenew(
                localAssessment: .checksPassed,
                localCheckedAt: now.addingTimeInterval(-100 * 3600),
                now: now
            )
        )
        XCTAssertFalse(
            OfflineRenewPolicy.allowsSameArtifactRenew(
                localAssessment: .blocked,
                localCheckedAt: now.addingTimeInterval(-1 * 3600),
                now: now
            )
        )
        XCTAssertEqual(OfflineRenewPolicy.graceHours, 72)
    }

    func testIncompleteScanDoesNotAllowProceed() {
        let incomplete = EligibilityResult(
            scanStatus: .failed,
            assessmentStatus: .incomplete,
            installEligibility: .deny,
            reportID: nil,
            reportSha256: nil,
            ipaSha256: String(repeating: "d", count: 64),
            limitations: ["scan_failed"],
            findingsSummary: [:],
            findings: [],
            reasons: ["scan_failed"],
            reportJSON: nil,
            userApprovalState: nil,
            offlineGrace: false
        )
        let result = SecurityScanResult.fromEligibility(incomplete, publishedAt: Date())
        XCTAssertFalse(result.allowsAutoRenew)
        XCTAssertFalse(result.allowsProceedAnyway)
        XCTAssertEqual(result.eligibility?.installEligibility, .deny)
    }

    func testConfigSecurityReviewDefaultsOn() {
        let config = RenewioConfig(teamID: "TEAM123456")
        XCTAssertTrue(config.isSecurityReviewEnabled)
        var disabled = config
        disabled.securityReviewEnabled = false
        XCTAssertFalse(disabled.isSecurityReviewEnabled)
    }

    // MARK: - Per-app auto-update

    func testAutoUpdateEnabledDefaultsTrueWhenMissing() throws {
        let json = """
        {
          "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "deviceID": "dev-1",
          "name": "App",
          "githubRepo": "owner/repo",
          "bundleID": "com.example.app"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TrackedAppInstall.self, from: json)
        XCTAssertNil(decoded.autoUpdateEnabled)
        XCTAssertTrue(decoded.isAutoUpdateEnabled)
    }

    func testAutoUpdateEnabledFalseRoundTrip() throws {
        var install = TrackedAppInstall(
            deviceID: "dev-1",
            name: "App",
            bundleID: "com.example.app",
            autoUpdateEnabled: false
        )
        XCTAssertFalse(install.isAutoUpdateEnabled)
        let data = try JSONEncoder().encode(install)
        let decoded = try JSONDecoder().decode(TrackedAppInstall.self, from: data)
        XCTAssertEqual(decoded.autoUpdateEnabled, false)
        XCTAssertFalse(decoded.isAutoUpdateEnabled)

        install.autoUpdateEnabled = true
        XCTAssertTrue(install.isAutoUpdateEnabled)
    }

    func testAutoRenewFilterRespectsPerAppOff() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expiresSoon = formatter.string(from: now.addingTimeInterval(12 * 3600))

        let enabled = TrackedAppInstall(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            deviceID: "d1",
            name: "On",
            bundleID: "com.on",
            lastInstalledAt: formatter.string(from: now.addingTimeInterval(-6 * 24 * 3600)),
            lastExpiresAt: expiresSoon,
            autoUpdateEnabled: true
        )
        let disabled = TrackedAppInstall(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            deviceID: "d1",
            name: "Off",
            bundleID: "com.off",
            lastInstalledAt: formatter.string(from: now.addingTimeInterval(-6 * 24 * 3600)),
            lastExpiresAt: expiresSoon,
            autoUpdateEnabled: false
        )
        let missingField = TrackedAppInstall(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            deviceID: "d1",
            name: "Default",
            bundleID: "com.default",
            lastInstalledAt: formatter.string(from: now.addingTimeInterval(-6 * 24 * 3600)),
            lastExpiresAt: expiresSoon,
            autoUpdateEnabled: nil
        )

        let threshold: TimeInterval = 24 * 60 * 60
        let due = [enabled, disabled, missingField].filter { install in
            guard install.isAutoUpdateEnabled else { return false }
            guard let expiresAt = install.expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) <= threshold
        }
        XCTAssertEqual(Set(due.map(\.id)), Set([enabled.id, missingField.id]))
        XCTAssertFalse(due.contains(where: { $0.id == disabled.id }))
    }

    // MARK: - IPA cache prune

    func testPruneIPACacheKeepsTwoNewestPerFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("renewio-prune-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("owner__App", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let older = repo.appendingPathComponent("old.ipa")
        let mid = repo.appendingPathComponent("mid.ipa")
        let newer = repo.appendingPathComponent("new.ipa")
        try Data("a".utf8).write(to: older)
        try Data("b".utf8).write(to: mid)
        try Data("c".utf8).write(to: newer)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: older.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: mid.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: newer.path)

        let deleted = try ConfigStore.pruneIPACache(keepPerRepo: 2, root: root)
        XCTAssertEqual(deleted, 1)
        XCTAssertFalse(fm.fileExists(atPath: older.path))
        XCTAssertTrue(fm.fileExists(atPath: mid.path))
        XCTAssertTrue(fm.fileExists(atPath: newer.path))
    }

    // MARK: - Auth error mapping

    func testAuthErrorMessageMapsInvalidCredentials() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "error_code": "invalid_credentials",
            "msg": "Invalid login credentials",
        ])
        let message = SecurityClient.authErrorMessage(from: data, fallback: "fallback")
        XCTAssertTrue(message.contains("Invalid email or password"))
    }

    func testAuthErrorMessagePrefersMsgWhenNoSpecialCode() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "error_code": "some_other_error",
            "msg": "Something went wrong upstream",
        ])
        let message = SecurityClient.authErrorMessage(from: data, fallback: "fallback")
        XCTAssertEqual(message, "Something went wrong upstream")
    }

    func testAuthErrorMessageEmailNotConfirmed() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "error_code": "email_not_confirmed",
            "msg": "Email not confirmed",
        ])
        let message = SecurityClient.authErrorMessage(from: data, fallback: "fallback")
        XCTAssertTrue(message.contains("Confirm email"))
    }

    // MARK: - Work scratch cleanup

    func testClearWorkScratchRemovesBulkyDirs() throws {
        let fm = FileManager.default
        let extract = ConfigStore.workDirectoryURL.appendingPathComponent("PayloadExtract", isDirectory: true)
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)
        let marker = extract.appendingPathComponent("marker.bin")
        try Data(repeating: 1, count: 2048).write(to: marker)
        XCTAssertGreaterThan(ConfigStore.workScratchSizeBytes(), 0)
        let freed = try ConfigStore.clearWorkScratch()
        XCTAssertGreaterThanOrEqual(freed, 2048)
        XCTAssertFalse(fm.fileExists(atPath: extract.path))
        XCTAssertEqual(ConfigStore.workScratchSizeBytes(), 0)
    }

}
