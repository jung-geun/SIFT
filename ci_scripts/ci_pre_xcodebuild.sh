#!/bin/sh
set -e

# Xcode Cloud 환경에서 Swift 매크로(MLXHuggingFaceMacros) 신뢰 오류 해결.
#
# 주의: Xcode Cloud는 ci_pre_xcodebuild.sh 실행 전에 SPM 패키지 해결을 수행하므로
# Package.resolved가 HEAD 커밋과 달라질 수 있다. git diff 비교 대신
# 커밋 이력에 Package.resolved가 추적되는지만 검증한다.

RESOLVED="todo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if [ ! -f "$RESOLVED" ]; then
  echo "[CI] Package.resolved 파일을 찾을 수 없습니다: $RESOLVED" >&2
  exit 1
fi

# Package.resolved가 git에서 추적 중인지 확인 (전혀 untracked이면 의심)
if ! git ls-files --error-unmatch "$RESOLVED" > /dev/null 2>&1; then
  echo "[CI] Package.resolved가 git 추적 대상이 아닙니다. 커밋 후 재시도하세요." >&2
  exit 1
fi

echo "[CI] Package.resolved 확인 완료 — 매크로 검증 우회 적용"
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
