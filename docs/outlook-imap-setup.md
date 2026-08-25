---
layout: default
title: Outlook 메일 연결하기 (IMAP 레거시)
description: Outlook.com 앱 비밀번호 IMAP 연결 시도 — Microsoft 365 제한사항 및 OAuth2 계획
---

# Outlook 메일 연결하기 (IMAP 레거시)

**⚠️ 중요 제한사항**: SIFT는 **Outlook IMAP 레거시 앱 비밀번호 경로**를 베스트 에포트(Best-effort)로 제공합니다. 다만 **Microsoft는 Modern Authentication(OAuth2)를 요구하며 Microsoft 365 등에서 기본 인증(Basic Auth) 및 앱 비밀번호를 영구 차단**했으므로, 서버에서 연결이 거부될 수 있습니다.

> **Microsoft 인증 정책 및 한계**:
> - **인증 요구사항**: Microsoft는 [Modern Authentication(OAuth2) 정책](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-basic-authentication-exchange-online)에 따라 Outlook.com 및 Microsoft 365 계정에 OAuth2 사용을 권장/강제합니다.
> - **Exchange Online 차단**: [Microsoft 365(Exchange Online) 환경](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-basic-authentication-exchange-online)에서는 IMAP 기본 인증이 영구 비활성화되어 앱 비밀번호를 사용한 LOGIN이 거부됩니다.
> - **레거시 시도**: 현재 SIFT는 사용자가 명시적으로 입력한 **앱 비밀번호**를 통한 레거시 IMAP 연결을 시도하며, 향후 **OAuth2 정식 지원**이 계획되어 있습니다.

---

## Outlook.com (개인 계정) 메일 연결

### 1단계: Outlook.com에서 IMAP 사용 설정

Outlook.com에서 IMAP 프로토콜 접근이 켜져 있어야 합니다.

