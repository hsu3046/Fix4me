# Fix4me 아키텍처 (Mac 앱 + iPhone 키보드)

포커스된 입력창을 **클릭 없이 단축키 한 번으로** 교정하는 macOS 앱과, 쓰던 자리에서 고치는 iPhone 교정 키보드. 본인 전용(배포 안 함).

## 흐름

```
⌥ 두 번 (두 번째를 뗄 때) 또는 ⌃⌥F (Carbon 전역 단축키) — 설정에서 고른 하나만 동작
  → AXText.focused()        앞 앱의 포커스 요소·값·선택 범위 (Chrome/Electron 은 접근성 트리 강제 활성화 후 재시도)
  → TextScope.plan()        선택 영역 우선. 자동 = 바뀐 섹션(최대 8개), 없으면 커서 섹션 / 커서 섹션 / 모든 섹션
  → CorrectionService       캐시 적중이면 즉시, 미리 교정이 보내 둔 요청이면 이어받음
  → OpenRouterClient        anthropic/claude-haiku-5.5, 설정의 교정 강도별 프롬프트, provider.sort=latency, {"corrected": ...} JSON
  → CorrectionParser        JSON 추출 + 길이 비율로 "대답/번역" 응답 차단
  → 스냅샷 대조              기다리는 동안 문단이 바뀌었으면 쓰지 않음
  → TextDiff.edits          줄 수가 같으면 바뀐 줄만, 다르면 한 구간 (안 바뀐 줄의 서식·멘션 보존)
  → AXText.replace()        뒤에서부터. 줄 선택으로 위치를 맞춤 → **선택된 글 = 원문** 확인 → 쓰기(웹은 붙여넣기) → 글 전체가 예상과 같을 때만 성공
  → HUD                     텍스트 아래 "N곳 고쳤어요 · 0.9초 · 않 → 안"
⌃⌥Z → 같은 입력창·같은 자리에 교정 결과가 그대로 있을 때만 원문으로 되돌림
```

## 파일

| 경로 | 역할 |
|---|---|
| `Fix4me/App/main.swift`, `AppDelegate.swift` | 메뉴 막대 앱 수명주기, 단축키 등록, 설정 창 |
| `Fix4me/App/CorrectionController.swift` | 교정·되돌리기 전체 흐름 (MainActor, 동시 실행 1개) |
| `Fix4me/Core/AXText.swift` | Accessibility 읽기·쓰기·좌표, 붙여넣기 대체 경로 |
| `Fix4me/Core/DoubleTap.swift` | ⌥ 두 번 누르기 판정(순수 로직)과 시스템 전체 감시 (키를 가로채지 않음) |
| `Fix4me/Core/HotKeyCenter.swift` | Carbon `RegisterEventHotKey` 래퍼 |
| `Shared/OpenRouterClient.swift` | 교정 요청 1회, 오류 원문(status·metadata.raw) 보존 |
| `Fix4me/App/Precomputer.swift` | 미리 교정: 0.3초마다 감시, 0.6초 멈추면 요청, 표시 (분당 30건 상한, 오류 시 쉼) |
| `Fix4me/App/CorrectionService.swift`, `Core/CorrectionCache.swift` | 결과 캐시(메모리, 300개)와 진행 중 요청 공유 |
| `Shared/CorrectionPipeline.swift` | 강도별 호출 순서. 다시 쓰기는 교정 → 다시 쓰기 (교정 결과는 캐시 공유, 분당 상한에는 2건으로 셈) |
| `Fix4me/UI/Indicator.swift`, `DiffText.swift`, `Core/IndicatorLayout.swift` | 고칠 문단 왼쪽 막대(위치를 모르면 모서리 배지), 롤오버 미리보기(원문 취소선 + 고친 글, 적용/무시) |
| `Shared/PersonalDictionary.swift` | 개인 사전: 프롬프트 지시 + 어긴 줄은 원문으로 |
| `Fix4me/Core/History.swift`, `UI/HistoryView.swift` | 교정 기록(기본 꺼짐, 이 Mac 에만, 30일)과 보기 창 |
| `Fix4me/Core/Evaluation.swift`, `App/DevCommands.swift`, `eval/cases.jsonl` | 채점 기준과 개발용 명령줄 |
| `Fix4me/Core/FieldMemory.swift` | 최근 입력창 20개의 상태(메모리 전용)와 사용자의 입력/다른 글이 들어옴 구별 |
| `Fix4me/Core/PrecomputeFilter.swift`, `Prefs.swift` | 보내지 않을 글 판정, 설정값·제외 앱 |
| `Shared/Keychain.swift` | API 키 저장 (로그인 키체인) |
| `Shared/EditorText.swift` | 입력창마다 다른 글·위치 표현 맞추기(줄바꿈·빈 줄 보정, 끼워 넣기 앵커, 조각 위치 합치기) |
| `Shared/Sectioner.swift` | 규칙만으로 섹션 나누기: 줄 종류 → 경계 3단계 → 크기 맞추기, 참고 문맥(가까운 제목 + 앞 덩어리) |
| `Fix4me/Core/TextScope.swift`, `TextDiff.swift`, `CorrectionParser.swift` | 순수 로직 (단위 테스트 대상) |
| `Shared/CorrectionLevel.swift` | 교정 강도(교정·다듬기·다시 쓰기): 프롬프트 지시·길이 범위·저장 |
| `Fix4me/UI/HUD.swift` | 포커스를 빼앗지 않는 플로팅 패널 |
| `Fix4me/UI/SettingsView.swift` | 권한 상태·키 저장·연결 테스트 |

