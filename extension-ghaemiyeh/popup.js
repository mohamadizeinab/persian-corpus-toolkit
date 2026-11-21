// Ghaemiyeh Book Collector — popup (PCM-EXT-05)
'use strict';

const BACKEND = 'https://corpus.ai.ismc.ir';
let state = { items: [], collId: null, collName: '', running: false, stopped: false };
let pollTimer = null;

function esc(s) {
  const MAP = {
    '&': '\u0026amp;',
    '<': '\u0026lt;',
    '>': '\u0026gt;',
    '"': '\u0026quot;',
    "'": '\u0026#39;',
  };
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => MAP[c]);
}

function $(id) { return document.getElementById(id); }

function log(msg, cls) {
  const box = $('logBox');
  const d = document.createElement('div');
  d.className = cls || 'info';
  const t = new Date().toLocaleTimeString('fa-IR', { hour12: false });
  d.textContent = `[${t}] ${msg}`;
  box.appendChild(d);
  while (box.children.length > 200) box.removeChild(box.firstChild);
  box.scrollTop = box.scrollHeight;
}

function send(action, extra) {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage(Object.assign({ action }, extra || {}), (resp) => {
      if (chrome.runtime.lastError) resolve({ ok: false, message: chrome.runtime.lastError.message });
      else resolve(resp || { ok: false, message: 'no response' });
    });
  });
}

async function loadCollections() {
  const r = await send('ghListCollections');
  const sel = $('collSelect');
  if (r.status === 401) {
    sel.innerHTML = '<option value="">401 — وارد داشبورد شوید</option>';
    log('401: برای ساخت/انتخاب کالکشن، وارد corpus.ai.ismc.ir/dashboard شوید', 'err');
    return;
  }
  if (!r.ok) {
    sel.innerHTML = '<option value="">خواندن فهرست ناموفق</option>';
    return;
  }
  const list = r.collections || [];
  sel.innerHTML = '';
  const blank = document.createElement('option');
  blank.value = '';
  blank.textContent = list.length ? 'یک کالکشن را انتخاب کن' : 'کالکشنی نیست — بساز';
  sel.appendChild(blank);
  for (const c of list) {
    const o = document.createElement('option');
    o.value = String(c.collection_id != null ? c.collection_id : c.id);
    o.textContent = `${c.name || c.slug} (${c.slug})`;
    sel.appendChild(o);
  }
  if (state.collId != null) {
    const cur = [...sel.options].find((o) => o.value === String(state.collId));
    if (cur) sel.value = String(state.collId);
  }
}

function renderBooks() {
  const tb = $('bookTbody');
  tb.innerHTML = '';
  const counts = {
    done: 0, duplicate: 0, failed: 0, 'need-manual': 0,
    unsupported: 0, queued: 0, 'downloading': 0, 'uploading': 0,
  };
  for (const it of state.items) {
    const st = it.status || 'queued';
    if (counts[st] !== undefined) counts[st] += 1;
    const tr = document.createElement('tr');

    const td1 = document.createElement('td');
    const cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.checked = !!it.selected;
    cb.addEventListener('change', () => {
      it.selected = cb.checked;
      send('ghSelect', { ids: [it.book_id], selected: it.selected });
    });
    td1.appendChild(cb);

    const td2 = document.createElement('td');
    td2.className = 't';
    td2.title = it.title || '';
    td2.textContent = `${it.title || '؟'}  (${it.book_id})`;

    const td3 = document.createElement('td');
    td3.style.textAlign = 'center';
    if (it.download_url) {
      td3.textContent = '✓';
      td3.title = it.download_url;
    } else {
      td3.textContent = '—';
      td3.title = 'لینک مستقیم نبود؛ از صفحهٔ کتاب گرفته می‌شود';
    }

    const td4 = document.createElement('td');
    const stEl = document.createElement('span');
    stEl.className = `st st-${st}`;
    stEl.textContent = stLabel(st);
    stEl.title = it.detail || '';
    td4.appendChild(stEl);

    const td5 = document.createElement('td');
    const b = document.createElement('button');
    b.className = 'row-btn';
    b.textContent = 'آپلود';
    b.title = 'فایل DOCX این کتاب را از کامپیوتر انتخاب کن';
    b.addEventListener('click', () => manualUpload(it));
    td5.appendChild(b);

    tr.appendChild(td1); tr.appendChild(td2); tr.appendChild(td3);
    tr.appendChild(td4); tr.appendChild(td5);
    tb.appendChild(tr);
  }
  const n = state.items.length;
  $('statBar').innerHTML = n
    ? `کتاب: <b>${n}</b> · آماده: <b>${counts.queued}</b> · شد: <b>${counts.done}</b> · تکراری: <b>${counts.duplicate}</b> · خطا: <b>${counts.failed}</b> · دستی: <b>${counts['need-manual']}</b> · پشتیبانی‌نشده: <b>${counts.unsupported}</b>`
    : 'هنوز تریسی نشده — URL دسته را بنویس یا تب غایمیه را باز بگذار.';
}

