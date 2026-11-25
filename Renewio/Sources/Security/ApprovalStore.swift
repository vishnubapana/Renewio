import Foundation

struct LocalApprovalSnapshot: Codable, Equatable {
    var artifactSha256: String
    var reportID: String
    var reportSha256: String
    var findingIDs: [String]
    var approvedAt: Date
    var expiresAt: Date?
    var assessmentStatus: String
}

/// On-device cache of risk acceptances + last known report metadata for offline grace.
@MainActor
final class ApprovalStore: ObservableObject {
    @Published private(set) var approvals: [String: LocalApprovalSnapshot] = [:]

    private let url: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Renewio", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent("security-approvals.json")
        load()
    }

    func approval(forSha sha: String) -> LocalApprovalSnapshot? {
        let key = sha.lowercased()
        guard let snap = approvals[key] else { return nil }
        if let expires = snap.expiresAt, expires < Date() { return nil }
        return snap
    }

    func save(_ snap: LocalApprovalSnapshot) {
        approvals[snap.artifactSha256.lowercased()] = snap
        persist()
    }

    func invalidate(sha: String) {
        approvals.removeValue(forKey: sha.lowercased())
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: LocalApprovalSnapshot].self, from: data)
        else { return }
        approvals = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(approvals) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
