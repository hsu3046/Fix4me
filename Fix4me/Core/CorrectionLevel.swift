import Foundation

/// 교정 강도. 설정에서 하나를 고르고 단축키(⌃⌥F)는 항상 그 강도로 동작한다.
enum CorrectionLevel: String, CaseIterable, Identifiable, Sendable {
    case proofread   // 틀린 것만
    case polish      // 틀린 것 + 어색한 표현
    case rewrite     // 구조까지 다시 씀

    var id: String { rawValue }

    // MARK: - 저장 (UserDefaults)

    static let defaultsKey = "correctionLevel"

    /// 저장된 값이 없거나 알 수 없는 값이면 가장 보수적인 교정
    static var current: CorrectionLevel { load() }

    static func load(from defaults: UserDefaults = .standard) -> CorrectionLevel {
        defaults.string(forKey: defaultsKey).flatMap(CorrectionLevel.init(rawValue:)) ?? .proofread
    }

    static func save(_ level: CorrectionLevel, to defaults: UserDefaults = .standard) {
        defaults.set(level.rawValue, forKey: defaultsKey)
    }

    // MARK: - 화면 문구

    var title: String {
        switch self {
        case .proofread: "교정"
        case .polish: "다듬기"
        case .rewrite: "다시 쓰기"
        }
    }

    /// HUD 진행 문구
    var workingTitle: String {
        switch self {
        case .proofread: "교정 중…"
        case .polish: "다듬는 중…"
        case .rewrite: "다시 쓰는 중…"
        }
    }

    var summary: String {
        switch self {
        case .proofread: "맞춤법·문법·오타·띄어쓰기만 고쳐요. 맞는 문장은 그대로 둬요."
        case .polish: "틀린 곳에 더해 어색한 어순·단어·군더더기·번역투를 자연스럽게 고쳐요. 의미와 말투는 유지해요."
        case .rewrite: "문장 구조를 바꿔서라도 더 명확하고 매끄럽게 다시 써요. 내용과 말투는 유지해요."
        }
    }

    var example: String {
        switch self {
        case .proofread: "I has a apple → I have an apple"
        case .polish: "역할에 대해서 확인을 하는 것이 필요하다고 생각되어집니다 → 역할을 확인할 필요가 있다고 생각합니다"
        case .rewrite: "It was a very successful beta test → The beta test was a great success"
        }
    }

    // MARK: - LLM 지시

    /// 시스템 프롬프트의 "무엇을 고칠지" 부분. 공통 규칙(언어·말투·형식 유지, JSON)은 OpenRouterClient 가 붙인다.
    var instructions: String {
        switch self {
        case .proofread:
            """
            Fix every error: spelling, typos, grammar, wrong tense or word form, missing articles, \
            capitalization (e.g. a lowercase "i" or sentence start), punctuation errors, particles, \
            Korean spacing (띄어쓰기), honorific errors, and ungrammatical or incomplete phrases \
            (fix those with the smallest natural change). \
            Do not rephrase text that is already correct.
            """
        case .polish:
            """
            Fix all errors (spelling, typos, grammar, particles, Korean spacing (띄어쓰기), honorifics). \
            Then actively improve phrasing even where it is already grammatical, the way a native copy editor \
            would: prefer the clearer word order (e.g. put the real topic first as the subject), the more precise \
            or natural word, and cut filler and wordiness. Remove translationese and stiff constructions such as \
            Korean "~에 있어서", "~에 대해서", double passives like "~되어지다", and Japanese filler like \
            「〜の方」「〜という形になります」. Make politeness levels consistent. \
            Keep the meaning, all information, the tone and register, and keep each sentence a sentence \
            (do not merge or split them).
            """
        case .rewrite:
            """
            Rewrite it as a skilled native editor would to make it as clear, concise and natural as possible. \
            Do everything a copy edit does, and go further: restructure sentences, merge or split them, reorder \
            clauses and points so the main message comes first, and replace weak or vague wording with strong, \
            specific wording. Keep all information, the meaning, the language and the tone/register. \
            Do not add new facts, greetings or commentary.
            """
        }
    }

    /// "대답·번역" 같은 이상 응답을 거르는 길이 범위. 강도가 높을수록 정상 결과의 길이 변화가 크다.
    /// shortDelta: 원문 20자 미만일 때 허용하는 글자 수 차이, ratio: 그 이상일 때 허용하는 길이 비율.
    var lengthBounds: (shortDelta: Int, ratio: ClosedRange<Double>) {
        switch self {
        case .proofread: (12, 0.6...1.5)
        case .polish: (20, 0.5...1.7)
        case .rewrite: (30, 0.35...2.2)
        }
    }
}
