import Foundation

// MARK: - Age policy

enum ReleaseAgePolicy {
    /// Fixed v1 floor: GitHub IPA releases must be at least this old before install.
    static let minimumAgeDays = 14
    static var minimumAge: TimeInterval { TimeInterval(minimumAgeDays) * 24 * 60 * 60 }

    static func ageStatus(publishedAt: Date?, now: Date = Date()) -> ReleaseAgeStatus {
        guard let publishedAt else { return .unknown }
        let age = now.timeIntervalSince(publishedAt)
        let days = max(0, Int(age / (24 * 60 * 60)))
        if age >= minimumAge {
            return .eligible(ageDays: days)
        }
        return .tooNew(ageDays: days, requiredDays: minimumAgeDays)
    }

    static func isEligible(publishedAt: Date?, now: Date = Date()) -> Bool {
        if case .eligible = ageStatus(publishedAt: publishedAt, now: now) {
            return true
        }
        return false
    }
}

enum ReleaseAgeStatus: Equatable {
    case eligible(ageDays: Int)
    case tooNew(ageDays: Int, requiredDays: Int)
    case unknown
    /// Local IPA / no GitHub release date applies.
    case notApplicable

    /// Auto / “Latest” paths never install these; manual pin may Proceed after review.
    var blocksAutomaticInstall: Bool {
        switch self {
        case .tooNew, .unknown: return true
        case .eligible, .notApplicable: return false
        }
    }

    var summary: String {
        switch self {
        case let .eligible(days):
            return days == 1 ? "Release is 1 day old (meets 14-day floor)" : "Release is \(days) days old (meets 14-day floor)"
        case let .tooNew(days, required):
            return "Release is only \(days) day\(days == 1 ? "" : "s") old — auto/latest waits \(required)+ days; you can Proceed anyway"
        case .unknown:
            return "Release publish date unknown — review before install"
        case .notApplicable:
            return "Local IPA — no GitHub age rule"
        }
    }
}

// MARK: - Findings

enum SecuritySeverity: String, Comparable, CaseIterable {
    case unknown
    case low
    case medium
    case high
    case critical

    private var rank: Int {
        switch self {
        case .unknown: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    static func < (lhs: SecuritySeverity, rhs: SecuritySeverity) -> Bool {
        lhs.rank < rhs.rank
    }

    var displayName: String { rawValue.capitalized }

    /// Auto-renew / “clean” gate: medium and above block automatic proceed.
    var isElevated: Bool { self >= .medium }

    static func fromOSV(severity: String?, databaseSpecific: [String: Any]?) -> SecuritySeverity {
        if let raw = severity?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
            switch raw {
            case "critical": return .critical
            case "high": return .high
            case "medium", "moderate": return .medium
            case "low": return .low
            default: break
            }
        }
        if let score = databaseSpecific?["severity"] as? String {
            return fromOSV(severity: score, databaseSpecific: nil)
        }
        if let cvss = databaseSpecific?["cvss"] as? [String: Any],
           let score = cvss["score"] as? Double ?? (cvss["score"] as? NSNumber)?.doubleValue {
            if score >= 9.0 { return .critical }
            if score >= 7.0 { return .high }
            if score >= 4.0 { return .medium }
            if score > 0 { return .low }
        }
        return .unknown
    }
}

struct SecurityFinding: Identifiable, Hashable, Equatable {
    let id: String
    let packageName: String
    let packageVersion: String
    let ecosystem: String
    let severity: SecuritySeverity
    let summary: String
    let advisoryID: String?

    var titleLine: String {
        let sev = severity.displayName
        if let advisoryID, !advisoryID.isEmpty {
            return "[\(sev)] \(packageName)@\(packageVersion) — \(advisoryID)"
        }
        return "[\(sev)] \(packageName)@\(packageVersion)"
    }
}

struct ScannedPackage: Hashable {
    let name: String
    let version: String
    let ecosystem: String
}

struct SecurityScanResult: Equatable {
    var findings: [SecurityFinding]
    var ageStatus: ReleaseAgeStatus
    var notes: [String]
    var release: ReleaseOption?
    var scannedTag: String?
    var lockfilesFound: [String]

    var elevatedFindings: [SecurityFinding] {
        findings.filter { $0.severity.isElevated }
    }

    var hasElevatedFindings: Bool { !elevatedFindings.isEmpty }

    /// Manual install needs an explicit Proceed/Reject (age warning and/or elevated findings).
    var needsManualDecision: Bool {
        ageStatus.blocksAutomaticInstall || hasElevatedFindings
    }

