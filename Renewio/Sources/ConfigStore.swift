import Foundation

enum DevicePlatform: String, Codable, CaseIterable, Hashable, Identifiable {
    case tvos
    case ios
    case ipados

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tvos: return "Apple TV"
        case .ios: return "iPhone"
        case .ipados: return "iPad"
        }
    }

    var systemImage: String {
        switch self {
        case .tvos: return "appletv"
        case .ios: return "iphone"
        case .ipados: return "ipad"
        }
    }

    /// Platform string passed to xcodebuild / renewio.sh.
    var scriptPlatform: String {
        switch self {
        case .tvos: return "tvos"
        case .ios, .ipados: return "ios"
        }
    }

    var xcodePlatform: String {
        switch self {
        case .tvos: return "tvOS"
        case .ios, .ipados: return "iOS"
        }
    }

    var sdkName: String {
        switch self {
        case .tvos: return "appletvos"
        case .ios, .ipados: return "iphoneos"
        }
    }
}

struct TrackedDevice: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
    var platform: DevicePlatform
}

struct TrackedAppInstall: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var deviceID: String
    var name: String
    var githubRepo: String
    var bundleID: String
    var selectedTag: String?
    var lastInstalledVersion: String?
    var lastInstalledTag: String?
    var lastInstalledAt: String?
    var lastAssetName: String?

    static let defaultGitHubRepo = "bobsupra/NuvioTVOS"
    static let signingLifetime: TimeInterval = 7 * 24 * 60 * 60

    init(
        id: UUID = UUID(),
        deviceID: String,
        name: String,
        githubRepo: String = TrackedAppInstall.defaultGitHubRepo,
        bundleID: String,
        selectedTag: String? = nil,
        lastInstalledVersion: String? = nil,
        lastInstalledTag: String? = nil,
        lastInstalledAt: String? = nil,
        lastAssetName: String? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.name = name
        self.githubRepo = githubRepo
        self.bundleID = bundleID
        self.selectedTag = selectedTag
        self.lastInstalledVersion = lastInstalledVersion
        self.lastInstalledTag = lastInstalledTag
        self.lastInstalledAt = lastInstalledAt
        self.lastAssetName = lastAssetName
    }

    var lastInstalledDate: Date? {
        guard let raw = lastInstalledAt, !raw.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFractional.date(from: raw) {
            return parsed
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }

    var expiresAt: Date? {
        lastInstalledDate?.addingTimeInterval(Self.signingLifetime)
    }

    var displayVersion: String? {
        guard let version = lastInstalledVersion, !version.isEmpty else { return nil }
        return version.hasPrefix("v") ? version : "v\(version)"
    }
}

struct RenewioConfig: Codable, Equatable {
    var schemaVersion: Int
    var teamID: String
    var devices: [TrackedDevice]
    var installs: [TrackedAppInstall]
    var selectedDeviceID: String?

    static let currentSchemaVersion = 2

    init(
        schemaVersion: Int = RenewioConfig.currentSchemaVersion,
        teamID: String,
        devices: [TrackedDevice] = [],
        installs: [TrackedAppInstall] = [],
        selectedDeviceID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.teamID = teamID
        self.devices = devices
        self.installs = installs
        self.selectedDeviceID = selectedDeviceID
    }

    var isComplete: Bool {
        !teamID.isEmpty && !devices.isEmpty && !installs.isEmpty
    }

    var selectedDevice: TrackedDevice? {
        if let selectedDeviceID,
           let match = devices.first(where: { $0.id == selectedDeviceID }) {
            return match
        }
        return devices.first
    }

    func installs(forDeviceID deviceID: String) -> [TrackedAppInstall] {
        let needle = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let matched = installs.filter { $0.deviceID == needle }
        if !matched.isEmpty { return matched }
        // Fallback: substring match for CoreDevice identifier vs UDID mismatches.
        return installs.filter {
            !$0.deviceID.isEmpty && (needle.contains($0.deviceID) || $0.deviceID.contains(needle))
        }
    }

