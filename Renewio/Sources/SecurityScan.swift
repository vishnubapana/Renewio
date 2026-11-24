import Foundation

// MARK: - Age policy (client-side defense-in-depth; server policy is authoritative)

enum ReleaseAgePolicy {
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
    case notApplicable

    var blocksAutomaticInstall: Bool {
        switch self {
        case .tooNew, .unknown: return true
        case .eligible, .notApplicable: return false
        }
    }

    var summary: String {
        switch self {
        case let .eligible(days):
            return days == 1
                ? "Release is 1 day old (meets 14-day floor)"
                : "Release is \(days) days old (meets 14-day floor)"
        case let .tooNew(days, required):
            return "Release is only \(days) day\(days == 1 ? "" : "s") old — auto/latest waits \(required)+ days"
        case .unknown:
            return "Release publish date unknown — review before install"
        case .notApplicable:
            return "Local IPA — no GitHub age rule"
        }
    }
}

// MARK: - Severity (shared with remote findings UI)

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
    var isElevated: Bool { self >= .medium }
}

/// Scan/eligibility presentation model for the menu review card.
struct SecurityScanResult {
    var findings: [RemoteFinding]
    var ageStatus: ReleaseAgeStatus
    var notes: [String]
    var release: ReleaseOption?
    var scannedTag: String?
    var lockfilesFound: [String]
    var eligibility: EligibilityResult? = nil

    var elevatedFindings: [RemoteFinding] {
        findings.filter { $0.severityEnum.isElevated }
    }

    var hasElevatedFindings: Bool { !elevatedFindings.isEmpty }

    var needsManualDecision: Bool {
        eligibility?.needsManualDecision
            ?? (ageStatus.blocksAutomaticInstall || hasElevatedFindings)
    }

    var allowsAutoRenew: Bool {
        if let eligibility { return eligibility.allowsAutoRenew }
        switch ageStatus {
        case .eligible, .notApplicable:
            return !hasElevatedFindings
        case .tooNew, .unknown:
            return false
        }
    }

    var allowsProceedAnyway: Bool {
        guard let eligibility else { return true }
        return eligibility.installEligibility == .allowWithApproval
            || eligibility.installEligibility == .allow
    }

    static func fromEligibility(_ result: EligibilityResult, publishedAt: Date?) -> SecurityScanResult {
        let age: ReleaseAgeStatus
        if result.ipaSha256.isEmpty {
            age = .unknown
        } else if publishedAt == nil && result.limitations.contains(where: { $0.contains("local") }) {
            age = .notApplicable
        } else {
            age = ReleaseAgePolicy.ageStatus(publishedAt: publishedAt)
        }
        return SecurityScanResult(
            findings: result.findings,
            ageStatus: age,
            notes: result.limitations + result.reasons,
            release: nil,
            scannedTag: nil,
            lockfilesFound: [],
            eligibility: result
        )
    }
}