1. [Outlook.com](https://outlook.com) 웹에 로그인합니다.
2. 우측 상단 **설정(Settings)** → **메일(Mail)** → **전달 및 IMAP(Forwarding and IMAP)**(또는 POP 및 IMAP) 섹션으로 이동합니다.
3. **디바이스 및 앱에서 IMAP을 사용하도록 허용** 토글을 **켜짐**으로 변경하고 저장합니다.
4. 세부 사항은 [Microsoft Support Outlook.com POP/IMAP 가이드](https://support.microsoft.com/en-us/office/pop-imap-and-smtp-settings-for-outlook-com-d088b986-291d-42b8-9564-9c414e2aa040)를 참조하세요.

### 2단계: Outlook.com 앱 비밀번호 생성

Outlook.com 계정에 연결하려면 일반 계정 비밀번호가 아닌 **앱 비밀번호**가 필요합니다.

1. [Microsoft 계정 보안 관리 페이지](https://account.microsoft.com/security)에 로그인합니다.
2. **2단계 인증(2FA)**이 활성화되어 있는지 확인합니다 (앱 비밀번호 생성 필수 조건).
3. **고급 보안 옵션** → **앱 비밀번호** 섹션에서 **새 앱 비밀번호 만들기**를 선택합니다.
4. 생성된 **앱 비밀번호**를 복사합니다.

### 3단계: SIFT에 계정 추가 및 연결 시도

1. SIFT 앱을 열고 **설정** → **이메일 연동** → **Outlook 메일 추가**로 이동합니다.
2. 이메일 주소와 위에서 생성한 **앱 비밀번호**를 입력합니다. (계정의 일반 비밀번호 사용 금지)
3. **연결** 버튼을 누릅니다.

**서버 설정 정보**:
- **호스트**: `outlook.office365.com`
- **포트**: `993` (보안 TLS/SSL)
- **인증 방식**: 레거시 기본 인증 (앱 비밀번호)

### 연결 결과 안내

서버 정책 및 계정 상태에 따라 처리됩니다:
- **성공 시**: 받은편지함 메일이 동기화됩니다.
- **거부 시**: `NO AUTHENTICATE failed` 또는 `NO LOGIN failed` 응답이 반환됩니다. Microsoft의 기본 인증 제한 정책으로 인해 앱 비밀번호 연결이 거부된 결과입니다.

---

## Microsoft 365 (회사/학교 계정) 안내

### Exchange Online 기본 인증 영구 차단 정책

Microsoft 365(회사/학교 계정)는 [Microsoft Exchange Online 기본 인증 영구 차단 정책](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-basic-authentication-exchange-online)에 따라 IMAP 기본 인증 및 앱 비밀번호 사용이 차단되어 있습니다.

- **사서함 IMAP 활성화만으로 해결 불가**: 관리자가 사서함의 IMAP 프로토콜을 활성화하더라도 이는 프로토콜 기능 자체의 활성화일 뿐이며, **기본 인증/앱 비밀번호가 복구되지 않습니다**.
- **SIFT 레거시 경로 접속 불가**: 따라서 SIFT의 현재 레거시 앱 비밀번호 경로로는 Microsoft 365 사서함에 연결할 수 없으며, OAuth2 지원 출시 전까지 접속이 제한됩니다.

### 관리자 참고: 사서함 IMAP 프로토콜 활성화 방법

조직 관리자가 사서함 단위로 IMAP 프로토콜 활성화 상태를 확인/변경하는 표준 절차입니다 (※ 이 설정 후에도 OAuth2 클라이언트만 접속 가능):

**Exchange 관리 센터 (웹 UI)**:
1. [Exchange 관리 센터](https://admin.exchange.microsoft.com)에 로그인합니다.
2. **받는사람(Recipients)** → **사서함(Mailboxes)**으로 이동합니다.
3. 대상 사용자 사서함을 선택합니다.
4. **이메일 앱(Email apps)** 탭에서 **IMAP** 상태를 **켜짐(Enabled)**으로 관리합니다. 자세한 사항은 [Microsoft Learn IMAP 관리 가이드](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/pop3-and-imap4/enable-or-disable-pop3-or-imap4-access)를 참조하세요.

**Exchange Online PowerShell**:
```powershell
Set-CASMailbox -Identity <user@domain.com> -ImapEnabled $true
```

---

## ⚠️ IMAP 연결 후 제한사항

### Focused Inbox 및 카테고리 미지원

**IMAP 프로토콜 특성상 Outlook 전용 기능은 동기화되지 않습니다:**

- Outlook 웹/앱의 "중요(Focused)", "기타(Other)" 탭 구분은 IMAP으로 전달되지 않습니다.
- SIFT는 Outlook IMAP에서 받은편지함만 표시하며, Outlook의 Focused/Other 분류나 카테고리 탭을 제공하지 않습니다.

---

## 🔒 개인정보 및 자격증명 보안

### 기기 전용 Keychain 저장

- **앱 비밀번호 보안**: 사용자가 입력한 앱 비밀번호는 iOS **Keychain에 기기 전용(Device-Only)**으로 암호화 저장되며, iCloud로 동기화되지 않습니다 (`OutlookIMAPCredentialStore`).
- **메일 본문 보관**: 메일 본문 데이터는 기본적으로 기기 로컬 전용 저장소에만 보관되며 외부 서버로 전송되지 않습니다 (사용자가 Gemini 메일 본문 분석을 별도로 켠 경우에만 선택한 내용이 Gemini API로 전송될 수 있습니다).
- **개인정보 보호**: 입력된 자격증명은 SIFT 서버를 거치지 않고 사용자 기기에서 Outlook 서버로 직접 통신합니다.

---

## ❌ IMAP 연결 오류 및 의미

| 오류 응답 | 원인 | 대처 방안 |
|-----------|------|-----------|
| `NO AUTHENTICATE failed` / `NO LOGIN failed` | Microsoft 서버 또는 조직 정책이 기본 인증/앱 비밀번호를 거부함 | Microsoft 정책상 기본 인증이 차단된 상태입니다. SIFT의 OAuth2 정식 지원을 기다려주세요. |
| `NO IMAP is disabled` | 사서함의 IMAP 프로토콜 기능 자체가 비활성화됨 | Outlook.com 설정 또는 조직 관리자에게 IMAP 사용 활성화 요청 |
| `TLS connection failed` / Connection Timeout | 포트 993 차단 또는 네트워크 연결 문제 | 기기 네트워크 상태 및 방화벽 설정 확인 |

---

## 🔄 향후 계획: OAuth2 지원

Microsoft의 [Modern Authentication(OAuth2) 정책](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-basic-authentication-exchange-online)을 준수하기 위해 SIFT는 향후 업데이트에서 **Outlook OAuth2** 연동을 지원할 예정입니다. OAuth2가 도입되면 앱 비밀번호 없이 안전하게 계정을 승인하고 Microsoft 365 계정까지 정상 연결할 수 있게 됩니다.

---

## 🤔 자주 묻는 질문

### Q: 일반 계정 비밀번호를 입력해도 되나요?
**A**: 아니요. 레거시 연결 시도 시 계정의 일반 비밀번호가 아닌 **앱 비밀번호**를 사용해야 합니다.

### Q: Outlook.com / Microsoft 365에서 계속 연결 실패가 뜹니다.
**A**: Microsoft가 Exchange Online 및 일부 계정에서 기본 인증을 차단했기 때문입니다. 이는 SIFT의 문제가 아닌 Microsoft 서버의 보안 정책이며, SIFT의 OAuth2 지원 출시 전까지 연결이 거부될 수 있습니다.

### Q: 현재 권장되는 메일 연동 방식은 무엇인가요?
**A**: SIFT에서 완전히 지원하는 **Gmail 연동**을 사용하시거나, Outlook 계정의 경우 iOS 기본 메일 앱 또는 Outlook 공식 앱을 병행해 사용하시는 것을 권장합니다.

---

## 🔗 참고 자료

- [Outlook.com POP/IMAP 설정 및 OAuth2 - Microsoft Support](https://support.microsoft.com/en-us/office/pop-imap-and-smtp-settings-for-outlook-com-d088b986-291d-42b8-9564-9c414e2aa040)
- [Exchange Online 기본 인증 영구 차단 안내 - Microsoft Learn](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-basic-authentication-exchange-online)
- [Exchange Online POP3/IMAP4 정보 - Microsoft Learn](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/pop3-and-imap4/pop3-and-imap4)
- [사용자 IMAP 프로토콜 활성화 가이드 - Microsoft Learn](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/pop3-and-imap4/enable-or-disable-pop3-or-imap4-access)

---

**최종 업데이트**: 2026년 7월 31일  
**상태**: IMAP 레거시 경로 (앱 비밀번호 베스트 에포트)