function stLabel(st) {
  return {
    queued: 'در صف', downloading: 'دانلود…', uploading: 'آپلود…',
    done: '✓ شد', duplicate: 'تکراری (موجود)', failed: 'خطا',
    'auth-error': '401 ورود', unsupported: 'غیر-DOCX', 'need-manual': 'دستی',
  }[st] || st;
}

async function refreshState() {
  const r = await send('ghState');
  if (!r.ok) return;
  const wasRunning = state.running;
  state = {
    items: r.items || [],
    collId: r.collId != null ? r.collId : null,
    collName: r.collName || '',
    running: !!r.running,
    stopped: !!r.stopped,
  };
  renderBooks();
  $('btnStop').disabled = !state.running;
  if (wasRunning && !state.running) {
    log('صف خالی شد / انجام شد', 'ok');
  }
}

async function bindAll() {
  $('collSelect').addEventListener('change', (e) => {
    const v = e.target.value;
    const opt = [...e.target.options].find((o) => o.value === v);
    send('ghSetCollection', { collId: v ? Number(v) : null, collName: opt ? opt.textContent : '' });
  });

  $('btnCreateColl').addEventListener('click', async () => {
    const name = $('cName').value.trim();
    let slug = $('cSlug').value.trim().toLowerCase();
    if (!name) { log('نام کالکشن را بنویس', 'warn'); return; }
    if (!/^[a-z0-9-]{2,64}$/.test(slug)) {
      slug = name.replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-+|-+$/g, '').slice(0, 64);
      // ascii fallback: transliteration is not available; keep a stable id
      if (!/^[a-z0-9-]{2,}$/.test(slug)) slug = 'ghaemiyeh-' + Date.now().toString(36);
      $('cSlug').value = slug;
    }
    const r = await send('ghCreateCollection', { name, slug, description: 'غایمیه — توسط اکستنشن' });
    if (r.status === 401) { log('401: اول وارد داشبورد شوید', 'err'); return; }
    if (!r.ok) { log(`ساخت کالکشن ناموفق: ${r.json && r.json.message || r.message}`, 'err'); return; }
    log(`کالکشن ساخته شد: ${r.json.collection.name}`, 'ok');
    await loadCollections();
    $('collSelect').value = String(r.json.collection.collection_id);
    $('collSelect').dispatchEvent(new Event('change'));
  });

  $('chkAll').addEventListener('change', (e) => {
    const on = e.target.checked;
    for (const it of state.items) {
      it.selected = on;
      send('ghSelect', { ids: [it.book_id], selected: on });
    }
    renderBooks();
  });

  $('btnTrace').addEventListener('click', async () => {
    let url = $('traceUrl').value.trim();
    if (!url) { log('URL صفحهٔ دسته را بنویس', 'warn'); return; }
    if (!/^https?:\/\//i.test(url)) url = 'https://' + url;
    const sec = Number($('delaySec').value);
    await setDelay(Number.isFinite(sec) ? sec : 3);
    log(`تریس شروع شد: ${url}`, 'info');
    $('traceHint').textContent = 'در حال تریس… (چند دقیقه برای فهرست‌های بزرگ)';
    const t0 = Date.now();
    const r = await send('ghStartTrace', { url });
    $('traceHint').textContent = '';
    if (!r.ok) { log(`تریس ناموفق: ${r.message || 'خطای شبکه'}`, 'err'); return; }
    log(`تریس تمام شد: ${r.books} کتاب (${r.pages} صفحه${r.orphans ? ', ' + r.orphans + ' دانلود بی‌صاحب' : ''}) در ${Math.round((Date.now() - t0) / 1000)}s`, 'ok');
    await refreshState();
  });

  $('btnTraceTab').addEventListener('click', async () => {
    log('استخراج از تب باز…', 'info');
    const r = await send('ghExtractCurrentPage');
    if (!r.ok) { log(r.message || 'استخراج ناموفق', 'err'); return; }
    log(`${r.books} کتاب از تب افزوده شد (مجموع: ${r.total})`, 'ok');
    await refreshState();
  });

  $('btnRun').addEventListener('click', async () => {
    if (state.collId == null) { log('اول یک کالکشن انتخاب/بساز', 'warn'); return; }
    const r = await send('ghRun');
    if (!r.ok) { log(r.message || 'شروع نشد', 'err'); return; }
    log(`صف شروع شد: ${r.queued} کتاب → کالکشن ${state.collName || state.collId}`, 'info');
  });

  $('btnStop').addEventListener('click', async () => {
    await send('ghStop');
    log('درخواست توقف ثبت شد (بعد از کتاب جاری)', 'warn');
  });

  $('btnRetry').addEventListener('click', async () => {
    const r = await send('ghRetryFailed');
    log(`${r.retried} کتاب دوباره در صف`, 'info');
    await refreshState();
  });

  $('btnUploadManual').addEventListener('click', () => $('fileInput').click());
  $('fileInput').addEventListener('change', (e) => {
    const f = e.target.files && e.target.files[0];
    if (f) uploadFileTo(f, null);
    e.target.value = '';
  });
}

