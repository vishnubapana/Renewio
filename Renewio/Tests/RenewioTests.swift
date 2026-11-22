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
}
