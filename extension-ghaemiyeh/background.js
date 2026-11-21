// Ghaemiyeh Book Collector — service worker (PCM-EXT-05)
//
// Two layers:
//   1. A PURE pipeline (createPipeline helpers) that depends only on an
//      injected `deps` object — unit-testable in node (test_ghaemiyeh.js).
//   2. The service-worker wiring (chrome.* + real fetch) at the bottom.
//
// All network work happens in the USER'S BROWSER on purpose: ghaemiyeh.ir's
// edge rejects non-browser TLS clients (see docs/گزارش-PCM-EXT-05.md §1).
// Auth to corpus.ai.ismc.ir rides the user's existing `pct_session` cookie
// (credentials: 'include' + host_permissions) — no password in this code.

const BACKEND = 'https://corpus.ai.ismc.ir';
const MAX_TRACE_PAGES = 200;
const DEFAULT_DELAY_MS = 3000;
const MAX_FILE_BYTES = 50 * 1024 * 1024; // matches backend cap (50MB)

// ---------------------------------------------------------------------------
// Pure extraction helpers
// ---------------------------------------------------------------------------

function bookIdFromHref(href) {
  const m = String(href || '').match(/show-book\/(\d+)/);
  return m ? m[1] : null;
}

function downloadIdFromHref(href) {
  const m = String(href || '').match(/library\/download\/(\d+)/);
  return m ? m[1] : null;
}

function textOf(el) {
  return (el && (el.textContent || el.innerText) || '').replace(/\s+/g, ' ').trim();
}

function cleanTitle(s) {
  return String(s || '')
    .replace(/\s+/g, ' ')
    .replace(/(?:^|\s)(?:download|دانلود)[\s.]*$/i, '')
    .replace(/^[\s.·•|-]+|[\s.·•|-]+$/g, '')
    .trim();
}

function absUrl(href, base) {
  try {
    return new URL(href, base).href;
  } catch (_) {
    return null;
  }
}

/** Find the book card that owns a download link (walk up to 8 levels). */
function ownerBookId(a, books) {
  const CARD_SEL = ['li', 'tr', 'article', 'div', 'td'];
  let card = a.closest ? a.closest(CARD_SEL.join(',')) : a.parentElement;
  let depth = 0;
  while (card && depth < 8) {
    const links = card.querySelectorAll ? card.querySelectorAll('a[href]') : [];
    for (const b of links) {
      const bid = bookIdFromHref(b.getAttribute ? b.getAttribute('href') : '');
      if (bid && books.has(bid)) return bid;
    }
    card = card.parentElement || null;
    depth += 1;
  }
  return null;
}

/**
 * Extract the book set from a DOM (document or DOMParser result).
 * Returns { books: [{book_id,title,url,download_url}], orphans: [{download_id,url}] }
 * orphans = download links whose card has no recognizable book link.
 */
function extractBooks(dom, baseUrl) {
  const books = new Map();
  const orphans = [];
  const anchors = dom.querySelectorAll('a[href]');

  // Pass 1: canonical book links
  for (const a of anchors) {
    const href = a.getAttribute('href') || '';
    const bid = bookIdFromHref(href);
    if (!bid) continue;
    const url = absUrl(href, baseUrl);
    if (!url) continue;
    const title = cleanTitle(textOf(a));
    const prev = books.get(bid);
    if (!prev) {
      books.set(bid, { book_id: bid, title: title || `کتاب ${bid}`, url, download_url: null });
    } else if (!prev.title && title) {
      prev.title = title;
    }
  }

  // Pass 2: download links, tied to their book card
  for (const a of anchors) {
    const href = a.getAttribute('href') || '';
    const did = downloadIdFromHref(href);
    if (!did) continue;
    const url = absUrl(href, baseUrl);
    if (!url) continue;
    const bid = ownerBookId(a, books);
    if (bid) {
      const bk = books.get(bid);
      if (bk && !bk.download_url) bk.download_url = url;
    } else {
      orphans.push({ download_id: did, url });
    }
  }

  return { books: [...books.values()], orphans };
}