    /// Auto-renew / unpinned “latest” may proceed only when age is OK and there are no medium+ findings.
    var allowsAutoRenew: Bool {
        switch ageStatus {
        case .eligible, .notApplicable:
            return !hasElevatedFindings
        case .tooNew, .unknown:
            return false
        }
    }

    /// User-selected (pinned) releases may always Proceed after review — including newer than 14 days.
    var allowsProceedAnyway: Bool { true }
}

enum AutoRenewSecurityDecision: Equatable {
    case proceed
    case skip(reason: String)
}

/// Outcome of unpinned (auto/latest) selection after at most one older eligible vuln fallback.
enum UnpinnedVulnFallbackDecision: Equatable {
    /// Install this release (optionally after falling back from a dirtier newer eligible).
    case use(release: ReleaseOption, result: SecurityScanResult, fellBackFrom: ReleaseOption?)
    /// Manual path: show Proceed/Reject for the newest eligible; one prior attempt already failed or missing.
    case needsReview(release: ReleaseOption, result: SecurityScanResult, note: String?)
    /// Auto-renew path: skip — newest unclean and the single prior candidate failed or is missing.
    case skip(reason: String)
}

enum SecurityScan {
    static let lockfileNames = [
        "Package.resolved",
        "Podfile.lock",
        "package-lock.json",
        "pnpm-lock.yaml",
        "yarn.lock",
        "Cargo.lock",
        "go.sum",
        "Gemfile.lock",
    ]

    /// Hard limit: try the newest eligible, then at most **one** next-older eligible if elevated findings.
    static let maxVulnFallbackSteps = 1

    // MARK: Auto-renew matrix

    static func autoRenewDecision(
        result: SecurityScanResult,
        securityReviewEnabled: Bool
    ) -> AutoRenewSecurityDecision {
        if !securityReviewEnabled {
            switch result.ageStatus {
            case .eligible, .notApplicable:
                return .proceed
            case let .tooNew(days, required):
                return .skip(reason: "Release is only \(days)d old (needs \(required)+ days)")
            case .unknown:
                return .skip(reason: "Release publish date unknown")
            }
        }
        if result.allowsAutoRenew {
            return .proceed
        }
        if case let .tooNew(days, required) = result.ageStatus {
            return .skip(reason: "Release is only \(days)d old (needs \(required)+ days)")
        }
        if case .unknown = result.ageStatus {
            return .skip(reason: "Release publish date unknown")
        }
        if result.hasElevatedFindings {
            let count = result.elevatedFindings.count
            return .skip(reason: "\(count) medium/high/critical OSV finding\(count == 1 ? "" : "s")")
        }
        return .skip(reason: "Security review blocked auto-renew")
    }

    /// Pure decision for unpinned selection. Callers scan at most two eligible releases (newest + one prior).
    /// - Parameters:
    ///   - newestEligible: Newest age-eligible IPA release.
    ///   - newestScan: OSV/age scan of `newestEligible`.
    ///   - priorEligible: The single next-older eligible release, if any.
    ///   - priorScan: Scan of `priorEligible` when it exists and newest had elevated findings; nil if not scanned/missing.
    ///   - isAutoRenew: Auto-renew skips when fallback fails; manual shows review instead.
    static func decideUnpinnedVulnFallback(
        newestEligible: ReleaseOption,
        newestScan: SecurityScanResult,
        priorEligible: ReleaseOption?,
        priorScan: SecurityScanResult?,
        isAutoRenew: Bool
    ) -> UnpinnedVulnFallbackDecision {
        if !newestScan.hasElevatedFindings {
            if newestScan.needsManualDecision {
                // Unexpected for age-eligible, but surface review rather than auto-install.
                if isAutoRenew {
                    return .skip(reason: "Newest eligible release needs review")
                }
                return .needsReview(release: newestEligible, result: newestScan, note: nil)
            }
            return .use(release: newestEligible, result: newestScan, fellBackFrom: nil)
        }

        // Newest has elevated findings — try exactly one prior eligible.
        guard let priorEligible else {
            let note = "No older eligible release (≥\(ReleaseAgePolicy.minimumAgeDays) days) to fall back to."
            if isAutoRenew {
                let count = newestScan.elevatedFindings.count
                return .skip(
                    reason: "\(count) elevated OSV finding\(count == 1 ? "" : "s") on \(newestEligible.tag ?? "latest"); no prior eligible"
                )
            }
            var annotated = newestScan
            annotated.notes.insert(note, at: 0)
            return .needsReview(release: newestEligible, result: annotated, note: note)
        }

        guard let priorScan else {
            let note = "Could not scan prior eligible \(priorEligible.tag ?? "release")."
            if isAutoRenew {
                return .skip(reason: note)
            }
            var annotated = newestScan
            annotated.notes.insert(note, at: 0)
            return .needsReview(release: newestEligible, result: annotated, note: note)
        }

        if !priorScan.hasElevatedFindings && !priorScan.needsManualDecision {
            var adopted = priorScan
            let fromTag = newestEligible.tag ?? newestEligible.version
            let toTag = priorEligible.tag ?? priorEligible.version
            adopted.notes.insert(
                "Fell back from \(fromTag) → \(toTag) (elevated OSV on newer eligible; one-step limit).",
                at: 0
            )
            adopted.release = priorEligible
            return .use(release: priorEligible, result: adopted, fellBackFrom: newestEligible)
        }

        let priorTag = priorEligible.tag ?? priorEligible.version
        let note = "Also checked prior eligible \(priorTag) — still unclean. No further fallback."
        if isAutoRenew {
            return .skip(reason: "Elevated OSV on newest eligible and prior \(priorTag); no further fallback")
        }
        var annotated = newestScan
        annotated.notes.insert(note, at: 0)
        return .needsReview(release: newestEligible, result: annotated, note: note)
    }

