---
layout: default
title: SIFT — 할 일 관리가 귀찮은 사람을 위한 앱
description: 메일·캘린더에서 할 일을 자동으로 찾아내고, AI가 지금 뭐부터 해야 하는지 정렬해주는 온디바이스 TODO 앱
---

<div align="center">

<h1>🧺 SIFT</h1>
<p><strong>난잡한 일정을 채로 걸러 중요한 것만 추려주는 TODO 앱</strong></p>

<p>
  <img src="https://img.shields.io/badge/iOS-26.5+-000000?style=flat&logo=apple&logoColor=white" alt="iOS">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?style=flat&logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/AI-On--Device-34C759?style=flat&logo=apple&logoColor=white" alt="On-Device AI">
  <img src="https://img.shields.io/badge/상태-개발중-orange?style=flat" alt="Status">
</p>

<p>
  <a href="https://testflight.apple.com/join/qQNuSmj4"><strong>🧪 TestFlight 베타 신청</strong></a>
  &nbsp;·&nbsp;
  <a href="./privacy-policy.html">개인정보 처리방침</a>
  &nbsp;·&nbsp;
  <a href="./terms-of-service.html">서비스 약관</a>
</p>

</div>

---

## 왜 만들었나요

TODO 앱을 쓰려고 했는데, 어느 순간 **TODO 앱을 관리하는 일 자체가 또 하나의 TODO**가 되어버렸습니다.

해야 할 일은 계속 생깁니다.

- 메일로 뭔가 요청이 오고
- 캘린더에는 일정이 쌓이고
- 갑자기 생각난 일은 메모장 어딘가에 적히고
- 막상 TODO 앱을 열면 **뭐부터 해야 할지 다시 정리해야 합니다**

이 과정이 너무 귀찮아서 이런 생각을 했습니다.

> "그냥 알아서 중요한 것부터 보여주면 안 되나?"

**SIFT는 여기서 시작했습니다.**

---

## 기존 TODO 앱에서 아쉬웠던 것

### 우선순위를 내가 직접 정해야 한다

이게 중요한 일인지, 오늘 해야 하는지, 미뤄도 되는지, 이미 늦었지만 아직 해야 하는지 — 이걸 매번 직접 판단해야 합니다. SIFT는 사용자의 일정, 마감, 행동 패턴을 보고 *"지금은 이걸 먼저 보는 게 좋겠다"* 고 정렬해줍니다.

### 마감이 지났다고 끝난 일이 아니다

"오늘 점심 메뉴 정하기"는 시간이 지나면 그냥 끝난 일이지만, "서류 제출"이나 "메일 회신"은 늦었더라도 다시 챙겨야 합니다. SIFT는 지나면 무시해도 되는 일과, 지나도 반드시 처리해야 하는 일을 구분합니다.

### 메일과 캘린더 안에 숨어 있는 일을 놓친다

- *"이번 주까지 확인 부탁드립니다"*
- *"회의 전 자료 공유해주세요"*
- *"이 메일 확인 후 회신 부탁드립니다"*

중요한 메일도 바쁠 때는 그냥 묻힙니다. SIFT는 메일과 캘린더를 주기적으로 확인하고, 필요한 항목을 TODO로 자동 끌어올립니다.

---

## SIFT가 하는 일

```
메일 / 캘린더
      ↓  기본은 온디바이스 AI 분석
  할 일 자동 추출
      ↓  필요 시 Gemini fallback / 선택형 API 라우팅
  중요도 자동 정렬
      ↓
  지금 봐야 할 것만 화면 맨 위로
```

1. 받은편지함과 캘린더를 조용히 스캔합니다
2. 마감·요청·회신이 필요한 항목을 찾아냅니다
3. 필요한 항목을 TODO로 등록합니다 (검토 대기열 또는 즉시 진행)
4. 사용자의 행동 패턴과 페르소나를 바탕으로 중요도를 계산합니다
5. **지금 봐야 할 일을 먼저 보여줍니다**

SIFT는 *"TODO를 열심히 관리하게 만드는 앱"* 이 아니라, **TODO 관리를 덜 해도 되게 만드는 앱**에 가깝습니다.

---

## 핵심 기능

| 기능 | 설명 |
|------|------|
| 📬 **Gmail 자동 분석** | OAuth 읽기 전용 연동 · 마감·요청 자동 추출 · 원본 메일 딥링크 |
| 📅 **캘린더 연동** | 마감 있는 TODO → 시스템 캘린더 자동 등록 (EventKit) |
| 🧠 **AI 라우팅** | 기본 온디바이스 · 필요 시 Gemini API fallback/선택 |
| 👤 **페르소나 학습** | 행동 패턴 분석 → 우선순위 개인화 |
| ☁️ **iCloud 동기화** | SwiftData + CloudKit Private DB (선택 사항) |
| 🔒 **프라이버시 우선** | Gmail 본문은 기본 외부 전송 금지 · 별도 동의 시에만 Gemini 전송 |

