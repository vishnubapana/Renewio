import Foundation
import UserNotifications

enum RenewStage: String, CaseIterable, Identifiable {
    case device
    case release
    case download
    case provision
    case sign
    case install

    var id: String { rawValue }

    var label: String {
        switch self {
        case .device: return "Checking device"
        case .release: return "Fetching release"
        case .download: return "Downloading IPA"
        case .provision: return "Refreshing signing profile"
        case .sign: return "Signing app"
        case .install: return "Installing on device"
        }
    }
}

struct BatchFailure: Equatable, Identifiable {
    let id = UUID()
    let appName: String
    let message: String
}

enum RenewStatus: Equatable {
    case idle
    case running(stage: RenewStage?, detail: String)
    case success(version: String, deviceName: String, detail: String, tag: String?, assetName: String?, expiresAt: String?)
    case failure(stage: String, message: String)
    case batchSummary(succeeded: [String], failed: [BatchFailure])
}

struct DownloadProgress: Equatable {
    let percent: Int
    let downloadedBytes: Int64
    let totalBytes: Int64

    var fraction: Double {
        guard totalBytes > 0 else { return Double(percent) / 100.0 }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    var formattedLabel: String {
        let have = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(percent)% · \(have) / \(total)"
    }
}

@MainActor
final class RenewRunner: ObservableObject {
    @Published private(set) var status: RenewStatus = .idle
    @Published private(set) var downloadProgress: DownloadProgress?
    @Published private(set) var logTail: String = ""
    @Published private(set) var activeInstallID: UUID?

    typealias SuccessCallback = (UUID, String, String?, String?, String?) -> Void

    private var process: Process?
    private let logURL: URL
    private var queue: [(install: TrackedAppInstall, device: TrackedDevice, teamID: String)] = []
    private var currentInstallName: String = ""
    private var currentAssetName: String?
    private var currentTag: String?
    private var isBatchRun = false
    private var batchSucceeded: [String] = []
    private var batchFailed: [BatchFailure] = []
    private var wasCancelled = false
    private var onSuccess: SuccessCallback?

    private static let maxLogBytes: UInt64 = 2 * 1024 * 1024

    init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Renewio", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = logs.appendingPathComponent("renew-ui.log")
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    func renew(
        install: TrackedAppInstall,
        device: TrackedDevice,
        teamID: String,
        onSuccess: SuccessCallback? = nil
    ) {
        queue = []
        isBatchRun = false
        batchSucceeded = []
        batchFailed = []
        self.onSuccess = onSuccess
        start(install: install, device: device, teamID: teamID)
    }

    func renewAll(
        installs: [TrackedAppInstall],
        device: TrackedDevice,
        teamID: String,
        onSuccess: SuccessCallback? = nil
    ) {
        guard !installs.isEmpty else { return }
        self.onSuccess = onSuccess
        isBatchRun = installs.count > 1
        batchSucceeded = []
        batchFailed = []
        var remaining = installs
        let first = remaining.removeFirst()
        queue = remaining.map { ($0, device, teamID) }
        start(install: first, device: device, teamID: teamID)
    }

    func cancel() {
        guard isRunning else { return }
        wasCancelled = true
        queue = []
        isBatchRun = false
        batchSucceeded = []
        batchFailed = []
        downloadProgress = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        activeInstallID = nil
        status = .idle
    }

    /// Surfaces a pre-install gate failure (age / resolve) on the install card without starting a process.
    func surfacePreflightFailure(install: TrackedAppInstall, message: String) {
        guard !isRunning else { return }
        queue = []
        isBatchRun = false
        activeInstallID = install.id
        currentInstallName = install.name
        downloadProgress = nil
        status = .failure(stage: "security", message: message)
    }

