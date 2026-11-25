# Fix4me 아키텍처 (Mac, 미리 교정 + 단축키)

포커스된 입력창을 **클릭 없이 단축키 한 번으로** 교정하는 macOS 메뉴 막대 앱. 본인 전용(배포 안 함).

## 흐름

```
⌃⌥F (Carbon 전역 단축키)
  → AXText.focused()        앞 앱의 포커스 요소·값·선택 범위 (Chrome/Electron 은 접근성 트리 강제 활성화 후 재시도)
  → TextScope.plan()        선택 영역 우선. 자동 = 바뀐 섹션(최대 8개), 없으면 커서 섹션 / 커서 섹션 / 모든 섹션
  → CorrectionService       캐시 적중이면 즉시, 미리 교정이 보내 둔 요청이면 이어받음
  → OpenRouterClient        anthropic/claude-haiku-5.5, 설정의 교정 강도별 프롬프트, provider.sort=latency, {"corrected": ...} JSON
  → CorrectionParser        JSON 추출 + 길이 비율로 "대답/번역" 응답 차단
  → 스냅샷 대조              기다리는 동안 문단이 바뀌었으면 쓰지 않음
  → TextDiff.edits          줄 수가 같으면 바뀐 줄만, 다르면 한 구간 (안 바뀐 줄의 서식·멘션 보존)
  → AXText.replace()        뒤에서부터. AX 직접 쓰기 → 값 확인 → 안 바뀌었으면 붙여넣기(포커스 재확인, 클립보드 복구)
  → HUD                     텍스트 아래 "N곳 고쳤어요 · 0.9초 · 않 → 안"
⌃⌥Z → 같은 입력창·같은 자리에 교정 결과가 그대로 있을 때만 원문으로 되돌림
```

## 파일

| 경로 | 역할 |
|---|---|
| `Fix4me/App/main.swift`, `AppDelegate.swift` | 메뉴 막대 앱 수명주기, 단축키 등록, 설정 창 |
| `Fix4me/App/CorrectionController.swift` | 교정·되돌리기 전체 흐름 (MainActor, 동시 실행 1개) |
| `Fix4me/Core/AXText.swift` | Accessibility 읽기·쓰기·좌표, 붙여넣기 대체 경로 |
| `Fix4me/Core/HotKeyCenter.swift` | Carbon `RegisterEventHotKey` 래퍼 |
| `Fix4me/Core/OpenRouterClient.swift` | 교정 요청 1회, 오류 원문(status·metadata.raw) 보존 |
| `Fix4me/App/Precomputer.swift` | 미리 교정: 0.3초마다 감시, 0.9초 멈추면 요청, 표시 (분당 30건 상한, 오류 시 쉼) |
| `Fix4me/App/CorrectionService.swift`, `Core/CorrectionCache.swift` | 결과 캐시(메모리, 300개)와 진행 중 요청 공유 |
| `Fix4me/UI/Indicator.swift`, `DiffText.swift`, `Core/IndicatorLayout.swift` | 고칠 문단 왼쪽 막대(위치를 모르면 모서리 배지), 롤오버 미리보기(원문 취소선 + 고친 글, 적용/무시) |
| `Fix4me/Core/PersonalDictionary.swift` | 개인 사전: 프롬프트 지시 + 어긴 줄은 원문으로 |
| `Fix4me/Core/PrecomputeFilter.swift`, `Prefs.swift` | 보내지 않을 글 판정, 설정값·제외 앱 |
| `Fix4me/Core/Keychain.swift` | API 키 저장 (로그인 키체인) |
| `Fix4me/Core/Sectioner.swift` | 규칙만으로 섹션 나누기: 줄 종류 → 경계 3단계 → 크기 맞추기, 참고 문맥(가까운 제목 + 앞 덩어리) |
| `Fix4me/Core/TextScope.swift`, `TextDiff.swift`, `CorrectionParser.swift` | 순수 로직 (단위 테스트 대상) |
| `Fix4me/Core/CorrectionLevel.swift` | 교정 강도(교정·다듬기·다시 쓰기): 프롬프트 지시·길이 범위·저장 |
| `Fix4me/UI/HUD.swift` | 포커스를 빼앗지 않는 플로팅 패널 |
| `Fix4me/UI/SettingsView.swift` | 권한 상태·키 저장·연결 테스트 |

## 빌드

```bash
./scripts/build.sh        # xcodegen → xcodebuild → Apple Development 인증서 서명 → dist/Fix4me.app
xcodebuild -project Fix4me.xcodeproj -scheme Fix4me -derivedDataPath build/DerivedData test
dist/Fix4me.app/Contents/MacOS/Fix4me --compare "비교할 문장"   # 세 강도 결과 비교 (개발용)
dist/Fix4me.app/Contents/MacOS/Fix4me --sections 파일               # LLM 없이 섹션 경계만 출력 (개발용)
```

- `Fix4me.xcodeproj` 는 `project.yml` 에서 생성 (커밋 안 함).
- ad-hoc 서명은 빌드마다 서명 신원이 바뀌어 손쉬운 사용 권한이 풀린다 → 고정 인증서로 서명. 다른 인증서는 `FIX4ME_SIGN_ID`.
- 샌드박스 없음 (Accessibility·이벤트 게시가 필요해 Mac App Store 배포 불가 — 본인 전용이라 무관).

## 다음 단계

1. 앱별 쓰기 방식 기억 (AX 직접 쓰기가 안 되는 앱은 처음부터 붙여넣기)
2. iPhone (키보드 툴바 버튼 / 뒷면 탭 단축어)

## 미리 교정 규칙

- 입력창에 **원래 있던 글은 보내지 않는다.** 포커스를 얻은 때의 글이 기준이고, 사용자가 바꾼 뒤부터 본다.
- 보내지 않음: 비밀번호 입력(시스템 보안 입력 포함), 검색창, 브라우저 주소창, API 키처럼 보이는 글, 띄어쓰기 없는 영숫자 한 덩어리, 제외 앱(기본: 터미널·비밀번호 관리자·코드 편집기).
- 코드 블록·표·인용·구분선·주소만 있는 줄·서명은 섹션에서 빠지므로 보내지도 고치지도 않는다 (직접 선택하면 예외).
- 일부 문단만 고치면 그 문단만 처리된 것으로 본다 (`TextScope.baseline(_:adding:)`).

## 알려진 함정

- **손쉬운 사용을 켰는데 "필요함"이 남는다는 보고 (2026-11-25, 원인 미확정)**: 항목 재허용·앱 재시작 뒤 정상. 실행 중 프로세스도 tccd 에서 허용 응답을 받았으므로 "프로세스가 옛 값을 붙잡는다"는 설명은 맞지 않는다.
- Dock 아이콘 표시(일반 앱): 메뉴 막대 아이콘은 노치·메뉴 막대 정리 앱에 가려질 수 있어서. 다시 열기(Dock 클릭·Spotlight)는 설정 창을 띄운다.
