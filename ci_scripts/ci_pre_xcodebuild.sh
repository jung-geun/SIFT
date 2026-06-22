#!/bin/sh
set -e

# Xcode Cloud: Swift 매크로(MLXHuggingFaceMacros 등) 신뢰 검증을 건너뜀.
# CI 환경은 매 빌드마다 새 환경을 사용해 사용자별 신뢰 승인이 없으므로,
# IDESkipMacroFingerprintValidation 플래그를 사전에 설정한다.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
