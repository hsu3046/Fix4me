// Fix4me — 커서 자리의 글을 고쳐 주는 iPhone 키보드
// Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0
import SwiftUI

@main
struct Fix4meiOSApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @Environment(\.openURL) private var openURL
    @State private var level = CorrectionLevel.current
    @State private var dictionary = SharedStore.dictionaryText
    @State private var key = ""
    @State private var savedHint = Self.keyHint()
    @State private var editingKey = false
    @State private var message: String?
    @State private var sample = Self.initialSample

    private static var initialSample: String {
        #if DEBUG
        if let given = ProcessInfo.processInfo.environment["FIX4ME_SAMPLE"] { return given }   // 시뮬레이터 시험용
        #endif
        return "어제 정한 사항을 않 지키면 문제가 됩니다.\n이번주 금요일 까지 확인 부탁드려요."
    }
    #if DEBUG
    @State private var stub = SharedStore.defaults.bool(forKey: "stubCorrections")
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("키보드 켜기") {
                    Label("설정 → 키보드에서 Fix4me 켜기", systemImage: "1.circle")
                    Label("전체 접근 허용 켜기", systemImage: "2.circle")
                    Button("설정 열기") { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } }
                }
                Section {
                    if let savedHint, !editingKey {
                        HStack {
                            Text("키 \(savedHint)")
                            Spacer()
                            Button("변경") { editingKey = true }
                        }
                    } else {
                        SecureField("sk-or-…", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("저장", action: saveKey).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        if savedHint != nil { Button("삭제", role: .destructive, action: deleteKey) }
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("OpenRouter") } footer: {
                    Text("키보드를 열 때 커서가 있는 글을 OpenRouter 로 보내요. 키는 이 iPhone 의 키체인에만 저장해요.")
                }
                Section("교정 강도") {
                    Picker("교정 강도", selection: $level) { ForEach(CorrectionLevel.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                        .onChange(of: level) { CorrectionLevel.save(level) }
                }
                Section("개인 사전") {
                    TextField("고치지 않을 단어를 한 줄에 하나씩", text: $dictionary, axis: .vertical).lineLimit(3...8)
                        .onChange(of: dictionary) { SharedStore.dictionaryText = dictionary }
                }
                Section("써 보기") {
                    TextEditor(text: $sample).frame(minHeight: 110)
                }
                #if DEBUG
                Section("개발용") { Toggle("가짜 교정 (전송 안 함)", isOn: $stub).onChange(of: stub) { SharedStore.defaults.set(stub, forKey: "stubCorrections") } }
                #endif
            }
            .navigationTitle("Fix4me")
            .scrollDismissesKeyboard(.interactively)
            .onAppear { level = CorrectionLevel.current }
        }
    }

    private func saveKey() {
        let status = Keychain.save(Keychain.openRouterAccount, value: key.trimmingCharacters(in: .whitespacesAndNewlines))
        guard status == errSecSuccess else { message = "저장하지 못했어요 (OSStatus \(status))"; return }
        key = ""; message = nil; editingKey = false; savedHint = Self.keyHint()
    }

    private func deleteKey() {
        Keychain.delete(Keychain.openRouterAccount)
        savedHint = nil; editingKey = false; message = "키를 삭제했어요"
    }

    private static func keyHint() -> String? {
        guard let k = Keychain.read(Keychain.openRouterAccount), k.count > 8 else { return nil }
        return "…" + k.suffix(4)
    }
}