    // MARK: Public scan entry

    /// Scans lockfiles at `tag` via GitHub Contents + OSV querybatch. Local / no-repo skips OSS with a note.
    static func evaluate(
        install: TrackedAppInstall,
        release: ReleaseOption?,
        now: Date = Date(),
        token: String? = KeychainStore.readGitHubToken(),
        session: URLSession = .shared
    ) async -> SecurityScanResult {
        if install.isLocalIPA {
            let repo = GitHubSource.normalize(install.githubRepo)
            if repo == nil {
                return SecurityScanResult(
                    findings: [],
                    ageStatus: .notApplicable,
                    notes: ["Local IPA — OSS scan skipped (no GitHub source)."],
                    release: release,
                    scannedTag: nil,
                    lockfilesFound: []
                )
            }
            // Rare: local IPA with companion repo configured — still skip age, run OSS at tag if any.
            let tag = release?.tag ?? install.selectedTag
            guard let tag, !tag.isEmpty else {
                return SecurityScanResult(
                    findings: [],
                    ageStatus: .notApplicable,
                    notes: ["Local IPA — age rule skipped; no release tag for OSS scan."],
                    release: release,
                    scannedTag: nil,
                    lockfilesFound: []
                )
            }
            var result = await scanRepository(
                ownerRepo: repo!,
                tag: tag,
                publishedAt: nil,
                now: now,
                token: token,
                session: session
            )
            result.ageStatus = .notApplicable
            result.notes.insert("Local IPA — GitHub age rule skipped.", at: 0)
            result.release = release
            return result
        }

        guard let repo = GitHubSource.normalize(install.githubRepo) else {
            return SecurityScanResult(
                findings: [],
                ageStatus: .unknown,
                notes: ["No valid GitHub repository configured."],
                release: release,
                scannedTag: nil,
                lockfilesFound: []
            )
        }

        let tag = (release?.tag ?? install.selectedTag)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tag, !tag.isEmpty else {
            return SecurityScanResult(
                findings: [],
                ageStatus: .unknown,
                notes: ["Could not resolve a release tag to scan."],
                release: release,
                scannedTag: nil,
                lockfilesFound: []
            )
        }

        var result = await scanRepository(
            ownerRepo: repo,
            tag: tag,
            publishedAt: release?.publishedAt,
            now: now,
            token: token,
            session: session
        )
        result.release = release
        return result
    }

