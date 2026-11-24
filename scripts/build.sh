#!/bin/zsh
# Fix4me 빌드 + 고정 인증서 서명 → dist/Fix4me.app
# 손쉬운 사용(TCC) 권한은 서명 신원에 묶인다. ad-hoc 서명은 빌드마다 신원이 바뀌어 권한을 다시 받아야 하므로
# 키체인의 Apple Development 인증서로 서명한다. 다른 인증서를 쓰려면 FIX4ME_SIGN_ID 에 이름을 지정.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG="${1:-Debug}"
xcodegen generate --quiet
xcodebuild -project Fix4me.xcodeproj -scheme Fix4me -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData -quiet build

APP="build/DerivedData/Build/Products/$CONFIG/Fix4me.app"
SIGN_ID="${FIX4ME_SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [[ -z "$SIGN_ID" ]]; then
  echo "서명 인증서를 찾지 못했습니다 (FIX4ME_SIGN_ID 지정 필요)" >&2
  exit 1
fi
codesign --force --sign "$SIGN_ID" "$APP"

mkdir -p dist
rm -rf dist/Fix4me.app
cp -R "$APP" dist/
echo "빌드 완료: dist/Fix4me.app ($CONFIG, 서명: $SIGN_ID)"
