#!/bin/sh
set -e
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

# Xcode Cloud 환경에서 Swift 매크로(MLXHuggingFaceMacros) 신뢰 오류 해결.
#
# 무결성 검증 방식:
#   워킹 트리 파일은 Xcode Cloud의 SPM 해결 단계에서 갱신될 수 있으므로
#   git show HEAD:<path>로 HEAD에 커밋된 내용을 읽어 해시를 비교한다.
#   패키지를 업데이트할 때는 Package.resolved와 .package-resolved.sha256를
#   함께 커밋해야 한다.
# 
# Xcode Cloud는 이 스크립트를 ci_scripts/ 디렉터리에서 실행하므로
# 저장소 루트를 기준으로 경로를 계산한다.
RESOLVED_REPO_PATH="ios/todo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
EXPECTED_HASH_FILE="$REPO_ROOT/.package-resolved.sha256"

if [ ! -f "$EXPECTED_HASH_FILE" ]; then
  echo "[CI] $EXPECTED_HASH_FILE 파일이 없습니다. shasum -a 256 \"$RESOLVED_REPO_PATH\" | cut -d' ' -f1 로 생성 후 커밋하세요." >&2
  exit 1
fi

EXPECTED_HASH=$(cat "$EXPECTED_HASH_FILE" | tr -d '[:space:]')

# SPM이 워킹 트리 파일을 갱신했을 수 있으므로 HEAD 커밋의 내용으로 해시를 계산
if ! git -C "$REPO_ROOT" cat-file -e "HEAD:$RESOLVED_REPO_PATH" 2>/dev/null; then
  echo "[CI] git show HEAD:\"$RESOLVED_REPO_PATH\" 실패 — Package.resolved가 커밋에 포함되지 않았습니다." >&2
  exit 1
fi

COMMITTED_HASH=$(git -C "$REPO_ROOT" show HEAD:"$RESOLVED_REPO_PATH" | shasum -a 256 | cut -d' ' -f1)

if [ "$COMMITTED_HASH" != "$EXPECTED_HASH" ]; then
  echo "[CI] Package.resolved 해시 불일치." >&2
  echo "  기대: $EXPECTED_HASH" >&2
  echo "  커밋: $COMMITTED_HASH" >&2
  echo "  패키지 변경 후 .package-resolved.sha256를 갱신하고 함께 커밋하세요." >&2
  exit 1
fi

echo "[CI] Package.resolved 무결성 확인 완료 (SHA-256: $COMMITTED_HASH) — 매크로 검증 우회 적용"
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
