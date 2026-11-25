# Fix4me 아키텍처 (v0.1 — Mac, 단축키 교정)

포커스된 입력창을 **클릭 없이 단축키 한 번으로** 교정하는 macOS 메뉴 막대 앱. 본인 전용(배포 안 함).

## 흐름

```
⌃⌥F (Carbon 전역 단축키)
  → AXText.focused()        앞 앱의 포커스 요소·값·선택 범위 (Chrome/Electron 은 접근성 트리 강제 활성화 후 재시도)
  → TextScope.target()      선택 영역 있으면 그것, 없으면 커서가 있는 문단 (최대 4000자, 비밀번호 입력란 제외)
  → OpenRouterClient        anthropic/claude-haiku-5.5, 설정의 교정 강도별 프롬프트, provider.sort=latency, {"corrected": ...} JSON
  → CorrectionParser        JSON 추출 + 길이 비율로 "대답/번역" 응답 차단
  → 스냅샷 대조              기다리는 동안 문단이 바뀌었으면 쓰지 않음
  → TextDiff.changedSpan    공통 접두·접미를 뺀 최소 구간만
  → AXText.replace()        AX 직접 쓰기 → 값 확인 → 안 바뀌었으면 붙여넣기(클립보드 복구)
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
| `Fix4me/Core/Keychain.swift` | API 키 저장 (로그인 키체인) |
| `Fix4me/Core/TextScope.swift`, `TextDiff.swift`, `CorrectionParser.swift` | 순수 로직 (단위 테스트 대상) |
| `Fix4me/Core/CorrectionLevel.swift` | 교정 강도(교정·다듬기·다시 쓰기): 프롬프트 지시·길이 범위·저장 |
| `Fix4me/UI/HUD.swift` | 포커스를 빼앗지 않는 플로팅 패널 |
| `Fix4me/UI/SettingsView.swift` | 권한 상태·키 저장·연결 테스트 |

## 빌드

```bash
./scripts/build.sh        # xcodegen → xcodebuild → Apple Development 인증서 서명 → dist/Fix4me.app
xcodebuild -project Fix4me.xcodeproj -scheme Fix4me -derivedDataPath build/DerivedData test
dist/Fix4me.app/Contents/MacOS/Fix4me --compare "비교할 문장"   # 세 강도 결과 비교 (개발용)
```

- `Fix4me.xcodeproj` 는 `project.yml` 에서 생성 (커밋 안 함).
- ad-hoc 서명은 빌드마다 서명 신원이 바뀌어 손쉬운 사용 권한이 풀린다 → 고정 인증서로 서명. 다른 인증서는 `FIX4ME_SIGN_ID`.
- 샌드박스 없음 (Accessibility·이벤트 게시가 필요해 Mac App Store 배포 불가 — 본인 전용이라 무관).

## 다음 단계

1. **H3 선계산**: 입력이 멈출 때마다 백그라운드에서 미리 교정 → 단축키는 대기 0초로 즉시 적용 + 커서 옆 "N" 배지
2. 앱별 쓰기 방식 기억 (AX 직접 쓰기가 안 되는 앱은 처음부터 붙여넣기)
3. iPhone (키보드 툴바 버튼 / 뒷면 탭 단축어)

## 알려진 함정

- **손쉬운 사용을 허용해도 실행 중인 앱은 계속 "필요함"**: `AXIsProcessTrusted()` 는 프로세스 안에서 값을 붙잡고 있어 폴링해도 안 바뀐다 (tccd 로그는 authValue=2 허용). 허용 후 앱을 다시 켜야 반영된다.
- Dock 아이콘 표시(일반 앱): 메뉴 막대 아이콘은 노치·메뉴 막대 정리 앱에 가려질 수 있어서. 다시 열기(Dock 클릭·Spotlight)는 설정 창을 띄운다.
