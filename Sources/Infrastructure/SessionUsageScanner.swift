import Domain
import Foundation

/// Streams Claude and Codex JSONL transcripts without loading multi-GB files.
///
/// Codex rollouts on a busy machine are often several gigabytes. Materialising
/// those as `String` hangs the Usage page; a line-at-a-time read with a cheap
/// substring gate matches how T3 Code scans the same logs. Unchanged files are
/// reused from `usage-cache.json` keyed by size and mtime.
public struct SessionUsageScanner: Sendable {
    public static let cacheVersion = 1
    public static let window: TimeInterval = 90 * 86_400
    public static let maxClaudeLineBytes = 1_048_576
    public static let maxCodexLineBytes = 32_768

    public init() {}

    public func load(cacheURL: URL) -> UsageSummary? {
        guard let document = Self.readCache(cacheURL), document.version == Self.cacheVersion else { return nil }
        let events = document.files.values.flatMap(\.events)
        guard !events.isEmpty else { return nil }
        return UsageSummary(events: events)
    }

    public func scan(accounts: [Account], cacheURL: URL? = nil, now: Date = Date()) -> UsageSummary {
        var cache = cacheURL.flatMap { Self.readCache($0) } ?? UsageScanCacheDocument()
        var changed = cache.version != Self.cacheVersion
        if changed {
            cache = UsageScanCacheDocument()
        }
        let since = now.addingTimeInterval(-Self.window)
        var events: [UsageEvent] = []
        var keep = Set<String>()
        for account in accounts {
            if account.provider == .cursor {
                let key = "cursor://events/\(account.id.uuidString)"
                keep.insert(key)
                if let cached = cache.files[key],
                   now.timeIntervalSince1970 - cached.mtime < 1_800
                {
                    events.append(contentsOf: cached.events)
                    continue
                }
                let parsed = CursorQuotaProbe().usageEvents(
                    account: account,
                    environment: spawnEnvironment(for: account),
                    since: since,
                    now: now
                )
                changed = true
                cache.files[key] = UsageCachedFile(
                    size: parsed.count,
                    mtime: now.timeIntervalSince1970,
                    events: parsed
                )
                events.append(contentsOf: parsed)
                continue
            }
            let files = transcriptFiles(for: account, since: since)
            for file in files {
                keep.insert(file.path)
                if let cached = cache.files[file.path],
                   cached.size == file.size,
                   abs(cached.mtime - file.mtime) < 0.001,
                   cached.events.allSatisfy({ $0.accountID == account.id })
                {
                    events.append(contentsOf: cached.events)
                    continue
                }
                let parsed = parseFile(file, account: account)
                changed = true
                cache.files[file.path] = UsageCachedFile(size: file.size, mtime: file.mtime, events: parsed)
                events.append(contentsOf: parsed)
            }
        }
        if cache.files.keys.contains(where: { !keep.contains($0) }) {
            cache.files = cache.files.filter { keep.contains($0.key) }
            changed = true
        }
        if changed, let cacheURL {
            try? AtomicJSONFile(fileURL: cacheURL).write(cache, pretty: false)
        }
        return UsageSummary(events: events)
    }

    public func scan(account: Account) -> [UsageEvent] {
        scan(accounts: [account]).events.filter { $0.accountID == account.id }
    }

