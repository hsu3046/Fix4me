# ✍️ Fix4me

## Tagline-en

Stop rereading every message. Type in English, Korean or Japanese, press one shortcut, and it's fixed right where you typed.

## Tagline-ko

보내기 직전에 맞춤법을 다시 훑고, 번역기와 사전을 오가느라 지치셨나요? 한국어든 영어든 일본어든 쓰던 자리에서 단축키 한 번이면 됩니다. 손을 멈춘 사이 미리 고쳐 두고, 무엇이 바뀌는지 먼저 보여 드려요.

## Tagline-ja

送信する前に、何度も読み返していませんか？日本語でも韓国語でも英語でも、書いたその場所でショートカットを一度押すだけ。手を止めたあいだに直しを用意しておき、どこがどう変わるのかも先にお見せします。

---

## Summary-en

You write to people in three languages, and every message costs you a second look: a missing article here, a spacing slip there, a particle you are suddenly unsure about. Copying text into another tool breaks your train of thought. Fix4me stays where you are typing. When you pause, it quietly prepares a correction and leaves a small bar beside the section. Hover to see the original struck through next to the new wording, then apply it, ignore it, or fix everything with one shortcut. Changed your mind? Another shortcut puts it back.

## Summary-ko

세 가지 언어로 글을 쓰다 보면 보내기 전에 꼭 한 번 더 멈칫하게 됩니다. 띄어쓰기가 맞나, 관사가 빠졌나, 이 조사가 자연스러운가. 그렇다고 글을 복사해 다른 창에 붙여 넣다 보면 하던 생각이 끊기죠. Fix4me는 쓰던 자리를 떠나지 않게 해 줍니다. 손을 멈추면 조용히 교정을 준비해 두고, 고칠 곳이 있는 섹션 옆에 작은 막대를 띄워요. 마우스를 올리면 원문은 취소선으로, 고친 글은 강조로 나란히 보입니다. 하나만 적용해도 되고, 무시해도 되고, 단축키 한 번으로 전부 고쳐도 돼요. 마음이 바뀌면 되돌리기도 단축키 한 번이면 됩니다.

## Summary-ja

三つの言葉で文章を書いていると、送る前についもう一度手が止まります。助詞はこれでよかったか、冠詞が抜けていないか、敬語は揃っているか。かといって別の画面に貼り付けて直していると、考えの流れが途切れてしまいます。Fix4meは、書いているその場所から離れません。手を止めると静かに直しを用意し、直すところがある部分の横に小さなバーを出します。マウスを乗せれば、元の文は取り消し線で、直した文は強調して並べて見せます。一つだけ適用しても、無視しても、ショートカットでまとめて直しても構いません。気が変わったら、戻すのも一度押すだけです。

---

## ✨ What It Does

- **Fixes text where you type** — Press `⌃⌥F` with your cursor in a text field; no copying, no extra window.
- **Prepares fixes while you pause** — About a second after you stop typing, a correction is prepared in the background so the shortcut can apply it without waiting.
- **Shows what will change** — A thin bar marks each section that can be improved. Hover to see the original struck through beside the new text.
- **Lets you choose how far to go** — *Proofread* fixes mistakes, *Polish* smooths awkward wording, *Rewrite* restructures for clarity.
- **Works in sections, not walls of text** — Headings, dividers, blank lines, lists and line-break habits are recognised by plain rules, so only the part you changed is sent.
- **Leaves the wrong things alone** — Code blocks, tables, quotes, signatures and bare links are skipped, and your personal dictionary protects names and terms.
- **Never overwrites newer typing** — If the text changed while a correction was on its way, nothing is written.
- **Undoes in one step** — `⌃⌥Z` restores the last correction as long as it is still in place.
- **Keeps a private history, if you want one** — Off by default, stored only on your Mac, deleted after 30 days.

---

## ⚠️ Before You Use It

Fix4me started as a personal tool. Please read this first.

