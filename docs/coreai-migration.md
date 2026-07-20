# Core AI & Foundation Models 마이그레이션 분석

> 작성: 2026-06 | 기준: WWDC 2026 "Meet Core AI", "What's New in Foundation Models"

## 1. 배경 및 목적

현재 앱은 온디바이스 추론에 **MLX(Qwen3.5-4B-4bit, GPU, ~2.8GB)** 를 사용하지만
GPU 백그라운드 제약·메모리 경고·idleTimer 레이스로 인한 **CancellationError** 버그가 반복 발생함.
이 문서는 Apple의 두 신규 프레임워크를 분석해 **대체 vs 추가** 여부를 결정하기 위한 기술 검토 자료임.

---

## 2. 프레임워크 개요

### 2-A. Foundation Models (Apple Foundation Model, AFM)

| 항목 | 내용 |
|---|---|
| 최소 버전 | iOS 26.0 (일부 API 26.4 백포트) |
| 실행 위치 | Neural Engine (ANE) |
| 모델 | 시스템 AFM — 다운로드 불필요, Apple 관리 |
| 주요 API | `SystemLanguageModel`, `LanguageModelSession`, `@Generable`, `@Guide` |
| 특징 | Guided Generation으로 타입 안전 출력, 비전 첨부파일, Dynamic Profiles |
| 시스템 도구 | OCRTool, BarcodeReaderTool, Spotlight RAG (iOS 26.4+) |
| 파트너 모델 | `PrivateCloudComputeLanguageModel`, 파트너 모델 패키지 (iOS 27+) |
| 배포 타깃 호환 | ✅ iOS 26.5 배포 타깃 유지 가능 |

**WWDC 2026 주요 신규 기능:**
- `LanguageModel` 프로토콜 추상화 → `CoreAILanguageModel`(ANE), `MLXLanguageModel`(GPU)
- Guided Generation 범위·패턴 제약: `@Guide(.range(0.01...1.0))`
- Vision 첨부파일: `LanguageModelSession.Attachment.image()`
- Dynamic Profiles: 작업별 모델 특화 설정
- 오픈소스 백엔드: `CoreAILanguageModel`·`MLXLanguageModel` 소스 공개

### 2-B. Core AI

| 항목 | 내용 |
|---|---|
| 최소 버전 | **iOS 27** (Xcode 27 베타 필요, 2026 가을 정식) |
| 실행 위치 | ANE / GPU / CPU (선택) |
| 모델 형식 | `.aimodel` (coreai-torch 변환 필요) |
| 주요 API | `AIModel`, `InferenceFunction`, `NDArray`, `AIModelCache` |
| 특징 | 커스텀 모델 ANE 실행, AOT 컴파일(`specialize`), 배치 추론 |
| 도구 | `coreai-torch`, `coreai-optimization` (Python, pip 설치) |
| 배포 타깃 호환 | ❌ iOS 27 필요 (26.5 고정 시 빌드 제외 스캐폴드만) |

> **버전 오해 주의**: 일부 요약 자료에 "iOS 20"으로 기재된 것은 연도 기반 명칭을 오인한 오류임.
> 실제 배포 대상: iOS 27 / macOS 27 / Xcode 27.

---

## 3. 현재 MLX 경로의 취약점

```
MLX (Qwen3.5-4B, GPU)
├── GPU 백그라운드 제약 (iOS 26.2+) → 취소
├── 메모리 경고 시 즉시 unload → 취소
├── idleTimer 레이스 (120초 잔여 타이머) → 취소
├── ~2.8GB 상주 메모리 → OOM jetsam 위험
└── 모델 다운로드 필요 (~2.3GB, 사용자 동의)
```

---

## 4. 대체 vs 추가 결론

### 텍스트 생성 작업 (페르소나, 우선순위)

| 경로 | 적용 시기 | 장점 | 단점 |
|---|---|---|---|
| **FM SystemLanguageModel** | **즉시 (iOS 26.5)** | ANE, 취소 버그 구조적 해소, 다운로드 없음, Guided Generation | 기기·Apple Intelligence 필요 |
| Core AI (커스텀 모델) | iOS 27 이후 | 커스텀 Qwen ANE 실행 가능 | .aimodel 변환 작업, iOS 27 필요 |
| MLX (현재) | 폴백 유지 | FM 비가용 기기 커버 | GPU 취약성 지속 |

