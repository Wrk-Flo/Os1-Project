import Foundation

enum KnowledgeBaseError: LocalizedError {
    case folderNotFound(String)
    case folderEmpty(String)
    case tarFailed(String)
    case payloadTooLarge(bytes: Int, limit: Int)
    case invalidVaultName(String)

    var errorDescription: String? {
        switch self {
        case .folderNotFound(let path):
            return "The selected folder \(path) could not be read."
        case .folderEmpty(let path):
            return "\(path) does not contain any markdown files."
        case .tarFailed(let detail):
            return "Failed to package the vault: \(detail)"
        case .payloadTooLarge(let bytes, let limit):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let actual = formatter.string(fromByteCount: Int64(bytes))
            let cap = formatter.string(fromByteCount: Int64(limit))
            return "Vault is \(actual) compressed — exceeds the \(cap) limit. Reduce the vault size or split it before syncing."
        case .invalidVaultName(let name):
            return "“\(name)” is not a valid vault name. Use letters, numbers, hyphens, or underscores."
        }
    }
}

final class KnowledgeBaseService: @unchecked Sendable {
    /// Compressed payload cap. Markdown compresses heavily; 64 MB is plenty for
    /// a typical Obsidian vault while keeping the JSON-over-HTTP transport
    /// stable on Orgo VMs.
    static let maxCompressedPayloadBytes = 64 * 1024 * 1024

    private let transport: any RemoteTransport

    init(transport: any RemoteTransport) {
        self.transport = transport
    }

    func loadVault(connection: ConnectionProfile) async throws -> KnowledgeListResponse {
        let script = try RemotePythonScript.wrap(
            EmptyRequest(hermesHome: connection.remoteHermesHomePath),
            body: listBody
        )

        return try await transport.executeJSON(
            on: connection,
            pythonScript: script,
            responseType: KnowledgeListResponse.self
        )
    }

    func uploadVault(
        connection: ConnectionProfile,
        localFolder: URL,
        vaultName: String
    ) async throws -> KnowledgeUploadResponse {
        let trimmedName = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidVaultName(trimmedName) else {
            throw KnowledgeBaseError.invalidVaultName(vaultName)
        }

        let archive = try makeTarArchive(of: localFolder)
        guard archive.count <= Self.maxCompressedPayloadBytes else {
            throw KnowledgeBaseError.payloadTooLarge(
                bytes: archive.count,
                limit: Self.maxCompressedPayloadBytes
            )
        }

        let request = UploadRequest(
            hermesHome: connection.remoteHermesHomePath,
            vaultName: trimmedName,
            sourcePath: localFolder.path,
            archiveBase64: archive.base64EncodedString()
        )

        let script = try RemotePythonScript.wrap(request, body: uploadBody)

        return try await transport.executeJSON(
            on: connection,
            pythonScript: script,
            responseType: KnowledgeUploadResponse.self
        )
    }

    func removeVault(connection: ConnectionProfile) async throws -> KnowledgeRemoveResponse {
        let script = try RemotePythonScript.wrap(
            EmptyRequest(hermesHome: connection.remoteHermesHomePath),
            body: removeBody
        )

        return try await transport.executeJSON(
            on: connection,
            pythonScript: script,
            responseType: KnowledgeRemoveResponse.self
        )
    }

    // MARK: - Local archiving

