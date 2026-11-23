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
        XCTAssertTrue(status.isHardBlock)
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
        XCTAssertTrue(status.isHardBlock)
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
        XCTAssertFalse(tooNew.isAgeEligible)
        XCTAssertTrue(eligible.isAgeEligible)
    }

    // MARK: - Lockfile parse smoke tests

    func testParsePackageResolvedFixture() {
        let fixture = """
        {
          "pins" : [
            {
              "identity" : "alamofire",
              "kind" : "remoteSourceControl",
              "location" : "https://github.com/Alamofire/Alamofire.git",
              "state" : { "revision" : "abc", "version" : "5.6.4" }
            }
          ],
          "version" : 2
        }
        """
        let packages = SecurityScan.parsePackageResolved(fixture)
        XCTAssertEqual(packages.count, 1)
        XCTAssertEqual(packages.first?.name, "alamofire")
        XCTAssertEqual(packages.first?.version, "5.6.4")
        XCTAssertEqual(packages.first?.ecosystem, "SwiftURL")
    }

    func testParsePackageLockFixture() {
        let fixture = """
        {
          "packages": {
            "": { "name": "app", "version": "1.0.0" },
            "node_modules/lodash": { "version": "4.17.21" },
            "node_modules/@scope/pkg": { "version": "1.2.3" }
          }
        }
        """
        let packages = SecurityScan.parsePackageLock(fixture)
        XCTAssertTrue(packages.contains(where: { $0.name == "lodash" && $0.version == "4.17.21" }))
        XCTAssertTrue(packages.contains(where: { $0.name.contains("scope") && $0.version == "1.2.3" }))
        XCTAssertTrue(packages.allSatisfy { $0.ecosystem == "npm" })
    }

    func testParseCargoLockFixture() {
        let fixture = """
        [[package]]
        name = "serde"
        version = "1.0.152"
        source = "registry+https://github.com/rust-lang/crates.io-index"

        [[package]]
        name = "my-bin"
        version = "0.1.0"
        """
        let packages = SecurityScan.parseCargoLock(fixture)
        XCTAssertEqual(packages.count, 2)
        XCTAssertEqual(packages.first?.name, "serde")
        XCTAssertEqual(packages.first?.version, "1.0.152")
        XCTAssertEqual(packages.first?.ecosystem, "crates.io")
    }

    func testParseGoSumFixture() {
        let fixture = """
        github.com/pkg/errors v0.9.1 h1:abc
        github.com/pkg/errors v0.9.1/go.mod h1:def
        golang.org/x/sys v0.1.0 h1:xyz
        """
        let packages = SecurityScan.parseGoSum(fixture)
        XCTAssertTrue(packages.contains(where: {
            $0.name == "github.com/pkg/errors" && $0.version == "v0.9.1" && $0.ecosystem == "Go"
        }))
        // go.mod line should dedupe against the hash line for same module/version.
        XCTAssertEqual(
            packages.filter { $0.name == "github.com/pkg/errors" && $0.version == "v0.9.1" }.count,
            1
        )
    }

    func testParsePodfileLockFixture() {
        let fixture = """
        PODS:
          - Alamofire (5.6.4)
          - Something/Sub (1.0.0):
            - Alamofire

        DEPENDENCIES:
          - Alamofire
        """
        let packages = SecurityScan.parsePodfileLock(fixture)
        XCTAssertTrue(packages.contains(where: { $0.name == "Alamofire" && $0.version == "5.6.4" }))
        XCTAssertTrue(packages.contains(where: { $0.name == "Something" && $0.version == "1.0.0" }))
    }

    // MARK: - Auto-renew security decision matrix

    func testAutoRenewDecisionMatrix() {
        let cleanEligible = SecurityScanResult(
            findings: [],
            ageStatus: .eligible(ageDays: 20),
            notes: [],
            release: nil,
            scannedTag: "v1.0.0",
            lockfilesFound: ["Package.resolved"]
        )
        XCTAssertEqual(
            SecurityScan.autoRenewDecision(result: cleanEligible, securityReviewEnabled: true),
            .proceed
        )

        let tooNew = SecurityScanResult(
            findings: [],
            ageStatus: .tooNew(ageDays: 2, requiredDays: 14),
            notes: [],
            release: nil,
            scannedTag: "v2.0.0",
            lockfilesFound: []
        )
        if case let .skip(reason) = SecurityScan.autoRenewDecision(result: tooNew, securityReviewEnabled: true) {
            XCTAssertTrue(reason.contains("2d"))
        } else {
            XCTFail("Expected skip for too-new release")
        }

        let elevated = SecurityScanResult(
            findings: [
                SecurityFinding(
                    id: "GHSA-1",
                    packageName: "lodash",
                    packageVersion: "4.17.20",
                    ecosystem: "npm",
                    severity: .high,
                    summary: "Prototype pollution",
                    advisoryID: "GHSA-1"
                )
            ],
            ageStatus: .eligible(ageDays: 30),
            notes: [],
            release: nil,
            scannedTag: "v1.1.0",
            lockfilesFound: ["package-lock.json"]
        )
        if case let .skip(reason) = SecurityScan.autoRenewDecision(result: elevated, securityReviewEnabled: true) {
            XCTAssertTrue(reason.localizedCaseInsensitiveContains("finding"))
        } else {
            XCTFail("Expected skip for elevated findings")
        }

        // Review disabled: age still blocks, elevated findings do not.
        XCTAssertEqual(
            SecurityScan.autoRenewDecision(result: elevated, securityReviewEnabled: false),
            .proceed
        )
        if case .skip = SecurityScan.autoRenewDecision(result: tooNew, securityReviewEnabled: false) {
            // ok
        } else {
            XCTFail("Age floor still applies when review is disabled")
        }

        let local = SecurityScanResult(
            findings: [],
            ageStatus: .notApplicable,
            notes: ["Local IPA"],
            release: nil,
            scannedTag: nil,
            lockfilesFound: []
        )
        XCTAssertEqual(
            SecurityScan.autoRenewDecision(result: local, securityReviewEnabled: true),
            .proceed
        )

        let unknownAge = SecurityScanResult(
            findings: [],
            ageStatus: .unknown,
            notes: [],
            release: nil,
            scannedTag: "v0.0.1",
            lockfilesFound: []
        )
        if case .skip = SecurityScan.autoRenewDecision(result: unknownAge, securityReviewEnabled: true) {
            // ok
        } else {
            XCTFail("Unknown age should skip auto-renew")
        }
    }

    func testSecurityReviewAllowsProceedAnywayOnlyWhenAgeOK() {
        let ageBlocked = SecurityScanResult(
            findings: [],
            ageStatus: .tooNew(ageDays: 1, requiredDays: 14),
            notes: [],
            release: nil,
            scannedTag: "v1",
            lockfilesFound: []
        )
        XCTAssertFalse(ageBlocked.allowsProceedAnyway)
        XCTAssertTrue(ageBlocked.needsManualDecision)

        let vulnOnly = SecurityScanResult(
            findings: [
                SecurityFinding(
                    id: "x",
                    packageName: "foo",
                    packageVersion: "1.0.0",
                    ecosystem: "npm",
                    severity: .medium,
                    summary: "issue",
                    advisoryID: nil
                )
            ],
            ageStatus: .eligible(ageDays: 20),
            notes: [],
            release: nil,
            scannedTag: "v1",
            lockfilesFound: ["package-lock.json"]
        )
        XCTAssertTrue(vulnOnly.allowsProceedAnyway)
        XCTAssertTrue(vulnOnly.needsManualDecision)
        XCTAssertFalse(vulnOnly.allowsAutoRenew)
    }

    func testConfigSecurityReviewDefaultsOn() {
        let config = RenewioConfig(teamID: "TEAM123456")
        XCTAssertTrue(config.isSecurityReviewEnabled)
        var disabled = config
        disabled.securityReviewEnabled = false
        XCTAssertFalse(disabled.isSecurityReviewEnabled)
    }
}
