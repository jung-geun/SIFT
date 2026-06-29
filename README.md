# SIFT

> 난잡한 일정을 채로 걸러 중요한 것을 추려주는 TODO 관리 시스템

SIFT는 이메일·캘린더·수동 입력으로 쌓이는 할 일들을 기본적으로 온디바이스 AI가 자동으로 분류·정리해 **지금 당장 해야 할 것**만 보여주는 iOS/macOS TODO 앱입니다. 사용자가 선택하면 Gemini API를 보조 라우트로 사용할 수 있습니다.

---

## 핵심 기능

### 🔍 자동 분석 & 정리
- **기본값은 온디바이스 AI** (Apple Foundation Models / MLX Qwen) 로 이메일을 분석해 마감 할 일을 자동 추출
- Gemini를 선택하면 TODO 정렬·페르소나·캘린더 컨텍스트를 사용자 API 키로 Google Gemini API에 보낼 수 있음
- 추출된 할 일은 **등록 대기열** (검토 필요) 또는 **진행중** (즉시 처리)으로 분류

### 📬 Gmail 연동
- Gmail OAuth로 받은편지함 스캔 → 마감·일정 자동 추출 → 할 일 등록
- 원본 메일 딥링크: Gmail 앱(`googlegmail:///cv=`) 우선, Mail.app(`message://`) 폴백, 최종 Gmail 웹
- 저장 식별자: Gmail message.id · RFC822 Message-ID · threadId (3종 모두 보존)

### 📅 캘린더 연동
- **마감일이 있는 할 일**은 시스템 캘린더에 자동 등록 (EventKit)
- 캘린더 이벤트 → 등록 대기열 자동 import (30일 이내, 7일 쿨다운)
- **반복 일정**: 1주일 이내로 마감이 다가오면 대기열 → 진행중 자동 승급
- 완료 처리 시 캘린더 이벤트 삭제 또는 알람만 끄기 (설정에서 선택)

### 📊 숨김 Audit 기록
- 등록 시각·완료 시각·삭제 시각·출처·종류를 자동 기록 (UI에 미노출)
- 페르소나·행동 패턴 분석에 활용 — 처리 소요 시간·할 일 유형 통계

### 🔒 프라이버시 우선
- **기본값은 이메일 본문 외부 전송 없음** — 온디바이스 AI(AFM/NSDataDetector)만 처리
- Gemini 메일 본문 분석은 사용자가 별도 동의 토글을 켠 경우에만 활성화

---

## 아키텍처

```
┌─────────────────────────────────────────────────────┐
│                      SIFT iOS App                   │
│                                                     │
│  Views (SwiftUI)                                    │
│  ├── TodoListView  ── 필터링·우선순위·캘린더 정책   │
│  ├── TodoDetailView ─ 원본 메일 딥링크              │
│  └── PersonaSettingsView ─ AI·캘린더·Gmail 설정     │
│                                                     │
│  Models (SwiftData @Model)                          │
│  ├── Todo          ─ 핵심 할 일 (CloudKit 호환)     │
│  ├── Persona       ─ 사용자 페르소나                │
│  └── TaskAuditEvent ─ 삭제 lifecycle 스냅샷         │
│                                                     │
│  Services                                           │
│  ├── EmailService       ── Gmail REST API           │
│  ├── CalendarService    ── EventKit                 │
│  ├── LLMAutomationOrchestrator ─ 포그라운드 AI      │
│  ├── FoundationModelsService   ─ Apple FM (ANE)     │
│  ├── OnDeviceLLMService        ─ MLX Qwen           │
│  └── MemoryService      ── 패턴·페르소나 분석       │
└─────────────────────────────────────────────────────┘
```

**AI 라우팅 원칙**
- 페르소나 생성·패턴 분석·이메일 분석: 기본값은 **온디바이스 경로** 유지
- TODO 자동 정렬: 사용자 선택 모델 우선 (AFM / MLX Qwen / Gemini API fallback)
- Gmail 본문은 기본적으로 온디바이스만 사용하며, 별도 opt-in 시에만 Gemini로 전송 가능

---

## 빌드 요구사항

| 항목 | 버전 |
|------|------|
| Xcode | 26.5+ |
| iOS Deployment Target | 26.5 |
| 테스트 기기 | iPhone 17 (iOS 27+ beta 권장) |
| Apple Developer | 무료 계정 가능 (CloudKit·APNs 제외) |

### 주요 패키지
- `mlx-swift` 0.31.4 + `mlx-swift-lm` 3.31.3 — MLX Qwen 온디바이스 추론
- FoundationModels.framework (시스템 프레임워크, iOS 26+)

### Gmail OAuth 설정
1. Google Cloud Console에서 OAuth 2.0 클라이언트 ID 생성 (iOS 앱 유형)
2. `GoogleService-Info.plist` 또는 클라이언트 ID를 프로젝트에 등록
3. URL Scheme: `com.googleusercontent.apps.{CLIENT_ID}` (Info.plist에 이미 등록됨)

---

## 프라이버시 불변식

> **기본값은 이메일 본문 외부 전송 금지입니다.**

- 포그라운드: Apple Foundation Models (ANE 온디바이스) 또는 MLX Qwen (기기 내 DRAM)
- 백그라운드: NSDataDetector (Apple 시스템 프레임워크, 온디바이스)
- Gemini를 선택하면 TODO 제목·메모·마감·페르소나·캘린더 컨텍스트가 사용자의 API 키로 Google Gemini API에 전송될 수 있음
- Gmail 본문은 별도 동의 토글을 켠 경우에만 Gemini API로 전송될 수 있음

---

## 법적 문서

| 문서 | GitHub | 웹 |
|------|--------|-----|
| 개인정보 처리방침 | [docs/privacy-policy.md](docs/privacy-policy.md) | [jung-geun.github.io/SIFT/privacy-policy.html](https://jung-geun.github.io/SIFT/privacy-policy.html) |
| 서비스 약관 | [docs/terms-of-service.md](docs/terms-of-service.md) | [jung-geun.github.io/SIFT/terms-of-service.html](https://jung-geun.github.io/SIFT/terms-of-service.html) |

---

## 라이선스

Private repository — jung-geun/SIFT
