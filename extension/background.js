// Background — orchestrate two-phase crawls for thesaurus + khamenei
const BACKEND = 'https://corpus.ai.ismc.ir';
const KHAMENEI_HOST = 'farsi.khamenei.ir';
const THESAURUS_HOST = 'thesaurus.eiis.iki.ac.ir';

let crawlState = {
  mode: 'idle', // idle | phase1 | phase2 | both
  site: null,
  currentTabId: null,
  khamenei: { listPage: 1, ids: [], idx: 0, delayMs: 2000, errors: 0 },
};

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  handle(msg, sender).then(sendResponse).catch((e) => sendResponse({ ok: false, message: String(e) }));
  return true;
});

async function handle(msg, sender) {
  switch (msg.action) {
    case 'runPhase1':
      return runPhase1(msg.site || 'thesaurus');
    case 'runPhase2':
      return runPhase2(msg.site || 'thesaurus');
    case 'runBothPhases':
      return runBoth(msg.site || 'thesaurus');
    case 'startSingle':
      return startSingle();
    case 'stop':
      crawlState.mode = 'idle';
      await chrome.storage.local.set({ crawlStop: true });
      return { ok: true };
    case 'reset':
      await fetch(`${BACKEND}/api/reset-queue`, { method: 'POST' });
      crawlState.mode = 'idle';
      return { ok: true };
    case 'resetKhameneiPhase2': {
      const r = await fetch(`${BACKEND}/api/khamenei/reset`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ mode: 'phase2' }),
      });
      const data = await r.json();
      crawlState.mode = 'idle';
      return { ok: !!data.ok, ...data };
    }
    case 'getStats':
      return getStats(msg.site || 'thesaurus');
    case 'openProject':
      return controlPicker('openProject', { projectId: msg.projectId });
    case 'testProject':
      return controlPicker('testProject', { projectId: msg.projectId });
    case 'startReading':
      return startReading(msg, sender);
    case 'stopReading':
      return stopReading();
    case 'phaseProgress':
    case 'phaseDone':
      // relay to popup if open
      return { ok: true };
    case 'khameneiListScanned':
      if (crawlState.mode === 'phase1' && crawlState.site === 'khamenei') {
        if ((msg.seeded || 0) === 0) crawlState.khamenei.emptyPages = (crawlState.khamenei.emptyPages || 0) + 1;
        else crawlState.khamenei.emptyPages = 0;
        await continueKhameneiPhase1();
      }
      return { ok: true };
    case 'khameneiExtractResult':
      if (crawlState.mode === 'phase2' && crawlState.site === 'khamenei') {
        await onKhameneiPhase2Result(msg);
      }
      return { ok: true };
    default:
      return { error: 'unknown' };
  }
}

async function runBoth(site) {
  const p1 = await runPhase1(site);
  if (p1?.ok === false) return p1;
  // wait until phase1 finishes (thesaurus content script is long-running)
  if (site === 'thesaurus') {
    await waitUntilIdle();
  }
  return runPhase2(site);
}

async function waitUntilIdle() {
  for (let i = 0; i < 200000; i++) {
    if (crawlState.mode === 'idle') return;
    await sleep(1000);
  }
}

async function runPhase1(site) {
  await chrome.storage.local.set({ crawlStop: false });
  crawlState.mode = 'phase1';
  crawlState.site = site;

  if (site === 'thesaurus') {
    const tabId = await ensureSiteTab('thesaurus');
    await ensureContentScript(tabId, 'thesaurus');
    // fire and forget long harvest — progress via messages
    chrome.tabs.sendMessage(tabId, { action: 'phase1List', delayMs: 350 }, (resp) => {
      crawlState.mode = 'idle';
      chrome.runtime.sendMessage({ action: 'phaseDone', phase: 1, site: 'thesaurus', summary: resp?.summary });
    });
    return { ok: true, message: 'فاز۱ اصطلاح‌نامه شروع شد (Elastic ۱۰۰تایی × ۱۳ علم)' };
  }

  // Khamenei: walk list pages and seed IDs
  crawlState.khamenei = { listPage: 1, ids: [], idx: 0, delayMs: 2000, errors: 0 };
  await navigateToUrl(`https://${KHAMENEI_HOST}/speech?page=1`, 'khamenei');
  return { ok: true, message: 'فاز۱ بیانات: در حال کشف لیست...' };
}