- **Your text goes to a third party.** Text is sent to [OpenRouter](https://openrouter.ai) and on to the model provider it selects. With background preparation on (the default), that includes text you type but never ask to fix. See [Privacy](#-privacy).
- **A language model can be wrong.** It can change what you meant, especially in *Polish* and *Rewrite*. Check the preview before sending anything important.
- **You pay for usage** through your own OpenRouter account.
- **There is no download.** You build and sign it yourself; it is not notarised or on the App Store.
- **The interface is in Korean.**

---

## 🛠 Tech Stack

| Layer | Technology |
|-------|------------|
| Platform | macOS 15 or later (developed on macOS 27) |
| Language | Swift 6, strict concurrency |
| UI | SwiftUI + AppKit panels that never take focus |
| Text access | macOS Accessibility API, clipboard paste as fallback |
| Shortcuts | Carbon global hot keys |
| Section detection | Rule-based, with Apple's NaturalLanguage for sentence boundaries |
| Model | `anthropic/claude-haiku-5.5` through OpenRouter |
| Key storage | macOS Keychain |
| Project | XcodeGen, XCTest, no third-party runtime dependencies |

---

## 📦 Installation

You need Xcode (developed with 27.2), [XcodeGen](https://github.com/yonaskolb/XcodeGen), an Apple Development certificate in your keychain, and an [OpenRouter API key](https://openrouter.ai/keys).

```bash
brew install xcodegen
git clone https://github.com/hsu3046/Fix4me.git
cd Fix4me
./scripts/build.sh
open dist/Fix4me.app
```

Use another certificate with `FIX4ME_SIGN_ID="certificate name" ./scripts/build.sh`. A stable certificate matters: macOS ties the Accessibility permission to the app's signature, and ad-hoc signing changes it on every build.

### First run

1. In the settings window, press **권한 요청** and turn Fix4me on in *System Settings → Privacy & Security → Accessibility*.
2. Paste your OpenRouter key and press **저장**. It goes into your Keychain. The app does not read `.env` files.
3. Press **연결 테스트** to check the connection.

If the permission still shows as missing, quit and reopen the app.

---

## ⌨️ Using It

| Action | How |
|--------|-----|
| Fix the section you changed, or the one at the cursor | `⌃⌥F` |
| Fix only part of the text | Select it, then `⌃⌥F` |
| Undo the last correction | `⌃⌥Z` |
| Preview a change | Hover over the bar beside the section |
| Apply or ignore one section | **적용** / **무시** in the preview |
| Open settings | Dock icon, or `⌘,` |
| Open history | `⌘Y` |

The bar is yellow for *Proofread*, blue for *Polish* and purple for *Rewrite*. When an app doesn't report where its text is, a small number appears in the corner of the field instead.

### Settings

| Setting | Options |
|---------|---------|
| Strength (교정 강도) | Proofread · Polish · Rewrite |
| Scope (교정 범위) | Automatic · Section at cursor · All sections |
| Background preparation (미리 교정) | On/off, bar on/off, excluded apps |
| Personal dictionary (개인 사전) | One word per line; never changed |
| History (교정 기록) | Off by default; view or delete everything |

---

## 🔒 Privacy

**What is sent.** The section being corrected, the nearest heading, the preceding block (up to 300 characters), and your personal dictionary. Requests go directly from your Mac to OpenRouter; there is no Fix4me server and no analytics.

**What background preparation skips**

- Password fields, and any time macOS secure input is active
- Search fields, and browser address bars in the browsers it knows
- Text that looks like an API key or token, and single unbroken strings
- Sections you haven't changed since focusing the field
- Excluded apps: terminals, password managers and code editors by default

These are heuristics, not guarantees. Pressing the shortcut sends the text regardless of the filters, except in password fields. Turn background preparation off if you work with confidential text.

**What is stored.** Your key in the Keychain, your settings, and, only if you enable history, corrections in `~/Library/Application Support/Fix4me/`, readable only by your account.

---

## 🧭 How It Works

```
typing pauses ─► read focused field ─► split into sections (rules, no AI)
                                             │
                           only changed sections, filtered
                                             ▼
                                   OpenRouter (cached) ─► bar + preview
                                             │
⌃⌥F or Apply ─► is the text still the same? ─► write only the changed lines ─► verify
```

- **Sections** use three boundary strengths. Dividers, headings, two blank lines and skipped blocks always split; a single blank line or a list edge usually does; a single line break does only when that text uses line breaks as paragraphs.
- **Rewrite runs in two steps** (proofread, then rewrite). In one step, a typo of "didn't fix" became "completely fixed" in 9 of 14 tries on one test sentence; in two steps, 0 of 14.
- **Writing** never trusts positions alone: it selects the text, checks that the selection is exactly the original, and only then replaces it. If it can't confirm the place, nothing is written. If the result isn't what was expected, it tells you to press `⌘Z`. Pasting restores your clipboard afterwards.

More in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/DECISIONS.md](docs/DECISIONS.md) (Korean).

---

## 🧪 Development

```bash
# Unit tests
xcodegen generate
xcodebuild -project Fix4me.xcodeproj -scheme Fix4me -derivedDataPath build/DerivedData test

# Developer commands (those that call the model use the key in your Keychain)
B=dist/Fix4me.app/Contents/MacOS/Fix4me
$B --sections notes.md                          # show section boundaries, no AI
$B --compare "I has a apple."                   # compare the three strengths
$B --evaluate eval/cases.jsonl --repeat 2       # score against fixed cases
$B --evaluate-history                           # re-send rejected corrections
```

Language model output varies, so `--evaluate` reports counts rather than pass or fail. A baseline on 25 November 2026, with each case run twice: Proofread 38/38, Polish 37/38, Rewrite 30/32. Both *Rewrite* misses were an overly strict rule that has since been relaxed. The cases are few and short; treat this as a smoke test, not a benchmark.

---

## 📁 Project Structure

```
├── Fix4me/
│   ├── App/                # App lifecycle, correction flow, background preparation, dev commands
│   ├── Core/               # Accessibility, sections, diff, model client, cache, history
│   └── UI/                 # Settings, bar and preview, notices, history window
├── Fix4meTests/            # Unit tests
├── eval/cases.jsonl        # Fixed cases for scoring corrections
├── docs/                   # Architecture and decision log (Korean)
├── scripts/build.sh        # Generate, build, sign → dist/Fix4me.app
└── project.yml             # XcodeGen project definition
```

---

## 🚧 Known Limitations

- Used so far mainly in TextEdit, Slack and web text boxes. Other apps, and editors such as Google Docs, may not expose their text.
- Many web editors don't report blank lines, so blank lines don't separate sections there.
- Editors that use a separate field for each block may look like one section per block.
- *Polish* has turned `12/05` into `December 5`, guessing the date order.
- *Rewrite* can add small words or shift nuance.
- A field's formatting inside a changed line may be lost.

---

## 🗺 Roadmap

- [ ] iPhone version
- [ ] Faster corrections, measured against the evaluation set
- [ ] Remember the preferred strength for each app
- [ ] Protect dates and numbers in Polish and Rewrite
- [ ] English and Japanese interface

---

## 🤝 Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feat/amazing-feature`)
3. Run the unit tests, and `--evaluate` if you touched a prompt
4. Commit your changes (`git commit -m 'feat(scope): add amazing feature'`)
5. Push to the branch (`git push origin feat/amazing-feature`)
6. Open a Pull Request

Please don't paste private text into issues. Describe the app you were using and reproduce the problem with a made-up sentence.

---

## 📄 License

This project is licensed under the [GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html).

---

*Built by [AIB Inc.](https://www.aib.vote) · © 2026 AIB Inc.*