    static func scanRepository(
        ownerRepo: String,
        tag: String,
        publishedAt: Date?,
        now: Date = Date(),
        token: String? = nil,
        session: URLSession = .shared
    ) async -> SecurityScanResult {
        let age = ReleaseAgePolicy.ageStatus(publishedAt: publishedAt, now: now)
        var notes: [String] = []
        var lockfilesFound: [String] = []
        var packages: [ScannedPackage] = []

        for name in lockfileNames {
            do {
                guard let text = try await fetchGitHubFile(
                    ownerRepo: ownerRepo,
                    path: name,
                    ref: tag,
                    token: token,
                    session: session
                ) else { continue }
                lockfilesFound.append(name)
                let parsed = parseLockfile(named: name, content: text)
                packages.append(contentsOf: parsed)
            } catch {
                notes.append("Could not read \(name): \(error.localizedDescription)")
            }
        }

        if lockfilesFound.isEmpty {
            notes.append("No lockfiles found at \(tag) — OSS scan had nothing to query.")
        }

        // Deduplicate packages before OSV.
        var unique = Set<ScannedPackage>()
        var deduped: [ScannedPackage] = []
        for pkg in packages {
            if unique.insert(pkg).inserted {
                deduped.append(pkg)
            }
        }

        let findings: [SecurityFinding]
        if deduped.isEmpty {
            findings = []
        } else {
            do {
                findings = try await queryOSV(packages: deduped, session: session)
            } catch {
                notes.append("OSV query failed: \(error.localizedDescription)")
                findings = []
            }
        }

        return SecurityScanResult(
            findings: findings.sorted { $0.severity > $1.severity },
            ageStatus: age,
            notes: notes,
            release: nil,
            scannedTag: tag,
            lockfilesFound: lockfilesFound
        )
    }

    // MARK: GitHub Contents

