import Foundation

/// 개발용 명령줄. 키는 앱의 키체인에서 읽고 출력하지 않는다.
///   --sections 파일                         LLM 없이 섹션 경계만 출력
///   --compare "글" [--before ..] [--after ..] [--dict "단어,단어"] [--level rewrite]
///   --evaluate 파일 [--level ..] [--repeat 3]     정해 둔 글로 채점
///   --evaluate-history [--repeat 1]          기록에서 거절한 교정이 또 나오는지 (기록의 글을 OpenRouter 로 다시 보낸다)
@MainActor
enum DevCommands {
    private static let args = CommandLine.arguments

    /// 개발용 명령이면 실행하고 돌아오지 않는다. 아니면 그냥 돌아온다.
    static func runIfRequested() {
        if let path = option("--sections") { sections(path); exit(0) }
        let job: (() async -> Int32)?
        if let text = option("--compare") { job = { await compare(text) } }
        else if let path = option("--evaluate") { job = { await evaluate(path) } }
        else if args.contains("--evaluate-history") { job = { await evaluateHistory() } }
        else { job = nil }
        guard let job else { return }
        Task { exit(await job()) }
        dispatchMain()
    }

    private static func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static var levels: [CorrectionLevel] {
        option("--level").flatMap(CorrectionLevel.init(rawValue:)).map { [$0] } ?? CorrectionLevel.allCases
    }

    private static func client() -> OpenRouterClient? {
        guard let key = Keychain.read(Keychain.openRouterAccount) else {
            print("키체인에 OpenRouter 키가 없어요")
            return nil
        }
        return OpenRouterClient(apiKey: key)
    }

    private static func run(
        _ client: OpenRouterClient, _ text: String, _ level: CorrectionLevel,
        before: String = "", after: String = "", dictionary: [String] = []
    ) async throws -> (text: String, seconds: Double) {
        let started = ContinuousClock.now
        let result = try await CorrectionPipeline.run(text, level: level) { input, stage in
            try await client.correct(input, level: stage, before: before, after: after, dictionary: dictionary)
        }
        let c = (ContinuousClock.now - started).components
        return (result, Double(c.seconds) + Double(c.attoseconds) / 1e18)
    }

    // MARK: - 명령

    private static func sections(_ path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return print("파일을 읽지 못했어요") }
        let ns = text as NSString
        for block in Sectioner.blocks(in: text) {
            let head = ns.substring(with: block.range).prefix(40).replacingOccurrences(of: "\n", with: "⏎")
            print("[\(block.boundary) \(block.kind)\(block.kind.isProtected ? " 보호" : "")] \(head)")
        }
        for level in CorrectionLevel.allCases { print("== \(level.title): \(Sectioner.units(in: text, level: level).map(\.length))") }
    }

    private static func compare(_ text: String) async -> Int32 {
        guard let client = client() else { return 1 }
        let dictionary = (option("--dict") ?? "").split(separator: ",").map(String.init)
        print("원문      | \(text)")
        for level in levels {
            do {
                let r = try await run(client, text, level, before: option("--before") ?? "", after: option("--after") ?? "", dictionary: dictionary)
                print(String(format: "%@ %.2fs | %@", level.title.padding(toLength: 5, withPad: "　", startingAt: 0), r.seconds, r.text))
            } catch { print("\(level.title) | 오류: \(error.localizedDescription)") }
        }
        return 0
    }

    private static func evaluate(_ path: String) async -> Int32 {
        guard let client = client() else { return 1 }
        let cases: [EvalCase]
        do { cases = try EvalCase.load(Data(contentsOf: URL(fileURLWithPath: path))) }
        catch { print("채점 파일을 읽지 못했어요: \(error.localizedDescription)"); return 1 }
        for c in cases { if let p = c.problem { print("\(c.id): \(p)"); return 1 } }
        let times = max(1, Int(option("--repeat") ?? "1") ?? 1)

        for level in levels {
            var pass = 0, fail = 0, errors = 0, seconds: [Double] = []
            for c in cases where c.runs(at: level) {
                for _ in 0..<times {
                    do {
                        let r = try await run(client, c.text, level)
                        seconds.append(r.seconds)
                        if let why = c.failure(r.text) {
                            fail += 1
                            print("✗ \(level.title) \(c.id) — \(why)\n    \(r.text.replacingOccurrences(of: "\n", with: "⏎"))")
                        } else { pass += 1 }
                    } catch {
                        errors += 1
                        print("! \(level.title) \(c.id) — \(error.localizedDescription)")
                    }
                }
            }
            let sorted = seconds.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            print(String(format: "== %@: 통과 %d, 실패 %d, 오류 %d · 중앙값 %.2f초, 최대 %.2f초", level.title, pass, fail, errors, median, sorted.last ?? 0))
        }
        return 0
    }

    private static func evaluateHistory() async -> Int32 {
        guard let client = client() else { return 1 }
        let times = max(1, Int(option("--repeat") ?? "1") ?? 1)
        let rejected = HistoryStore().entries().filter { $0.outcome.isRejected }.suffix(50)
        guard !rejected.isEmpty else { print("되돌리거나 무시한 기록이 없어요"); return 0 }
        var again = 0, changed = 0, errors = 0
        for e in rejected {
            guard let level = CorrectionLevel(rawValue: e.level) else { continue }
            for _ in 0..<times {
                do {
                    let r = try await run(client, e.original, level, dictionary: Prefs.dictionary)
                    if r.text == e.corrected { again += 1 } else { changed += 1 }
                } catch { errors += 1 }
            }
        }
        print("거절한 교정 \(rejected.count)건 × \(times): 같은 결과가 또 나옴 \(again), 달라짐 \(changed), 오류 \(errors)")
        return 0
    }
}
