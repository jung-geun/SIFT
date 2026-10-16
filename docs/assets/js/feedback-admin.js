(() => {
  'use strict';

  const byID = (id) => document.getElementById(id);
  const ui = Object.fromEntries([
    'admin-error', 'admin-announcement', 'login-panel', 'login-form', 'operator-key',
    'connect-button', 'inbox', 'disconnect-button', 'list-panel', 'list-heading', 'status-filter',
    'refresh-button', 'list-message', 'report-list', 'previous-button', 'next-button',
    'page-label', 'detail-panel', 'detail-heading', 'detail-message', 'report-detail',
    'report-title', 'report-id', 'report-received', 'report-kind', 'report-app',
    'report-updated', 'report-message', 'diagnostics-disclosure', 'report-diagnostics',
    'no-diagnostics', 'edit-form', 'edit-fields', 'report-status', 'report-notes',
    'save-button', 'delete-button', 'delete-confirmation', 'delete-ticket',
    'cancel-delete-button', 'confirm-delete-button'
  ].map((id) => [id, byID(id)]));
  const statuses = new Map([
    ['new', '신규'], ['in_progress', '처리 중'],
    ['resolved', '해결'], ['declined', '진행하지 않음']
  ]);
  const ticketPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  const pending = new Set();
  let apiOrigin = null;
  let token = '';
  // Session generation protects all awaits, including response-body reads. Selection
  // and list generations additionally guard independent, overlapping requests.
  let session = 0;
  let listGeneration = 0;
  let detailGeneration = 0;
  let listController = null;
  let detailController = null;
  let listBusy = false;
  let mutationBusy = false;
  let listReady = false;
  let items = [];
  let cursors = [null];
  let page = 0;
  let nextCursor = null;
  let selectedID = null;
  let selected = null;

  class InboxError extends Error {}
  const stale = () => new DOMException('Request cancelled', 'AbortError');
  const showError = (message = '') => { ui['admin-error'].textContent = message; };
  const announce = (message = '') => { ui['admin-announcement'].textContent = message; };
  const text = (value, max, nonempty = false) => typeof value === 'string'
    && value.length <= max && (!nonempty || value.length > 0);
  const date = (value) => text(value, 64, true) && Number.isFinite(Date.parse(value));
  const formatDate = (value) => `${new Date(value).toLocaleString('ko-KR')} (${value})`;
  const kindLabel = (kind) => kind === 'bug' ? '버그 제보' : '기능 요청';
  const appLabel = (app) => `${app.platform} · ${app.version} (${app.build}) · OS ${app.osVersion} · ${app.language}`;

  function validSummary(item) {
    return item && ticketPattern.test(item.ticketID) && date(item.receivedAt)
      && (item.kind === 'bug' || item.kind === 'feature') && text(item.title, 240, true)
      && statuses.has(item.status) && item.app
      && ['iOS', 'iPadOS', 'macOS'].includes(item.app.platform)
      && text(item.app.version, 64, true) && text(item.app.build, 64, true)
      && text(item.app.osVersion, 128, true) && text(item.app.language, 64, true);
  }

  function validDetail(item, id) {
    return validSummary(item) && item.ticketID === id && date(item.updatedAt)
      && text(item.message, 16000, true) && text(item.notes, 16000)
      && (item.diagnostics === undefined || text(item.diagnostics, 524288));
  }

  function syncControls() {
    const locked = !token || listBusy || mutationBusy;
    ui['status-filter'].disabled = locked;
    ui['refresh-button'].disabled = locked;
    ui['previous-button'].disabled = locked || !listReady || page === 0;
    ui['next-button'].disabled = locked || !listReady || !nextCursor;
    for (const button of ui['report-list'].querySelectorAll('button')) {
      button.disabled = mutationBusy;
      if (button.dataset.ticketId === selectedID) button.setAttribute('aria-current', 'true');
      else button.removeAttribute('aria-current');
    }
    ui['edit-fields'].disabled = mutationBusy || !selected;
    for (const id of ['delete-button', 'cancel-delete-button', 'confirm-delete-button']) {
      ui[id].disabled = mutationBusy || !selected;
    }
  }

  function clearDetail(message = '목록에서 제보를 선택하세요.') {
    detailGeneration += 1;
    if (detailController) detailController.abort();
    detailController = null;
    selectedID = null;
    selected = null;
    ui['report-detail'].hidden = true;
    ui['detail-panel'].setAttribute('aria-busy', 'false');
    ui['detail-message'].textContent = message;
    for (const id of ['report-title', 'report-id', 'report-received', 'report-kind',
      'report-app', 'report-updated', 'report-message', 'report-diagnostics', 'delete-ticket']) {
      ui[id].textContent = '';
    }
    ui['report-notes'].value = '';
    ui['report-status'].value = 'new';
    ui['diagnostics-disclosure'].open = false;
    ui['diagnostics-disclosure'].hidden = true;
    ui['no-diagnostics'].hidden = true;
    ui['delete-confirmation'].hidden = true;
    ui['delete-button'].hidden = false;
    syncControls();
  }

  function disconnect(message = '', focus = true) {
    session += 1;
    listGeneration += 1;
    token = '';
    for (const controller of pending) controller.abort();
    pending.clear();
    listController = null;
    listBusy = false;
    mutationBusy = false;
    listReady = false;
    items = [];
    cursors = [null];
    page = 0;
    nextCursor = null;
    clearDetail();
    ui['operator-key'].value = '';
    ui['report-list'].replaceChildren();
    ui['list-message'].textContent = '';
    ui['page-label'].textContent = '';
    ui['status-filter'].value = '';
    ui['list-panel'].setAttribute('aria-busy', 'false');
    ui.inbox.hidden = true;
    ui['login-panel'].hidden = false;
    ui['operator-key'].disabled = !apiOrigin;
    ui['connect-button'].disabled = !apiOrigin;
    showError();
    announce(message);
    syncControls();
    if (focus && apiOrigin) ui['operator-key'].focus();
  }

  // No server-provided URLs are followed. Paths are constructed locally; cursor
  // values are query data only. Bearer credentials never enter URLs or storage.
  async function request(path, { method = 'GET', body, controller = new AbortController() } = {}) {
    const generation = session;
    if (!token || !apiOrigin) throw stale();
    const url = new URL(path, apiOrigin);
    if (url.origin !== apiOrigin || !url.pathname.startsWith('/v1/admin/feedback')) {
      throw new InboxError('허용되지 않은 API 주소입니다.');
    }
    pending.add(controller);
    try {
      const headers = { Accept: 'application/json', Authorization: `Bearer ${token}` };
      if (body !== undefined) headers['Content-Type'] = 'application/json';
      const response = await fetch(url.href, {
        method, headers, body: body === undefined ? undefined : JSON.stringify(body),
        mode: 'cors', credentials: 'omit', cache: 'no-store', redirect: 'error',
        referrerPolicy: 'no-referrer', signal: controller.signal
      });
      if (generation !== session || controller.signal.aborted) throw stale();
      if (response.status === 401) {
        disconnect('', true);
        showError('운영 키 인증이 만료되었거나 올바르지 않습니다. 비공개 내용을 지웠습니다. 다시 연결하세요.');
        throw stale();
      }
      const expectedStatus = method === 'DELETE' ? 204 : 200;
      if (response.status !== expectedStatus) {
        if (response.body) await response.body.cancel();
        const messages = {
          400: '요청을 처리할 수 없습니다. 입력 내용을 확인하세요.',
          404: '제보를 찾을 수 없습니다. 다른 운영자가 삭제했을 수 있습니다. 목록을 새로고침하세요.',
          413: '저장할 내용이 너무 큽니다. 메모를 줄여 주세요.',
          429: '요청이 많습니다. 잠시 후 직접 다시 시도하세요.'
        };
        throw new InboxError(messages[response.status] || '서버가 요청을 처리하지 못했습니다. 잠시 후 직접 다시 시도하세요.');
      }
      if (method === 'DELETE') return null;
      if (!(response.headers.get('Content-Type') || '').toLowerCase().startsWith('application/json') || !response.body) {
        if (response.body) await response.body.cancel();
        throw new InboxError('서버 응답 형식이 올바르지 않습니다.');
      }
      // Bounded JSON reading also covers escaped diagnostic text at its contract limit.
      const reader = response.body.getReader();
      const decoder = new TextDecoder('utf-8', { fatal: true });
      let size = 0;
      let json = '';
      try {
        while (true) {
          const chunk = await reader.read();
          if (generation !== session || controller.signal.aborted) throw stale();
          if (chunk.done) break;
          size += chunk.value.byteLength;
          if (size > 4 * 1024 * 1024) {
            await reader.cancel();
            throw new InboxError('서버 응답이 허용 크기를 초과했습니다.');
          }
          json += decoder.decode(chunk.value, { stream: true });
        }
        json += decoder.decode();
        return JSON.parse(json);
      } finally {
        reader.releaseLock();
      }
    } finally {
      pending.delete(controller);
    }
  }

  function reportFailure(error) {
    if (error.name === 'AbortError') return;
    showError(error instanceof InboxError ? error.message : '요청을 완료하지 못했습니다. 네트워크와 API 원점·CORS 설정을 확인한 뒤 직접 다시 시도하세요.');
  }

  function renderList() {
    ui['report-list'].replaceChildren();
    for (const item of items) {
      const row = document.createElement('li');
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'admin-report-button';
      button.dataset.ticketId = item.ticketID;
      const title = document.createElement('span');
      title.textContent = item.title;
      const summary = document.createElement('span');
      summary.className = 'admin-report-summary';
      summary.textContent = `${kindLabel(item.kind)} · ${statuses.get(item.status)} · ${formatDate(item.receivedAt)}${item.hasDiagnostics ? ' · 진단 첨부' : ''}`;
      const id = document.createElement('span');
      id.className = 'admin-report-summary admin-mono';
      id.textContent = item.ticketID;
      button.append(title, summary, id);
      button.addEventListener('click', () => { if (!mutationBusy) openReport(item.ticketID); });
      row.append(button);
      ui['report-list'].append(row);
    }
    ui['list-message'].textContent = items.length ? `현재 페이지에 ${items.length}건이 있습니다. 제보를 선택해 확인하세요.` : '이 페이지에는 해당 상태의 제보가 없습니다. 이전 페이지나 다른 상태를 확인하세요.';
    ui['page-label'].textContent = `${page + 1}페이지`;
    syncControls();
  }

  async function loadPage(cursor = null, targetPage = 0) {
    if (!token || mutationBusy) return;
    const generation = session;
    const sequence = ++listGeneration;
    if (listController) listController.abort();
    listController = new AbortController();
    const controller = listController;
    clearDetail();
    items = [];
    nextCursor = null;
    listReady = false;
    listBusy = true;
    showError();
    announce();
    ui['report-list'].replaceChildren();
    ui['page-label'].textContent = '';
    ui['list-message'].textContent = '제보 목록을 불러오는 중입니다…';
    ui['list-panel'].setAttribute('aria-busy', 'true');
    syncControls();
    const query = new URLSearchParams({ limit: '25' });
    if (ui['status-filter'].value) query.set('status', ui['status-filter'].value);
    if (cursor) query.set('cursor', cursor);
    try {
      const result = await request(`/v1/admin/feedback?${query}`, { controller });
      if (generation !== session || sequence !== listGeneration) return;
      if (!result || !Array.isArray(result.items) || result.items.length > 25
        || !result.items.every((item) => validSummary(item) && typeof item.hasDiagnostics === 'boolean')
        || !(result.nextCursor === null || text(result.nextCursor, 4096, true))) {
        throw new InboxError('서버의 목록 응답 형식이 올바르지 않습니다.');
      }
      items = result.items;
      nextCursor = result.nextCursor;
      page = targetPage;
      if (page === 0) cursors = [null];
      else cursors[page] = cursor;
      cursors.length = page + 1;
      listReady = true;
      renderList();
    } catch (error) {
      if (generation !== session || sequence !== listGeneration) return;
      ui['list-message'].textContent = '목록을 불러오지 못했습니다. 목록 새로고침으로 다시 시도하세요.';
      reportFailure(error);
    } finally {
      if (generation === session && sequence === listGeneration) {
        listBusy = false;
        ui['list-panel'].setAttribute('aria-busy', 'false');
        syncControls();
      }
    }
  }

  function renderDetail() {
    ui['report-title'].textContent = selected.title;
    ui['report-id'].textContent = selected.ticketID;
    ui['report-received'].textContent = formatDate(selected.receivedAt);
    ui['report-kind'].textContent = kindLabel(selected.kind);
    ui['report-app'].textContent = appLabel(selected.app);
    ui['report-updated'].textContent = formatDate(selected.updatedAt);
    ui['report-message'].textContent = selected.message;
    ui['report-status'].value = selected.status;
    ui['report-notes'].value = selected.notes;
    ui['report-diagnostics'].textContent = '';
    ui['diagnostics-disclosure'].open = false;
    ui['diagnostics-disclosure'].hidden = selected.diagnostics === undefined;
    ui['no-diagnostics'].hidden = selected.diagnostics !== undefined;
    ui['delete-confirmation'].hidden = true;
    ui['delete-button'].hidden = false;
    ui['delete-ticket'].textContent = '';
    ui['detail-message'].textContent = '';
    ui['report-detail'].hidden = false;
    syncControls();
  }

  async function openReport(id) {
    if (!token || mutationBusy || !ticketPattern.test(id)) return;
    clearDetail('제보를 불러오는 중입니다…');
    const generation = session;
    const sequence = detailGeneration;
    selectedID = id;
    detailController = new AbortController();
    const controller = detailController;
    showError();
    announce();
    ui['detail-panel'].setAttribute('aria-busy', 'true');
    syncControls();
    try {
      const result = await request(`/v1/admin/feedback/${encodeURIComponent(id)}`, { controller });
      if (generation !== session || sequence !== detailGeneration || selectedID !== id) return;
      if (!validDetail(result, id)) throw new InboxError('서버의 제보 응답 형식이 올바르지 않습니다.');
      selected = result;
      renderDetail();
      ui['detail-heading'].focus();
    } catch (error) {
      if (generation !== session || sequence !== detailGeneration) return;
      ui['detail-message'].textContent = '제보를 열지 못했습니다. 목록에서 다시 선택하세요.';
      reportFailure(error);
    } finally {
      if (generation === session && sequence === detailGeneration) {
        ui['detail-panel'].setAttribute('aria-busy', 'false');
        syncControls();
      }
    }
  }

  async function mutate(method) {
    if (!token || !selected || mutationBusy) return;
    if (method === 'DELETE' && (ui['delete-confirmation'].hidden || ui['delete-ticket'].textContent !== selectedID)) return;
    const id = selectedID;
    const generation = session;
    const sequence = detailGeneration;
    let body;
    if (method === 'PATCH') {
      let length = 0;
      for (const character of ui['report-notes'].value) length += 1;
      if (length > 8000) {
        showError('운영 메모는 8,000자 이하로 입력하세요.');
        ui['report-notes'].focus();
        return;
      }
      body = { status: ui['report-status'].value, notes: ui['report-notes'].value };
    }
    mutationBusy = true;
    showError();
    announce(method === 'DELETE' ? '제보를 영구 삭제하는 중입니다…' : '상태와 운영 메모를 저장하는 중입니다…');
    ui['detail-panel'].setAttribute('aria-busy', 'true');
    syncControls();
    try {
      const result = await request(`/v1/admin/feedback/${encodeURIComponent(id)}`, { method, body });
      if (generation !== session || sequence !== detailGeneration || selectedID !== id) return;
      if (method === 'PATCH') {
        if (!validDetail(result, id)) throw new InboxError('서버의 저장 응답 형식이 올바르지 않습니다. 목록에서 다시 확인하세요.');
        selected = result;
        items = items.flatMap((item) => {
          if (item.ticketID !== id) return [item];
          if (ui['status-filter'].value && ui['status-filter'].value !== result.status) return [];
          return [{ ...item, status: result.status }];
        });
        renderList();
        renderDetail();
        announce('상태와 비공개 운영 메모를 저장했습니다.');
      } else {
        clearDetail('제보를 영구 삭제했습니다.');
        mutationBusy = false;
        loadPage(cursors[page], page);
        announce('제보와 첨부 진단 정보, 운영 메모를 영구 삭제했습니다.');
        ui['list-heading'].focus();
      }
    } catch (error) {
      if (generation !== session || sequence !== detailGeneration) return;
      announce();
      reportFailure(error);
    } finally {
      if (generation === session && sequence === detailGeneration) {
        mutationBusy = false;
        ui['detail-panel'].setAttribute('aria-busy', 'false');
        syncControls();
      }
    }
  }

  ui['login-form'].addEventListener('submit', (event) => {
    event.preventDefault();
    if (!apiOrigin || token) return;
    const candidate = ui['operator-key'].value;
    ui['operator-key'].value = '';
    if (!/^[\x21-\x7e]{32,1024}$/.test(candidate)) {
      showError('32~1024자의 공백 없는 ASCII 운영 키를 입력하세요. 키는 저장하지 않았습니다.');
      ui['operator-key'].focus();
      return;
    }
    session += 1;
    token = candidate;
    ui['operator-key'].disabled = true;
    ui['connect-button'].disabled = true;
    ui['login-panel'].hidden = true;
    ui.inbox.hidden = false;
    loadPage();
  });
  ui['disconnect-button'].addEventListener('click', () => disconnect('연결을 해제하고 이 탭의 비공개 내용을 지웠습니다.'));
  ui['refresh-button'].addEventListener('click', () => loadPage());
  ui['status-filter'].addEventListener('change', () => loadPage());
  ui['previous-button'].addEventListener('click', () => { if (page > 0) loadPage(cursors[page - 1], page - 1); });
  ui['next-button'].addEventListener('click', () => { if (nextCursor) loadPage(nextCursor, page + 1); });
  ui['edit-form'].addEventListener('submit', (event) => { event.preventDefault(); mutate('PATCH'); });
  ui['diagnostics-disclosure'].addEventListener('toggle', () => {
    ui['report-diagnostics'].textContent = ui['diagnostics-disclosure'].open && selected ? selected.diagnostics || '' : '';
  });
  ui['delete-button'].addEventListener('click', () => {
    if (!selected || mutationBusy) return;
    ui['delete-ticket'].textContent = selectedID;
    ui['delete-button'].hidden = true;
    ui['delete-confirmation'].hidden = false;
    ui['cancel-delete-button'].focus();
  });
  ui['cancel-delete-button'].addEventListener('click', () => {
    ui['delete-confirmation'].hidden = true;
    ui['delete-ticket'].textContent = '';
    ui['delete-button'].hidden = false;
    ui['delete-button'].focus();
  });
  ui['confirm-delete-button'].addEventListener('click', () => mutate('DELETE'));
  // Explicitly drop secrets before a page can enter the browser's back/forward cache.
  window.addEventListener('pagehide', () => disconnect('', false));
  window.addEventListener('pageshow', () => { ui['operator-key'].value = ''; });

  try {
    const configured = document.querySelector('meta[name="feedback-api-url"]').content.trim();
    if (!configured) throw new Error('Missing configuration');
    const url = new URL(configured);
    const loopback = (host) => ['localhost', '127.0.0.1', '[::1]'].includes(host);
    const localHTTP = url.protocol === 'http:' && loopback(url.hostname) && loopback(window.location.hostname);
    if ((url.protocol !== 'https:' && !localHTTP) || url.username || url.password
      || url.pathname !== '/' || url.search || url.hash) throw new Error('Invalid origin');
    apiOrigin = url.origin;
    disconnect('', false);
  } catch {
    apiOrigin = null;
    disconnect('', false);
    showError('관리 API 원점이 설정되지 않았거나 안전한 주소가 아닙니다. site.feedback_api_url에 실제 HTTPS 원점을 설정하세요. 로컬 개발 페이지에서만 HTTP 루프백 API를 허용합니다.');
  }
})();
