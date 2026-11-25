// Fix4me — 포커스된 입력창을 단축키 한 번으로 교정하는 macOS 앱
// Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0
import AppKit

DevCommands.runIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)   // Dock 에 표시 (메뉴 막대 아이콘은 노치·정리 앱에 가려질 수 있다)
app.run()
