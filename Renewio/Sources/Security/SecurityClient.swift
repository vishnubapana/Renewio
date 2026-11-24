import Foundation

struct ScanRequestBody: Encodable {
    var ipaSha256: String
    var githubOwner: String
    var githubRepo: String
    var releaseTag: String
    var sourceCommit: String?
    var assetId: String?
    var assetName: String?
    var publishedAt: String?
    var policyVersion: String

    enum CodingKeys: String, CodingKey {
        case ipaSha256 = "ipa_sha256"
        case githubOwner = "github_owner"
        case githubRepo = "github_repo"
        case releaseTag = "release_tag"
        case sourceCommit = "source_commit"
        case assetId = "asset_id"
        case assetName = "asset_name"
        case publishedAt = "published_at"
        case policyVersion = "policy_version"
    }
}

struct ScanRequestResponse: Decodable {
    var jobId: String?
    var status: String?
    var scanStatus: String?
    var assessmentStatus: String?
    var reportId: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status
        case scanStatus = "scan_status"
        case assessmentStatus = "assessment_status"
        case reportId = "report_id"
        case error
    }
}

enum SecurityClientError: LocalizedError {
    case notConfigured
    case notSignedIn
    case http(Int, String)
    case decoding
    case scanFailed(String)
    case hashMismatch

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Security backend is not configured. Set RenewioSupabaseURL and RenewioSupabaseAnonKey."
        case .notSignedIn:
            return "Sign in under Settings to use shared security scanning."
        case let .http(code, body):
            return "Security API error (\(code)): \(body)"
        case .decoding:
            return "Could not parse security API response."
        case let .scanFailed(msg):
            return msg
        case .hashMismatch:
            return "IPA hash no longer matches the assessed artifact. Refusing to install."
        }
    }
}

@MainActor
final class SecurityClient: ObservableObject {
    @Published private(set) var accessToken: String?
    @Published private(set) var userEmail: String?

    private let session: URLSession = .shared

    init() {
        accessToken = KeychainStore.readSecurityAccessToken()
        userEmail = KeychainStore.readSecurityUserEmail()
    }

    var isSignedIn: Bool { accessToken != nil && !(accessToken?.isEmpty ?? true) }