function manualUpload(item) {
  const inp = $('fileInput');
  inp.dataset.bookId = item.book_id;
  inp.click();
  inp.onchange = (e) => {
    const f = e.target.files && e.target.files[0];
    if (f) uploadFileTo(f, item);
    e.target.value = '';
    inp.onchange = null;
  };
}

async function setDelay(sec) {
  const ms = Math.max(0, Math.min(30, sec)) * 1000;
  await new Promise((res) => chrome.storage.local.set({ ghDelayMs: ms }, res));
  // SW reads delayMs from its own deps at run time; keep it simple by
  // re-injecting via a message that re-reads storage (no-op if absent)
  try {
    const tabs = await chrome.tabs.query({});
    for (const t of tabs) {
      try { chrome.runtime.sendMessage({ action: 'ghDelay', ms }); } catch (_) {}
    }
  } catch (_) {}
}

async function uploadFileTo(file, item) {
  if (!state.collId) { log('اول کالکشن انتخاب کن', 'warn'); return; }
  if (!/\.docx$/i.test(file.name)) { log('فقط DOCX', 'err'); return; }
  if (file.size > 50 * 1024 * 1024) { log('بزرگ‌تر از 50MB', 'err'); return; }
  log(`آپلود ${file.name} (${Math.round(file.size / 1024)}KB)…`, 'info');
  const fd = new FormData();
  fd.append('file', file, file.name);
  try {
    const r = await fetch(
      `${BACKEND}/api/knowledge/collections/${state.collId}/documents`,
      { method: 'POST', body: fd, credentials: 'include' }
    );
    let json = null;
    try { json = await r.json(); } catch (_) {}
    if (r.status === 201) {
      log(`✓ آپلود شد: ${file.name}`, 'ok');
      if (item) send('ghMarkResult', { book_id: item.book_id, status: 'done', name: file.name });
    } else if (r.status === 409) {
      log('قبلاً در این کالکشن بود (409)', 'warn');
      if (item) send('ghMarkResult', { book_id: item.book_id, status: 'duplicate', name: file.name });
    } else if (r.status === 401) {
      log('401: وارد داشبورد شوید', 'err');
    } else {
      log(`آپلود ناموفق: ${json && json.message || 'HTTP ' + r.status}`, 'err');
    }
  } catch (e) {
    log(`آپلود خطا: ${e.message}`, 'err');
  }
  await refreshState();
}

chrome.runtime.onMessage.addListener((msg) => {
  if (!msg || !msg.action) return;
  if (msg.action === 'ghEvent') {
    const label = msg.type === 'finished' ? 'صف انجام شد'
      : msg.type === 'stopped' ? 'توقف کرد'
      : msg.type === 'auth-error' ? '401 — وارد داشبورد شوید و دوباره بزن'
      : `${stLabel(msg.status || '')} · ${msg.book_id || ''}${msg.name ? ' · ' + msg.name : ''}${msg.detail ? ' · ' + msg.detail : ''}`;
    const cls = msg.type === 'auth-error' ? 'err'
      : (msg.status === 'done') ? 'ok'
      : (msg.status && ['failed', 'unsupported', 'need-manual'].includes(msg.status)) ? 'warn'
      : 'info';
    log(label, cls);
    refreshState();
  }
});

document.addEventListener('DOMContentLoaded', async () => {
  bindAll();
  await loadCollections();
  await refreshState();
  pollTimer = setInterval(refreshState, 2500);
});
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { clearInterval(pollTimer); }
  else { refreshState(); pollTimer = setInterval(refreshState, 2500); }
});