**권장: FM SystemLanguageModel → MLX 폴백 → Heuristic 폴백** 3단계 체인.

### 비전·멀티모달 작업 (MLX VLM)

FM의 Vision 첨부파일(iOS 26.4+)이 현재 MLX VLM 기능을 대체 가능.
단, 현재 앱에서 VLM 기능이 핵심이 아니므로 별도 검토 필요.

---

## 5. Foundation Models 재링크 절차

> 과거 iOS 27 베타 XPC 크래시로 링크를 제거했음. 최신 베타에서 재검증 필요.

1. **프레임워크 추가**: Xcode > 프로젝트 > 타깃 > "Frameworks, Libraries, and Embedded Content"
   → `+` 버튼 → `FoundationModels.framework` 추가.
2. **최소 프로브 빌드**: `FoundationModelsService.isAvailable` 로그 출력 + 단발 `session.respond()` 1회.
3. **실기기 테스트**: iPhone 15 Pro+ / iOS 27 베타 실기기에서 XPC 크래시 재발 여부 확인.
4. **크래시 없음** → 페르소나/우선순위 FM 경로 활성화.
5. **크래시 재발** → `FoundationModelsService.swift`의 `#if canImport(FoundationModels)` 블록 유지,
   프레임워크 링크 제거, MLX+Heuristic 폴백으로 운용.

코드는 `#if canImport(FoundationModels)` + `@available(iOS 26.0, *)` 로 이중 격리되므로
링크 제거만으로 컴파일 아웃 가능.

---

## 6. Core AI 구현 로드맵 (iOS 27 대비)

### 6-A. .aimodel 변환 흐름

```
HuggingFace (Qwen3.5-4B-MLX-4bit)
  ↓ scripts/convert_qwen_to_aimodel.py
  ↓ coreai-torch: PyTorch 모델 로드
  ↓ coreai-optimization: 4-bit 양자화 + ANE 최적화
  → Qwen3.5-4B-ANE.aimodel
  → Bundle 또는 Application Support에 배포
```

### 6-B. Swift 통합 (빌드 제외 스캐폴드)

`ios/todo/Services/CoreAILanguageModelBackend.swift` 참조.

```swift
// COREAI_PREVIEW 플래그 활성화 시 컴파일
let backend = CoreAILanguageModelBackend()
try await backend.loadModel()
let logits = try await backend.forward(inputTokenIDs: tokens)
```

활성화: `OTHER_SWIFT_FLAGS` += `-DCOREAI_PREVIEW` (Xcode Build Settings).

### 6-C. 선행 조건

- Xcode 27 (베타 이상)
- Core AI 툴체인: `pip install coreai-torch coreai-optimization`
- macOS 26+ 빌드 머신 (ANE 컴파일 최적화)

---

## 7. 버전 매트릭스

| 기능 | 최소 iOS | 프레임워크 | 비고 |
|---|---|---|---|
| Heuristic Engine | 모든 버전 | 없음 | 항상 폴백 가능 |
| MLX (Qwen, GPU) | 26.0 | MLXLLM (SPM) | 백그라운드 취약 |
| FM 온디바이스 (AFM) | **26.0** | FoundationModels | Apple Intelligence 필요 |
| FM API 확장 (contextSize 등) | 26.4 | FoundationModels | 백포트 |
| Core AI | **27.0** | CoreAI | Xcode 27 필요 |
| FM 파트너 모델 | 27.0 | FoundationModels | 2026 가을 |

---

## 8. 참고 자료

- WWDC 2026: "Meet Core AI" (Session XXXXX)
- WWDC 2026: "What's New in Foundation Models" (Session XXXXX)
- Apple Developer: https://developer.apple.com/documentation/coreai/
- Apple Developer: https://developer.apple.com/documentation/foundationmodels/
- coreai-torch (PyPI): `pip install coreai-torch`