async function continueKhameneiPhase1() {
  if (crawlState.mode !== 'phase1') return;
  const stop = await chrome.storage.local.get(['crawlStop']);
  if (stop.crawlStop) {
    crawlState.mode = 'idle';
    return;
  }
  const s = crawlState.khamenei;
  s.emptyPages = (s.emptyPages || 0);
  // caller should set lastSeeded via message — check storage
  s.listPage += 1;
  if (s.listPage > 800 || s.emptyPages >= 3) {
    crawlState.mode = 'idle';
    chrome.runtime.sendMessage({ action: 'phaseDone', phase: 1, site: 'khamenei' });
    return;
  }
  await sleep(s.delayMs);
  await navigateToUrl(`https://${KHAMENEI_HOST}/speech?page=${s.listPage}`, 'khamenei');
}

async function runPhase2(site) {
  await chrome.storage.local.set({ crawlStop: false });
  crawlState.mode = 'phase2';
  crawlState.site = site;

  if (site === 'thesaurus') {
    const tabId = await ensureSiteTab('thesaurus');
    await ensureContentScript(tabId, 'thesaurus');
    chrome.tabs.sendMessage(tabId, { action: 'phase2Save', batchSize: 50 }, (resp) => {
      crawlState.mode = 'idle';
      chrome.runtime.sendMessage({ action: 'phaseDone', phase: 2, site: 'thesaurus', summary: resp?.summary });
    });
    return { ok: true, message: 'فاز۲ اصطلاح‌نامه: ذخیره کامل از صف...' };
  }

  // Khamenei: pull pending speech IDs and visit pages
  const ids = await fetchPendingKhameneiIds();
  if (!ids.length) {
    crawlState.mode = 'idle';
    const st = await fetch(`${BACKEND}/api/pipeline/status?site=khamenei`).then((r) => r.json());
    if (st.complete) {
      return {
        ok: true,
        alreadyComplete: true,
        message: `همه بیانات ذخیره شده‌اند. آخرین: ${st.phase2?.khamenei_last_crawled_at || '-'}`,
      };
    }
    return { ok: false, message: 'صف بیانات خالی است — اول فاز ۱ را بزنید' };
  }
  crawlState.khamenei.ids = ids;
  crawlState.khamenei.idx = 0;
  crawlState.khamenei.errors = 0;
  await navigateKhameneiDetail();
  return { ok: true, message: `فاز۲: ${ids.length} بیان در صف` };
}

async function fetchPendingKhameneiIds(limit = 500) {
  try {
    const r = await fetch(`${BACKEND}/api/phase2/next-batch?site=khamenei&limit=${limit}`);
    const data = await r.json();
    return (data.items || [])
      .map((j) => {
        const m = (j.url || '').match(/id=(\d+)/);
        return m ? { id: m[1], queue_id: j.id, url: j.url } : null;
      })
      .filter(Boolean);
  } catch (_) {
    return [];
  }
}

async function navigateKhameneiDetail() {
  const s = crawlState.khamenei;
  if (crawlState.mode !== 'phase2') return;
  if (s.idx >= s.ids.length) {
    // try refresh more pending
    const more = await fetchPendingKhameneiIds();
    if (more.length) {
      s.ids = more;
      s.idx = 0;
    } else {
      crawlState.mode = 'idle';
      chrome.runtime.sendMessage({ action: 'phaseDone', phase: 2, site: 'khamenei' });
      return;
    }
  }
  const item = s.ids[s.idx];
  await sleep(s.delayMs);
  await navigateToUrl(item.url || `https://${KHAMENEI_HOST}/speech-content?id=${item.id}`, 'khamenei');
}

