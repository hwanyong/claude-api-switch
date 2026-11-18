import Foundation

struct SettingsFailure: Error { let message: String }

/// Read-modify-write of ~/.claude/settings.json "env" block.
/// Never touches any other key. Backups + atomic replace + verify + rollback.
final class SettingsEditor {
    let path: String

    init(path: String = Paths.settings) { self.path = path }

    // MARK: locking

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        ensureDir(Paths.claudeDir)
        let fd = open(Paths.lockFile, O_CREAT | O_RDWR, 0o600)
        if fd < 0 { throw SettingsFailure(message: "cannot open lock file") }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return try body()
    }

    // MARK: read

    func readDoc() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else {
            return [:]
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw SettingsFailure(message: "cannot read \(path)")
        }
        // Empty file tolerated; malformed JSON is refused (no writes ever).
        if String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let doc = obj as? [String: Any] else {
            throw SettingsFailure(message: "settings.json is not valid JSON — refusing to modify")
        }
        return doc
    }

    func currentEnv() -> [String: String] {
        guard let doc = try? readDoc(), let env = doc["env"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in env { if let s = v as? String { out[k] = s } }
        return out
    }

    // MARK: backups

    func listBackups() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: Paths.backups) else { return [] }
        return files.filter { $0.hasSuffix(".json") }.sorted(by: >)
    }

    @discardableResult
    private func backupCurrent(tag: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        ensureDir(Paths.backups)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        let dest = Paths.backups + "/" + df.string(from: Date()) + "-" + tag + ".json"
        try? data.write(to: URL(fileURLWithPath: dest), options: .atomic)
        // keep newest 20
        let all = listBackups()
        for old in all.dropFirst(20) {
            try? FileManager.default.removeItem(atPath: Paths.backups + "/" + old)
        }
        return dest
    }

    // MARK: write

    /// Apply env changes: set dict entries and remove a key set.
    /// Returns backup path (if any). Throws on any failure; original file untouched in that case.
    @discardableResult
    func apply(set: [String: String], remove: [String], tag: String,
               maxRetries: Int = 3) throws -> String? {
        try withLock {
            for attempt in 0..<maxRetries {
                let doc = try readDoc()
                let beforeMTime = fileMTime(path)

                var env = (doc["env"] as? [String: Any]) ?? [:]
                for k in remove { env.removeValue(forKey: k) }
                for (k, v) in set { env[k] = v }

                var newDoc = doc
                if env.isEmpty {
                    newDoc.removeValue(forKey: "env")
                } else {
                    newDoc["env"] = env
                }

                // Re-check: Claude Code may have written the file between read and write.
                if let before = beforeMTime, let now = fileMTime(path), now != before, attempt + 1 < maxRetries {
                    Thread.sleep(forTimeInterval: 0.3)
                    continue
                }

                let backup = backupCurrent(tag: tag)
                if !jsonWrite(path, newDoc) {
                    throw SettingsFailure(message: "atomic write failed")
                }

                // Verify read-back.
                let check = try readDoc()
                let envCheck = (check["env"] as? [String: Any]) ?? [:]
                for (k, v) in set {
                    if envCheck[k] as? String != v {
                        if let b = backup { try? FileManager.default.removeItem(atPath: path)
                            try? FileManager.default.copyItem(atPath: b, toPath: path) }
                        throw SettingsFailure(message: "verification failed after write (rolled back)")
                    }
                }
                for k in remove {
                    if envCheck[k] != nil {
                        if let b = backup { try? FileManager.default.removeItem(atPath: path)
                            try? FileManager.default.copyItem(atPath: b, toPath: path) }
                        throw SettingsFailure(message: "verification failed after write (rolled back)")
                    }
                }
                return backup
            }
            throw SettingsFailure(message: "settings.json kept changing during write; aborted")
        }
    }

    /// Restore a specific backup file (backing up current state first).
    @discardableResult
    func restore(backupFile: String) throws -> String {
        try withLock {
            guard let data = FileManager.default.contents(atPath: backupFile),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw SettingsFailure(message: "backup is missing or not valid JSON")
            }
            guard let cur = backupCurrent(tag: "pre-restore") else {
                throw SettingsFailure(message: "cannot read current settings")
            }
            if !jsonWrite(path, try JSONSerialization.jsonObject(with: data)) {
                try? FileManager.default.copyItem(atPath: cur, toPath: path)
                throw SettingsFailure(message: "restore write failed")
            }
            return cur
        }
    }
}
