// Fix4me — 포커스된 입력창을 단축키 한 번으로 교정하는 메뉴 막대 앱
// Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
