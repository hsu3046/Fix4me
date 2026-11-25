import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsModel {
    var axTrusted = AXText.isTrusted
    var savedKeyHint: String? = SettingsModel.keyHint()
    var keyInput = ""
    var message: String?
    var testing = false
    var hotKeysOK = true

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
                let result = try await OpenRouterClient(apiKey: key).correct(sample)
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
                LabeledContent("포커스된 입력창 교정", value: HotKeyCenter.correct.label)
                LabeledContent("마지막 교정 되돌리기", value: HotKeyCenter.revert.label)
                Text("선택한 텍스트가 있으면 그 부분만, 없으면 커서가 있는 문단을 교정해요.")
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
               minHeight: 360, idealHeight: 540, maxHeight: .infinity)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }
}
