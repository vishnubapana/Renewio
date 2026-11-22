import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    let configStore = ConfigStore()
    let renewRunner = RenewRunner()

    @Published var showOnboarding = false
    @Published var availableVersions: [ReleaseOption] = []
    @Published var editingInstallID: UUID?

    private var cancellables = Set<AnyCancellable>()

    init() {
        showOnboarding = configStore.needsOnboarding
        ExpiryNotifier.requestAuthorizationIfNeeded()
        ExpiryNotifier.reschedule(for: configStore.config)

        configStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        renewRunner.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
        // If IDs drifted (CoreDevice identifier vs UDID) still show installs for the only device.
        if matched.isEmpty, config.devices.count == 1, !config.installs.isEmpty {
            return config.installs
        }
        return matched
    }

    func openOnboarding() {
        showOnboarding = true
    }

    func handleSetupClosed() {
        showOnboarding = false
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
        ) { [weak self] installID, version, tag, assetName in
            self?.recordSuccess(installID: installID, version: version, tag: tag, assetName: assetName)
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
        ) { [weak self] installID, version, tag, assetName in
            self?.recordSuccess(installID: installID, version: version, tag: tag, assetName: assetName)
        }
    }

    private func recordSuccess(installID: UUID, version: String, tag: String?, assetName: String?) {
        guard var config = configStore.config else { return }
        config.markInstallSuccess(
            installID: installID,
            version: version,
            tag: tag,
            assetName: assetName
        )
        try? configStore.save(config)
        ExpiryNotifier.reschedule(for: config)
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
}