    mutating func selectDevice(_ deviceID: String) {
        selectedDeviceID = deviceID
    }

    mutating func upsertDevice(_ device: TrackedDevice) {
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            devices[idx] = device
        } else {
            devices.append(device)
        }
        if selectedDeviceID == nil {
            selectedDeviceID = device.id
        }
    }

    mutating func removeDevice(_ deviceID: String) {
        devices.removeAll { $0.id == deviceID }
        installs.removeAll { $0.deviceID == deviceID }
        if selectedDeviceID == deviceID {
            selectedDeviceID = devices.first?.id
        }
    }

    mutating func upsertInstall(_ install: TrackedAppInstall) {
        if let idx = installs.firstIndex(where: { $0.id == install.id }) {
            installs[idx] = install
        } else {
            installs.append(install)
        }
    }

    mutating func removeInstall(_ installID: UUID) {
        installs.removeAll { $0.id == installID }
    }

    mutating func markInstallSuccess(
        installID: UUID,
        version: String,
        tag: String?,
        assetName: String?,
        installedAt: Date = Date()
    ) {
        guard let idx = installs.firstIndex(where: { $0.id == installID }) else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        installs[idx].lastInstalledVersion = version
        installs[idx].lastInstalledTag = tag
        installs[idx].lastAssetName = assetName
        installs[idx].lastInstalledAt = formatter.string(from: installedAt)
    }
}

/// Legacy v1 flat config used only for migration.
private struct LegacyRenewioConfig: Codable {
    var teamID: String?
    var bundleID: String?
    var deviceID: String?
    var deviceName: String?
    var lastInstalledVersion: String?
    var lastInstalledTag: String?
    var lastInstalledAt: String?
    var lastAssetName: String?
}

struct CachedVersion: Identifiable, Hashable {
    let filename: String
    let version: String
    let sizeBytes: Int64
    let modifiedAt: Date

    var id: String { filename }

    var displayVersion: String {
        version.hasPrefix("v") ? version : "v\(version)"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct ReleaseOption: Identifiable, Hashable {
    let tag: String?
    let version: String
    let assetName: String
    let sizeBytes: Int64
    let isCached: Bool

    var id: String { tag ?? assetName }

    var displayVersion: String {
        version.hasPrefix("v") ? version : "v\(version)"
    }

    var formattedSize: String {
        sizeBytes > 0
            ? ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
            : ""
    }
}

struct GitHubRepoInfo: Equatable {
    let ownerRepo: String
    let name: String
    let fullName: String
    let description: String?
}

enum GitHubSource {
    /// Accepts `owner/repo`, HTTPS clone URLs, github.com page URLs, or SSH clone URLs.
    static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.lowercased().hasPrefix("git@") {
            // git@github.com:owner/repo.git
            if let colon = value.firstIndex(of: ":") {
                value = String(value[value.index(after: colon)...])
            }
        } else if let url = URL(string: value), let host = url.host?.lowercased(),
                  (host == "github.com" || host == "www.github.com") {
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            value = "\(parts[0])/\(parts[1])"
        } else if value.lowercased().contains("github.com/") {
            if let range = value.range(of: "github.com/", options: .caseInsensitive) {
                value = String(value[range.upperBound...])
            }
        }

        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.lowercased().hasSuffix(".git") {
            value = String(value.dropLast(4))
        }
        // Drop extra path segments (tree/main, releases, etc.)
        let segments = value.split(separator: "/").map(String.init)
        guard segments.count >= 2 else { return nil }
        let owner = segments[0]
        let repo = segments[1]
        guard !owner.isEmpty, !repo.isEmpty,
              !owner.contains(" "), !repo.contains(" ")
        else { return nil }
        return "\(owner)/\(repo)"
    }
}

@MainActor
final class ConfigStore: ObservableObject {
    @Published private(set) var config: RenewioConfig?

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        Self.migrateLegacySupportDirectoriesIfNeeded()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Renewio", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? support.appendingPathComponent("config.json")
        reload()
    }