    func signInWithOTP(email: String) async throws {
        guard let base = SecurityConfig.supabaseURL, let anon = SecurityConfig.supabaseAnonKey else {
            throw SecurityClientError.notConfigured
        }
        let url = base.appendingPathComponent("auth/v1/otp")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anon, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "create_user": true,
        ])
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SecurityClientError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "otp_failed")
        }
        userEmail = email
        KeychainStore.saveSecurityUserEmail(email)
    }

    func verifyOTP(email: String, token: String) async throws {
        guard let base = SecurityConfig.supabaseURL, let anon = SecurityConfig.supabaseAnonKey else {
            throw SecurityClientError.notConfigured
        }
        let url = base.appendingPathComponent("auth/v1/verify")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anon, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "token": token,
            "type": "email",
        ])
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SecurityClientError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, body)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else { throw SecurityClientError.decoding }
        accessToken = access
        userEmail = email
        KeychainStore.saveSecurityAccessToken(access)
        KeychainStore.saveSecurityUserEmail(email)
    }

    func signOut() {
        accessToken = nil
        KeychainStore.deleteSecurityAccessToken()
    }

    func requestScan(_ body: ScanRequestBody) async throws -> ScanRequestResponse {
        try await postFunction(name: "request-scan", body: body, as: ScanRequestResponse.self)
    }

    func checkEligibility(
        ipaSha256: String,
        isAutoRenew: Bool,
        localReportSha256: String? = nil,
        localAssessmentStatus: String? = nil,
        localCheckedAt: Date? = nil
    ) async throws -> EligibilityResult {
        var payload: [String: Any] = [
            "ipa_sha256": ipaSha256,
            "policy_version": SecurityConfig.policyVersion,
            "is_auto_renew": isAutoRenew,
            "offline_grace_hours": OfflineRenewPolicy.graceHours,
        ]
        if let localReportSha256 { payload["local_report_sha256"] = localReportSha256 }
        if let localAssessmentStatus { payload["local_assessment_status"] = localAssessmentStatus }
        if let localCheckedAt {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            payload["local_checked_at"] = f.string(from: localCheckedAt)
        }
        let data = try await postFunctionRaw(name: "check-eligibility", jsonObject: payload)
        return try Self.parseEligibility(data, fallbackSha: ipaSha256)
    }

    func recordApproval(ipaSha256: String, reportID: String, findingIDs: [String]) async throws {
        struct Body: Encodable {
            var ipa_sha256: String
            var report_id: String
            var finding_ids: [String]
        }
        struct Resp: Decodable { var ok: Bool? }
        _ = try await postFunction(
            name: "record-approval",
            body: Body(ipa_sha256: ipaSha256, report_id: reportID, finding_ids: findingIDs),
            as: Resp.self
        )
    }

    func pollUntilComplete(
        jobID: String?,
        ipaSha256: String,
        timeout: TimeInterval = 900,
        pollInterval: TimeInterval = 5
    ) async throws -> EligibilityResult {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = try await checkEligibility(ipaSha256: ipaSha256, isAutoRenew: false)
            switch result.installEligibility {
            case .pending:
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                continue
            case .allow, .allowWithApproval, .deny:
                if result.scanStatus == .queued || result.scanStatus == .scanning {
                    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    continue
                }
                return result
            }
        }
        throw SecurityClientError.scanFailed("Security scan timed out. Try again later.")
    }

    // MARK: - HTTP

    private func postFunction<T: Decodable, B: Encodable>(name: String, body: B, as: T.Type) async throws -> T {
        let data = try await postFunctionRaw(name: name, encodable: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SecurityClientError.decoding
        }
    }

    private func postFunctionRaw(name: String, encodable: some Encodable) async throws -> Data {
        let data = try JSONEncoder().encode(encodable)
        return try await postFunctionRaw(name: name, bodyData: data)
    }

    private func postFunctionRaw(name: String, jsonObject: [String: Any]) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        return try await postFunctionRaw(name: name, bodyData: data)
    }

    private func postFunctionRaw(name: String, bodyData: Data) async throws -> Data {
        guard let base = SecurityConfig.supabaseURL, let anon = SecurityConfig.supabaseAnonKey else {
            throw SecurityClientError.notConfigured
        }
        guard let token = accessToken, !token.isEmpty else {
            throw SecurityClientError.notSignedIn
        }
        let url = base.appendingPathComponent("functions/v1/\(name)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anon, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = bodyData
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SecurityClientError.http(0, "") }
        guard (200..<300).contains(http.statusCode) else {
            throw SecurityClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func parseEligibility(_ data: Data, fallbackSha: String) throws -> EligibilityResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SecurityClientError.decoding
        }
        let scanRaw = json["scan_status"] as? String ?? "not_scanned"
        let assessRaw = json["assessment_status"] as? String
        let eligRaw = json["install_eligibility"] as? String ?? "deny"
        var findings: [RemoteFinding] = []
        if let arr = json["findings"] as? [[String: Any]] {
            for item in arr {
                findings.append(
                    RemoteFinding(
                        id: item["id"] as? String ?? UUID().uuidString,
                        scanner: item["scanner"] as? String ?? "",
                        severity: item["severity"] as? String ?? "unknown",
                        title: item["title"] as? String ?? "",
                        summary: item["summary"] as? String,
                        overrideEligible: item["override_eligible"] as? Bool ?? true
                    )
                )
            }
        }
        let approval = json["user_approval"] as? [String: Any]
        return EligibilityResult(
            scanStatus: ScanStatus(rawValue: scanRaw) ?? .notScanned,
            assessmentStatus: assessRaw.flatMap(AssessmentStatus.init(rawValue:)),
            installEligibility: InstallEligibility(rawValue: eligRaw) ?? .deny,
            reportID: json["report_id"] as? String,
            reportSha256: json["report_sha256"] as? String,
            ipaSha256: (json["ipa_sha256"] as? String) ?? fallbackSha,
            limitations: json["limitations"] as? [String] ?? [],
            findingsSummary: json["findings_summary"] as? [String: Int] ?? [:],
            findings: findings,
            reasons: json["reasons"] as? [String] ?? [],
            reportJSON: json["report"] as? [String: Any],
            userApprovalState: approval?["state"] as? String,
            offlineGrace: json["offline_grace"] as? Bool ?? false
        )
    }
}
