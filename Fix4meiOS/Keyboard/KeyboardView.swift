import SwiftUI

struct KeyboardView: View {
    @Bindable var model: KeyboardModel

    var body: some View {
        VStack(spacing: 10) {
            Picker("교정 강도", selection: $model.level) {
                ForEach(CorrectionLevel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(isBlocked)

            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            buttons
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var isBlocked: Bool { model.state == .needsFullAccess || model.state == .needsKey }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .needsFullAccess:
            notice("lock", "전체 접근 허용이 필요해요", "설정 → Fix4me → 키보드에서 켜 주세요. 교정하려면 인터넷을 써야 해요.")
        case .needsKey:
            notice("key", "OpenRouter 키가 없어요", "Fix4me 앱에서 저장해 주세요.")
        case .reading:
            busy("글을 읽는 중…")
        case .empty:
            notice("text.cursor", "고칠 글이 없어요", "글을 쓴 뒤 다시 열어 주세요.")
        case let .working(title):
            busy(title)
        case let .result(original, corrected):
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let segments = TextDiff.segments(old: original, new: corrected)
                    if TextDiff.isMostlyChanged(segments) {
                        Text(DiffText.removed(original)).opacity(0.8)
                        Text(DiffText.added(corrected))
                    } else {
                        Text(DiffText.inline(segments))
                    }
                }
                .font(.system(size: 16)).lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12))
        case .noChange:
            notice("hand.thumbsup", "고칠 곳이 없어요", nil)
        case .applied:
            notice("checkmark.circle", "고쳤어요", nil)
        case let .error(message):
            notice("exclamationmark.triangle", message, nil)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .result:
                big("닫기", prominent: false) { model.finish() }
                big("적용", prominent: true) { model.apply() }
            case .applied:
                big("되돌리기", prominent: false) { model.revert() }
                big("다시 교정", prominent: true) { model.retry() }
            case .error, .empty, .noChange:
                big("닫기", prominent: false) { model.finish() }
                big("다시", prominent: true) { model.retry() }
            case .needsFullAccess, .needsKey, .reading, .working:
                big("닫기", prominent: false) { model.finish() }
            }
        }
        .frame(height: 46)
    }

    private func big(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(prominent ? Color.indigo : Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func busy(_ title: String) -> some View {
        VStack(spacing: 10) { ProgressView(); Text(title).font(.subheadline).foregroundStyle(.secondary) }
    }

    private func notice(_ icon: String, _ title: String, _ detail: String?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
    }
}