---

## 개인 데이터는 개인적인 곳에

메일과 캘린더는 생각보다 민감합니다. 업무 내용, 생활 패턴, 약속, 인간관계가 다 들어 있습니다.

그래서 SIFT는 기본적으로 **온디바이스에서 동작**합니다.

- ✅ 기본 분석: 온디바이스 LLM (Apple Foundation Models / MLX Qwen)
- ✅ 데이터 저장: 기기 로컬 또는 본인의 iCloud Private DB
- ✅ **TODO/페르소나/캘린더 컨텍스트**: Gemini를 선택한 경우에만 사용자 API 키로 외부 전송 가능
- ✅ **이메일 본문**: 기본은 기기 밖 전송 금지, 별도 opt-in 시에만 Gemini 전송

---

## 현재 진행 상황

### ✅ 완료

- SwiftData 기반 로컬 / iCloud 데이터 저장소
- Gmail OAuth2 연동 및 이메일 자동 분석
- 이메일 딥링크 (Gmail 앱 → Mail.app → 웹 순 폴백)
- 캘린더 마감 자동 등록 및 완료 처리 정책 연동
- 앱-시스템 캘린더 실시간 양방향 동기화
- 완료된 항목 1개월 경과 시 자동 숨김
- 시간대·태그별 처리 속도 기반 행동 패턴 분석
- 온디바이스 LLM (Qwen3.5 2B, MLX 최적화)
- iCloud 동기화 설정 + 기기별 로컬 설정 분리

### 🔄 진행 중

- Qwen3.5 4B 고성능 모델 기기 메모리 최적화
- 백그라운드 캘린더 변경 감지 정확도 향상

### 📋 다음 예정

- 다중 이메일 계정 연동 (IMAP 등 Gmail 외 서비스)
- Apple Foundation Models 정식 버전 대응 및 통합
- 커스텀 파인튜닝 LLM 교체 지원

---

## 설치 방법 (TestFlight 베타)

SIFT는 현재 TestFlight 베타 테스트를 준비 중입니다.

**요구사항**

| 항목 | 버전 |
|------|------|
| iOS | 26.5 이상 |
| 기기 | iPhone (Apple Silicon) |
| Apple Intelligence | 온디바이스 AI 기능 사용 시 필요 |

**설치 순서**

1. [TestFlight 앱](https://apps.apple.com/kr/app/testflight/id899247664) 설치
2. 아래 링크로 베타 참여 신청 (활성화 후 이용 가능)
3. TestFlight에서 SIFT 설치

<div align="center">
<a href="https://testflight.apple.com/join/qQNuSmj4">
  <strong>🧪 베타 테스트 참여하기</strong>
</a>
<br><br>
<em>현재 준비 중입니다. 링크가 활성화되면 위 버튼에서 바로 설치할 수 있습니다.</em>
</div>

---

## 써보고 후기 주세요

SIFT는 처음부터 완벽한 정답을 정해놓고 만들기보다, **실제 사용자의 피드백을 보면서 다듬어가는 앱**이 되었으면 합니다.

특히 이런 피드백이 도움이 됩니다.

- 실제로 중요한 일이 위로 올라오나요?
- 알림이 적절한가요, 아니면 귀찮은가요?
- 메일·캘린더에서 TODO로 가져오는 기준이 자연스러운가요?
- "이 기능 있으면 계속 쓰겠다" 싶은 포인트가 있나요?
- 직접 조정하고 싶은 부분이 있나요?

피드백은 이메일로 주시면 됩니다: **[pieroot.02@gmail.com](mailto:pieroot.02@gmail.com)**

---

## 마무리

SIFT는 스케줄 관리를 잘하는 사람을 위한 앱이라기보다, **스케줄 관리를 귀찮아하는 사람**을 위한 앱에 가깝습니다.

목표는 사용자를 더 부지런하게 만드는 것이 아닙니다.
중요한 일을 놓치지 않도록, **귀찮은 정리 과정을 앱이 최대한 대신해주는 것**입니다.

> 일정 관리가 귀찮고, TODO 앱을 쓰다가 TODO 앱 관리에 지친 적이 있다면
> SIFT를 한번 써보고 후기를 남겨주세요. 정말 큰 도움이 됩니다.

---

<div align="center">

<strong>개발자</strong> jung-geun &nbsp;·&nbsp; <strong>연락처</strong> <a href="mailto:pieroot.02@gmail.com">pieroot.02@gmail.com</a>

<br>

<a href="./privacy-policy.html">개인정보 처리방침</a> &nbsp;·&nbsp; <a href="./terms-of-service.html">서비스 약관</a>

</div>
