import Foundation

enum ScanStatus: String, Codable, Equatable {
    case notScanned = "not_scanned"
    case queued
    case scanning
    case succeeded
    case failed
    case timedOut = "timed_out"
}

enum AssessmentStatus: String, Codable, Equatable {
    case incomplete
    case checksPassed = "checks_passed"
    case reviewRequired = "review_required"
    case blocked
    case expired
    case revoked
}

enum InstallEligibility: String, Codable, Equatable {
    case allow
    case allowWithApproval = "allow_with_approval"
    case deny
    case pending
}

struct RemoteFinding: Identifiable, Equatable, Codable {
    var id: String
    var scanner: String
    var severity: String
    var title: String
    var summary: String?
    var overrideEligible: Bool

    enum CodingKeys: String, CodingKey {
        case id, scanner, severity, title, summary
        case overrideEligible = "override_eligible"
    }

    var severityEnum: SecuritySeverity {
        SecuritySeverity(rawValue: severity.lowercased()) ?? .unknown
    }

    var titleLine: String {
        "[\(severityEnum.displayName)] \(title)"
    }
}

struct EligibilityResult {
    var scanStatus: ScanStatus
    var assessmentStatus: AssessmentStatus?
    var installEligibility: InstallEligibility
    var reportID: String?
    var reportSha256: String?
    var ipaSha256: String
    var limitations: [String]
    var findingsSummary: [String: Int]
    var findings: [RemoteFinding]
    var reasons: [String]
    var reportJSON: [String: Any]?
    var userApprovalState: String?
    var offlineGrace: Bool

    var displayAssessment: String {
        switch assessmentStatus {
        case .checksPassed: return "Checks Passed"
        case .reviewRequired: return "Review Required"
        case .blocked: return "Blocked"
        case .incomplete: return "Incomplete assessment"
        case .expired: return "Report expired"
        case .revoked: return "Report revoked"
        case .none:
            switch scanStatus {
            case .queued, .scanning: return "Scanning"
            case .failed, .timedOut: return "Scan Failed"
            default: return "Not scanned"
            }
        }
    }

    var allowsAutoRenew: Bool {
        installEligibility == .allow && assessmentStatus == .checksPassed
            || (installEligibility == .allow && userApprovalState == "valid")
    }

    var needsManualDecision: Bool {
        installEligibility == .allowWithApproval
    }
}

enum OfflineRenewPolicy {
    /// Hours a locally cached checks_passed / approved report may authorize same-artifact renew offline.
    static let graceHours: Double = 72

    static func allowsSameArtifactRenew(
        localAssessment: AssessmentStatus?,
        localCheckedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let localAssessment, let localCheckedAt else { return false }
        let ageHours = now.timeIntervalSince(localCheckedAt) / 3600
        guard ageHours <= graceHours else { return false }
        switch localAssessment {
        case .checksPassed:
            return true
        case .reviewRequired:
            // Requires a still-valid local approval snapshot; caller checks ApprovalStore.
            return true
        default:
            return false
        }
    }
}
