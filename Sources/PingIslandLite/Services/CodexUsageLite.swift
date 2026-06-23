import Foundation

struct CodexUsageLiteSnapshot: Equatable {
    let sourceFilePath: String
    let capturedAt: Date?
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let lastTurnTokens: Int?
    let planType: String?
    let limitID: String?

    var compactSummary: String {
        let total = Self.compactNumber(totalTokens)
        let last = lastTurnTokens.map { " · last \(Self.compactNumber($0))" } ?? ""
        let plan = planType.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
        return "Codex usage \(total) tokens\(last)\(plan)"
    }

    private static func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

enum CodexUsageLiteLoader {
    static let defaultRootURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    static func load(
        rootURL: URL = defaultRootURL,
        fileManager: FileManager = .default,
        scanLimit: Int = 16,
        maxBytesPerFile: Int = 512 * 1024
    ) -> CodexUsageLiteSnapshot? {
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        let candidates: [URL] = enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return url
        }
        .sorted {
            let lhs = ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
            let rhs = ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        .prefix(scanLimit)
        .map { $0 }

        for url in candidates {
            if let snapshot = loadSnapshot(from: url, maxBytes: maxBytesPerFile) {
                return snapshot
            }
        }
        return nil
    }

    private static func loadSnapshot(from url: URL, maxBytes: Int) -> CodexUsageLiteSnapshot? {
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty else { return nil }
        let suffix = data.count > maxBytes ? data.suffix(maxBytes) : data[...]
        guard let text = String(data: Data(suffix), encoding: .utf8) else { return nil }

        var best: CodexUsageLiteSnapshot?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("\"token_count\""),
                  let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totalUsage = info["total_token_usage"] as? [String: Any] else {
                continue
            }

            let timestamp = (object["timestamp"] as? String).flatMap(Self.parseDate)
            let rateLimits = payload["rate_limits"] as? [String: Any]
            best = CodexUsageLiteSnapshot(
                sourceFilePath: url.path,
                capturedAt: timestamp,
                totalTokens: int(totalUsage["total_tokens"]) ?? 0,
                inputTokens: int(totalUsage["input_tokens"]) ?? 0,
                outputTokens: int(totalUsage["output_tokens"]) ?? 0,
                lastTurnTokens: (info["last_token_usage"] as? [String: Any]).flatMap { int($0["total_tokens"]) },
                planType: rateLimits?["plan_type"] as? String,
                limitID: rateLimits?["limit_id"] as? String
            )
            break
        }
        return best
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