    static func fetchGitHubFile(
        ownerRepo: String,
        path: String,
        ref: String,
        token: String?,
        session: URLSession
    ) async throws -> String? {
        guard let encodedRepo = ownerRepo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.github.com/repos/\(encodedRepo)/contents/\(encodedPath)?ref=\(encodedRef)")
        else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Renewio", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else {
            throw NSError(
                domain: "Renewio.SecurityScan",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "GitHub Contents HTTP \(http.statusCode) for \(path)"]
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? String,
              (json["encoding"] as? String) == "base64"
        else {
            return nil
        }

        let cleaned = content.replacingOccurrences(of: "\n", with: "")
        guard let decoded = Data(base64Encoded: cleaned),
              let text = String(data: decoded, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    // MARK: Lockfile parsers

    static func parseLockfile(named name: String, content: String) -> [ScannedPackage] {
        switch name {
        case "Package.resolved":
            return parsePackageResolved(content)
        case "Podfile.lock":
            return parsePodfileLock(content)
        case "package-lock.json":
            return parsePackageLock(content)
        case "pnpm-lock.yaml":
            return parsePnpmLock(content)
        case "yarn.lock":
            return parseYarnLock(content)
        case "Cargo.lock":
            return parseCargoLock(content)
        case "go.sum":
            return parseGoSum(content)
        case "Gemfile.lock":
            return parseGemfileLock(content)
        default:
            return []
        }
    }

    static func parsePackageResolved(_ content: String) -> [ScannedPackage] {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        let pins: [[String: Any]]
        if let direct = json["pins"] as? [[String: Any]] {
            pins = direct
        } else if let objects = json["object"] as? [String: Any],
                  let nested = objects["pins"] as? [[String: Any]] {
            pins = nested
        } else {
            pins = []
        }

        var packages: [ScannedPackage] = []
        for pin in pins {
            let name = (pin["identity"] as? String)
                ?? (pin["package"] as? String)
                ?? ""
            let state = pin["state"] as? [String: Any]
            let version = (state?["version"] as? String) ?? ""
            guard !name.isEmpty, !version.isEmpty else { continue }
            packages.append(ScannedPackage(name: name, version: version, ecosystem: "SwiftURL"))
        }
        return packages
    }

    static func parsePodfileLock(_ content: String) -> [ScannedPackage] {
        var packages: [ScannedPackage] = []
        var inPods = false
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine
            if line.hasPrefix("PODS:") {
                inPods = true
                continue
            }
            if inPods, !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t"), line.contains(":") {
                break
            }
            guard inPods else { continue }
            // "  - Alamofire (5.6.4)" or "  - Foo/Bar (1.0.0):"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { continue }
            let body = String(trimmed.dropFirst(2))
            guard let open = body.lastIndex(of: "("),
                  let close = body.lastIndex(of: ")"),
                  open < close
            else { continue }
            var name = String(body[..<open]).trimmingCharacters(in: .whitespaces)
            if let slash = name.firstIndex(of: "/") {
                name = String(name[..<slash])
            }
            let version = String(body[body.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !version.isEmpty else { continue }
            packages.append(ScannedPackage(name: name, version: version, ecosystem: "SwiftURL"))
        }
        return packages
    }

    static func parsePackageLock(_ content: String) -> [ScannedPackage] {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var packages: [ScannedPackage] = []

        if let pkgs = json["packages"] as? [String: Any] {
            for (key, value) in pkgs {
                guard key.hasPrefix("node_modules/"),
                      let obj = value as? [String: Any],
                      let version = obj["version"] as? String
                else { continue }
                let name = String(key.dropFirst("node_modules/".count))
                guard !name.isEmpty else { continue }
                // Prefer leaf package name for nested paths.
                let shortName = name.split(separator: "/").last.map(String.init) ?? name
                let osvName = name.hasPrefix("@") ? name : shortName
                packages.append(ScannedPackage(name: name.contains("/") && name.hasPrefix("@") ? name : osvName, version: version, ecosystem: "npm"))
            }
        } else if let deps = json["dependencies"] as? [String: Any] {
            for (name, value) in deps {
                guard let obj = value as? [String: Any],
                      let version = obj["version"] as? String
                else { continue }
                packages.append(ScannedPackage(name: name, version: version, ecosystem: "npm"))
            }
        }
        return packages
    }

    static func parsePnpmLock(_ content: String) -> [ScannedPackage] {
        var packages: [ScannedPackage] = []
        var inPackages = false
        for rawLine in content.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("packages:") {
                inPackages = true
                continue
            }
            if inPackages, !rawLine.isEmpty, !rawLine.hasPrefix(" "), !rawLine.hasPrefix("\t"), rawLine.hasSuffix(":") {
                // next top-level section
                if !rawLine.hasPrefix("/") && rawLine != "packages:" {
                    break
                }
            }
            guard inPackages else { continue }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            // '/lodash@4.17.21:' or '/@babel/core@7.0.0:'
            guard trimmed.hasPrefix("/"), trimmed.hasSuffix(":") else { continue }
            var spec = String(trimmed.dropFirst().dropLast())
            // Strip peer suffix '(...)'
            if let paren = spec.firstIndex(of: "(") {
                spec = String(spec[..<paren])
            }
            guard let at = spec.lastIndex(of: "@") else { continue }
            let name = String(spec[..<at])
            let version = String(spec[spec.index(after: at)...])
            guard !name.isEmpty, !version.isEmpty, !version.contains(":") else { continue }
            packages.append(ScannedPackage(name: name, version: version, ecosystem: "npm"))
        }
        return packages
    }

    static func parseYarnLock(_ content: String) -> [ScannedPackage] {
        var packages: [ScannedPackage] = []
        var pendingNames: [String] = []
        for rawLine in content.components(separatedBy: .newlines) {
            if rawLine.isEmpty || rawLine.hasPrefix("#") {
                continue
            }
            if !rawLine.hasPrefix(" ") && rawLine.hasSuffix(":") {
                pendingNames = []
                let header = String(rawLine.dropLast())
                for part in header.split(separator: ",") {
                    var token = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    token = token.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    // "@scope/name@version" or "name@version"
                    if let at = token.lastIndex(of: "@"), at != token.startIndex {
                        let name = String(token[..<at])
                        if !name.isEmpty { pendingNames.append(name) }
                    }
                }
                continue
            }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("version "), !pendingNames.isEmpty {
                var version = trimmed.dropFirst("version ".count).trimmingCharacters(in: .whitespaces)
                version = version.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                for name in pendingNames {
                    packages.append(ScannedPackage(name: name, version: version, ecosystem: "npm"))
                }
                pendingNames = []
            }
        }
        return packages
    }

    static func parseCargoLock(_ content: String) -> [ScannedPackage] {
        var packages: [ScannedPackage] = []
        var name: String?
        var version: String?
        var inPackage = false
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "[[package]]" {
                if let name, let version {
                    packages.append(ScannedPackage(name: name, version: version, ecosystem: "crates.io"))
                }
                name = nil
                version = nil
                inPackage = true
                continue
            }
            guard inPackage else { continue }
            if line.hasPrefix("name = ") {
                name = line.dropFirst(7).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if line.hasPrefix("version = ") {
                version = line.dropFirst(10).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if line.hasPrefix("[") {
                if let name, let version {
                    packages.append(ScannedPackage(name: name, version: version, ecosystem: "crates.io"))
                }
                name = nil
                version = nil
                inPackage = false
            }
        }
        if let name, let version {
            packages.append(ScannedPackage(name: name, version: version, ecosystem: "crates.io"))
        }
        return packages
    }

    static func parseGoSum(_ content: String) -> [ScannedPackage] {
        var packages: [ScannedPackage] = []
        var seen = Set<String>()
        for rawLine in content.components(separatedBy: .newlines) {
            let parts = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let name = parts[0]
            var version = parts[1]
            if version.hasSuffix("/go.mod") {
                version = String(version.dropLast("/go.mod".count))
            }
            // Skip pseudo "+incompatible" marker stripping beyond keeping version string.
            let key = "\(name)@\(version)"
            guard seen.insert(key).inserted else { continue }
            packages.append(ScannedPackage(name: name, version: version, ecosystem: "Go"))
        }
        return packages
    }

    static func parseGemfileLock(_ content: String) -> [ScannedPackage] {
        var packages: [ScannedPackage] = []
        var inSpecs = false
        for rawLine in content.components(separatedBy: .newlines) {
            if rawLine.trimmingCharacters(in: .whitespaces) == "specs:" {
                inSpecs = true
                continue
            }
            if inSpecs, rawLine.hasPrefix("    "), !rawLine.hasPrefix("      ") {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                // "rack (2.2.3)"
                guard let open = trimmed.lastIndex(of: "("),
                      let close = trimmed.lastIndex(of: ")"),
                      open < close
                else { continue }
                let name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
                let version = String(trimmed[trimmed.index(after: open)..<close])
                guard !name.isEmpty, !version.isEmpty else { continue }
                packages.append(ScannedPackage(name: name, version: version, ecosystem: "RubyGems"))
            } else if inSpecs, !rawLine.isEmpty, !rawLine.hasPrefix(" ") {
                break
            }
        }
        return packages
    }

    // MARK: OSV

    static func queryOSV(
        packages: [ScannedPackage],
        session: URLSession
    ) async throws -> [SecurityFinding] {
        guard let url = URL(string: "https://api.osv.dev/v1/querybatch") else { return [] }

        // OSV caps batch size; chunk to stay polite.
        let chunkSize = 80
        var findings: [SecurityFinding] = []
        var offset = 0
        while offset < packages.count {
            let end = min(offset + chunkSize, packages.count)
            let chunk = Array(packages[offset..<end])
            offset = end

            let queries: [[String: Any]] = chunk.map { pkg in
                [
                    "package": [
                        "name": pkg.name,
                        "ecosystem": pkg.ecosystem,
                    ],
                    "version": pkg.version,
                ]
            }
            let body = try JSONSerialization.data(withJSONObject: ["queries": queries])

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Renewio", forHTTPHeaderField: "User-Agent")
            request.httpBody = body
            request.timeoutInterval = 45

            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw NSError(
                    domain: "Renewio.SecurityScan",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "OSV HTTP \(http.statusCode)"]
                )
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]]
            else { continue }

            for (idx, result) in results.enumerated() {
                guard idx < chunk.count else { continue }
                let pkg = chunk[idx]
                let vulns = (result["vulns"] as? [[String: Any]]) ?? []
                for vuln in vulns {
                    let advisoryID = (vuln["id"] as? String) ?? ""
                    let summary = (vuln["summary"] as? String)
                        ?? (vuln["details"] as? String)
                        ?? "Vulnerability reported by OSV"
                    let db = vuln["database_specific"] as? [String: Any]
                    var resolvedSeverity = SecuritySeverity.fromOSV(
                        severity: vuln["severity"] as? String,
                        databaseSpecific: db
                    )
                    if let sevArr = vuln["severity"] as? [[String: Any]] {
                        for entry in sevArr {
                            let score = entry["score"] as? String
                            let type = entry["type"] as? String
                            if let type, type.uppercased().contains("CVSS"), let score {
                                let parsed = SecuritySeverity.fromOSV(severity: score, databaseSpecific: db)
                                if parsed > resolvedSeverity { resolvedSeverity = parsed }
                            } else if let score {
                                let parsed = SecuritySeverity.fromOSV(severity: score, databaseSpecific: nil)
                                if parsed > resolvedSeverity { resolvedSeverity = parsed }
                            } else if let type {
                                let parsed = SecuritySeverity.fromOSV(severity: type, databaseSpecific: nil)
                                if parsed > resolvedSeverity { resolvedSeverity = parsed }
                            }
                        }
                    }

                    findings.append(
                        SecurityFinding(
                            id: "\(advisoryID)-\(pkg.name)-\(pkg.version)",
                            packageName: pkg.name,
                            packageVersion: pkg.version,
                            ecosystem: pkg.ecosystem,
                            severity: resolvedSeverity,
                            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                            advisoryID: advisoryID.isEmpty ? nil : advisoryID
                        )
                    )
                }
            }
        }
        return findings
    }
}
