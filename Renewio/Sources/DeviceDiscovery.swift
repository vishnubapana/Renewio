import Foundation

struct AppleDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let state: String
    let udid: String
    let platform: DevicePlatform

    var displaySubtitle: String {
        let base = state.isEmpty ? udid : "\(state) · \(udid)"
        return "\(platform.displayName) · \(base)"
    }

    var trackedDevice: TrackedDevice {
        TrackedDevice(id: udid.isEmpty ? id : udid, name: name, platform: platform)
    }
}

typealias AppleTVDevice = AppleDevice

struct TeamHint: Identifiable, Hashable {
    let id: String
    let name: String
}

struct AvailableSDKs: Equatable {
    var tvOS: Bool
    var iOS: Bool

    func supports(_ platform: DevicePlatform) -> Bool {
        switch platform {
        case .tvos: return tvOS
        case .ios, .ipados: return iOS
        }
    }
}

enum DeviceDiscovery {
    static func listDevices() async throws -> [AppleDevice] {
        let result = try await run(
            "/usr/bin/xcrun",
            ["devicectl", "list", "devices", "--json-output", "-"]
        )
        return try parseDevices(jsonText: result.stdout)
    }

    /// Back-compat alias used by older call sites.
    static func listAppleTVs() async throws -> [AppleDevice] {
        try await listDevices().filter { $0.platform == .tvos }
    }

    static func detectTeamHints() -> [TeamHint] {
        var byID: [String: TeamHint] = [:]
        var preferredID: String?

        let xcodePlistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dt.Xcode.plist")
        if let data = try? Data(contentsOf: xcodePlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            preferredID = plist["IDEProvisioningTeamManagerLastSelectedTeamID"] as? String

            if let teamsByAccount = plist["IDEProvisioningTeamByIdentifier"] as? [String: [[String: Any]]] {
                for accountTeams in teamsByAccount.values {
                    for entry in accountTeams {
                        guard let teamID = entry["teamID"] as? String, !teamID.isEmpty else { continue }
                        let teamName = (entry["teamName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let displayName = (teamName?.isEmpty == false) ? teamName! : "Xcode Team"
                        byID[teamID] = TeamHint(id: teamID, name: displayName)
                    }
                }
            }
        }

        let profileDirs = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/MobileDevice/Provisioning Profiles"),
        ]

        for dir in profileDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ) else { continue }

            for file in files where file.pathExtension == "mobileprovision" {
                guard let decoded = decodeProvision(file), let team = decoded.teamID, !team.isEmpty else { continue }
                if byID[team] == nil {
                    byID[team] = TeamHint(id: team, name: decoded.teamName ?? team)
                }
            }
        }

        if let certsOut = try? runSync(
            "/usr/bin/security",
            ["find-certificate", "-a", "-c", "Apple Development", "-p"]
        ) {
            for cert in extractCertTeamHints(pemBundle: certsOut.stdout) {
                if byID[cert.id] == nil {
                    byID[cert.id] = cert
                }
            }
        }