    public static func parseClaudeLine(_ line: String, account: Account, sessionID: String) -> UsageEvent? {
        guard let json = decode(line),
              json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }
        let model = message["model"] as? String ?? ""
        guard !model.isEmpty else { return nil }
        guard let date = QuotaReset.isoDate(json["timestamp"] as? String ?? "") else { return nil }
        let uncached = QuotaReset.double(usage["input_tokens"]) ?? 0
        let cached = QuotaReset.double(usage["cache_read_input_tokens"]) ?? 0
        let write = QuotaReset.double(usage["cache_creation_input_tokens"]) ?? 0
        let output = QuotaReset.double(usage["output_tokens"]) ?? 0
        guard uncached + cached + write + output > 0 else { return nil }
        let messageID = message["id"] as? String
        let requestID = json["requestId"] as? String
        let dedupeKey: String?
        if messageID == nil, requestID == nil {
            dedupeKey = nil
        } else {
            dedupeKey = "\(messageID ?? ""):\(requestID ?? "")"
        }
        return UsageEvent(
            date: date,
            provider: .claude,
            accountID: account.id,
            sessionID: (json["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sessionID,
            model: model,
            uncachedInput: uncached,
            cachedInput: cached,
            cacheWrite: write,
            output: output,
            dedupeKey: dedupeKey
        )
    }

    public static func consumeCodexLine(
        _ line: String,
        account: Account,
        state: inout CodexFileState
    ) -> UsageEvent? {
        guard let json = decode(line) else { return nil }
        let type = json["type"] as? String
        let payload = json["payload"] as? [String: Any] ?? [:]
        if type == "session_meta" {
            if state.sawSessionMeta { return nil }
            state.sawSessionMeta = true
            if let id = payload["id"] as? String ?? payload["session_id"] as? String, !id.isEmpty {
                state.sessionID = id
            }
            if isForkedSessionMeta(payload), let date = QuotaReset.isoDate(json["timestamp"] as? String ?? "") {
                state.suppressingForkCopies = true
                state.forkCopyAnchor = date
            }
            return nil
        }
        if type == "turn_context", let payloadModel = payload["model"] as? String, !payloadModel.isEmpty {
            state.model = payloadModel
            return nil
        }
        guard payload["type"] as? String == "token_count" else { return nil }
        let info = payload["info"] as? [String: Any] ?? [:]
        let usage = info["last_token_usage"] as? [String: Any] ?? [:]
        guard !state.model.isEmpty else { return nil }
        guard let date = QuotaReset.isoDate(json["timestamp"] as? String ?? "") else { return nil }
        let input = QuotaReset.double(usage["input_tokens"]) ?? 0
        let cached = QuotaReset.double(usage["cached_input_tokens"]) ?? 0
        let write = QuotaReset.double(usage["cache_write_input_tokens"]) ?? 0
        let output = QuotaReset.double(usage["output_tokens"]) ?? 0
        let uncached = max(0, input - cached - write)
        guard uncached + cached + write + output > 0 else { return nil }
        let signature = "\(input)|\(cached)|\(write)|\(output)"
        if signature == state.lastSignature { return nil }
        state.lastSignature = signature
        if state.suppressingForkCopies {
            if let anchor = state.forkCopyAnchor, date.timeIntervalSince(anchor) < 1 {
                state.forkCopyAnchor = date
                return nil
            }
            state.suppressingForkCopies = false
        }
        return UsageEvent(
            date: date,
            provider: .codex,
            accountID: account.id,
            sessionID: state.sessionID,
            model: state.model,
            uncachedInput: uncached,
            cachedInput: cached,
            cacheWrite: write,
            output: output
        )
    }

    public struct CodexFileState: Sendable {
        public var model: String
        public var sessionID: String
        public var lastSignature: String?
        public var sawSessionMeta = false
        public var suppressingForkCopies = false
        public var forkCopyAnchor: Date?

        public init(model: String = "", sessionID: String = "") {
            self.model = model
            self.sessionID = sessionID
        }
    }

    private func parseFile(_ file: TranscriptFile, account: Account) -> [UsageEvent] {
        switch account.provider {
        case .claude:
            return parseClaudeFile(file.url, account: account)
        case .codex:
            return parseCodexFile(file.url, account: account)
        case .cursor, .opencode:
            return []
        }
    }

    private func parseClaudeFile(_ url: URL, account: Account) -> [UsageEvent] {
        let fallbackID = url.deletingPathExtension().lastPathComponent
        var events: [UsageEvent] = []
        var seen = Set<String>()
        autoreleasepool {
            forEachLine(in: url, maxLineBytes: Self.maxClaudeLineBytes) { line in
                guard line.range(of: Self.usageNeedle) != nil,
                      let text = String(data: line, encoding: .utf8),
                      let event = Self.parseClaudeLine(text, account: account, sessionID: fallbackID)
                else { return }
                if let key = event.dedupeKey {
                    if seen.contains(key) { return }
                    seen.insert(key)
                }
                events.append(event)
            }
        }
        return events
    }

    private func parseCodexFile(_ url: URL, account: Account) -> [UsageEvent] {
        let fallbackID = url.deletingPathExtension().lastPathComponent
        var state = CodexFileState(sessionID: fallbackID)
        var events: [UsageEvent] = []
        autoreleasepool {
            forEachLine(in: url, maxLineBytes: Self.maxCodexLineBytes) { line in
                guard line.range(of: Self.tokenCountNeedle) != nil
                    || line.range(of: Self.turnContextNeedle) != nil
                    || line.range(of: Self.sessionMetaNeedle) != nil
                else { return }
                guard let text = String(data: line, encoding: .utf8) else { return }
                if let event = Self.consumeCodexLine(text, account: account, state: &state) {
                    events.append(event)
                }
            }
        }
        return events
    }

    private func transcriptFiles(for account: Account, since: Date) -> [TranscriptFile] {
        switch account.provider {
        case .claude:
            return jsonlFiles(under: URL(fileURLWithPath: account.homePath).appendingPathComponent("projects"), since: since)
        case .codex:
            let home = URL(fileURLWithPath: account.homePath)
            return jsonlFiles(under: home.appendingPathComponent("sessions"), since: since)
                + jsonlFiles(under: home.appendingPathComponent("archived_sessions"), since: since)
        case .cursor, .opencode:
            return []
        }
    }

    private func jsonlFiles(under root: URL, since: Date) -> [TranscriptFile] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        guard let enumerator else { return [] }
        var files: [TranscriptFile] = []
        let sinceInterval = since.timeIntervalSince1970
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            ])
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension == "jsonl", values?.isRegularFile == true else { continue }
            let mtime = values?.contentModificationDate ?? Date.distantPast
            guard mtime.timeIntervalSince1970 >= sinceInterval else { continue }
            files.append(
                TranscriptFile(
                    url: url,
                    path: url.path,
                    size: values?.fileSize ?? 0,
                    mtime: mtime.timeIntervalSince1970
                )
            )
        }
        return files
    }

    private func spawnEnvironment(for account: Account) -> [String: String] {
        IsolationEngine().spawnEnvironment(for: account)
    }

    private func forEachLine(in url: URL, maxLineBytes: Int, body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(min(maxLineBytes, 64 * 1024))
        var skipping = false
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            } catch {
                break
            }
            if chunk.isEmpty { break }
            var slice = chunk[...]
            if skipping {
                guard let newline = slice.firstIndex(of: 0x0A) else { continue }
                skipping = false
                slice = slice[(slice.index(after: newline))...]
            }
            if !slice.isEmpty {
                buffer.append(contentsOf: slice)
            }
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                if newline - start <= maxLineBytes {
                    body(Data(buffer[start..<newline]))
                }
                start = buffer.index(after: newline)
            }
            if start != buffer.startIndex { buffer.removeSubrange(..<start) }
            if buffer.count > maxLineBytes {
                skipping = true
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !skipping, !buffer.isEmpty, buffer.count <= maxLineBytes {
            body(buffer)
        }
    }

    private static func decode(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func isForkedSessionMeta(_ payload: [String: Any]) -> Bool {
        if payload["forked_from_id"] is String { return true }
        let source = payload["source"] as? [String: Any] ?? [:]
        let subagent = source["subagent"] as? [String: Any] ?? [:]
        let spawn = subagent["thread_spawn"] as? [String: Any] ?? [:]
        return spawn["parent_thread_id"] is String
    }

    private static func readCache(_ url: URL) -> UsageScanCacheDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? AtomicJSONFile(fileURL: url).read(UsageScanCacheDocument.self)
    }

    private static let usageNeedle = Data("\"usage\"".utf8)
    private static let tokenCountNeedle = Data("token_count".utf8)
    private static let turnContextNeedle = Data("turn_context".utf8)
    private static let sessionMetaNeedle = Data("session_meta".utf8)
}

private struct TranscriptFile {
    var url: URL
    var path: String
    var size: Int
    var mtime: TimeInterval
}

private struct UsageScanCacheDocument: Codable {
    var version: Int
    var files: [String: UsageCachedFile]

    init(version: Int = SessionUsageScanner.cacheVersion, files: [String: UsageCachedFile] = [:]) {
        self.version = version
        self.files = files
    }
}

private struct UsageCachedFile: Codable {
    var size: Int
    var mtime: TimeInterval
    var events: [UsageEvent]
}
