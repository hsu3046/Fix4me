import SwiftUI
import UIKit

/// 교정 전용 키보드. 글자판은 없고, 열면 커서가 있는 섹션을 교정해 보여 준다.
final class KeyboardViewController: UIInputViewController, KeyboardProxy {
    private let corrector = KeyboardCorrector()
    private lazy var model = KeyboardModel(
        session: KeyboardSession(proxy: self),
        environment: .init(
            hasFullAccess: { [weak self] in self?.hasFullAccess ?? false },
            hasKey: { [corrector] in corrector.hasKey },
            correct: { [corrector] in try await corrector.correct($0, level: $1) }
        ),
        close: { [weak self] in self?.advanceToNextInputMode() }
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let height = view.heightAnchor.constraint(equalToConstant: 290)
        height.priority = .init(999)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor), height,
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        model.open()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.closed()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) { model.textMayHaveChanged() }

    // MARK: - KeyboardProxy

    var before: String { textDocumentProxy.documentContextBeforeInput ?? "" }
    var after: String { textDocumentProxy.documentContextAfterInput ?? "" }
    var selected: String { textDocumentProxy.selectedText ?? "" }
    func move(by offset: Int) { textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) }
    func insert(_ text: String) { textDocumentProxy.insertText(text) }
    func deleteBackward() { textDocumentProxy.deleteBackward() }
    func pause() async { try? await Task.sleep(for: .milliseconds(20)) }
}
