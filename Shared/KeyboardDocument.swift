import Foundation

/// 키보드가 입력창에 할 수 있는 일 (UITextDocumentProxy 의 필요한 부분). 시험에서는 가짜 입력창으로 바꾼다.
@MainActor
protocol KeyboardProxy: AnyObject {
    var before: String { get }
    var after: String { get }
    var selected: String { get }
    func move(by offset: Int)
    func insert(_ text: String)
    func deleteBackward()
    /// 앱이 처리할 시간을 준다
    func pause() async
}

enum KeyboardError: LocalizedError, Equatable {
    case lostPosition
    case changed
    case notFound
    case mismatch

    var errorDescription: String? {
        switch self {
        case .lostPosition: "글을 읽다가 커서 위치를 놓쳤어요"
        case .changed: "글이 바뀌어 적용하지 않았어요"
        case .notFound: "고칠 위치를 확인하지 못해 적용하지 않았어요"
        case .mismatch: "예상과 다르게 들어갔어요 — 흔들어서 실행 취소해 주세요"
        }
    }
}

/// 읽어 온 글과 커서 위치
struct KeyboardText: Equatable, Sendable {
    let before: String
    let after: String
    /// 선택한 글 (있으면 이것만 고친다)
    let selected: String

    struct Target: Equatable, Sendable {
        let text: String
        let context: String
        /// 커서에서 대상 끝까지의 글. 대상 끝이 커서보다 앞이면 backward 에 들어 있다. 선택한 글이면 둘 다 빔
        let forward: String
        let backward: String
        let isSelection: Bool
    }

    /// 선택한 글, 없으면 커서가 있는 섹션, 그것도 없으면 바로 앞 섹션
    func target(level: CorrectionLevel) -> Target? {
        if !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Target(text: selected, context: "", forward: "", backward: "", isSelection: true)
        }
        let text = before + after, ns = text as NSString, cursor = before.utf16.count
        let units = Sectioner.units(in: text, level: level)
        guard let unit = units.first(where: { cursor >= $0.location && cursor <= NSMaxRange($0) })
            ?? units.last(where: { NSMaxRange($0) <= cursor }) else { return nil }
        let end = NSMaxRange(unit)
        return Target(
            text: ns.substring(with: unit), context: Sectioner.context(before: unit, in: text),
            forward: end >= cursor ? ns.substring(with: NSRange(location: cursor, length: end - cursor)) : "",
            backward: end < cursor ? ns.substring(with: NSRange(location: end, length: cursor - end)) : "",
            isSelection: false
        )
    }
}

/// 입력창을 읽고 고친다. 커서를 옮기기 전후로 글을 대조하고, 다르면 쓰지 않는다.
@MainActor
struct KeyboardSession {
    let proxy: any KeyboardProxy
    /// 한쪽으로 읽을 최대 글자 수와 걸음 수 (한 걸음이 수십 ms 걸린다)
    var maxCharacters = 600
    var maxSteps = 14
    /// 실패로 판정하기 전에 기다리는 횟수 (약 1초). 맞으면 바로 끝나므로 평소에는 느려지지 않는다
    var patience = 50

    init(proxy: any KeyboardProxy) { self.proxy = proxy }

    /// 커서 이동은 UTF-16 으로 센다 (iOS 실측: 글자 수로 옮기면 이모지 가운데에 놓인다).
    /// 다르게 세는 앱이 있으면 아래의 확인에서 걸려 읽거나 쓰지 않는다.
    private func length(_ s: String) -> Int { s.utf16.count }

    // MARK: - 읽기

    func read() async throws -> KeyboardText {
        guard proxy.selected.isEmpty else { return KeyboardText(before: "", after: "", selected: proxy.selected) }
        let home = snapshot
        let after = await collect(forward: true)
        try await goHome(home, undo: after, forward: true)
        let before = await collect(forward: false)
        try await goHome(home, undo: before, forward: false)
        return KeyboardText(before: before, after: after, selected: "")
    }

    private struct Snapshot: Equatable { let before: String, after: String }
    private var snapshot: Snapshot { Snapshot(before: proxy.before, after: proxy.after) }

    /// 커서를 옮기며 한쪽 글을 모은다. 빈 줄(섹션 경계)을 지나거나 한도에 이르거나, 조금이라도 확실하지 않으면 멈춘다.
    private func collect(forward: Bool) async -> String {
        var text = ""
        for _ in 0..<maxSteps where text.count < maxCharacters {
            if text.contains("\n\n\n") || (text.count >= Sectioner.minLength && text.contains("\n\n")) { break }
            let piece = forward ? proxy.after : proxy.before
            let next = piece.isEmpty ? await crossBoundary(forward: forward) : await cross(piece, forward: forward)
            guard let next else { break }
            text = forward ? text + next : next + text
        }
        return text
    }

    /// 보이는 조각을 넘는다. 못 넘었으면 제자리로 돌아와 nil.
    private func cross(_ piece: String, forward: Bool) async -> String? {
        guard !Self.isBroken(piece) else { return nil }   // 이모지 가운데에서 잘려 보이는 조각
        let old = snapshot
        move(over: piece, forward: forward)
        let moved = await changed(from: old)   // 같은 문장이 반복되면 움직여도 같아 보일 수 있다
        for _ in 0..<12 {
            // 넘은 조각이 반대쪽에 붙어 보여야 한다 (앱이 보여 주는 만큼). 빈 글은 변화를 봤을 때만 증거가 된다
            let other = forward ? proxy.before : proxy.after
            if moved || !other.isEmpty, forward ? Self.agrees(other, withEndOf: piece) : Self.agrees(other, withStartOf: piece) { return piece }
            await proxy.pause()
        }
        move(over: piece, forward: !forward)
        _ = await settled(to: old)
        return nil
    }

