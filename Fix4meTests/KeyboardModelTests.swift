import XCTest
@testable import Fix4me

@MainActor
final class KeyboardModelTests: XCTestCase {
    private var closes = 0
    private var level = CorrectionLevel.proofread
    private var asked = 0
    /// 교정 응답을 붙잡아 둔다
    private var gate: CheckedContinuation<Void, Never>?
    private var held = false

    override func setUp() async throws {
        KeyboardModel.forget(); closes = 0; level = .proofread; asked = 0; gate = nil; held = false
    }

    private func make(_ f: FakeField, access: Bool = true, key: Bool = true) -> KeyboardModel {
        KeyboardModel(
            session: KeyboardSession(proxy: f),
            environment: .init(
                hasFullAccess: { access }, hasKey: { key },
                loadLevel: { [unowned self] in level }, saveLevel: { [unowned self] in level = $0 },
                correct: { [unowned self] target, _ in
                    asked += 1
                    if held { await withCheckedContinuation { gate = $0 } }
                    return target.text.replacingOccurrences(of: "않 ", with: "안 ")
                },
                showNoChange: {}
            ),
            close: { [unowned self] in closes += 1 }
        )
    }

    private func wait(_ what: String, _ done: () -> Bool) async {
        for _ in 0..<2000 { if done() { return }; await Task.yield() }
        XCTFail("기다렸지만 안 됨: \(what)")
    }
    private func settle() async { for _ in 0..<500 { await Task.yield() } }

    func testProofreadAppliesAndLeavesByItself() async {
        let f = FakeField("이건 않 돼요."), m = make(f)
        m.open()
        await wait("닫힘") { closes == 1 }
        XCTAssertEqual(f.string, "이건 안 돼요.")
    }

    func testPolishAndRewriteShowThePreviewFirst() async {
        for l in [CorrectionLevel.polish, .rewrite] {
            level = l; closes = 0
            let f = FakeField("이건 않 돼요."), m = make(f)
            m.open()
            await wait("미리보기") { if case .result = m.state { true } else { false } }
            await settle()
            XCTAssertEqual(f.string, "이건 않 돼요."); XCTAssertEqual(closes, 0)
            m.apply()
            await wait("닫힘") { closes == 1 }
            XCTAssertEqual(f.string, "이건 안 돼요.")
        }
    }

    /// 강도를 바꿔 다시 교정한 것은 바로 적용하지 않는다
    func testChangingTheLevelInTheKeyboardShowsThePreview() async {
        level = .polish
        let f = FakeField("이건 않 돼요."), m = make(f)
        m.open()
        await wait("미리보기") { if case .result = m.state { true } else { false } }
        m.level = .proofread
        await wait("다시 교정") { asked == 2 && { if case .result = m.state { true } else { false } }() }
        await settle()
        XCTAssertEqual(f.string, "이건 않 돼요."); XCTAssertEqual(closes, 0)
    }

    func testNothingToFixLeavesByItself() async {
        let f = FakeField("이건 안 돼요."), m = make(f)
        m.open()
        await wait("닫힘") { closes == 1 }
        XCTAssertEqual(m.state, .noChange); XCTAssertEqual(f.string, "이건 안 돼요.")
    }

    /// 기다리다 다른 키보드로 나갔으면 뒤늦게 고치지도, 키보드를 바꾸지도 않는다
    func testLeavingWhileWaitingChangesNothing() async {
        held = true
        let f = FakeField("이건 않 돼요."), m = make(f)
        m.open()
        await wait("요청") { gate != nil }
        m.closed()
        gate?.resume()
        await settle()
        XCTAssertEqual(f.string, "이건 않 돼요."); XCTAssertEqual(closes, 0)
    }

    func testReopeningOffersRevertAndRevertedTextIsNotFixedAgainByItself() async {
        let f = FakeField("이건 않 돼요.")
        let first = make(f); first.open()
        await wait("적용") { closes == 1 }
        first.closed()

        let second = make(f); second.open()
        await wait("되돌리기 화면") { second.state == .applied }
        second.revert()
        await wait("되돌림") { closes == 2 }
        XCTAssertEqual(f.string, "이건 않 돼요.")
        second.closed()

        let third = make(f); third.open()
        await wait("미리보기") { if case .result = third.state { true } else { false } }
        await settle()
        XCTAssertEqual(f.string, "이건 않 돼요."); XCTAssertEqual(closes, 2)
        third.apply()
        await wait("직접 적용") { closes == 3 }
        XCTAssertEqual(f.string, "이건 안 돼요.")
    }

    func testTextTypedWhileWaitingIsNotOverwritten() async {
        held = true
        let f = FakeField("이건 않 돼요."), m = make(f)
        m.open()
        await wait("요청") { gate != nil }
        f.insert(" 추가"); await f.pause(); await f.pause()
        gate?.resume()
        await wait("오류") { if case .error = m.state { true } else { false } }
        XCTAssertEqual(f.string, "이건 않 돼요. 추가"); XCTAssertEqual(closes, 0)
    }

    func testDoubleTapOnApplyWritesOnce() async {
        level = .polish
        let f = FakeField("이건 않 돼요."), m = make(f)
        m.open()
        await wait("미리보기") { if case .result = m.state { true } else { false } }
        m.apply(); m.apply()
        await wait("닫힘") { closes == 1 }
        await settle()
        XCTAssertEqual(f.string, "이건 안 돼요."); XCTAssertEqual(closes, 1); XCTAssertEqual(m.state, .applied)
    }

    /// 쓰는 도중에 나갔으면 쓰기는 마치되, 사용자가 고른 키보드를 바꾸지 않는다
    func testLeavingWhileWritingDoesNotSwitchTheKeyboardAgain() async {
        level = .polish
        let f = FakeField("이건 않 돼요."), m = make(f)
        m.open()
        await wait("미리보기") { if case .result = m.state { true } else { false } }
        m.apply(); m.closed()
        await wait("적용") { m.state == .applied }
        await settle()
        XCTAssertEqual(f.string, "이건 안 돼요."); XCTAssertEqual(closes, 0)
    }

    func testMissingAccessOrKeyAsksNothing() async {
        let f = FakeField("이건 않 돼요.")
        let a = make(f, access: false); a.open(); XCTAssertEqual(a.state, .needsFullAccess)
        let b = make(f, key: false); b.open(); XCTAssertEqual(b.state, .needsKey)
        await settle()
        XCTAssertEqual(asked, 0); XCTAssertEqual(f.string, "이건 않 돼요.")
    }
}
