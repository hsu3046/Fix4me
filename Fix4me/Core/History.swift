import Foundation

/// 교정 1건의 기록
struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case applied, ignored, reverted

        /// 사용자가 받아들이지 않은 결과인지
        var isRejected: Bool { self != .applied }

        var title: String {
            switch self {
            case .applied: "적용"
            case .ignored: "무시"
            case .reverted: "되돌림"
            }
        }
    }

    let id: UUID
    let date: Date
    let app: String
    let level: String
    let original: String
    let corrected: String
    var outcome: Outcome
}

/// 기록 파일의 형식 (한 줄에 사건 하나, 뒤에만 덧붙임). 순수 함수.
enum HistoryLog {
    static let retentionDays = 30

    /// 새 기록이거나, 이미 있는 기록의 결과 변경(되돌림)
    private struct Event: Codable {
        var entry: HistoryEntry?
        var id: UUID?
        var outcome: HistoryEntry.Outcome?
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func line(_ entry: HistoryEntry) throws -> Data { try encoder().encode(Event(entry: entry)) + [0x0A] }

    static func line(id: UUID, outcome: HistoryEntry.Outcome) throws -> Data {
        try encoder().encode(Event(id: id, outcome: outcome)) + [0x0A]
    }

    /// 깨진 줄(쓰다 만 줄 등)은 건너뛴다. 줄은 LF 로만 나눈다 (글 속의 다른 줄바꿈 문자를 경계로 보지 않도록).
    static func parse(_ data: Data) -> [HistoryEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [HistoryEntry] = [], index: [UUID: Int] = [:]
        for raw in data.split(separator: 0x0A) {
            guard let event = try? decoder.decode(Event.self, from: Data(raw)) else { continue }
            if let entry = event.entry {
                if let i = index[entry.id] { entries[i] = entry; continue }
                index[entry.id] = entries.count
                entries.append(entry)
            } else if let id = event.id, let outcome = event.outcome, let i = index[id] {
                entries[i].outcome = outcome
            }
        }
        return entries
    }

    static func pruned(_ entries: [HistoryEntry], now: Date) -> [HistoryEntry] {
        let limit = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return entries.filter { $0.date >= limit }
    }
}

/// 이 Mac 에만 저장하는 교정 기록. 설정에서 켠 동안만 쓴다 (기본 꺼짐).
@MainActor
final class HistoryStore {
    let url: URL
    /// 저장 실패를 화면에 알리기 위한 마지막 오류
    private(set) var lastError: String?

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Fix4me/history.jsonl")
    }

    func entries() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return HistoryLog.pruned(HistoryLog.parse(data), now: .now)
    }

    /// 켜져 있고, 제외한 앱이 아니고, 키처럼 보이는 글이 아닐 때만 저장한다. 저장했으면 id.
    func record(
        original: String, corrected: String, level: CorrectionLevel, app: String, outcome: HistoryEntry.Outcome,
        enabled: Bool = Prefs.history, excluded: [String] = Prefs.excluded
    ) -> UUID? {
        guard enabled, original != corrected, !excluded.contains(app),
              !PrecomputeFilter.looksSecret(original), !PrecomputeFilter.looksSecret(corrected) else { return nil }
        let entry = HistoryEntry(
            id: UUID(), date: .now, app: app, level: level.rawValue,
            original: original, corrected: corrected, outcome: outcome
        )
        return append { try HistoryLog.line(entry) } ? entry.id : nil
    }

    func update(_ ids: [UUID], outcome: HistoryEntry.Outcome) {
        for id in ids { _ = append { try HistoryLog.line(id: id, outcome: outcome) } }
    }

    func delete(_ id: UUID) { rewrite(entries().filter { $0.id != id }) }

    func deleteAll() {
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    /// 보관 기간이 지난 기록을 파일에서도 지운다 (시작할 때 한 번)
    func prune() {
        guard let data = try? Data(contentsOf: url) else { return }
        let all = HistoryLog.parse(data), kept = HistoryLog.pruned(all, now: .now)
        if kept.count != all.count { rewrite(kept) }
    }

    private func append(_ make: () throws -> Data) -> Bool {
        do {
            let data = try make()
            try prepareFile()
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func rewrite(_ entries: [HistoryEntry]) {
        do {
            let data = try entries.reduce(into: Data()) { $0 += try HistoryLog.line($1) }
            try prepareFile()
            try data.write(to: url, options: .atomic)
            try protect()
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    /// 나만 읽을 수 있는 폴더(700)·파일(600)
    private func prepareFile() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            try protect()
        }
    }

    private func protect() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
