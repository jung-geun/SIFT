---
layout: landing
title: 할 일과 일정을 한곳에서
description: 직접 적은 할 일부터 메일 속 요청까지. 실제 앱 화면으로 SIFT를 둘러보고, App Store에서 iPhone과 iPad용 앱을 다운로드하세요.
image: /assets/images/app-icon.webp
---

<header class="site-header">
  <div class="container header-inner">
    <a class="brand" href="{{ '/' | relative_url }}" aria-label="SIFT 홈">
      <img src="{{ '/assets/images/app-icon.webp' | relative_url }}" width="40" height="40" alt="">
      <span>SIFT</span>
    </a>
    <nav class="site-nav" aria-label="주요 메뉴">
      <a href="#screens">앱 화면</a>
      <a href="#how-to">사용 방법</a>
      <a href="#download">다운로드 <span aria-hidden="true">↗</span></a>
    </nav>
  </div>
</header>

<main id="content">
  <section class="hero" aria-labelledby="hero-title">
    <div class="container hero-grid">
      <div class="hero-copy">
        <h1 id="hero-title">할 일과 일정,<br><span>한곳에서.</span></h1>
        <p class="hero-description">직접 적은 할 일부터 메일 속 요청까지.<br>마감을 확인하고, 오늘 할 일에 집중하세요.</p>
        <div class="hero-actions">
          <a class="store-link" href="{{ site.app_store_url }}">
            <img src="{{ '/assets/images/app-store-badge.svg' | relative_url }}" width="195" height="60" alt="App Store에서 다운로드">
          </a>
          <a class="text-link" href="#screens">앱 화면 보기 <span aria-hidden="true">→</span></a>
        </div>
      </div>
      <div class="hero-visual" aria-label="SIFT의 실제 할 일 목록과 캘린더 화면">
        <figure class="hero-device hero-device-secondary device">
          <img src="{{ '/assets/images/app-1113.webp' | relative_url }}" width="640" height="1391" alt="날짜를 선택하고 일정을 확인하는 SIFT 캘린더 화면" decoding="async">
        </figure>
        <figure class="hero-device hero-device-primary device">
          <img src="{{ '/assets/images/app-1112.webp' | relative_url }}" width="640" height="1391" alt="진행중, 기한초과, 등록 대기열, 완료로 나누어 보는 SIFT 할 일 목록" fetchpriority="high" decoding="async">
        </figure>
      </div>
    </div>
  </section>

  <section class="section screenshots-section" id="screens" aria-labelledby="screens-title">
    <div class="container">
      <div class="section-heading reveal">
        <h2 id="screens-title">눌러보면,<br>어떻게 쓰는지 보여요.</h2>
        <p>매일 사용하는 네 가지 화면부터 둘러보세요.</p>
      </div>
      <div class="screen-tour reveal">
        <div class="tour-copy">
          <div class="screen-tabs" data-screen-tabs aria-label="앱 화면 선택">
            <a class="screen-tab" id="tab-tasks" href="#screen-tasks" data-screen-target="screen-tasks">
              <span class="tab-name">할 일 <span class="tab-arrow" aria-hidden="true">↗</span></span>
              <span class="tab-detail">진행중인 일부터 완료한 일까지</span>
            </a>
            <a class="screen-tab" id="tab-add" href="#screen-add" data-screen-target="screen-add">
              <span class="tab-name">새 할 일 <span class="tab-arrow" aria-hidden="true">↗</span></span>
              <span class="tab-detail">제목을 적고, 필요한 옵션만 선택</span>
            </a>
            <a class="screen-tab" id="tab-calendar" href="#screen-calendar" data-screen-target="screen-calendar">
              <span class="tab-name">캘린더 <span class="tab-arrow" aria-hidden="true">↗</span></span>
              <span class="tab-detail">날짜별 일정과 할 일을 함께</span>
            </a>
            <a class="screen-tab" id="tab-settings" href="#screen-settings" data-screen-target="screen-settings">
              <span class="tab-name">설정 <span class="tab-arrow" aria-hidden="true">↗</span></span>
              <span class="tab-detail">메일·캘린더·iCloud 연결은 여기서</span>
            </a>
          </div>
          <p class="screens-source">App Store에 공개된 실제 앱 화면입니다.<br>화면을 누르면 크게 볼 수 있어요.</p>
        </div>
        <div class="tour-viewer">
          <div class="screen-panels">
            <article class="screen-panel" id="screen-tasks" data-screen-label="할 일">
              <figure>
                <a class="device-link" href="{{ '/assets/images/app-1112.webp' | relative_url }}" target="_blank" rel="noopener" aria-label="할 일 화면 크게 보기 (새 탭)">
                  <span class="device tour-device"><img src="{{ '/assets/images/app-1112.webp' | relative_url }}" width="640" height="1391" alt="진행중인 할 일과 완료 상태를 확인하는 실제 SIFT 목록 화면" loading="lazy" decoding="async"></span>
                </a>
                <figcaption><h3>해야 할 일을 놓치지 않게.</h3><p>진행중·기한초과·등록 대기열·완료를 나누어 확인하세요.</p></figcaption>
              </figure>
            </article>
            <article class="screen-panel" id="screen-add" data-screen-label="새 할 일">
              <figure>
                <a class="device-link" href="{{ '/assets/images/app-1125.webp' | relative_url }}" target="_blank" rel="noopener" aria-label="새 할 일 화면 크게 보기 (새 탭)">
                  <span class="device tour-device"><img src="{{ '/assets/images/app-1125.webp' | relative_url }}" width="640" height="1391" alt="제목과 메모를 입력하고 마감·우선순위를 선택하는 실제 SIFT 새 할 일 화면" loading="lazy" decoding="async"></span>
                </a>
                <figcaption><h3>생각났을 때, 바로 적어요.</h3><p>제목을 입력하고 필요할 때만 메모·마감·우선순위를 더하세요.</p></figcaption>
              </figure>
            </article>
            <article class="screen-panel" id="screen-calendar" data-screen-label="캘린더">
              <figure>
                <a class="device-link" href="{{ '/assets/images/app-1113.webp' | relative_url }}" target="_blank" rel="noopener" aria-label="캘린더 화면 크게 보기 (새 탭)">
                  <span class="device tour-device"><img src="{{ '/assets/images/app-1113.webp' | relative_url }}" width="640" height="1391" alt="월간 날짜와 선택한 날의 일정을 확인하는 실제 SIFT 캘린더 화면" loading="lazy" decoding="async"></span>
                </a>
                <figcaption><h3>목록에서 날짜로, 한 번에.</h3><p>캘린더에서 날짜를 선택해 일정을 확인하고 새 이벤트를 추가하세요.</p></figcaption>
              </figure>
            </article>
            <article class="screen-panel" id="screen-settings" data-screen-label="설정">
              <figure>
                <a class="device-link" href="{{ '/assets/images/app-1115.webp' | relative_url }}" target="_blank" rel="noopener" aria-label="설정 화면 크게 보기 (새 탭)">
                  <span class="device tour-device"><img src="{{ '/assets/images/app-1115.webp' | relative_url }}" width="640" height="1391" alt="이메일 연동, 캘린더, 시스템 권한, iCloud 동기화를 관리하는 실제 SIFT 설정 화면" loading="lazy" decoding="async"></span>
                </a>
                <figcaption><h3>필요한 연결만 켜두세요.</h3><p>메일·캘린더·iCloud와 AI 관련 옵션을 확인하고 직접 선택하세요.</p></figcaption>
              </figure>
            </article>
          </div>
          <div class="tour-controls">
            <button class="round-button" type="button" data-screen-previous aria-label="이전 앱 화면" hidden>←</button>
            <span class="screen-count" data-screen-count aria-hidden="true">1 / 4</span>
            <button class="round-button" type="button" data-screen-next aria-label="다음 앱 화면" hidden>→</button>
          </div>
          <p class="sr-only" data-screen-status role="status" aria-live="polite" aria-atomic="true"></p>
        </div>
      </div>
    </div>
  </section>

  <section class="section how-to-section" id="how-to" aria-labelledby="how-to-title">
    <div class="container">
      <div class="section-heading reveal">
        <h2 id="how-to-title">메일 속 요청을,<br>내 할 일로.</h2>
        <p>그대로 넘기지 말고, 확인한 내용만 저장하세요.</p>
      </div>
      <ol class="flow-diagram" aria-label="메일에서 할 일로 저장하는 세 단계">
        <li class="flow-node">
          <div class="flow-icon"><span class="icon icon-mail" aria-hidden="true"></span></div>
          <span class="step-number">1</span>
          <h3>메일 확인</h3>
          <p>연결한 메일에서<br>발신자와 요청을 확인해요.</p>
          <span class="flow-connector" aria-hidden="true"><span>→</span></span>
        </li>
        <li class="flow-node">
          <div class="flow-icon"><span class="icon icon-edit" aria-hidden="true"></span></div>
          <span class="step-number">2</span>
          <h3>내용 검토</h3>
          <p>‘할 일로 저장’을 눌러<br>제목·메모·기한을 고쳐요.</p>
          <span class="flow-connector" aria-hidden="true"><span>→</span></span>
        </li>
        <li class="flow-node">
          <div class="flow-icon"><span class="icon icon-check" aria-hidden="true"></span></div>
          <span class="step-number">3</span>
          <h3>저장하고 실행</h3>
          <p>진행중 목록에서<br>마감이 빠른 일부터 확인해요.</p>
        </li>
      </ol>
      <div class="flow-bottom">
        <p class="flow-note">기한을 찾지 못한 메일은 임의의 마감 없이 저장해요.</p>
        <div class="flow-actions">
          <button class="text-button" type="button" data-flow-replay hidden>흐름 다시 보기 <span aria-hidden="true">↻</span></button>
          <button class="text-button" type="button" data-motion-toggle aria-pressed="false" hidden>모션 멈추기</button>
        </div>
      </div>
    </div>
  </section>

  <section class="section connections-section" aria-labelledby="connections-title">
    <div class="container connections-grid">
      <div class="connection-visual reveal" aria-label="기기에 저장하고, 원할 때 iCloud 동기화">
        <div class="connection-node"><span class="icon icon-device" aria-hidden="true"></span><span>기기 저장</span></div>
        <div class="connection-choice"><span>내가 선택</span><span aria-hidden="true">→</span></div>
        <div class="connection-node connection-cloud"><span class="icon icon-cloud" aria-hidden="true"></span><span>iCloud 동기화</span></div>
      </div>
      <div class="connections-copy reveal">
        <h2 id="connections-title">연결은 필요한 만큼.<br>선택은 내가.</h2>
        <p>기본은 기기 저장. 메일·캘린더 연결과 iCloud 동기화는 설정에서 선택하세요.</p>
        <p class="privacy-note">AI 기능은 기기와 설정에 따라 달라집니다. 클라우드 AI를 선택하면 할 일 등의 데이터가 외부로 전송될 수 있습니다.</p>
        <a class="text-link" href="{{ '/privacy-policy.html' | relative_url }}">데이터 처리 방식 보기 <span aria-hidden="true">↗</span></a>
      </div>
    </div>
  </section>

  <section class="download-section" id="download" aria-labelledby="download-title">
    <div class="container download-inner reveal">
      <img class="download-icon" src="{{ '/assets/images/app-icon.webp' | relative_url }}" width="96" height="96" alt="SIFT 앱 아이콘" loading="lazy" decoding="async">
      <h2 id="download-title">오늘의 할 일을<br>SIFT에서.</h2>
      <p>iPhone과 iPad에서 시작하세요.</p>
      <a class="store-link" href="{{ site.app_store_url }}">
        App Store에서 다운로드 <span aria-hidden="true">↗</span>
      </a>
      <p class="download-meta">무료 · 한국어·영어 · 지원 기기는 App Store에서 확인</p>
    </div>
  </section>
</main>

<footer class="site-footer">
  <div class="container footer-inner">
    <a class="brand footer-brand" href="{{ '/' | relative_url }}"><span>SIFT</span></a>
    <nav class="footer-links" aria-label="프로젝트, 도움말 및 정책">
      <a href="{{ '/changes.html' | relative_url }}">변경사항</a>
      <a href="{{ '/outlook-imap-setup.html' | relative_url }}">Outlook (레거시 IMAP)</a>
      <a href="{{ '/privacy-policy.html' | relative_url }}">개인정보 처리방침</a>
      <a href="{{ '/terms-of-service.html' | relative_url }}">서비스 약관</a>
      <a href="mailto:pieroot.02@gmail.com">문의</a>
      <a href="https://github.com/jung-geun/SIFT" target="_blank" rel="noopener noreferrer" aria-label="SIFT GitHub 저장소 (새 탭)">GitHub ↗</a>
    </nav>
    <p class="footer-credit">© {{ site.time | date: '%Y' }} Jung-geun Bong</p>
    <p class="footer-credit">Apple 및 Apple 로고, iPhone, iPad, iCloud, App Store는 Apple Inc.의 상표입니다.</p>
  </div>
</footer>
