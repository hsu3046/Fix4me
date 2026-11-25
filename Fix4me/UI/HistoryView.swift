import SwiftUI

@MainActor
@Observable
final class HistoryModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all, rejected
        var id: String { rawValue }
        var title: String { self == .all ? "전체" : "되돌림·무시" }
    }

    @ObservationIgnored let store: HistoryStore
    private(set) var entries: [HistoryEntry] = []
    var filter = Filter.all

    init(store: HistoryStore) { self.store = store }

    var shown: [HistoryEntry] {
        entries.filter { filter == .all || $0.outcome.isRejected }.sorted { $0.date > $1.date }
    }

    func reload() { entries = store.entries() }
    func delete(_ id: UUID) { store.delete(id); reload() }
    func deleteAll() { store.deleteAll(); reload() }
}

struct HistoryView: View {
    @Bindable var model: HistoryModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("보기", selection: $model.filter) {
                    ForEach(HistoryModel.Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
                Text("\(model.shown.count)건").foregroundStyle(.secondary)
                Button("새로 고침") { model.reload() }
                Button("모두 지우기…", role: .destructive) { confirming = true }.disabled(model.entries.isEmpty)
            }
            .padding(12)
            Divider()
            if model.shown.isEmpty {
                ContentUnavailableView(
                    "기록이 없어요", systemImage: "text.badge.checkmark",
                    description: Text("설정에서 교정 기록을 켜면 여기에 쌓여요.")
                )
            } else {
                List(model.shown) { row($0) }
            }
        }
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity, minHeight: 360, idealHeight: 560, maxHeight: .infinity)
        .onAppear { model.reload() }
        .confirmationDialog("교정 기록을 모두 지울까요? 되돌릴 수 없어요.", isPresented: $confirming) {
            Button("모두 지우기", role: .destructive) { model.deleteAll() }
            Button("취소", role: .cancel) {}
        }
    }

    private func row(_ e: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(e.outcome.title).bold().foregroundStyle(e.outcome.isRejected ? .orange : .green)
                Text(CorrectionLevel(rawValue: e.level)?.title ?? e.level)
                Text(SettingsModel.appName(e.app))
                Text(e.date.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                Button("지우기") { model.delete(e.id) }.controlSize(.small)
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(DiffText.comparison(old: e.original, new: e.corrected)).textSelection(.enabled).lineLimit(8)
        }
        .padding(.vertical, 4)
    }
}
