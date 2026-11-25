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
    /// 교정 강도 — 바꾸면 즉시 저장, 다음 교정부터 적용 (didSet 안에서 자기 대입 금지: @Observable 재귀)
    var tab = LevelTab.current {
        didSet {
            tab.save()
            tabChanged()
        }
    }
    @ObservationIgnored var tabChanged: () -> Void = {}
    var isOn: Bool { tab.level != nil }

    var scope = Prefs.scope { didSet { Prefs.scope = scope } }
    var precompute = Prefs.precompute { didSet { Prefs.precompute = precompute } }
    var indicator = Prefs.indicator { didSet { Prefs.indicator = indicator } }
    var dictionaryText = Prefs.dictionaryText { didSet { Prefs.dictionaryText = dictionaryText } }
    var excluded = Prefs.excluded { didSet { Prefs.excluded = excluded } }

    var doubleTap = Prefs.doubleTap {
        didSet {
            Prefs.doubleTap = doubleTap
            shortcutsChanged()
        }
    }
    @ObservationIgnored var shortcutsChanged: () -> Void = {}
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

    private(set) var keySaved = true

    func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let status = Keychain.save(Keychain.openRouterAccount, value: key)
        keySaved = status == errSecSuccess
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
                let result = try await OpenRouterClient(apiKey: key).correct(sample, level: CorrectionLevel.current)
                let s = (ContinuousClock.now - started).components
                let secs = Double(s.seconds) + Double(s.attoseconds) / 1e18
                message = result.isEmpty ? "응답이 비어 있어요" : String(format: "연결됨 · %.1f초", secs)
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
    @State private var editingKey = false
    @State private var showingExcluded = false

    var body: some View {
        VStack(spacing: 14) {
            if !model.axTrusted { permission }
            group("교정 강도") {
                FullWidthSegments(items: LevelTab.all.map { ($0.title, $0.summary) }, selection: Binding(
                    get: { LevelTab.all.firstIndex(of: model.tab) ?? 0 }, set: { model.tab = LevelTab.all[$0] }
                ))
            }
            group("교정 범위") {
                FullWidthSegments(items: ScopeMode.allCases.map { ($0.title, $0.summary) }, selection: index($model.scope))
            }
            // 같은 줄의 두 카드는 높이가 같다
            pair { precompute.disabled(!model.isOn).opacity(model.isOn ? 1 : 0.5) } _: { dictionary }
            pair { shortcuts } _: { history }
            connection
        }
        .padding(20)
        .frame(width: 660)
        .onAppear { model.startPolling(); model.refreshHistory() }
        .onDisappear { model.stopPolling() }
        .confirmationDialog("교정 기록을 모두 지울까요? 되돌릴 수 없어요.", isPresented: $confirmingDelete) {
            Button("모두 지우기", role: .destructive) { model.deleteHistory() }
            Button("취소", role: .cancel) {}
        }
    }

    // MARK: - 카드

    private var permission: some View {
        card(nil) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("손쉬운 사용 권한이 필요해요")
                Spacer()
                Button("권한 요청") { AXText.requestTrust() }
                Button("시스템 설정 열기") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private var precompute: some View {
        card("미리 교정") {
            row("입력을 멈추면 준비") { Toggle("", isOn: $model.precompute) }
            row("왼쪽 막대로 표시") { Toggle("", isOn: $model.indicator).disabled(!model.precompute) }
            row("제외할 앱") {
                Button("\(model.excluded.count)개") { showingExcluded = true }
                    .disabled(!model.precompute)
                    .popover(isPresented: $showingExcluded, arrowEdge: .trailing) { excludedApps }
            }
            note("누르지 않은 글도 OpenRouter 로 보내요. 비밀번호·검색창·주소창은 빼요.")
        }
    }

    private var shortcuts: some View {
        card("단축키") {
            row("교정") {
                Picker("", selection: $model.doubleTap) {
                    Text("⌥ 두 번").tag(true)
                    Text(HotKeyCenter.correct.label).tag(false)
                }
                .pickerStyle(.segmented).fixedSize()
            }
            row("되돌리기") { Text(HotKeyCenter.revert.label).foregroundStyle(.secondary) }
            if !model.hotKeysOK {
                Text("다른 앱이 같은 키를 쓰고 있어 등록하지 못했어요").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var dictionary: some View {
        group("개인 사전", trailing: "\(PersonalDictionary.parse(model.dictionaryText).count)개") {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.dictionaryText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                if model.dictionaryText.isEmpty {
                    Text("고치지 않을 단어를 한 줄에 하나씩")
                        .font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 84, maxHeight: .infinity)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var history: some View {
        card("교정 기록", trailing: "\(model.historyCount)건") {
            row("이 Mac 에 저장") { Toggle("", isOn: $model.historyEnabled) }
                .help("원문이 이 Mac 에만 \(HistoryLog.retentionDays)일 동안 남아요.")
            HStack {
                Button("보기…") { model.openHistory() }
                Button("모두 지우기…") { confirmingDelete = true }.disabled(model.historyCount == 0)
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var connection: some View {
        card("OpenRouter") {
            HStack {
                if let hint = model.savedKeyHint, !editingKey {
                    Text("키 \(hint)")
                    Text(OpenRouterClient.defaultModel).foregroundStyle(.secondary)
                    Spacer()
                    if let message = model.message {
                        Text(message).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(message)
                    }
                    Button(model.testing ? "확인 중…" : "연결 확인") { model.testConnection() }.disabled(model.testing)
                    Button("키 변경") { editingKey = true }
                } else {
                    SecureField("", text: $model.keyInput, prompt: Text("sk-or-…"))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                        .onSubmit(saveKey)
                    Button("저장", action: saveKey).disabled(model.keyInput.isEmpty)
                    if model.savedKeyHint != nil {
                        Button("삭제", role: .destructive) { model.deleteKey(); editingKey = false }
                        Button("취소") { model.keyInput = ""; editingKey = false }
                    }
                }
            }
            .controlSize(.small)
            if model.savedKeyHint == nil || editingKey, let message = model.message { note(message) }
        }
    }

    private func saveKey() {
        model.saveKey()
        editingKey = !model.keySaved   // 저장에 실패하면 안내를 보이게 입력란을 남긴다
    }

    private var excludedApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.excluded, id: \.self) { id in
                        row(SettingsModel.appName(id)) {
                            Button { model.excluded.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("목록에서 빼기")
                        }
                    }
                }
            }
            .frame(height: 220)
            Button("앱 추가…") { model.addExcludedApp() }
        }
        .padding(14)
        .frame(width: 260)
    }

    // MARK: - 공통 모양

    private func card(_ title: String?, trailing: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        group(title, trailing: trailing) {
            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func pair(@ViewBuilder _ left: () -> some View, @ViewBuilder _ right: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 14) { left(); right() }
            .fixedSize(horizontal: false, vertical: true)
    }

    private func group(_ title: String?, trailing: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary) }
                }
            }
            content()
        }
    }

    private func row(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label).lineLimit(1)
            Spacer(minLength: 8)
            control().labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .frame(minHeight: 20)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func index<T: CaseIterable & Equatable>(_ value: Binding<T>) -> Binding<Int> where T.AllCases == [T] {
        Binding(get: { T.allCases.firstIndex(of: value.wrappedValue) ?? 0 }, set: { value.wrappedValue = T.allCases[$0] })
    }
}

/// 폭을 꽉 채우고 칸 너비가 모두 같은 선택 탭 (SwiftUI 의 segmented 는 글자 폭에 맞춰 줄어든다). 설명은 마우스를 올리면 보인다.
struct FullWidthSegments: NSViewRepresentable {
    let items: [(title: String, help: String)]
    @Binding var selection: Int

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: items.map(\.title), trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.changed(_:))
        )
        control.segmentDistribution = .fillEqually
        control.controlSize = .large
        for (i, item) in items.enumerated() { control.setToolTip(item.help, forSegment: i) }
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        if control.selectedSegment != selection { control.selectedSegment = selection }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Int>
        init(selection: Binding<Int>) { self.selection = selection }
        @objc func changed(_ sender: NSSegmentedControl) { selection.wrappedValue = sender.selectedSegment }
    }
}