/** Highest `page=N` link that stays on the same category page (else 0). */
function nextPageInfo(dom, baseUrl) {
  let maxPage = 0;
  let curPath = null;
  try {
    curPath = new URL(baseUrl).pathname;
  } catch (_) {
    curPath = null;
  }
  for (const a of dom.querySelectorAll('a[href]')) {
    const href = a.getAttribute('href') || '';
    const m = href.match(/[?&]page=(\d+)/);
    if (!m) continue;
    const p = parseInt(m[1], 10);
    if (!Number.isFinite(p) || p <= 1) continue;
    try {
      if (curPath && new URL(href, baseUrl).pathname !== curPath) continue;
    } catch (_) {
      continue;
    }
    if (p > maxPage) maxPage = p;
  }
  return maxPage;
}

/**
 * Walk a category listing from startUrl until there is no next page.
 * deps: { fetchText(url), parseHtml(html), sleep(ms), delayMs }
 */
async function traceCategory(deps, startUrl, maxPages = MAX_TRACE_PAGES) {
  const books = new Map();
  const orphans = [];
  const visited = new Set();
  let current = startUrl;
  let pages = 0;
  let stoppedReason = 'done';

  while (current && !visited.has(current)) {
    if (pages >= maxPages) {
      stoppedReason = 'max-pages';
      break;
    }
    visited.add(current);
    pages += 1;
    const html = await deps.fetchText(current);
    const dom = deps.parseHtml(html);
    const { books: fb, orphans: fo } = extractBooks(dom, current);
    for (const b of fb) {
      const prev = books.get(b.book_id);
      if (!prev) {
        books.set(b.book_id, b);
      } else {
        if (!prev.download_url && b.download_url) prev.download_url = b.download_url;
        if (!prev.title && b.title) prev.title = b.title;
      }
    }
    orphans.push(...fo);

    const thisPage = (() => {
      try {
        const p = parseInt(new URL(current).searchParams.get('page') || '1', 10);
        return Number.isFinite(p) && p > 1 ? p : 1;
      } catch (_) {
        return 1;
      }
    })();
    const maxPage = nextPageInfo(dom, current);
    if (maxPage > thisPage) {
      const u = new URL(current);
      u.searchParams.set('page', String(maxPage));
      current = u.href;
      await deps.sleep(deps.delayMs || 0);
    } else {
      current = null;
    }
  }

  return { books: [...books.values()], orphans, pages, stoppedReason };
}

/**
 * Filename from a Content-Disposition header (RFC 5987 first, then plain).
 * Returns null when absent.
 */
