import Foundation

struct DownloadedIPA: Equatable {
    var localURL: URL
    var sha256: String
    var tag: String
    var version: String
    var assetName: String
    var assetID: String?
    var publishedAt: Date?
    var owner: String
    var repo: String
}

/// Downloads the original GitHub release IPA into Renewio's cache and hashes it.
enum IPADownloader {
    @MainActor
    static func downloadForSecurityGate(
        install: TrackedAppInstall,
        preferTag: String? = nil
    ) async throws -> DownloadedIPA {
        if install.isLocalIPA, let path = install.localIPAPath {
            let url = URL(fileURLWithPath: path)
            let sha = try ArtifactHasher.sha256Hex(ofFileAt: url)
            return DownloadedIPA(
                localURL: url,
                sha256: sha,
                tag: install.selectedTag ?? install.lastInstalledTag ?? "local",
                version: install.lastInstalledVersion ?? "local",
                assetName: url.lastPathComponent,
                assetID: nil,
                publishedAt: nil,
                owner: "local",
                repo: "ipa"
            )
        }

        let repo = install.githubRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else {
            throw SecurityClientError.scanFailed("Invalid GitHub repo: \(repo)")
        }
        let owner = String(parts[0])
        let name = String(parts[1])

        let release: ReleaseOption
        if let pinned = (preferTag ?? install.selectedTag)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pinned.isEmpty {
            guard let found = try await ConfigStore.fetchRelease(repo: repo, tag: pinned) else {
                throw SecurityClientError.scanFailed("Release tag \(pinned) not found.")
            }
            release = found
        } else {
            let eligible = try await ConfigStore.fetchEligibleReleases(repo: repo)
            guard let latest = eligible.first else {
                throw SecurityClientError.scanFailed("No age-eligible GitHub IPA releases found.")
            }
            release = latest
        }

        let tag = release.tag ?? preferTag ?? "unknown"
        let destDir = ConfigStore.downloadsDirectoryURL(forRepo: repo)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent(release.assetName)

        var needsDownload = true
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let size = attrs[.size] as? NSNumber,
           size.int64Value == release.sizeBytes,
           release.sizeBytes > 0 {
            needsDownload = false
        }

        if needsDownload {
            try await downloadAsset(
                owner: owner,
                repo: name,
                assetID: release.assetID,
                browserURL: release.browserDownloadURL,
                destination: dest
            )
        }

        let sha = try ArtifactHasher.sha256Hex(ofFileAt: dest)
        return DownloadedIPA(
            localURL: dest,
            sha256: sha,
            tag: tag,
            version: release.version,
            assetName: release.assetName,
            assetID: release.assetID.map(String.init),
            publishedAt: release.publishedAt,
            owner: owner,
            repo: name
        )
    }

    @MainActor
    static func downloadTag(install: TrackedAppInstall, tag: String) async throws -> DownloadedIPA {
        var copy = install
        copy.selectedTag = tag
        return try await downloadForSecurityGate(install: copy, preferTag: tag)
    }

    private static func downloadAsset(
        owner: String,
        repo: String,
        assetID: Int?,
        browserURL: URL?,
        destination: URL
    ) async throws {
        var request: URLRequest
        if let assetID {
            let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/assets/\(assetID)")!
            request = URLRequest(url: api)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        } else if let browserURL {
            request = URLRequest(url: browserURL)
        } else {
            throw SecurityClientError.scanFailed("Release has no downloadable IPA asset.")
        }
        request.setValue("Renewio", forHTTPHeaderField: "User-Agent")
        if let token = KeychainStore.readGitHubToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SecurityClientError.scanFailed("IPA download failed.")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }
}