    private func isValidVaultName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 80 else { return false }
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9 _.-]*$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    /// Tars (gzipped) the vault folder, skipping common per-machine and binary
    /// junk. Markdown-only is the goal of v1; large attachments stay on the
    /// user's machine.
    private func makeTarArchive(of folder: URL) throws -> Data {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw KnowledgeBaseError.folderNotFound(folder.path)
        }

        let parent = folder.deletingLastPathComponent().path
        let leaf = folder.lastPathComponent
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kb-\(UUID().uuidString).tar.gz")

        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "--no-mac-metadata",
            "--exclude=.DS_Store",
            "--exclude=.git",
            "--exclude=.obsidian/workspace.json",
            "--exclude=.obsidian/workspace-mobile.json",
            "--exclude=.obsidian/cache",
            "--exclude=.trash",
            "--exclude=node_modules",
            "-czf", outputURL.path,
            "-C", parent,
            leaf
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw KnowledgeBaseError.tarFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw KnowledgeBaseError.tarFailed(detail.isEmpty ? "tar exit code \(process.terminationStatus)" : detail)
        }

        let data: Data
        do {
            data = try Data(contentsOf: outputURL)
        } catch {
            throw KnowledgeBaseError.tarFailed(error.localizedDescription)
        }

        guard !data.isEmpty else {
            throw KnowledgeBaseError.folderEmpty(folder.path)
        }
        return data
    }

    // MARK: - Remote python bodies

    private var listBody: String {
        """

        try:
            home = resolved_hermes_home()
            kb_root = home / "knowledge"
            manifest_path = kb_root / ".knowledge.json"
            skill_path = home / "skills" / "knowledge-base" / "SKILL.md"

            vault = None
            if manifest_path.is_file():
                try:
                    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                except Exception:
                    manifest = {}

                vault = {
                    "id": manifest.get("name") or "knowledge",
                    "manifest": {
                        "name": manifest.get("name") or "knowledge",
                        "source": manifest.get("source"),
                        "last_synced_at": manifest.get("last_synced_at"),
                        "file_count": int(manifest.get("file_count") or 0),
                        "total_bytes": int(manifest.get("total_bytes") or 0),
                    },
                    "root_path": tilde(kb_root),
                    "exists": kb_root.is_dir(),
                }

            print(json.dumps({
                "ok": True,
                "vault": vault,
                "skill_installed": skill_path.is_file(),
            }, ensure_ascii=False))
        except Exception as exc:
            fail(f"Unable to read the remote knowledge base: {exc}")
        """
    }

    private var uploadBody: String {
        skillTemplateLiteral + """

        import datetime
        import shutil
        import tarfile
        import io

        try:
            home = resolved_hermes_home()
            home.mkdir(parents=True, exist_ok=True)

            kb_root = home / "knowledge"
            staging = home / "knowledge.staging"
            backup = home / "knowledge.old"

            archive_b64 = payload.get("archive_base64")
            if not isinstance(archive_b64, str) or not archive_b64:
                fail("The vault archive is missing.")

            try:
                archive_bytes = base64.b64decode(archive_b64)
            except Exception as exc:
                fail(f"The vault archive could not be decoded: {exc}")

            # Clear any half-finished previous attempts before extracting.
            if staging.exists():
                shutil.rmtree(staging, ignore_errors=True)
            if backup.exists():
                shutil.rmtree(backup, ignore_errors=True)
            staging.mkdir(parents=True, exist_ok=True)

            file_count = 0
            total_bytes = 0

            with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:gz") as tar:
                # Path-traversal hardening: reject members with an absolute
                # path, any '..' segment, or any link (symlink/hardlink)
                # before extraction. Symlinks would let a vault file
                # point at host files (/etc/passwd, ~/.ssh/...), and
                # the agent would happily `cat` them on the next
                # vault read. We only ship markdown — links have no
                # legitimate purpose in this payload.
                for member in tar.getmembers():
                    parts = pathlib.PurePosixPath(member.name).parts
                    if member.name.startswith("/") or ".." in parts:
                        fail(f"Vault archive contains an unsafe path: {member.name}")
                    if member.issym() or member.islnk():
                        fail(f"Vault archive contains a link, which is not allowed: {member.name} -> {member.linkname}")
                tar.extractall(staging)

            # Find the single top-level dir the local tar produced and flatten
            # it, so the on-disk layout is `$HERMES_HOME/knowledge/<files>`
            # rather than `$HERMES_HOME/knowledge/<vault-folder>/<files>`.
            entries = [item for item in staging.iterdir() if item.name not in {".DS_Store"}]
            if len(entries) == 1 and entries[0].is_dir():
                inner = entries[0]
                for child in inner.iterdir():
                    shutil.move(str(child), str(staging / child.name))
                inner.rmdir()

            # Walk the extracted vault to record stats and skip writing
            # anything outside the staging tree.
            for path in staging.rglob("*"):
                if path.is_file():
                    file_count += 1
                    try:
                        total_bytes += path.stat().st_size
                    except OSError:
                        pass

            if file_count == 0:
                shutil.rmtree(staging, ignore_errors=True)
                fail("The uploaded vault is empty.")

            now_iso = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
            manifest = {
                "name": payload.get("vault_name") or "knowledge",
                "source": payload.get("source_path"),
                "last_synced_at": now_iso,
                "file_count": file_count,
                "total_bytes": total_bytes,
            }
            (staging / ".knowledge.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )

            # Regenerate INDEX.md as a flat table of contents — the agent
            # reads this first, then opens individual files on demand.
            index_lines = [f"# {manifest['name']}", ""]
            display_source = manifest['source'] or "<unknown>"
            index_lines.append(f"_Synced from `{display_source}` at {manifest['last_synced_at']}._")
            index_lines.append("")
            index_lines.append("## Files")
            index_lines.append("")
            md_paths = sorted(
                str(p.relative_to(staging))
                for p in staging.rglob("*.md")
                if p.is_file() and p.name != "INDEX.md"
            )
            for rel in md_paths:
                index_lines.append(f"- [{rel}]({rel})")
            (staging / "INDEX.md").write_text("\\n".join(index_lines) + "\\n", encoding="utf-8")

            # Atomic-ish swap: move current → backup, staging → live, then drop
            # the backup. If the second move fails we restore the backup so the
            # agent never reads a half-vault.
            had_existing = kb_root.exists()
            if had_existing:
                kb_root.rename(backup)
            try:
                staging.rename(kb_root)
            except Exception:
                if had_existing and backup.exists():
                    backup.rename(kb_root)
                raise
            if backup.exists():
                shutil.rmtree(backup, ignore_errors=True)

            # Auto-install a tiny skill that points the agent at the vault.
            skill_dir = home / "skills" / "knowledge-base"
            skill_path = skill_dir / "SKILL.md"
            skill_dir.mkdir(parents=True, exist_ok=True)
            if not skill_path.is_file():
                skill_path.write_text(KNOWLEDGE_BASE_SKILL, encoding="utf-8")
                skill_installed_now = True
            else:
                skill_installed_now = skill_path.is_file()

            vault_summary = {
                "id": manifest["name"],
                "manifest": {
                    "name": manifest["name"],
                    "source": manifest["source"],
                    "last_synced_at": manifest["last_synced_at"],
                    "file_count": manifest["file_count"],
                    "total_bytes": manifest["total_bytes"],
                },
                "root_path": tilde(kb_root),
                "exists": True,
            }

            print(json.dumps({
                "ok": True,
                "vault": vault_summary,
                "skill_installed": bool(skill_installed_now),
            }, ensure_ascii=False))
        except SystemExit:
            raise
        except Exception as exc:
            shutil.rmtree(home / "knowledge.staging", ignore_errors=True)
            fail(f"Unable to install the knowledge base: {exc}")
        """
    }

    private var removeBody: String {
        """

        import shutil

        try:
            home = resolved_hermes_home()
            kb_root = home / "knowledge"
            if kb_root.exists():
                shutil.rmtree(kb_root, ignore_errors=True)

            print(json.dumps({"ok": True}, ensure_ascii=False))
        except Exception as exc:
            fail(f"Unable to remove the knowledge base: {exc}")
        """
    }

    /// Skill template injected once on the first sync. Lives at
    /// `$HERMES_HOME/skills/knowledge-base/SKILL.md` and tells the agent how
    /// to use the wiki — the same skill is reused across every host.
    private var skillTemplateLiteral: String {
        let template = #"""

        KNOWLEDGE_BASE_SKILL = """---
        name: knowledge-base
        description: Use the user-supplied knowledge base (their Obsidian vault) to ground answers in their own notes before falling back to general knowledge.
        ---

        # Knowledge Base

        The user has synced a personal wiki to this host. Use it as primary context for any topic the user is likely to have written about.

        ## Where it lives

        - Root: `$HERMES_HOME/knowledge/`
        - Index: `$HERMES_HOME/knowledge/INDEX.md` — read this first to see what topics exist.
        - Manifest: `$HERMES_HOME/knowledge/.knowledge.json` — name, source path, last sync time.

        ## How to use it

        1. **Start with INDEX.md** to learn the table of contents.
        2. **Search with ripgrep** for keywords across the vault:
           `rg -n -i "<query>" $HERMES_HOME/knowledge/`
        3. **Read whole files** before answering:
           `cat $HERMES_HOME/knowledge/<path>.md`
        4. **Cite the file you used** in `[[path/to/note.md]]` form so the user can jump to it.

        ## When to skip the knowledge base

        - The user explicitly says "ignore your wiki" or "answer from general knowledge."
        - The vault has nothing on the topic — say so before answering from general knowledge.
        """
        """#
        return template
    }
}

private struct EmptyRequest: Encodable {
    let hermesHome: String

    enum CodingKeys: String, CodingKey {
        case hermesHome = "hermes_home"
    }
}

private struct UploadRequest: Encodable {
    let hermesHome: String
    let vaultName: String
    let sourcePath: String
    let archiveBase64: String

    enum CodingKeys: String, CodingKey {
        case hermesHome = "hermes_home"
        case vaultName = "vault_name"
        case sourcePath = "source_path"
        case archiveBase64 = "archive_base64"
    }
}
