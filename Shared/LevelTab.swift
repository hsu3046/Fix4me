import Foundation

/// 교정 강도 탭: 끄기 + 강도 셋. 껐다 켜도 마지막 강도를 기억한다.
enum LevelTab: Hashable, Sendable {
    case off
    case level(CorrectionLevel)

    static let all: [LevelTab] = [.off] + CorrectionLevel.allCases.map(LevelTab.level)

    var level: CorrectionLevel? { if case let .level(l) = self { l } else { nil } }
    var title: String { level?.title ?? "끄기" }
    var summary: String { level?.summary ?? "아무것도 보내지 않고 고치지도 않아요" }

    static var current: LevelTab { load() }

    static func load(from store: any SettingsStore = SharedStore.store) -> LevelTab {
        SharedStore.isOn(in: store) ? .level(.load(from: store)) : .off
    }

    @discardableResult
    func save(to store: any SettingsStore = SharedStore.store) -> Bool {
        guard let level else { return SharedStore.saveOn(false, to: store) }
        let saved = CorrectionLevel.save(level, to: store)
        return SharedStore.saveOn(true, to: store) && saved
    }
}