async function onKhameneiPhase2Result(msg) {
  const s = crawlState.khamenei;
  if (msg.status === 'inserted' || msg.status === 'updated' || msg.status === 'skipped') {
    s.errors = 0;
    s.delayMs = Math.max(1500, Math.floor(s.delayMs * 0.95));
  } else {
    s.errors += 1;
    s.delayMs = Math.min(20000, Math.floor(s.delayMs * 1.5) + 500);
    if (s.errors >= 5) {
      crawlState.mode = 'idle';
      return;
    }
  }
  s.idx += 1;
  await navigateKhameneiDetail();
}

async function controlPicker(action, extra) {
  const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  const tab = tabs[0];
  if (!tab?.id || !/^https?:/i.test(tab.url || '')) {
    return { ok: false, message: 'یک صفحه وب باز کن' };
  }
  try {
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['content_picker.js'] });
  } catch (_) {}
  try {
    return await chrome.tabs.sendMessage(tab.id, { action, ...(extra || {}) });
  } catch (e) {
    return { ok: false, message: e.message };
  }
}

async function startSingle() {
  const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tabs[0]) return { ok: false, message: 'تب فعالی نیست' };
  const url = tabs[0].url || '';
  const site = /khamenei\.ir/i.test(url) ? 'khamenei' : 'thesaurus';
  await ensureContentScript(tabs[0].id, site);
  try {
    return await chrome.tabs.sendMessage(tabs[0].id, { action: 'extractCurrentPage' });
  } catch (e) {
    return { ok: false, message: e.message };
  }
}

async function getStats(site) {
  try {
    const [pipe, stats, kh] = await Promise.all([
      fetch(`${BACKEND}/api/pipeline/status?site=${site}`).then((r) => r.json()),
      fetch(`${BACKEND}/api/stats`).then((r) => r.json()).catch(() => ({})),
      fetch(`${BACKEND}/api/khamenei/stats`).then((r) => r.json()).catch(() => ({})),
    ]);
    return {
      pipeline: pipe,
      stats,
      khStats: kh,
      mode: crawlState.mode,
      site: crawlState.site,
    };
  } catch (e) {
    return { error: e.message };
  }
}

async function ensureSiteTab(site) {
  const host = site === 'khamenei' ? KHAMENEI_HOST : THESAURUS_HOST;
  const start =
    site === 'khamenei'
      ? `https://${host}/speech`
      : `https://${host}/fa/list/`;
  const tabs = await chrome.tabs.query({ url: `https://${host}/*` });
  if (tabs.length) {
    crawlState.currentTabId = tabs[0].id;
    return tabs[0].id;
  }
  const t = await chrome.tabs.create({ url: start, active: false });
  crawlState.currentTabId = t.id;
  await sleep(2500);
  return t.id;
}

async function navigateToUrl(url, site) {
  const host = site === 'khamenei' ? KHAMENEI_HOST : THESAURUS_HOST;
  const tabs = await chrome.tabs.query({ url: `https://${host}/*` });
  if (tabs.length) {
    crawlState.currentTabId = tabs[0].id;
    await chrome.tabs.update(tabs[0].id, { url, active: false });
  } else {
    const t = await chrome.tabs.create({ url, active: false });
    crawlState.currentTabId = t.id;
  }
}