    /// 문장 경계에서는 글이 더 있어도 비어 보인다 → 한 칸 넘어가 본다. 글의 끝이거나 확실하지 않으면 제자리로 돌아와 nil.
    private func crossBoundary(forward: Bool) async -> String? {
        // 같은 글자가 이어진 곳(빈 줄 등)에서는 움직였는지 구별할 수 없다
        let around = forward ? Array(proxy.before.suffix(2)) : Array(proxy.after.prefix(2))
        if around.count == 2, around[0] == around[1] { return nil }
        let old = snapshot
        proxy.move(by: forward ? 1 : -1)
        guard await changed(from: old) else {
            // 글의 끝이라 안 움직였거나, 움직였는데 똑같아 보이거나. 되돌려 보고 어느 쪽이든 제자리로.
            proxy.move(by: forward ? -1 : 1)
            if await changed(from: old) { proxy.move(by: forward ? 1 : -1); _ = await settled(to: old) }
            return nil
        }
        // 넘은 것이 한 칸짜리 보통 글자일 때만 받아들인다 (이모지 가운데·결합 문자는 되돌아간다)
        if let c = forward ? proxy.before.unicodeScalars.last : proxy.after.unicodeScalars.first, Self.isPlain(c),
           let other = forward ? proxy.before.last : proxy.after.first, other.unicodeScalars.count == 1 {
            return String(c)
        }
        proxy.move(by: forward ? -1 : 1)
        _ = await settled(to: old)
        return nil
    }

    private static func isPlain(_ c: Unicode.Scalar) -> Bool {
        c.value < 0xD800 && c != "\u{200D}" && !c.properties.isEmojiPresentation && !c.properties.isVariationSelector
            && c.properties.generalCategory != .nonspacingMark && c.properties.generalCategory != .enclosingMark
    }

    private static func isBroken(_ s: String) -> Bool { s.unicodeScalars.contains("\u{FFFD}") }

    private func move(over text: String, forward: Bool) { proxy.move(by: forward ? length(text) : -length(text)) }

    private func goHome(_ home: Snapshot, undo text: String, forward: Bool) async throws {
        guard !text.isEmpty else { return }
        move(over: text, forward: !forward)
        for _ in 0..<patience {
            if snapshot == home { return }
            await proxy.pause()
        }
        throw KeyboardError.lostPosition
    }

    private func settled(to target: Snapshot) async -> Bool {
        for _ in 0..<patience {
            if snapshot == target { return true }
            await proxy.pause()
        }
        return false
    }

    private func changed(from old: Snapshot) async -> Bool {
        for _ in 0..<12 {
            await proxy.pause()
            if snapshot != old { return true }
        }
        return false
    }

    // MARK: - 쓰기

    /// 대상을 corrected 로 바꾼다. 커서는 바꾼 글의 끝에 둔다.
    func apply(_ target: KeyboardText.Target, in text: KeyboardText, corrected: String) async throws {
        if target.isSelection {
            guard proxy.selected == target.text else { throw KeyboardError.changed }
            proxy.insert(corrected)
            await letAppAnswer()
            guard await before(endsWith: corrected) else { throw KeyboardError.mismatch }
            return
        }
        // 읽은 뒤 글이나 커서가 바뀌었으면 쓰지 않는다
        guard proxy.selected.isEmpty, Self.agrees(proxy.before, withEndOf: text.before),
              Self.agrees(proxy.after, withStartOf: text.after) else { throw KeyboardError.changed }

        let old = Array(target.text), new = Array(corrected)
        guard old != new else { return }
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let deleted = String(old[prefix..<(old.count - suffix)]), inserted = String(new[prefix..<(new.count - suffix)])
        let keep = String(old[0..<prefix]), tail = String(old[(old.count - suffix)...])

        let offset = length(target.forward) - length(target.backward) - length(tail)
        if offset != 0 { proxy.move(by: offset); await letAppAnswer() }
        guard await before(endsWith: keep + deleted) else {
            if offset != 0 { proxy.move(by: -offset) }
            throw KeyboardError.notFound
        }
        for _ in 0..<deleted.count { proxy.deleteBackward() }
        guard await before(endsWith: keep) else {
            throw KeyboardError.mismatch
        }
        if !inserted.isEmpty { proxy.insert(inserted) }
        if suffix > 0 { proxy.move(by: length(tail)) }
        await letAppAnswer()
        guard await before(endsWith: keep + inserted + tail) else { throw KeyboardError.mismatch }
    }

    /// iOS 는 옮기고 고친 결과를 앱의 응답이 오기 전에 예측해서 보여 준다(실측: 0ms). 앱의 실제 응답(약 20ms)을 기다린 뒤에 확인해야 한다.
    private func letAppAnswer() async {
        for _ in 0..<3 { await proxy.pause() }
    }

    /// 커서 앞 글이 expected 로 끝날 때까지 기다린다. 앱은 앞 글의 일부만 보여 주므로 보이는 만큼 대조한다.
    private func before(endsWith expected: String) async -> Bool {
        for _ in 0..<patience {
            if Self.agrees(proxy.before, withEndOf: expected), expected.isEmpty || !proxy.before.isEmpty || expected.hasSuffix("\n") { return true }
            await proxy.pause()
        }
        return false
    }

    /// 짧은 쪽이 긴 쪽의 끝(시작)과 같은지
    static func agrees(_ visible: String, withEndOf text: String) -> Bool {
        visible.count >= text.count ? visible.hasSuffix(text) : text.hasSuffix(visible)
    }

    static func agrees(_ visible: String, withStartOf text: String) -> Bool {
        visible.count >= text.count ? visible.hasPrefix(text) : text.hasPrefix(visible)
    }
}