## iPhone 교정 키보드

글자판은 없다. 평소 키보드로 쓰고 🌐 로 Fix4me 를 열면 커서가 있는 섹션을 교정해 보여 주고, **적용**을 누르면 고친 뒤 쓰던 키보드로 돌아간다.

```
열림 → KeyboardSession.read()   커서를 옮기며 앞뒤를 읽고 제자리로 (섹션 경계·600자·14걸음까지)
     → KeyboardText.target()    선택한 글 > 커서가 있는 섹션 > 바로 앞 섹션
     → CorrectionPipeline       Mac 과 같은 교정 코드 (Shared)
     → 미리보기                  원문 취소선 + 고친 글
적용 → KeyboardSession.apply()  글이 그대로인지 → 옮긴 자리가 맞는지 → 바뀐 부분만 지우고 넣기 → 결과 확인
```

| 경로 | 역할 |
|---|---|
| `Shared/KeyboardDocument.swift` | 읽기·쓰기 로직 (`KeyboardProxy` 로 시험 가능, `Fix4meTests/KeyboardTests.swift`) |
| `Fix4meiOS/Keyboard/` | 키보드 확장: 컨트롤러, 상태(`KeyboardModel`), 화면 |
| `Fix4meiOS/App/` | 설정 앱: 키보드 켜기 안내, API 키, 강도, 개인 사전, 써 보기 |
| `Fix4meiOS/Support/` | Info.plist·entitlements (키체인 공유) |

- 키·강도·사전 모두 앱과 키보드가 공유하는 키체인에 둔다(`KeychainSettings`). 네트워크 때문에 **전체 접근 허용**이 필요하다.
- DEBUG 의 "가짜 교정"은 전송 없이 정해 둔 교정을 보여 준다(키 없이 화면 확인용).

iOS 실측(시뮬레이터 27.0):
- 커서 앞뒤 글은 문장 단위로 일부만 보이고, 문장·줄 끝에서는 뒤가 비어 보인다 → 한 칸 넘어가 본다.
- 커서 이동은 **UTF-16** 단위. 글자 수로 옮기면 이모지 가운데에 놓여 글이 `�` 로 깨져 보인다.
- 이동·삭제·입력의 결과는 **앱의 응답 전에 예측값으로 먼저 보인다(0ms)**. 실제 응답은 약 20ms 뒤 → 60ms 기다린 다음 확인한다.
- 키보드를 열 때마다 컨트롤러가 새로 만들어진다 → 되돌리기 정보는 프로세스에 둔다.
- 읽기는 짧은 글도 약 0.6초 (글의 양 끝인지 확인하느라 각 0.25초 기다림).

## 빌드

iPhone 설치 (TEAM·UDID 는 자기 것으로, 처음 한 번은 Xcode 에 Apple 계정 로그인 필요):

```bash
xcodebuild -project Fix4me.xcodeproj -scheme Fix4meiOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/iOSDevice -allowProvisioningUpdates DEVELOPMENT_TEAM=TEAM CODE_SIGN_STYLE=Automatic build
xcrun devicectl device install app --device UDID build/iOSDevice/Build/Products/Release-iphoneos/Fix4me.app
```