async function ensureContentScript(tabId, site) {
  try {
    await chrome.tabs.sendMessage(tabId, { action: 'ping' });
  } catch (_) {
    const files =
      site === 'khamenei' ? ['shared.js', 'content_khamenei.js'] : ['shared.js', 'content_thesaurus.js'];
    await chrome.scripting.executeScript({ target: { tabId }, files });
  }
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// Auto-trigger extract/discover when khamenei tab finishes loading during crawl
chrome.tabs.onUpdated.addListener(async (tabId, info, tab) => {
  if (info.status !== 'complete') return;
  if (tabId !== crawlState.currentTabId) return;
  if (!tab.url || !tab.url.includes(KHAMENEI_HOST)) return;
  if (crawlState.site !== 'khamenei') return;
  if (crawlState.mode !== 'phase1' && crawlState.mode !== 'phase2') return;

  try {
    await ensureContentScript(tabId, 'khamenei');
    if (crawlState.mode === 'phase1' && /\/speech(\?|$)/.test(tab.url)) {
      await chrome.tabs.sendMessage(tabId, { action: 'discoverSpeechIds' });
    } else if (crawlState.mode === 'phase2' && tab.url.includes('speech-content')) {
      await chrome.tabs.sendMessage(tabId, { action: 'extractCurrentPage' });
    }
  } catch (e) {
    console.error(e);
    crawlState.khamenei.errors += 1;
    if (crawlState.mode === 'phase2') {
      crawlState.khamenei.idx += 1;
      await navigateKhameneiDetail();
    }
  }
});

let reading = false;

// --- Next-page strategies ----------------------------------------------------
// next_param holds a spec string (next_mode stays 'url_param' for backend compat):
//   ''                              → none
//   '<param>'                       → legacy: increment ?<param>=N query param
//   'next-link' | 'next-link:<css>' → follow the next-page link found on the page
//   'url-number'                    → last number in the path, +step, zero-pad kept
//   'regex:<pattern>'               → exactly one digit capture group, +step

function parseNextSpec(project) {
  const spec = String((project && project.next_param) || '').trim();
  if (!spec) return { kind: 'none' };
  if (spec === 'next-link' || spec.indexOf('next-link:') === 0) {
    return { kind: 'nextLink', selector: spec === 'next-link' ? '' : spec.slice('next-link:'.length).trim() };
  }
  if (spec === 'url-number') return { kind: 'number' };
  if (spec.indexOf('regex:') === 0) return { kind: 'regex', pattern: spec.slice('regex:'.length).trim() };
  return { kind: 'param', param: spec };
}

function bumpNumber(numStr, step) {
  const n = parseInt(numStr, 10) + step;
  if (!Number.isFinite(n) || n < 0) throw new Error('عدد ' + numStr + ' جلو نمی‌رود');
  return (numStr.length > 1 && numStr[0] === '0') ? String(n).padStart(numStr.length, '0') : String(n);
}

function advanceUrl(url, project) {
  const spec = parseNextSpec(project);
  if (spec.kind === 'none') throw new Error('قانون صفحه بعد ذخیره نشده');
  if (spec.kind === 'nextLink') throw new Error('روش «لینک صفحه بعد» نیاز به باز شدن صفحه دارد');
  const step = Number((project && project.next_step) || 1) || 1;
  const next = new URL(url);
  if (spec.kind === 'param') {
    const param = spec.param;
    if (!next.searchParams.has(param)) throw new Error('پارامتر ' + param + ' در لینک نیست');
    const n = parseInt(next.searchParams.get(param), 10);
    if (!Number.isFinite(n)) throw new Error('پارامتر صفحه عدد نیست');
    next.searchParams.set(param, String(n + step));
    return next.toString();
  }
  if (spec.kind === 'number') {
    const runs = next.pathname.match(/\d+/g);
    if (!runs) throw new Error('عدد در مسیر آدرس نیست — از روش رجکس استفاده کن');
    const run = runs[runs.length - 1];
    const idx = next.pathname.lastIndexOf(run);
    next.pathname = next.pathname.slice(0, idx) + bumpNumber(run, step) + next.pathname.slice(idx + run.length);
    return next.toString();
  }
  if (spec.kind === 'regex') {
    let re;
    try {
      re = new RegExp(spec.pattern);
    } catch (e) {
      throw new Error('رجکس نامعتبر: ' + e.message);
    }
    const m = re.exec(next.pathname);
    if (!m) throw new Error('رجکس با این آدرس همخوانی ندارد');
    const groups = m.slice(1).filter((g) => g !== undefined);
    if (groups.length !== 1) throw new Error('رجکس باید دقیقا‌ یک گروه ( ) داشته باشد');
    const g = groups[0];
    if (!/^\d+$/.test(g)) throw new Error('گروهِ رجکس عدد نیست');
    const idx = m.index + m[0].indexOf(g);
    next.pathname = next.pathname.slice(0, idx) + bumpNumber(g, step) + next.pathname.slice(idx + g.length);
    return next.toString();
  }
  throw new Error('قانون صفحه بعد نامعتبر است');
}

async function postReport(projectId, body) {
  const r = await fetch(`${BACKEND}/api/projects/${projectId}/report`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  return r.json();
}

function newToken() {
  return 'r' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
}

async function startReading(msg, sender) {
  const stored = await chrome.storage.local.get('pctRun');
  if (stored.pctRun?.active) {
    return { ok: false, message: 'یک پروژهٔ دیگر در حال خواندن است — اول «توقف» را بزن.' };
  }
  const projectId = msg.projectId;
  const info = await fetch(`${BACKEND}/api/projects/${projectId}`).then((r) => r.json());
  if (!info.id) return { ok: false, message: 'پروژه پیدا نشد' };
  if (info.status === 'draft' || !info.tested_at) {
    return { ok: false, message: 'اول آزمایش این صفحه باید موفق شود' };
  }
  if (info.next_mode !== 'url_param' || !info.next_param) {
    return { ok: false, message: 'قانون صفحه بعد ذخیره نشده' };
  }
  const pages = Math.max(1, Math.min(12, Number(msg.pagesPerMinute || info.pages_per_minute || 4)));
  // تب اختصاصی در background: تب کاربر (و پنلش) دست‌نخورده می‌ماند و می‌تواند
  // در همان meanwhile پروژهٔ دیگر را ویرایش کند.
  const tab = await chrome.tabs.create({ url: 'about:blank', active: false });
  const tabId = tab.id;
  await postReport(projectId, { status: 'running', message: `خواندن شروع شد، ${pages} صفحه در دقیقه` });
  await chrome.storage.local.set({
    pctRun: { active: true, token: newToken(), projectId, tabId, pagesPerMinute: pages, emptyStreak: 0, nextUrl: String(msg.nextUrl || '') },
  });
  chrome.alarms.create('pctRead', { delayInMinutes: 1, periodInMinutes: 1 });
  runMinute();
  return { ok: true, message: `خواندن شروع شد، ${pages} صفحه در دقیقه` };
}

async function stopReading() {
  const stored = await chrome.storage.local.get('pctRun');
  const run = stored.pctRun;
  await chrome.alarms.clear('pctRead');
  if (run?.active && run?.projectId) {
    await postReport(run.projectId, { status: 'paused', message: 'خواندن متوقف شد' });
  }
  // تغییر token: حلقه‌ای که در حال اجراست ناهمخوانی را می‌بیند و می‌ایستد؛
  // هیچ snapshot قدیمی دیگر نمی‌تواند active:true را برگرداند.
  await chrome.storage.local.set({
    pctRun: { ...(run || {}), active: false, token: newToken() },
  });
  return { ok: true, message: 'خواندن متوقف شد' };
}

function waitComplete(tabId, timeout) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      chrome.tabs.onUpdated.removeListener(onUp);
      reject(new Error('صفحه دیر باز شد'));
    }, timeout);
    function onUp(id, info) {
      if (id === tabId && info.status === 'complete') {
        clearTimeout(timer);
        chrome.tabs.onUpdated.removeListener(onUp);
        resolve();
      }
    }
    chrome.tabs.onUpdated.addListener(onUp);
  });
}

