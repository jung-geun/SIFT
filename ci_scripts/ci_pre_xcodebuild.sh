#!/bin/sh
set -e

# Xcode Cloud 환경에서 Swift 매크로(MLXHuggingFaceMacros) 신뢰 오류 해결.
#
# 보안 고려:
#   IDESkipMacroFingerprintValidation은 모든 매크로 검증을 건너뛰므로,
#   신뢰할 수 없는 매크로 패키지가 추가되어도 CI가 허용하게 된다.
#   이를 완화하기 위해 Package.resolved가 git 커밋 내용과 동일한지 먼저 검증한다.
#   Package.resolved 변경 없이 알려진 버전만 빌드되는 경우에만 검증을 우회한다.

RESOLVED="todo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if [ ! -f "$RESOLVED" ]; then
  echo "[CI] Package.resolved 파일을 찾을 수 없습니다: $RESOLVED" >&2
  exit 1
fi

# 커밋된 Package.resolved와 현재 파일이 다르면 미검토 패키지 추가를 의심해 중단
if ! git diff --exit-code HEAD -- "$RESOLVED" > /dev/null 2>&1; then
  echo "[CI] Package.resolved가 HEAD 커밋과 다릅니다. 새 매크로 패키지를 검토 후 커밋하세요." >&2
  exit 1
fi

echo "[CI] Package.resolved 무결성 확인 완료 — 매크로 검증 우회 적용"
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
