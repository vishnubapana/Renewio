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

enum RenewStatus: Equatable {
    case idle
    case running(stage: RenewStage?, detail: String)
    case success(version: String, deviceName: String, detail: String, tag: String?, assetName: String?)
    case failure(stage: String, message: String)
}

@MainActor
final class RenewRunner: ObservableObject {
    @Published private(set) var status: RenewStatus = .idle
    @Published private(set) var logTail: String = ""
    @Published private(set) var activeInstallID: UUID?

    private var process: Process?
    private let logURL: URL
    private var queue: [(install: TrackedAppInstall, device: TrackedDevice, teamID: String)] = []
    private var currentAssetName: String?
    private var currentTag: String?
    private var onSuccess: ((UUID, String, String?, String?) -> Void)?

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
        onSuccess: ((UUID, String, String?, String?) -> Void)? = nil
    ) {
        queue = []
        self.onSuccess = onSuccess
        start(install: install, device: device, teamID: teamID)
    }

    func renewAll(
        installs: [TrackedAppInstall],
        device: TrackedDevice,
        teamID: String,
        onSuccess: ((UUID, String, String?, String?) -> Void)? = nil
    ) {
        guard !installs.isEmpty else { return }
        self.onSuccess = onSuccess
        var remaining = installs
        let first = remaining.removeFirst()
        queue = remaining.map { ($0, device, teamID) }
        start(install: first, device: device, teamID: teamID)
    }

    private func start(install: TrackedAppInstall, device: TrackedDevice, teamID: String) {
        guard !isRunning else { return }
        activeInstallID = install.id
        currentAssetName = install.lastAssetName
        currentTag = install.selectedTag ?? install.lastInstalledTag
        status = .running(stage: nil, detail: "Starting…")
        logTail = ""

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
            "--repo", install.githubRepo,
            "--platform", device.platform.scriptPlatform,
            "--no-config-write",
        ]
        if let tag = install.selectedTag, !tag.isEmpty {
            args.append(contentsOf: ["--tag", tag])
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
                if let text = String(data: leftoverOut, encoding: .utf8), !text.isEmpty {
                    self?.consume(output: text)
                }
                if let text = String(data: leftoverErr, encoding: .utf8), !text.isEmpty {
                    self?.consume(output: text)
                }
                self?.process = nil
                self?.handleTermination(status: proc.terminationStatus)
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
            activeInstallID = nil
        }
    }

    // MARK: - Parsing

    private func consume(output: String) {
        appendLog(output)
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("[STAGE] ") {
                let payload = String(line.dropFirst("[STAGE] ".count))
                let parts = payload.split(separator: "|", maxSplits: 1).map(String.init)
                let stageID = parts.first ?? ""
                let label = parts.count > 1 ? parts[1] : stageID
                let stage = RenewStage(rawValue: stageID)
                status = .running(stage: stage, detail: label)
            } else if line.hasPrefix("[INFO] ") {
                let info = String(line.dropFirst("[INFO] ".count))
                if info.localizedCaseInsensitiveContains("Selected cached IPA:")
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
                status = .failure(stage: stageID, message: message)
                notify(title: "Renewio failed", body: message)
                queue = []
            } else if line.hasPrefix("[RESULT] ") {
                let payload = String(line.dropFirst("[RESULT] ".count))
                let parts = payload.split(separator: "|").map(String.init)
                if parts.count >= 4, parts[0] == "ok" {
                    let version = parts[1]
                    let device = parts[2]
                    let detail = parts[3...].joined(separator: "|")
                    status = .success(
                        version: version,
                        deviceName: device,
                        detail: detail,
                        tag: currentTag,
                        assetName: currentAssetName
                    )
                    if let installID = activeInstallID {
                        onSuccess?(installID, version, currentTag, currentAssetName)
                    }
                    notify(
                        title: "Installed \(version)",
                        body: "Installed on \(device). Renew again within 7 days if you use a free Apple ID."
                    )
                }
            }
        }
    }

    private func handleTermination(status code: Int32) {
        switch self.status {
        case .success:
            advanceQueueIfNeeded()
            return
        case .failure:
            activeInstallID = nil
            return
        case .running, .idle:
            break
        }

        if let line = Self.latestStructuredLine() {
            consume(output: line + "\n")
            switch self.status {
            case .success:
                advanceQueueIfNeeded()
                return
            case .failure:
                activeInstallID = nil
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
                assetName: currentAssetName
            )
            if let installID = activeInstallID {
                onSuccess?(installID, "unknown", currentTag, currentAssetName)
            }
            advanceQueueIfNeeded()
        } else {
            let detail = Self.latestErrorFromLog()
                ?? "Renew exited with code \(code)."
            self.status = .failure(stage: "unknown", message: detail)
            notify(title: "Renewio failed", body: detail)
            queue = []
            activeInstallID = nil
        }
    }

    private func advanceQueueIfNeeded() {
        guard !queue.isEmpty else {
            activeInstallID = nil
            return
        }
        let next = queue.removeFirst()
        // Brief pause so UI can show success before the next run starts.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.status = .idle
            self.start(install: next.install, device: next.device, teamID: next.teamID)
        }
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