    /// Moves Application Support / Logs from the old ReNuvio folder names into Renewio.
    private static func migrateLegacySupportDirectoriesIfNeeded() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let pairs: [(URL, URL)] = [
            (
                appSupport.appendingPathComponent("ReNuvio", isDirectory: true),
                appSupport.appendingPathComponent("Renewio", isDirectory: true)
            ),
            (
                library.appendingPathComponent("Logs/ReNuvio", isDirectory: true),
                library.appendingPathComponent("Logs/Renewio", isDirectory: true)
            ),
        ]
        for (legacy, modern) in pairs {
            guard fm.fileExists(atPath: legacy.path) else { continue }
            if !fm.fileExists(atPath: modern.path) {
                try? fm.moveItem(at: legacy, to: modern)
                continue
            }
            // Prefer keeping modern; copy missing children from legacy, then remove legacy.
            if let children = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
                for child in children {
                    let dest = modern.appendingPathComponent(child.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.moveItem(at: child, to: dest)
                    }
                }
            }
            try? fm.removeItem(at: legacy)
        }
    }

    var needsOnboarding: Bool {
        !(config?.isComplete ?? false)
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            config = nil
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            if let decoded = try? JSONDecoder().decode(RenewioConfig.self, from: data),
               !decoded.devices.isEmpty || !decoded.installs.isEmpty || decoded.schemaVersion >= 2 {
                var value = decoded
                if value.schemaVersion < RenewioConfig.currentSchemaVersion {
                    value.schemaVersion = RenewioConfig.currentSchemaVersion
                }
                if value.selectedDeviceID == nil {
                    value.selectedDeviceID = value.devices.first?.id
                }
                config = value
                if decoded.schemaVersion < RenewioConfig.currentSchemaVersion {
                    try? save(value)
                }
                return
            }

            if let legacy = try? JSONDecoder().decode(LegacyRenewioConfig.self, from: data),
               let migrated = Self.migrateLegacy(legacy) {
                config = migrated
                try? save(migrated)
                return
            }

            config = nil
        } catch {
            config = nil
        }
    }

    func save(_ value: RenewioConfig) throws {
        var next = value
        next.schemaVersion = RenewioConfig.currentSchemaVersion
        if next.selectedDeviceID == nil {
            next.selectedDeviceID = next.devices.first?.id
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        try data.write(to: fileURL, options: .atomic)
        config = next
    }

    private static func migrateLegacy(_ legacy: LegacyRenewioConfig) -> RenewioConfig? {
        let teamID = (legacy.teamID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceID = (legacy.deviceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = (legacy.bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !teamID.isEmpty, !deviceID.isEmpty, !bundleID.isEmpty else { return nil }

        let device = TrackedDevice(
            id: deviceID,
            name: (legacy.deviceName?.isEmpty == false) ? legacy.deviceName! : "Apple TV",
            platform: .tvos
        )
        let install = TrackedAppInstall(
            deviceID: deviceID,
            name: "Nuvio TV",
            githubRepo: TrackedAppInstall.defaultGitHubRepo,
            bundleID: bundleID,
            lastInstalledVersion: legacy.lastInstalledVersion,
            lastInstalledTag: legacy.lastInstalledTag,
            lastInstalledAt: legacy.lastInstalledAt,
            lastAssetName: legacy.lastAssetName
        )
        return RenewioConfig(
            schemaVersion: RenewioConfig.currentSchemaVersion,
            teamID: teamID,
            devices: [device],
            installs: [install],
            selectedDeviceID: deviceID
        )
    }

    static func repoFolderName(_ repo: String) -> String {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: " ", with: "-")
        return sanitized.isEmpty ? "unknown" : sanitized
    }

    static var downloadsRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Renewio/downloads", isDirectory: true)
    }

    static func downloadsDirectoryURL(forRepo repo: String) -> URL {
        let dir = downloadsRootURL.appendingPathComponent(repoFolderName(repo), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Legacy flat downloads folder (pre per-repo layout).
    static var legacyDownloadsDirectoryURL: URL { downloadsRootURL }

    static func listCachedVersions(forRepo repo: String, limit: Int = 3) -> [CachedVersion] {
        var dirs = [downloadsDirectoryURL(forRepo: repo)]
        if repo == TrackedAppInstall.defaultGitHubRepo {
            dirs.append(legacyDownloadsDirectoryURL)
        }

        var items: [CachedVersion] = []
        var seen = Set<String>()
        for dir in dirs {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in urls where url.pathExtension.lowercased() == "ipa" {
                let name = url.lastPathComponent
                guard !seen.contains(name) else { continue }
                guard let values = try? url.resourceValues(forKeys: [
                    .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
                ]),
                    values.isRegularFile == true
                else { continue }
                seen.insert(name)
                let version: String
                if let match = name.firstMatch(of: #/(\d+\.\d+\.\d+)/#) {
                    version = String(match.1)
                } else {
                    version = url.deletingPathExtension().lastPathComponent
                }
                items.append(
                    CachedVersion(
                        filename: name,
                        version: version,
                        sizeBytes: Int64(values.fileSize ?? 0),
                        modifiedAt: values.contentModificationDate ?? .distantPast
                    )
                )
            }
        }

        return Array(items.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit))
    }

    static func fetchRepoInfo(repo: String) async throws -> GitHubRepoInfo {
        guard let normalized = GitHubSource.normalize(repo),
              let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.github.com/repos/\(encoded)")
        else {
            throw NSError(
                domain: "Renewio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Paste a GitHub HTTPS clone link or owner/repo."]
            )
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Renewio", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(
                domain: "Renewio",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "GitHub returned HTTP \(http.statusCode) for \(normalized)."]
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fullName = json["full_name"] as? String
        else {
            throw NSError(
                domain: "Renewio",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not read repository metadata."]
            )
        }

        let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = json["description"] as? String
        return GitHubRepoInfo(
            ownerRepo: GitHubSource.normalize(fullName) ?? normalized,
            name: (name?.isEmpty == false) ? name! : (fullName.split(separator: "/").last.map(String.init) ?? normalized),
            fullName: fullName,
            description: description
        )
    }

    static func fetchRecentReleases(repo: String, limit: Int = 3) async throws -> [ReleaseOption] {
        guard let trimmed = GitHubSource.normalize(repo),
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.github.com/repos/\(encoded)/releases?per_page=10")
        else {
            throw NSError(
                domain: "Renewio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Paste a GitHub HTTPS clone link or owner/repo."]
            )
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Renewio", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(
                domain: "Renewio",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "GitHub returned HTTP \(http.statusCode)."]
            )
        }

        guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        let cachedFiles = Set(listCachedVersions(forRepo: trimmed, limit: 20).map(\.filename))
        var options: [ReleaseOption] = []

        for rel in releases {
            let tag = (rel["tag_name"] as? String) ?? ""
            let assets = (rel["assets"] as? [[String: Any]]) ?? []
            let ipaAssets = assets.filter {
                (($0["name"] as? String)?.lowercased().hasSuffix(".ipa") ?? false)
            }
            guard !ipaAssets.isEmpty else { continue }

            let chosen = ipaAssets.first(where: {
                (($0["name"] as? String)?.lowercased().contains("unsigned") ?? false)
            }) ?? ipaAssets[0]

            guard let assetName = chosen["name"] as? String else { continue }
            let size = (chosen["size"] as? NSNumber)?.int64Value ?? 0
            let version: String
            if let match = assetName.firstMatch(of: #/(\d+\.\d+\.\d+)/#) {
                version = String(match.1)
            } else if let match = tag.firstMatch(of: #/(\d+\.\d+\.\d+)/#) {
                version = String(match.1)
            } else {
                version = tag
            }

            options.append(
                ReleaseOption(
                    tag: tag,
                    version: version,
                    assetName: assetName,
                    sizeBytes: size,
                    isCached: cachedFiles.contains(assetName)
                )
            )
            if options.count >= limit { break }
        }

        return options
    }
}