async function extractWhenReady(tabId, payload) {
  let last = 'اسکریپت صفحه جواب نداد';
  for (let i = 0; i < 8; i += 1) {
    try {
      await chrome.scripting.executeScript({ target: { tabId }, files: ['content_picker.js'] });
    } catch (_) {}
    try {
      return await chrome.tabs.sendMessage(tabId, payload);
    } catch (e) {
      last = e.message;
      await sleep(400);
    }
  }
  return { ok: false, message: last };
}

// توقفی که token هنوز هم‌خوانی دارد: گزارش paused + غیرفعال‌سازی. اگر کاربر
// از قبل «توقف» زده باشد (token عوض شده)، دست به storage نمی‌زند.
async function endRun(projectId, message, token) {
  await postReport(projectId, { status: 'paused', message });
  const stored = await chrome.storage.local.get('pctRun');
  const cur = stored.pctRun;
  if (cur?.active && cur.token === token) {
    await chrome.storage.local.set({ pctRun: { ...cur, active: false } });
  }
  await chrome.alarms.clear('pctRead');
}

// خفتی که به توقف واکنش نشان می‌دهد: هر یک ثانیه یک‌بار چک می‌کند.
async function sleepLive(ms, isLive) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    await sleep(Math.min(1000, end - Date.now()));
    if (!(await isLive())) return false;
  }
  return true;
}

