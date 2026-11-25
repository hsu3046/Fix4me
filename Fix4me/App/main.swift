// Fix4me — 포커스된 입력창을 단축키 한 번으로 교정하는 메뉴 막대 앱
// Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0
import AppKit

// 개발용: `Fix4me --compare "문장" [--before "앞 문맥"] [--after "뒤 문맥"] [--dict "단어,단어"]` → 세 교정 강도의 결과를 출력하고 종료.
// 키는 앱의 키체인 항목에서 읽고 출력하지 않는다 (같은 서명의 바이너리라 키체인 확인 창 없음).
if let i = CommandLine.arguments.firstIndex(of: "--compare"), i + 1 < CommandLine.arguments.count {
    let text = CommandLine.arguments[i + 1]
    let args = CommandLine.arguments
    let option = { (name: String) -> String in
        guard let j = args.firstIndex(of: name), j + 1 < args.count else { return "" }
        return args[j + 1]
    }
    let before = option("--before"), after = option("--after")
    let dictionary = option("--dict").split(separator: ",").map(String.init)
    Task {
        guard let key = Keychain.read(Keychain.openRouterAccount) else {
            print("키체인에 OpenRouter 키가 없어요")
            exit(1)
        }
        print("원문      | \(text)")
        for level in CorrectionLevel.allCases {
            let started = ContinuousClock.now
            do {
                let result = try await OpenRouterClient(apiKey: key).correct(text, level: level, before: before, after: after, dictionary: dictionary)
                let ms = (ContinuousClock.now - started).components
                print(String(format: "%@ %.2fs | %@", level.title.padding(toLength: 5, withPad: "　", startingAt: 0),
                             Double(ms.seconds) + Double(ms.attoseconds) / 1e18, result))
            } catch {
                print("\(level.title) | 오류: \(error.localizedDescription)")
            }
        }
        exit(0)
    }
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)   // Dock 에 표시 (메뉴 막대 아이콘은 노치·정리 앱에 가려질 수 있다)
app.run()
