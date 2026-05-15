import Foundation

struct KnowledgeVaultManifest: Codable, Hashable {
    let name: String
    let source: String?
    let lastSyncedAt: String?
    let fileCount: Int
    let totalBytes: Int

    enum CodingKeys: String, CodingKey {
        case name
        case source
        case lastSyncedAt = "last_synced_at"
        case fileCount = "file_count"
        case totalBytes = "total_bytes"
    }
}

struct KnowledgeVaultSummary: Codable, Identifiable, Hashable {
    let id: String
    let manifest: KnowledgeVaultManifest
    let rootPath: String
    let exists: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case manifest
        case rootPath = "root_path"
        case exists
    }
}

struct KnowledgeListResponse: Codable {
    let ok: Bool
    let vault: KnowledgeVaultSummary?
    let skillInstalled: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case vault
        case skillInstalled = "skill_installed"
    }
}

struct KnowledgeUploadResponse: Codable {
    let ok: Bool
    let vault: KnowledgeVaultSummary
    let skillInstalled: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case vault
        case skillInstalled = "skill_installed"
    }
}

struct KnowledgeRemoveResponse: Codable {
    let ok: Bool
}

extension KnowledgeVaultManifest {
    var displayLastSynced: String {
        guard let lastSyncedAt, !lastSyncedAt.isEmpty else {
            return "Not yet synced"
        }
        return lastSyncedAt
    }

    var displaySize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(totalBytes))
    }
}