async function runMinute() {
  if (reading) return;
  const stored = await chrome.storage.local.get('pctRun');
  const run0 = stored.pctRun;
  if (!run0?.active) return;
  // خواندنی قدیمی (بدون token، قبل از v3.7): پایان می‌دهد و شروع دوباره می‌خواهد.
  if (!run0.token) {
    await postReport(run0.projectId, { status: 'paused', message: 'خواندن نسخهٔ قدیمی قطع شد — دوباره «آزمایش و شروع» بزن.' });
    await chrome.storage.local.set({ pctRun: { ...run0, active: false } });
    await chrome.alarms.clear('pctRead');
    return;
  }
  const token = run0.token;
  // هویت این اجرا: تا tokenِ storage با token ما یکی باشد و active باشد، زنده‌ایم؛
  // «توقف» فقط token را عوض می‌کند.
  const isLive = async () => {
    const fresh = await chrome.storage.local.get('pctRun');
    return !!(fresh.pctRun && fresh.pctRun.active && fresh.pctRun.token === token);
  };
  reading = true;
  let saved = 0;
  let skipped = 0;
  let failed = 0;
  let emptyStreak = run0.emptyStreak || 0;
  let nextUrl = run0.nextUrl || '';
  const run = { projectId: run0.projectId, tabId: run0.tabId, pagesPerMinute: run0.pagesPerMinute };
  try {
    const project = await fetch(`${BACKEND}/api/projects/${run.projectId}`).then((r) => r.json());
    if (!project?.id || project.status === 'paused') {
      await endRun(run.projectId, 'پروژه متوقف یا پیدا نشد.', token);
      return;
    }
    const spec = parseNextSpec(project);
    let cursor = project.cursor_url || project.start_url;
    const pages = Math.max(1, Math.min(12, Number(run.pagesPerMinute || project.pages_per_minute || 4)));
    const gap = Math.max(2000, Math.floor(60000 / pages) - 4000);
    let target = '';
    if (spec.kind === 'nextLink') {
      // صفحه بعد از لینکِ خود صفحه پیدا می‌شود؛ در آزمایش اولین‌اش ذخیره شد.
      target = String(nextUrl || '');
      if (!target) target = cursor; // لینک ذخیره‌شده نیست: اول صفحه فعلی را بخوان تا کشف شود
    } else {
      try {
        target = advanceUrl(cursor, project);
      } catch (e) {
        await endRun(run.projectId, 'نمی‌توان به صفحه بعد رفت: ' + e.message, token);
        return;
      }
    }
    for (let i = 0; i < pages; i += 1) {
      if (!(await isLive())) return; // «توقف» زده شد
      if (!target) {
        await endRun(run.projectId, 'لینک صفحه بعد پیدا نشد — خواندن تمام شد.', token);
        return;
      }
      try { await chrome.tabs.get(run.tabId); } catch (_) {
        await endRun(run.projectId, 'تب خواندن بسته شد.', token);
        return;
      }
      try {
        await chrome.tabs.update(run.tabId, { url: target });
        await waitComplete(run.tabId, 20000);
        if (!(await isLive())) return;
        await sleep(600);
        const result = await extractWhenReady(run.tabId, {
          action: 'extractProject',
          projectId: project.id,
          points: project.points,
          nextSpec: project.next_param || '',
        });
        if (!(await isLive())) return;
        // مقصد بعدی: در روش لینک، از خود صفحه؛ در بقیه، از آدرس.
        let nextTarget = '';
        if (spec.kind === 'nextLink') {
          nextTarget = String((result && result.nextUrl) || '');
        } else {
          try {
            nextTarget = advanceUrl(target, project);
          } catch (e) {
            nextTarget = 'ERR:' + e.message;
          }
        }
        const advanceFailed = spec.kind !== 'nextLink' && nextTarget.indexOf('ERR:') === 0;
        if (!result?.ok) {
          emptyStreak += 1;
          failed += 1;
          await postReport(run.projectId, { failed: 1, cursor_url: target, message: result?.message || 'صفحه خوانده نشد' });
          if (advanceFailed) {
            await endRun(run.projectId, 'نمی‌توان به صفحه بعد رفت: ' + nextTarget.slice(4), token);
            return;
          }
          if (spec.kind === 'nextLink' && !nextTarget) {
            await endRun(run.projectId, 'صفحه بعد پیدا نشد. خواندن ایستاد.', token);
            return;
          }
          if (emptyStreak >= 2) {
            await endRun(run.projectId, 'دو صفحه پشت‌سرهم متن نداشت. خواندن ایستاد.', token);
            return;
          }
        } else {
          emptyStreak = 0;
          if (result.status === 'skipped') skipped += 1;
          else saved += 1;
          const label = Object.entries(result.values || {}).map(([k, v]) => `${k}=${String(v || '').slice(0, 24)}`).join(' ');
          const tail = spec.kind === 'nextLink' && nextTarget ? ' → ' + nextTarget : '';
          await postReport(run.projectId, {
            cursor_url: target,
            message: `${result.status}: ${label || target}${tail}`,
          });
          if (advanceFailed) {
            await endRun(run.projectId, 'نمی‌توان به صفحه بعد رفت: ' + nextTarget.slice(4), token);
            return;
          }
          if (spec.kind === 'nextLink' && !nextTarget) {
            await endRun(run.projectId, 'صفحه ذخیره شد ولی لینک صفحه بعد نداشت — خواندن تمام شد.', token);
            return;
          }
        }
        cursor = target;
        if (nextTarget) {
          if (spec.kind === 'nextLink') nextUrl = nextTarget;
          target = nextTarget;
        }
        if (!(await isLive())) return;
        // ذخیره پیشرفت با همان token — snapshot قدیمی دیگر نمی‌تواند run را
        // بعد از توقف زنده کند.
        await chrome.storage.local.set({
          pctRun: { active: true, token, projectId: run.projectId, tabId: run.tabId, pagesPerMinute: run.pagesPerMinute, emptyStreak, nextUrl },
        });
      } catch (e) {
        if (!(await isLive())) return;
        failed += 1;
        await postReport(run.projectId, { failed: 1, message: e.message });
      }
      if (i < pages - 1) {
        if (!(await sleepLive(gap, isLive))) return;
      }
    }
    if (!(await isLive())) return;
    const summary = await fetch(`${BACKEND}/api/projects/${run.projectId}`).then((r) => r.json());
    // آخرین چک: اگر وسط fetch توقف زده شد، «running» قدیمی را بعد از «paused» نپوشانیم.
    if (!(await isLive())) return;
    await postReport(run.projectId, {
      status: 'running',
      message: `این دقیقه ${saved} ذخیره، ${skipped} رد، ${failed} خطا. مجموع ${summary.saved_count || 0}.`,
    });
  } finally {
    reading = false;
  }
}

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'pctRead') runMinute();
});

// اگر تب خواندن بسته شود، run پایان می‌یابد و گزارش می‌دهد.
chrome.tabs.onRemoved.addListener(async (tabId) => {
  const stored = await chrome.storage.local.get('pctRun');
  const run = stored.pctRun;
  if (run?.active && run.tabId === tabId) {
    await chrome.alarms.clear('pctRead');
    await postReport(run.projectId, { status: 'paused', message: 'خواندن متوقف شد — تب خواندن بسته شد.' });
    await chrome.storage.local.set({ pctRun: { ...run, active: false, token: newToken() } });
  }
});

async function resumeReadingAlarm() {
  const stored = await chrome.storage.local.get('pctRun');
  if (stored.pctRun?.active) {
    chrome.alarms.create('pctRead', { delayInMinutes: 1, periodInMinutes: 1 });
  }
}
chrome.runtime.onStartup.addListener(resumeReadingAlarm);
chrome.runtime.onInstalled.addListener(resumeReadingAlarm);