        return byID.values.sorted { lhs, rhs in
            if lhs.id == preferredID { return true }
            if rhs.id == preferredID { return false }
            return lhs.id < rhs.id
        }
    }

    private static func extractCertTeamHints(pemBundle: String) -> [TeamHint] {
        let marker = "-----BEGIN CERTIFICATE-----"
        let endMarker = "-----END CERTIFICATE-----"
        var hints: [TeamHint] = []

        for chunk in pemBundle.components(separatedBy: marker).dropFirst() {
            guard let endRange = chunk.range(of: endMarker) else { continue }
            let pem = marker + chunk[..<endRange.upperBound]
            guard let subject = opensslSubject(pem: String(pem)) else { continue }
            if let ouMatch = subject.firstMatch(of: #/OU=([A-Z0-9]{10})/#) {
                let teamID = String(ouMatch.1)
                let org = subject.firstMatch(of: #/O=([^/,]+)/#).map { String($0.1) } ?? "From Keychain"
                hints.append(TeamHint(id: teamID, name: org))
            }
        }
        return hints
    }

    private static func opensslSubject(pem: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["x509", "-noout", "-subject"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        do {
            try process.run()
            if let data = pem.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            stdinPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch {
            return nil
        }
    }

    static func xcodeAvailable() -> Bool {
        (try? runSync("/usr/bin/xcodebuild", ["-version"])) != nil
    }

    static func tvOSSDKAvailable() -> Bool {
        availableSDKs().tvOS
    }

    static func availableSDKs() -> AvailableSDKs {
        guard let result = try? runSync("/usr/bin/xcodebuild", ["-showsdks"]) else {
            return AvailableSDKs(tvOS: false, iOS: false)
        }
        let out = result.stdout.lowercased()
        return AvailableSDKs(
            tvOS: out.contains("appletvos"),
            iOS: out.contains("iphoneos")
        )
    }

    static func openXcodeAccounts() {
        _ = try? runSync("/usr/bin/open", ["-a", "Xcode"])
    }

    static func openXcodeDevices() {
        _ = try? runSync("/usr/bin/open", ["-a", "Xcode"])
        let script = """
        tell application "Xcode" to activate
        tell application "System Events"
          tell process "Xcode"
            try
              click menu item "Devices and Simulators" of menu "Window" of menu bar 1
            end try
          end tell
        end tell
        """
        _ = try? runSync("/usr/bin/osascript", ["-e", script])
    }

    // MARK: - Private

    private struct ProvisionInfo {
        var teamID: String?
        var teamName: String?
    }

    private static func decodeProvision(_ url: URL) -> ProvisionInfo? {
        guard let result = try? runSync("/usr/bin/security", ["cms", "-D", "-i", url.path]),
              let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        let teams = plist["TeamIdentifier"] as? [String]
        return ProvisionInfo(
            teamID: teams?.first,
            teamName: plist["TeamName"] as? String
        )
    }

    private static func inferPlatform(
        platform: String,
        deviceType: String,
        name: String
    ) -> DevicePlatform? {
        let blob = "\(platform) \(deviceType) \(name)".lowercased()
        if blob.contains("mac") || blob.contains("simulator") {
            return nil
        }
        if blob.contains("appletv") || blob.contains("apple tv") || platform.localizedCaseInsensitiveContains("tv") {
            return .tvos
        }
        if blob.contains("ipad") {
            return .ipados
        }
        if blob.contains("iphone") || blob.contains("ios") || deviceType.localizedCaseInsensitiveContains("iPhone") {
            return .ios
        }
        // Name heuristics for unlabeled TVs
        if name.localizedCaseInsensitiveContains("living") || name.localizedCaseInsensitiveContains("tv") {
            return .tvos
        }
        return nil
    }

    static func parseDevices(jsonText: String) throws -> [AppleDevice] {
        guard let data = jsonText.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        let devices = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]]
            ?? root["devices"] as? [[String: Any]]
            ?? []

        var parsed: [AppleDevice] = []
        for device in devices {
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let deviceProps = device["deviceProperties"] as? [String: Any] ?? [:]
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            let nested = device["properties"] as? [String: Any] ?? [:]
            let nestedHardware = nested["hardware"] as? [String: Any] ?? [:]
            let nestedDevice = nested["device"] as? [String: Any] ?? [:]
            let nestedConnection = nested["connection"] as? [String: Any] ?? [:]

            let platformRaw = (hardware["platform"] as? String)
                ?? (nestedHardware["platform"] as? String)
                ?? (deviceProps["platform"] as? String)
                ?? ""
            let deviceType = (hardware["deviceType"] as? String)
                ?? (nestedHardware["deviceType"] as? String)
                ?? ""
            let name = (deviceProps["name"] as? String)
                ?? (nestedDevice["name"] as? String)
                ?? (device["name"] as? String)
                ?? "Device"

            guard let platform = inferPlatform(platform: platformRaw, deviceType: deviceType, name: name) else {
                continue
            }

            let udid = (hardware["udid"] as? String)
                ?? (nestedHardware["udid"] as? String)
                ?? (device["identifier"] as? String)
                ?? UUID().uuidString
            let identifier = (device["identifier"] as? String) ?? udid
            let state = (connection["tunnelState"] as? String)
                ?? (connection["pairingState"] as? String)
                ?? (nestedConnection["tunnelState"] as? String)
                ?? "unknown"

            parsed.append(
                AppleDevice(
                    id: identifier,
                    name: name,
                    state: state,
                    udid: udid,
                    platform: platform
                )
            )
        }

        return parsed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private struct CommandResult {
        var stdout: String
        var stderr: String
        var status: Int32
    }

    private static func run(_ launchPath: String, _ arguments: [String]) async throws -> CommandResult {
        try await Task.detached {
            try runSync(launchPath, arguments)
        }.value
    }

    @discardableResult
    private static func runSync(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw DiscoveryError.commandFailed(
                command: ([launchPath] + arguments).joined(separator: " "),
                status: process.terminationStatus,
                output: stderr.isEmpty ? stdout : stderr
            )
        }
        return CommandResult(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }
}

enum DiscoveryError: LocalizedError {
    case commandFailed(command: String, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(_, _, output):
            if output.localizedCaseInsensitiveContains("CoreDeviceService") {
                return "Apple’s device service isn’t ready. Open Xcode once, wait a few seconds, then refresh."
            }
            return output.isEmpty ? "Device discovery failed." : output
        }
    }
}