Mac:

```bash
./scripts/build.sh        # xcodegen → xcodebuild → Apple Development 인증서 서명 → dist/Fix4me.app
xcodebuild -project Fix4me.xcodeproj -scheme Fix4me -derivedDataPath build/DerivedData test
dist/Fix4me.app/Contents/MacOS/Fix4me --compare "비교할 문장"   # 세 강도 결과 비교 (개발용)
dist/Fix4me.app/Contents/MacOS/Fix4me --sections 파일               # LLM 없이 섹션 경계만 출력 (개발용)
dist/Fix4me.app/Contents/MacOS/Fix4me --evaluate eval/cases.jsonl --repeat 2   # 정해 둔 글로 채점
dist/Fix4me.app/Contents/MacOS/Fix4me --evaluate-history                      # 거절한 교정이 또 나오는지 (기록의 글을 다시 전송)
```

- `Fix4me.xcodeproj` 는 `project.yml` 에서 생성 (커밋 안 함).
- 앱 아이콘은 `Fix4me/AppIcon.icon` (Icon Composer). 빌드가 macOS 26+ 용 Assets.car 와 예전 macOS 용 icns 를 함께 만든다.
- ad-hoc 서명은 빌드마다 서명 신원이 바뀌어 손쉬운 사용 권한이 풀린다 → 고정 인증서로 서명. 다른 인증서는 `FIX4ME_SIGN_ID`.
- 샌드박스 없음 (Accessibility·이벤트 게시가 필요해 Mac App Store 배포 불가 — 본인 전용이라 무관).

## 다음 단계

1. 앱별 쓰기 방식 기억 (AX 직접 쓰기가 안 되는 앱은 처음부터 붙여넣기)
2. iPhone 실기기 확인 (읽는 속도, 앱별 동작)

## 미리 교정 규칙

- 입력창에 **원래 있던 글은 보내지 않는다.** 포커스를 얻은 때의 글이 기준이고, 사용자가 바꾼 뒤부터 본다. 다른 앱에 다녀와도 기준을 기억한다. 같은 입력창에 다른 글이 통째로 들어오면(다른 메모·초안) 원래 있던 글로 본다.
- 보내지 않음: 비밀번호 입력(시스템 보안 입력 포함), 검색창, 브라우저 주소창, API 키처럼 보이는 글, 띄어쓰기 없는 영숫자 한 덩어리, 제외 앱(기본: 터미널·비밀번호 관리자·코드 편집기).
- 코드 블록·표·인용·구분선·주소만 있는 줄·서명은 섹션에서 빠지므로 보내지도 고치지도 않는다 (직접 선택하면 예외).
- 일부 문단만 고치면 그 문단만 처리된 것으로 본다 (`TextScope.baseline(_:adding:)`).

## 알려진 함정

- **웹 편집기(contenteditable·Draft.js)의 위치** (시험용 Chromium 실측): 글에는 줄바꿈을 넣어 주면서 위치에는 세지 않고, 빈 줄은 글에서 빼면서 위치에는 센다. 접근성 쓰기는 성공이라 답하고 무시한다(뒤에 있는 창에서 확인). 글자 위치(BoundsForRange)는 nil. → 선택된 글을 읽어 확인하고, 글 조각의 위치로 막대를 그린다.
  - 빈 줄이 글에서 빠지므로 **웹 편집기에서는 빈 줄로 섹션이 나뉘지 않는다.**
- 막대가 안 뜨는 이유: `/usr/bin/log show --last 1d --predicate 'subsystem == "com.aib.fix4me" AND category == "status"'` (앱과 이유만, 글 내용 없음)

- **손쉬운 사용을 켰는데 "필요함"이 남는다는 보고 (2026-11-25, 원인 미확정)**: 항목 재허용·앱 재시작 뒤 정상. 실행 중 프로세스도 tccd 에서 허용 응답을 받았으므로 "프로세스가 옛 값을 붙잡는다"는 설명은 맞지 않는다.
- Dock 아이콘 표시(일반 앱): 메뉴 막대 아이콘은 노치·메뉴 막대 정리 앱에 가려질 수 있어서. 다시 열기(Dock 클릭·Spotlight)는 설정 창을 띄운다.