    private func start(install: TrackedAppInstall, device: TrackedDevice, teamID: String) {
        guard !isRunning else { return }
        wasCancelled = false
        activeInstallID = install.id
        currentInstallName = install.name
        currentAssetName = install.lastAssetName
        currentTag = install.selectedTag ?? install.lastInstalledTag
        downloadProgress = nil
        status = .running(stage: nil, detail: "Starting…")
        logTail = ""

        rotateLogIfNeeded()

        guard let scriptURL = Self.resolveScriptURL() else {
            status = .failure(
                stage: "init",
                message: "renewio.sh was not found inside the app bundle. Rebuild Renewio."
            )
            activeInstallID = nil
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        var args = [
            scriptURL.path,
            "--team-id", teamID,
            "--bundle-id", install.bundleID,
            "--device-id", device.id,
            "--device-name", device.name,
            "--app-name", install.name,
            "--platform", device.platform.scriptPlatform,
            "--no-config-write",
        ]
        if let localPath = install.localIPAPath, !localPath.isEmpty {
            args.append(contentsOf: ["--ipa", localPath])
        } else {
            args.append(contentsOf: ["--repo", install.githubRepo])
            if let tag = install.selectedTag, !tag.isEmpty {
                args.append(contentsOf: ["--tag", tag])
            }
        }
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Renewio")
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Logs/Renewio")
        env["RENEWIO_SUPPORT_DIR"] = support.path
        env["RENEWIO_LOG_DIR"] = logs.path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        if let token = KeychainStore.readGitHubToken(), !token.isEmpty {
            env["GITHUB_TOKEN"] = token
        }
        process.environment = env

        let statusURL = support.appendingPathComponent("last-status.txt")
        try? FileManager.default.removeItem(at: statusURL)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process

        let outHandle = stdout.fileHandleForReading
        let errHandle = stderr.fileHandleForReading

        outHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.consume(output: text)
            }
        }
        errHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.consume(output: text)
            }
        }

        process.terminationHandler = { [weak self] proc in
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            let leftoverOut = outHandle.readDataToEndOfFile()
            let leftoverErr = errHandle.readDataToEndOfFile()
            Task { @MainActor in
                guard let self else { return }
                if self.wasCancelled {
                    self.wasCancelled = false
                    return
                }
                if let text = String(data: leftoverOut, encoding: .utf8), !text.isEmpty {
                    self.consume(output: text)
                }
                if let text = String(data: leftoverErr, encoding: .utf8), !text.isEmpty {
                    self.consume(output: text)
                }
                self.process = nil
                self.handleTermination(status: proc.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            status = .failure(stage: "init", message: "Could not start renew script: \(error.localizedDescription)")
            self.process = nil
            activeInstallID = nil
        }
    }

    func clearStatus() {
        if !isRunning {
            status = .idle
            downloadProgress = nil
            activeInstallID = nil
        }
    }

    // MARK: - Parsing

    private func consume(output: String) {
        guard !wasCancelled else { return }
        appendLog(output)
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("[STAGE] ") {
                let payload = String(line.dropFirst("[STAGE] ".count))
                let parts = payload.split(separator: "|", maxSplits: 1).map(String.init)
                let stageID = parts.first ?? ""
                let label = parts.count > 1 ? parts[1] : stageID
                let stage = RenewStage(rawValue: stageID)
                if stage != .download {
                    downloadProgress = nil
                }
                status = .running(stage: stage, detail: label)
            } else if line.hasPrefix("[PROGRESS] ") {
                let payload = String(line.dropFirst("[PROGRESS] ".count))
                let parts = payload.split(separator: "|").map(String.init)
                if parts.count >= 4, parts[0] == "download",
                   let pct = Int(parts[1]),
                   let have = Int64(parts[2]),
                   let total = Int64(parts[3]) {
                    downloadProgress = DownloadProgress(percent: pct, downloadedBytes: have, totalBytes: total)
                }
            } else if line.hasPrefix("[INFO] ") {
                let info = String(line.dropFirst("[INFO] ".count))
                if info.localizedCaseInsensitiveContains("Selected cached IPA:")
                    || info.localizedCaseInsensitiveContains("Selected local IPA:")
                    || info.localizedCaseInsensitiveContains("Latest release:")
                    || info.localizedCaseInsensitiveContains("Using cached")
                    || info.localizedCaseInsensitiveContains("Downloading ") {
                    if let name = info.split(separator: " ").last(where: { $0.hasSuffix(".ipa") || $0.contains(".ipa") }) {
                        currentAssetName = String(name).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    }
                }
            } else if line.hasPrefix("[ERROR] ") {
                let payload = String(line.dropFirst("[ERROR] ".count))
                let parts = payload.split(separator: "|", maxSplits: 1).map(String.init)
                let stageID = parts.first ?? "unknown"
                let message = parts.count > 1 ? parts[1] : payload
                downloadProgress = nil
                status = .failure(stage: stageID, message: message)
                if !isBatchRun {
                    notify(title: "Renewio failed", body: message)
                }
            } else if line.hasPrefix("[RESULT] ") {
                let payload = String(line.dropFirst("[RESULT] ".count))
                let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if parts.count >= 4, parts[0] == "ok" {
                    let version = parts[1]
                    let device = parts[2]
                    let detail = parts[3]
                    let expiresAt = (parts.count >= 5 && !parts[4].isEmpty) ? parts[4] : nil
                    downloadProgress = nil
                    status = .success(
                        version: version,
                        deviceName: device,
                        detail: detail,
                        tag: currentTag,
                        assetName: currentAssetName,
                        expiresAt: expiresAt
                    )
                    if let installID = activeInstallID {
                        onSuccess?(installID, version, currentTag, currentAssetName, expiresAt)
                    }
                    if !isBatchRun {
                        notify(
                            title: "Installed \(currentInstallName) \(version)",
                            body: "Installed on \(device)."
                        )
                    }
                }
            }
        }
    }

    private func handleTermination(status code: Int32) {
        downloadProgress = nil
        switch self.status {
        case .success:
            if isBatchRun { batchSucceeded.append(currentInstallName) }
            advanceQueueIfNeeded()
            return
        case let .failure(_, message):
            if isBatchRun {
                batchFailed.append(BatchFailure(appName: currentInstallName, message: message))
                advanceQueueIfNeeded()
            } else {
                activeInstallID = nil
            }
            return
        case .running, .idle, .batchSummary:
            break
        }

        if let line = Self.latestStructuredLine() {
            consume(output: line + "\n")
            switch self.status {
            case .success:
                if isBatchRun { batchSucceeded.append(currentInstallName) }
                advanceQueueIfNeeded()
                return
            case let .failure(_, message):
                if isBatchRun {
                    batchFailed.append(BatchFailure(appName: currentInstallName, message: message))
                    advanceQueueIfNeeded()
                } else {
                    activeInstallID = nil
                }
                return
            default:
                break
            }
        }

        if code == 0 {
            self.status = .success(
                version: "unknown",
                deviceName: "device",
                detail: "Renew finished.",
                tag: currentTag,
                assetName: currentAssetName,
                expiresAt: nil
            )
            if let installID = activeInstallID {
                onSuccess?(installID, "unknown", currentTag, currentAssetName, nil)
            }
            if isBatchRun { batchSucceeded.append(currentInstallName) }
            advanceQueueIfNeeded()
        } else {
            let detail = Self.latestErrorFromLog()
                ?? "Renew exited with code \(code)."
            self.status = .failure(stage: "unknown", message: detail)
            if isBatchRun {
                batchFailed.append(BatchFailure(appName: currentInstallName, message: detail))
                advanceQueueIfNeeded()
            } else {
                notify(title: "Renewio failed", body: detail)
                activeInstallID = nil
            }
        }
    }

    private func advanceQueueIfNeeded() {
        guard !queue.isEmpty else {
            activeInstallID = nil
            if isBatchRun {
                let succeeded = batchSucceeded
                let failed = batchFailed
                isBatchRun = false
                status = .batchSummary(succeeded: succeeded, failed: failed)
                let summaryBody = failed.isEmpty
                    ? "Renewed \(succeeded.count) apps successfully."
                    : "\(succeeded.count) succeeded, \(failed.count) failed."
                notify(title: "Renew all finished", body: summaryBody)
            }
            return
        }
        let next = queue.removeFirst()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !self.wasCancelled else { return }
            self.status = .idle
            self.start(install: next.install, device: next.device, teamID: next.teamID)
        }
    }

    private func rotateLogIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? UInt64,
              size > Self.maxLogBytes
        else { return }
        let backup = logURL.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: logURL, to: backup)
    }

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Renewio", isDirectory: true)
    }

    private static var renewLogURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Renewio/renew.log")
    }

    private static func latestStructuredLine() -> String? {
        let statusURL = supportDirectory.appendingPathComponent("last-status.txt")
        if let line = (try? String(contentsOf: statusURL, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { $0.hasPrefix("[") }),
           !line.isEmpty {
            return line
        }

        guard let text = try? String(contentsOf: renewLogURL, encoding: .utf8) else { return nil }
        return text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { $0.hasPrefix("[RESULT] ") || $0.hasPrefix("[ERROR] ") || $0.hasPrefix("[STAGE] ") })
    }

    private static func latestErrorFromLog() -> String? {
        let statusURL = supportDirectory.appendingPathComponent("last-status.txt")
        guard let line = (try? String(contentsOf: statusURL, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { $0.hasPrefix("[ERROR] ") })
        else { return nil }
        let payload = String(line.dropFirst("[ERROR] ".count))
        let parts = payload.split(separator: "|", maxSplits: 1).map(String.init)
        return parts.count > 1 ? parts[1] : payload
    }

    private func appendLog(_ text: String) {
        logTail = String((logTail + text).suffix(8000))
        if let data = text.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    static func resolveScriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "renewio", withExtension: "sh") {
            return bundled
        }
        let candidates = [
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("scripts/renewio.sh"),
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("scripts/renewio.sh"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) || FileManager.default.fileExists(atPath: $0.path) }
    }

    static var logDirectoryURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Renewio", isDirectory: true)
    }

    static func recentErrorLogExcerpt(maxLines: Int = 20) -> String {
        let statusURL = supportDirectory.appendingPathComponent("last-status.txt")
        let statusLine = (try? String(contentsOf: statusURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let text = try? String(contentsOf: renewLogURL, encoding: .utf8), !text.isEmpty else {
            return statusLine ?? ""
        }

        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return statusLine ?? "" }

        let errorIndex = lines.lastIndex(where: { $0.hasPrefix("[ERROR] ") })
            ?? lines.lastIndex(where: { $0.hasPrefix("[STAGE] ") })
            ?? lines.index(before: lines.endIndex)

        let start = max(lines.startIndex, errorIndex - (maxLines - 5))
        let end = min(lines.endIndex, errorIndex + 5)
        var excerpt = Array(lines[start..<end]).joined(separator: "\n")

        if let statusLine, !statusLine.isEmpty, !excerpt.contains(statusLine) {
            excerpt = excerpt.isEmpty ? statusLine : excerpt + "\n" + statusLine
        }
        return excerpt
    }
}