function fileNameFromDisposition(cd) {
  if (!cd) return null;
  let m = String(cd).match(/filename\*\s*=\s*([^']*?)'[^']*'([^;]+)/i);
  if (m) {
    const raw = m[2].trim().replace(/^"|"$/g, '');
    try {
      return decodeURIComponent(raw);
    } catch (_) {
      return raw;
    }
  }
  m = String(cd).match(/filename\s*=\s*("([^"]+)"|[^;]+)/i);
  if (m) {
    const raw = (m[2] !== undefined ? m[2] : m[1]).trim();
    try {
      return decodeURIComponent(raw);
    } catch (_) {
      return raw;
    }
  }
  return null;
}

/**
 * Download one book (with show-book fallback) and upload it to the collection.
 * deps: { fetchText, parseHtml, fetchBlob(url) -> Response,
 *         uploadDocument(collId, FormData) -> {status, json}, openTab(url) }
 * Returns { status: done|duplicate|unsupported|failed|auth-error|need-manual,
 *           book_id, name?, detail? }
 */
async function processBook(deps, book, collId) {
  let resp = null;
  if (book.download_url) {
    try {
      resp = await deps.fetchBlob(book.download_url);
    } catch (_) {
      resp = null;
    }
    if (resp && !resp.ok) resp = null;
  }

  // Fallback: open the canonical book page and mine its download link.
  let fallbackUrl = null;
  if (!resp) {
    try {
      const html = await deps.fetchText(book.url);
      const dom = deps.parseHtml(html);
      const { books: fb } = extractBooks(dom, book.url);
      const found = fb.find((b) => b.book_id === book.book_id && b.download_url);
      if (found) {
        fallbackUrl = found.download_url;
        resp = await deps.fetchBlob(fallbackUrl);
        if (resp && !resp.ok) resp = null;
      }
    } catch (_) {
      resp = null;
    }
  }

  if (!resp) {
    try {
      deps.openTab(book.url);
    } catch (_) {}
    return { status: 'need-manual', book_id: book.book_id };
  }

  const cd = resp.headers ? resp.headers.get('content-disposition') : null;
  const name = fileNameFromDisposition(cd) || `book_${book.book_id}.docx`;
  const ext = (name.split('.').pop() || '').toLowerCase();
  if (ext !== 'docx') {
    return { status: 'unsupported', book_id: book.book_id, name };
  }

  const buf = await resp.arrayBuffer();
  if (buf && buf.byteLength > MAX_FILE_BYTES) {
    return { status: 'failed', book_id: book.book_id, name,
             detail: `بزرگ‌تر از ۵۰ مگابایت (${buf.byteLength} بایت)` };
  }

  const blob = new Blob([buf], {
    type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  });
  const fd = new FormData();
  fd.append('file', blob, name);

  const up = await deps.uploadDocument(collId, fd);
  if (up.status === 201) return { status: 'done', book_id: book.book_id, name };
  if (up.status === 401) return { status: 'auth-error', book_id: book.book_id, name };
  if (up.status === 409) return { status: 'duplicate', book_id: book.book_id, name };
  const msg = up.json && up.json.message ? up.json.message : `HTTP ${up.status}`;
  return { status: 'failed', book_id: book.book_id, name, detail: msg };
}

/**
 * Run the queue one-by-one. Mutates item.status in place.
 * deps: { isStopped() -> bool|Promise, sleep(ms), delayMs, persist(items) }
 * onEvent(type, item) is called for every transition (UI relay).
 */
async function runQueue(deps, items, collId, onEvent) {
  const emit = onEvent || (() => {});
  for (const item of items) {
    if (await deps.isStopped()) {
      emit('stopped', item);
      break;
    }
    if (item.status !== 'queued') continue;
    item.status = 'downloading';
    emit('progress', item);
    deps.persist(items);

    const r = await processBook(deps, {
      book_id: item.book_id,
      url: item.url,
      download_url: item.download_url,
    }, collId);

    item.status = r.status;
    if (r.name) item.file_name = r.name;
    if (r.detail) item.detail = r.detail;
    if (r.status === 'done' || r.status === 'duplicate') delete item.detail;
    emit('progress', item);
    deps.persist(items);

    if (r.status === 'auth-error') {
      emit('auth-error', item);
      break;
    }
    if (!await deps.isStopped()) {
      await deps.sleep(deps.delayMs || 0);
    }
  }
  return items;
}

// ---------------------------------------------------------------------------
// Service-worker wiring (chrome must exist; skipped under node)
// ---------------------------------------------------------------------------

if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.onMessage) {
  const GH_STATE_KEY = 'ghState';

  const deps = {
    delayMs: DEFAULT_DELAY_MS,
    fetchText: async (url) => {
      const r = await fetch(url, {
        credentials: 'include',
        headers: { 'Accept-Language': 'fa-IR,fa;q=0.9' },
      });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.text();
    },
    parseHtml: (html) => new DOMParser().parseFromString(html, 'text/html'),
    fetchBlob: (url) => fetch(url, { credentials: 'include' }),
    uploadDocument: async (collId, fd) => {
      const r = await fetch(
        `${BACKEND}/api/knowledge/collections/${collId}/documents`,
        { method: 'POST', body: fd, credentials: 'include' }
      );
      let json = null;
      try { json = await r.json(); } catch (_) {}
      return { status: r.status, json };
    },
    openTab: (url) => {
      try { chrome.tabs.create({ url }); } catch (_) {}
    },
    sleep: (ms) => new Promise((res) => setTimeout(res, ms)),
    isStopped: async () => ((await chrome.storage.local.get('ghStop')).ghStop === true),
    persist: (items) => {
      chrome.storage.local.get(GH_STATE_KEY, (s) => {
        const st = s[GH_STATE_KEY] || {};
        st.items = items;
        st.updatedAt = new Date().toISOString();
        chrome.storage.local.set({ [GH_STATE_KEY]: st });
      });
    },
  };

  function readState() {
    return new Promise((res) =>
      chrome.storage.local.get(GH_STATE_KEY, (s) =>
        res(s[GH_STATE_KEY] || { items: [], collId: null, collName: '', running: false })
      )
    );
  }
  function writeState(patch) {
    return readState().then((st) => {
      const next = Object.assign({}, st, patch);
      return new Promise((res) => chrome.storage.local.set({ [GH_STATE_KEY]: next }, res));
    });
  }

  async function apiJson(path, opts) {
    const r = await fetch(BACKEND + path, Object.assign({ credentials: 'include' }, opts || {}));
    let json = null;
    try { json = await r.json(); } catch (_) {}
    return { status: r.status, json };
  }

  /** Live fallback: ask the ghaemiyeh content script to extract the open page. */
  async function extractFromOpenTab() {
    const tabs = await chrome.tabs.query({ url: ['*://*.ghaemiyeh.ir/*'] });
    if (!tabs.length) return null;
    return new Promise((res) => {
      chrome.tabs.sendMessage(tabs[0].id, { action: 'ghExtract' }, (resp) => {
        if (chrome.runtime.lastError || !resp) res(null);
        else res(resp);
      });
    });
  }

  chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    (async () => {
      switch (msg.action) {
        case 'ghListCollections': {
          const { status, json } = await apiJson('/api/knowledge/collections');
          return { ok: status === 200, status, collections: (json && json.collections) || [] };
        }
        case 'ghCreateCollection': {
          const { status, json } = await apiJson('/api/knowledge/collections', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              name: msg.name,
              slug: msg.slug,
              description: msg.description || '',
            }),
          });
          return { ok: status === 201, status, json };
        }
        case 'ghStartTrace': {
          await chrome.storage.local.set({ ghStop: false });
          const t0 = Date.now();
          try {
            const res = await traceCategory(deps, msg.url, MAX_TRACE_PAGES);
            const items = res.books.map((b) => ({
              book_id: b.book_id,
              title: b.title,
              url: b.url,
              download_url: b.download_url,
              selected: true,
              status: 'queued',
              file_name: null,
              detail: null,
            }));
            // keep an existing collection choice if the user had one
            await writeState({
              items,
              lastTrace: { url: msg.url, pages: res.pages, stoppedReason: res.stoppedReason, at: t0 },
              running: false,
            });
            return {
              ok: true,
              books: items.length,
              orphans: res.orphans.length,
              pages: res.pages,
              stoppedReason: res.stoppedReason,
            };
          } catch (e) {
            return { ok: false, message: String(e && e.message || e) };
          }
        }
        case 'ghExtractCurrentPage': {
          const resp = await extractFromOpenTab();
          if (!resp || !resp.ok) return { ok: false, message: 'صفحهٔ غایمیه‌ای باز نیست یا خوانده نشد' };
          const merged = [];
          const seen = new Set();
          for (const b of resp.data.books || []) {
            if (seen.has(b.book_id)) continue;
            seen.add(b.book_id);
            merged.push({
              book_id: b.book_id, title: b.title, url: b.url,
              download_url: b.download_url, selected: true,
              status: 'queued', file_name: null, detail: null,
            });
          }
          const st = await readState();
          // merge with existing (dedup by book_id, prefer new download_url)
          const byId = new Map((st.items || []).map((i) => [i.book_id, i]));
          for (const m of merged) {
            const prev = byId.get(m.book_id);
            if (!prev) byId.set(m.book_id, m);
            else if (!prev.download_url && m.download_url) prev.download_url = m.download_url;
          }
          await writeState({ items: [...byId.values()] });
          return { ok: true, books: merged.length, total: byId.size };
        }
        case 'ghSelect': {
          const st = await readState();
          for (const i of st.items || []) {
            if (msg.ids && !msg.ids.includes(i.book_id)) continue;
            if (msg.selected !== undefined) i.selected = !!msg.selected;
          }
          await writeState({ items: st.items });
          return { ok: true };
        }
        case 'ghSetCollection': {
          await writeState({ collId: msg.collId, collName: msg.collName || '' });
          return { ok: true };
        }
        case 'ghRun': {
          const st = await readState();
          if (st.running) return { ok: false, message: 'قبلاً در حال اجراست' };
          if (!st.collId) return { ok: false, message: 'اول یک کالکشن انتخاب کن' };
          await chrome.storage.local.set({ ghStop: false });
          await writeState({ running: true });
          const items = (st.items || []).filter((i) => i.selected);
          for (const i of items) if (i.status === 'done' || i.status === 'duplicate') i.status = 'queued';
          const all = st.items || [];
          const queue = all.filter((i) => i.selected && i.status === 'queued');
          if (!queue.length) {
            await writeState({ running: false });
            return { ok: true, message: 'کتابی در صف نیست (همه انتخاب‌شدهها done/duplicate هستند)' };
          }
          (async () => {
            try {
              await runQueue(deps, all, st.collId, (type, item) => {
                try {
                  chrome.runtime.sendMessage({
                    action: 'ghEvent', type,
                    book_id: item ? item.book_id : null,
                    status: item ? item.status : null,
                    name: item && item.file_name ? item.file_name : null,
                    detail: item && item.detail ? item.detail : null,
                  });
                } catch (_) {}
              });
            } finally {
              await writeState({ running: false });
              try {
                chrome.runtime.sendMessage({ action: 'ghEvent', type: 'finished' });
              } catch (_) {}
            }
          })();
          return { ok: true, queued: queue.length };
        }
        case 'ghStop': {
          await chrome.storage.local.set({ ghStop: true });
          return { ok: true };
        }
        case 'ghRetryFailed': {
          const st = await readState();
          let n = 0;
          for (const i of st.items || []) {
            if (i.selected && (i.status === 'failed' || i.status === 'unsupported' ||
                i.status === 'need-manual')) {
              i.status = 'queued';
              i.detail = null;
              n += 1;
            }
          }
          await writeState({ items: st.items });
          return { ok: true, retried: n };
        }
        case 'ghMarkResult': {
          const st = await readState();
          for (const i of st.items || []) {
            if (i.book_id === msg.book_id) {
              i.status = msg.status;
              if (msg.name) i.file_name = msg.name;
              if (msg.detail) i.detail = msg.detail;
            }
          }
          await writeState({ items: st.items });
          return { ok: true };
        }
        case 'ghState': {
          const st = await readState();
          const stopped = (await chrome.storage.local.get('ghStop')).ghStop === true;
          return { ok: true, ...st, stopped };
        }
        default:
          return { ok: false, error: 'unknown' };
      }
    })().then(sendResponse).catch((e) => sendResponse({ ok: false, message: String(e) }));
    return true;
  });
}

// Test export (node only)
if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    BACKEND,
    MAX_TRACE_PAGES,
    DEFAULT_DELAY_MS,
    MAX_FILE_BYTES,
    bookIdFromHref,
    downloadIdFromHref,
    textOf,
    cleanTitle,
    absUrl,
    ownerBookId,
    extractBooks,
    nextPageInfo,
    traceCategory,
    fileNameFromDisposition,
    processBook,
    runQueue,
  };
}
