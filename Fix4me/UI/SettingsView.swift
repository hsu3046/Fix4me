import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class SettingsModel {
    var axTrusted = AXText.isTrusted
    var savedKeyHint: String? = SettingsModel.keyHint()
    var keyInput = ""
    var message: String?
    var testing = false
    var hotKeysOK = true
    /// 교정 강도 — 바꾸면 즉시 저장, 다음 ⌃⌥F 부터 적용 (didSet 안에서 자기 대입 금지: @Observable 재귀)
    var level = CorrectionLevel.current {
        didSet { CorrectionLevel.save(level) }
    }

    var scope = Prefs.scope { didSet { Prefs.scope = scope } }
    var precompute = Prefs.precompute { didSet { Prefs.precompute = precompute } }
    var indicator = Prefs.indicator { didSet { Prefs.indicator = indicator } }
    var dictionaryText = Prefs.dictionaryText { didSet { Prefs.dictionaryText = dictionaryText } }
    var excluded = Prefs.excluded { didSet { Prefs.excluded = excluded } }

    var doubleTap = Prefs.doubleTap { didSet { Prefs.doubleTap = doubleTap } }
    var historyEnabled = Prefs.history { didSet { Prefs.history = historyEnabled } }
    private(set) var historyCount = 0
    @ObservationIgnored let history: HistoryStore
    @ObservationIgnored var openHistory: () -> Void = {}

    init(history: HistoryStore) {
        self.history = history
        refreshHistory()
    }

    func refreshHistory() { historyCount = history.entries().count }

    func deleteHistory() {
        history.deleteAll()
        refreshHistory()
        message = history.lastError.map { "기록을 지우지 못했어요: \($0)" } ?? "교정 기록을 모두 지웠어요"
    }

    /// 앱을 골라 미리 교정 제외 목록에 넣는다
    func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "제외"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier,
              !excluded.contains(id) else { return }
        excluded.append(id)
    }

    /// 설치된 앱이면 이름, 아니면 번들 ID
    static func appName(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// 창이 떠 있는 동안 권한 상태를 1초마다 갱신 (시스템 설정에서 켜면 바로 반영)
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.axTrusted = AXText.isTrusted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() { pollTask?.cancel() }

    func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let status = Keychain.save(Keychain.openRouterAccount, value: key)
        keyInput = ""
        savedKeyHint = Self.keyHint()
        message = status == errSecSuccess ? "키를 키체인에 저장했어요" : "저장 실패 (OSStatus \(status))"
    }

    func deleteKey() {
        Keychain.delete(Keychain.openRouterAccount)
        savedKeyHint = nil
        message = "키를 삭제했어요"
    }

    /// 짧은 문장으로 실제 호출해 키·모델·지연을 확인
    func testConnection() {
        guard let key = Keychain.read(Keychain.openRouterAccount) else {
            message = CorrectionError.missingKey.localizedDescription
            return
        }
        testing = true
        message = nil
        Task {
            let sample = "어제 회의에서 결정된 사항을 않 지키면 문제가 됩니다."
            let started = ContinuousClock.now
            do {
                let result = try await OpenRouterClient(apiKey: key).correct(sample, level: level)
                let s = (ContinuousClock.now - started).components
                let secs = Double(s.seconds) + Double(s.attoseconds) / 1e18
                message = String(format: "연결 OK · %.2f초\n→ %@", secs, result)
            } catch {
                message = error.localizedDescription
            }
            testing = false
        }
    }

    /// 키 원문은 보여주지 않고 끝 4자리만
    private static func keyHint() -> String? {
        guard let key = Keychain.read(Keychain.openRouterAccount), key.count > 8 else { return nil }
        return "…" + key.suffix(4)
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section("손쉬운 사용 권한") {
                HStack {
                    Circle().fill(model.axTrusted ? .green : .red).frame(width: 8, height: 8)
                    Text(model.axTrusted ? "허용됨" : "필요함 — 다른 앱의 입력창을 읽고 쓰려면 허용해야 해요")
                    Spacer()
                    if !model.axTrusted {
                        Button("권한 요청") { AXText.requestTrust() }
                        Button("시스템 설정 열기") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }

            Section("교정 강도") {
                Picker("교정 강도", selection: $model.level) {
                    ForEach(CorrectionLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.level.summary)
                    Text("예: \(model.level.example)").foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            Section("교정 범위") {
                Picker("교정 범위", selection: $model.scope) {
                    ForEach(ScopeMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(model.scope.summary + " 선택한 글이 있으면 항상 그 부분만 고쳐요.").font(.callout)
            }

            Section("미리 교정") {
                Toggle("입력이 멈추면 미리 교정해 두기", isOn: $model.precompute)
                Toggle("고칠 섹션을 왼쪽 막대로 표시 (올리면 미리보기)", isOn: $model.indicator).disabled(!model.precompute)
                Text("켜면 단축키를 누르지 않은 글도 OpenRouter 로 보내요. 비밀번호 입력란, 검색창, 주소창, 키처럼 보이는 글과 아래 앱은 보내지 않아요.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("제외한 앱 \(model.excluded.count)개") {
                    ForEach(model.excluded, id: \.self) { id in
                        HStack {
                            Text(SettingsModel.appName(id))
                            Spacer()
                            Button("제거") { model.excluded.removeAll { $0 == id } }
                        }
                    }
                    Button("앱 추가…") { model.addExcludedApp() }
                }
                .disabled(!model.precompute)
            }

            Section("개인 사전") {
                TextEditor(text: $model.dictionaryText)
                    .font(.system(size: 13))
                    .frame(height: 72)
                Text("고치지 말아야 할 이름·용어를 한 줄에 하나씩 적어요. 지금 \(PersonalDictionary.parse(model.dictionaryText).count)개.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("교정 기록") {
                Toggle("교정 전후의 글을 이 Mac 에 저장", isOn: $model.historyEnabled)
                HStack {
                    Text("\(model.historyCount)건").foregroundStyle(.secondary)
                    Spacer()
                    Button("기록 보기…") { model.openHistory() }
                    Button("모두 지우기…", role: .destructive) { confirmingDelete = true }.disabled(model.historyCount == 0)
                }
                Text("켜면 적용·무시·되돌린 교정의 원문이 저장돼요. 이 Mac 밖으로 보내지 않고 \(HistoryLog.retentionDays)일 뒤 지워요. 제외한 앱과 키처럼 보이는 글은 저장하지 않아요. 꺼도 이미 저장한 기록은 남아요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .confirmationDialog("교정 기록을 모두 지울까요? 되돌릴 수 없어요.", isPresented: $confirmingDelete) {
                Button("모두 지우기", role: .destructive) { model.deleteHistory() }
                Button("취소", role: .cancel) {}
            }

            Section("OpenRouter API 키") {
                HStack {
                    SecureField("sk-or-…", text: $model.keyInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.saveKey() }
                    Button("저장") { model.saveKey() }.disabled(model.keyInput.isEmpty)
                }
                HStack {
                    Text(model.savedKeyHint.map { "저장된 키 \($0)" } ?? "저장된 키 없음")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.savedKeyHint != nil {
                        Button("삭제", role: .destructive) { model.deleteKey() }
                    }
                    Button(model.testing ? "테스트 중…" : "연결 테스트") { model.testConnection() }
                        .disabled(model.testing || model.savedKeyHint == nil)
                }
                Text("모델: \(OpenRouterClient.defaultModel)").font(.caption).foregroundStyle(.secondary)
            }

            Section("단축키") {
                Toggle("⌥(Option) 두 번 눌러 교정", isOn: $model.doubleTap)
                LabeledContent("포커스된 입력창 교정", value: model.doubleTap ? "⌥⌥ 또는 ⌃⌥F" : "⌃⌥F")
                LabeledContent("마지막 교정 되돌리기", value: HotKeyCenter.revert.label)
                Text("위에서 고른 교정 강도와 범위로 고쳐요. ⌥ 두 번이 다른 앱과 겹치면 끄고 ⌃⌥F 를 쓰세요.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.hotKeysOK {
                    Text("단축키 등록 실패 — 다른 앱이 같은 조합을 쓰고 있어요").foregroundStyle(.red)
                }
            }

            if let message = model.message {
                Text(message).font(.callout).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        // grouped Form 은 내부가 스크롤 영역이라 스스로 높이를 정하지 않는다 → 높이를 명시 (없으면 창이 0 높이로 접힘)
        .frame(minWidth: 460, idealWidth: 520, maxWidth: .infinity,
               minHeight: 360, idealHeight: 780, maxHeight: .infinity)
        .onAppear { model.startPolling(); model.refreshHistory() }
        .onDisappear { model.stopPolling() }
    }
}
