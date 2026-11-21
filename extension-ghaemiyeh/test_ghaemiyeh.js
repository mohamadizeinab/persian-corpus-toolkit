// G1-G8 — unit tests for the PURE Ghaemiyeh pipeline (PCM-EXT-05).
//
// Runs in node, no browser:  node test_ghaemiyeh.js
// The pipeline (background.js) is injected with fake deps, so these tests
// exercise the real logic (extraction, pagination, queue, upload mapping).
'use strict';

const gh = require('./background.js');

let pass = 0;
let fail = 0;
const failures = [];

async function t(name, fn) {
  try {
    await fn();
    pass += 1;
    console.log(`PASS  ${name}`);
  } catch (e) {
    fail += 1;
    failures.push(`${name}: ${e && e.message}`);
    console.log(`FAIL  ${name}\n      ${e && e.stack}`);
  }
}

function assert(cond, msg) {
  if (!cond) throw new Error('assert: ' + msg);
}

function assertEq(a, b, msg) {
  if (a !== b) throw new Error(`assertEq: ${msg} (got ${JSON.stringify(a)}, want ${JSON.stringify(b)})`);
}

// ---------------------------------------------------------------------------
// Fake-DOM helpers (minimal stubs: anchors + cards + document)
// ---------------------------------------------------------------------------

function anchor(href, text, card) {
  const a = {
    textContent: text || '',
    getAttribute(n) { return n === 'href' ? href : null; },
    closest() { return card || null; },
  };
  a.parentElement = card || null;
  return a;
}

function cardWith(...anchors) {
  const card = {
    querySelectorAll(sel) { return sel === 'a[href]' ? anchors : []; },
    parentElement: null,
  };
  for (const a of anchors) {
    a.closest = () => card;
    a.parentElement = card;
  }
  return card;
}

function makeDom(anchors) {
  return {
    querySelectorAll(sel) { return sel === 'a[href]' ? anchors : []; },
  };
}

// Fake fetchBlob response
function fakeResp({ cd = null, bytes = 1024, ok = true } = {}) {
  const headers = {};
  if (cd) headers['content-disposition'] = cd;
  return {
    ok,
    status: ok ? 200 : 404,
    headers: { get(k) { return headers[String(k).toLowerCase()] || null; } },
    arrayBuffer: async () => new ArrayBuffer(bytes),
  };
}

// Base pipeline deps; each test overrides what it needs.
function baseDeps(overrides = {}) {
  return Object.assign({
    delayMs: 0,
    sleep: async () => {},
    fetchText: async () => { throw new Error('fetchText not stubbed'); },
    parseHtml: () => makeDom([]),
    fetchBlob: async () => { throw new Error('fetchBlob not stubbed'); },
    uploadDocument: async () => ({ status: 201, json: {} }),
    openTab: () => {},
    isStopped: async () => false,
    persist: () => {},
  }, overrides);
}

// ---------------------------------------------------------------------------
// G1 — extraction: dedup, title, card-tie, orphans, cleanTitle
// ---------------------------------------------------------------------------

async function g1() {
  const base = 'https://www.ghaemiyeh.ir/category-page?category=51636';

  const a1 = anchor('/show-book/349117', 'درس‌های پیامبر اعظم (صلی الله علیه و آله)');
  const a2 = anchor('/show-book/349117', 'دانلود'); // same book, generic label
  const a3 = anchor('/library/download/5970520');   // download inside the card
  const card1 = cardWith(a1, a2, a3);

  const a4 = anchor('/library/download/5970521');   // no book link anywhere near
  cardWith(a4);

  const dom = makeDom([a1, a2, a3, a4]);
  const r = gh.extractBooks(dom, base);

  assertEq(r.books.length, 1, 'one deduplicated book');
  const b = r.books[0];
  assertEq(b.book_id, '349117', 'book id');
  assertEq(b.title, 'درس‌های پیامبر اعظم (صلی الله علیه و آله)', 'real title kept (not «دانلود»)');
  assertEq(b.url, 'https://www.ghaemiyeh.ir/show-book/349117', 'abs url');
  assertEq(b.download_url, 'https://www.ghaemiyeh.ir/library/download/5970520', 'download tied to card');
  assertEq(r.orphans.length, 1, 'one orphan download');
  assertEq(r.orphans[0].download_id, '5970521', 'orphan id');

  // cleanTitle: trailing download-word stripped (Persian + English), separators trimmed
  assertEq(gh.cleanTitle('کتابی دانلود'), 'کتابی', 'Persian trailing «دانلود»');
  assertEq(gh.cleanTitle('A Book  Download.'), 'A Book', 'English trailing «Download»');
  assertEq(gh.cleanTitle('  ·  |  نام  |  '), 'نام', 'separators trimmed');
}

// ---------------------------------------------------------------------------
// G2 — pagination walk: jump to max page, stop, loop protection, max-pages
// ---------------------------------------------------------------------------

async function g2() {
  const CAT = 'https://www.ghaemiyeh.ir/category-page?category=51636';

  const b1 = anchor('/show-book/101', 'کتاب یک');
  const d1 = anchor('/library/download/7001');
  const cardB1 = cardWith(b1, d1);
  const page1 = [
    b1, d1,
    anchor('?page=2&category=51636'),
    anchor('?page=3&category=51636'), // max page on p1 -> jump straight to 3
  ];

  const b2 = anchor('/show-book/102', 'کتاب دو');
  cardWith(b2);
  const page3 = [b2, anchor('/show-book/101', 'کتاب یک'), anchor('?page=1&category=51636')];

  const pages = {
    [CAT]: page1,
    [CAT + '&page=3']: page3,
  };

  const deps = baseDeps({
    fetchText: async (u) => pages[u] || [],
    parseHtml: (anchors) => makeDom(anchors),
  });

  const r = await gh.traceCategory(deps, CAT);
  assertEq(r.pages, 2, 'visited exactly 2 pages (p1 -> p3)');
  assertEq(r.stoppedReason, 'done', 'stopped done');
  assertEq(r.books.length, 2, 'two distinct books merged');
  const k1 = r.books.find((x) => x.book_id === '101');
  const k2 = r.books.find((x) => x.book_id === '102');
  assertEq(k1.title, 'کتاب یک', 'title from first sighting');
  assertEq(k1.download_url, 'https://www.ghaemiyeh.ir/library/download/7001', 'download kept from p1');

  // --- loop protection: p2 -> p3 -> p2 (visited set stops the cycle)
  const loop = {
    [CAT]: [anchor('?page=2&category=51636')],
    [CAT + '&page=2']: [anchor('?page=3&category=51636')],
    [CAT + '&page=3']: [anchor('?page=2&category=51636')],
  };
  const depsLoop = baseDeps({
    fetchText: async (u) => loop[u] || [],
    parseHtml: (anchors) => makeDom(anchors),
  });
  const rl = await gh.traceCategory(depsLoop, CAT);
  assertEq(rl.pages, 3, 'cycle visited once each');
  assertEq(rl.stoppedReason, 'done', 'visited-set stops the cycle');

  // --- max-pages cap
  const endless = {};
  for (let i = 1; i <= 50; i++) {
    endless[CAT + (i > 1 ? `&page=${i}` : '')] = [anchor(`?page=${i + 1}&category=51636`)];
  }
  const depsCap = baseDeps({
    fetchText: async (u) => endless[u] || [],
    parseHtml: (anchors) => makeDom(anchors),
  });
  const rc = await gh.traceCategory(depsCap, CAT, 2);
  assertEq(rc.pages, 2, 'capped at 2 pages');
  assertEq(rc.stoppedReason, 'max-pages', 'max-pages stop reason');
}

// ---------------------------------------------------------------------------
// G3 — processBook: upload status mapping + ext/size guards
// ---------------------------------------------------------------------------

async function g3() {
  const book = { book_id: '101', url: 'https://www.ghaemiyeh.ir/show-book/101',
                 download_url: 'https://www.ghaemiyeh.ir/library/download/7001' };
  // کتاب.docx — ک=U+06A9(DA A9) ت=U+062A(D8 AA) ا=U+0627(D8 A7) ب=U+0628(D8 A4)
  const CD_DOCX = "attachment; filename*=UTF-8''%DA%A9%D8%AA%D8%A7%D8%A8.docx";

  // 201 -> done, with the disposition filename as the upload name
  let gotFd = null;
  let r = await gh.processBook(baseDeps({
    fetchBlob: async () => fakeResp({ cd: CD_DOCX }),
    uploadDocument: async (cid, fd) => { gotFd = fd; return { status: 201, json: {} }; },
  }), book, 7);
  assertEq(r.status, 'done', '201 -> done');
  assertEq(r.name, 'کتاب.docx', 'unicode filename decoded');
  const f = gotFd.get('file');
  assertEq(f.name, 'کتاب.docx', 'FormData carries the name');
  assertEq(String(gotFd.get('file').type), 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'docx mime');

  // 409 -> duplicate
  r = await gh.processBook(baseDeps({
    fetchBlob: async () => fakeResp({ cd: CD_DOCX }),
    uploadDocument: async () => ({ status: 409, json: { code: 'duplicate' } }),
  }), book, 7);
  assertEq(r.status, 'duplicate', '409 -> duplicate');

  // 401 -> auth-error
  r = await gh.processBook(baseDeps({
    fetchBlob: async () => fakeResp({ cd: CD_DOCX }),
    uploadDocument: async () => ({ status: 401, json: {} }),
  }), book, 7);
  assertEq(r.status, 'auth-error', '401 -> auth-error');

  // 500 + message -> failed with the real message
  r = await gh.processBook(baseDeps({
    fetchBlob: async () => fakeResp({ cd: CD_DOCX }),
    uploadDocument: async () => ({ status: 500, json: { message: 'سرور در دسترس نیست' } }),
  }), book, 7);
  assertEq(r.status, 'failed', '500 -> failed');
  assert(r.detail.indexOf('سرور در دسترس نیست') !== -1, 'detail carries server message');

  // non-DOCX -> unsupported (no upload attempted)
  let uploaded = 0;
  r = await gh.processBook(baseDeps({
    fetchBlob: async () => fakeResp({ cd: 'attachment; filename="book.pdf"' }),
    uploadDocument: async () => { uploaded += 1; return { status: 201, json: {} }; },
  }), book, 7);
  assertEq(r.status, 'unsupported', 'pdf -> unsupported');
  assertEq(r.name, 'book.pdf', 'name recorded');
  assertEq(uploaded, 0, 'no upload for unsupported');

  // > 50MB -> failed with size detail
  r = await gh.processBook(baseDeps({
    fetchBlob: async () => fakeResp({ cd: CD_DOCX, bytes: 51 * 1024 * 1024 }),
    uploadDocument: async () => { uploaded += 1; return { status: 201, json: {} }; },
  }), book, 7);
  assertEq(r.status, 'failed', 'oversize -> failed');
  assert(r.detail.indexOf('۵۰') !== -1, 'detail mentions the 50MB cap');
  assertEq(uploaded, 0, 'no upload when oversize');

  // disposition absent -> default name book_<id>.docx, still uploadable
  r = await gh.processBook(baseDeps({
    fetchBlob: async () => fakeResp({}),
    uploadDocument: async () => ({ status: 201, json: {} }),
  }), book, 7);
  assertEq(r.status, 'done', 'no disposition -> default name');
  assertEq(r.name, 'book_101.docx', 'default name');
}

// ---------------------------------------------------------------------------
// G4 — runQueue: stop flag breaks the loop, later items stay queued
// ---------------------------------------------------------------------------

async function g4() {
  const events = [];
  let done = 0;
  const deps = baseDeps({
    fetchBlob: async () => fakeResp({ cd: "attachment; filename=\"b.docx\"" }),
    uploadDocument: async () => ({ status: 201, json: {} }),
    isStopped: async () => done >= 1, // stop right after the first book
    persist: () => {},
  });
  const items = [
    { book_id: '1', url: 'u1', download_url: 'https://www.ghaemiyeh.ir/library/download/1', status: 'queued' },
    { book_id: '2', url: 'u2', download_url: 'https://www.ghaemiyeh.ir/library/download/2', status: 'queued' },
    { book_id: '3', url: 'u3', download_url: 'https://www.ghaemiyeh.ir/library/download/3', status: 'queued' },
  ];
  // count processed via uploadDocument
  const realUpload = deps.uploadDocument;
  deps.uploadDocument = async () => { done += 1; return realUpload(); };

  await gh.runQueue(deps, items, 7, (type, it) => events.push([type, it.book_id]));

  assertEq(items[0].status, 'done', 'first processed');
  assertEq(items[1].status, 'queued', 'second untouched (stopped)');
  assertEq(items[2].status, 'queued', 'third untouched (stopped)');
  assert(events.some((e) => e[0] === 'stopped'), 'stopped event emitted');
  assertEq(events.filter((e) => e[0] === 'progress').length, 2, 'two progress events (dl + done)');
}

// ---------------------------------------------------------------------------
// G5 — runQueue: resume processes ONLY 'queued' items
// ---------------------------------------------------------------------------

async function g5() {
  const deps = baseDeps({
    fetchBlob: async () => fakeResp({ cd: "attachment; filename=\"b.docx\"" }),
    uploadDocument: async () => ({ status: 201, json: {} }),
  });
  const items = [
    { book_id: '1', url: 'u1', download_url: 'https://www.ghaemiyeh.ir/library/download/1', status: 'done' },
    { book_id: '2', url: 'u2', download_url: 'https://www.ghaemiyeh.ir/library/download/2', status: 'queued' },
    { book_id: '3', url: 'u3', download_url: 'https://www.ghaemiyeh.ir/library/download/3', status: 'duplicate' },
    { book_id: '4', url: 'u4', download_url: 'https://www.ghaemiyeh.ir/library/download/4', status: 'failed', detail: 'x' },
  ];
  const before = items.map((i) => ({ ...i }));
  await gh.runQueue(deps, items, 7, () => {});
  assertEq(items[0].status, 'done', 'done untouched');
  assertEq(items[1].status, 'done', 'queued re-processed');
  assertEq(items[2].status, 'duplicate', 'duplicate untouched');
  assertEq(items[3].status, 'failed', 'failed untouched until explicit retry');
  // explicit retry (ghRetryFailed semantics): flip the failed item back to queued
  items[3].status = 'queued';
  await gh.runQueue(deps, items, 7, () => {});
  assertEq(items[3].status, 'done', 'explicit retry re-processes the failed item');
}

// ---------------------------------------------------------------------------
// G6 — Content-Disposition filename parsing (RFC 5987 + plain + quoted)
// ---------------------------------------------------------------------------

async function g6() {
  assertEq(
    gh.fileNameFromDisposition("attachment; filename*=UTF-8''%DA%A9%D8%AA%D8%A7%D8%A8.docx; name=\"x\""),
    'کتاب.docx',
    'RFC5987 preferred');
  assertEq(
    gh.fileNameFromDisposition('attachment; filename="my book.docx"'),
    'my book.docx',
    'quoted plain');
  assertEq(
    gh.fileNameFromDisposition('attachment; filename=book.docx'),
    'book.docx',
    'bare plain');
  assertEq(gh.fileNameFromDisposition(null), null, 'absent -> null');
  assertEq(gh.fileNameFromDisposition('inline'), null, 'no filename -> null');
}

// ---------------------------------------------------------------------------
// G7 — show-book fallback: direct download fails -> mine the book page
// ---------------------------------------------------------------------------

async function g7() {
  const badUrl = 'https://www.ghaemiyeh.ir/library/download/7001';
  const goodUrl = 'https://www.ghaemiyeh.ir/library/download/9999';
  const bookUrl = 'https://www.ghaemiyeh.ir/show-book/101';

  const b1 = anchor('/show-book/101', 'کتاب یک');
  const d1 = anchor('/library/download/9999');
  const pageCard = cardWith(b1, d1);
  const pageAnchors = [b1, d1];

  const calls = { fetchText: [] };
  const deps = baseDeps({
    fetchBlob: async (u) => {
      if (u === badUrl) throw new Error('net down');
      if (u === goodUrl) return fakeResp({ cd: "attachment; filename=\"k.docx\"" });
      throw new Error('unexpected url ' + u);
    },
    fetchText: async (u) => { calls.fetchText.push(u); return pageAnchors; },
    parseHtml: (anchors) => makeDom(anchors),
    uploadDocument: async () => ({ status: 201, json: {} }),
  });

  const r = await gh.processBook(deps, { book_id: '101', url: bookUrl, download_url: badUrl }, 7);
  assertEq(r.status, 'done', 'fallback succeeds');
  assertEq(r.name, 'k.docx', 'fallback file name');
  assert(calls.fetchText.indexOf(bookUrl) !== -1, 'book page was fetched for the fallback');
}

// ---------------------------------------------------------------------------
// G8 — need-manual: nothing discoverable -> open the tab, mark need-manual
// ---------------------------------------------------------------------------

async function g8() {
  const opened = [];
  const deps = baseDeps({
    fetchBlob: async () => { throw new Error('net down'); },
    fetchText: async () => [],                 // book page yields no book link
    parseHtml: (anchors) => makeDom(anchors),
    openTab: (u) => opened.push(u),
    uploadDocument: async () => { throw new Error('should not upload'); },
  });
  const r = await gh.processBook(deps, { book_id: '55', url: 'https://www.ghaemiyeh.ir/show-book/55', download_url: null }, 7);
  assertEq(r.status, 'need-manual', 'need-manual status');
  assertEq(opened.length, 1, 'tab opened once');
  assertEq(opened[0], 'https://www.ghaemiyeh.ir/show-book/55', 'the book page was opened');
}

// ---------------------------------------------------------------------------

async function main() {
  await t('G1 extractBooks: dedup + title + card-tie + orphans + cleanTitle', g1);
  await t('G2 traceCategory: max-page jump + loop protection + max-pages cap', g2);
  await t('G3 processBook: 201/401/409/500 + unsupported + oversize + default name', g3);
  await t('G4 runQueue: stop flag breaks the loop, rest stay queued', g4);
  await t('G5 runQueue: resume processes only queued', g5);
  await t('G6 fileNameFromDisposition: RFC5987 / quoted / bare / absent', g6);
  await t('G7 processBook: show-book fallback mining', g7);
  await t('G8 processBook: need-manual opens the tab', g8);

  console.log(`\nGhaemiyeh pipeline: ${pass} PASS / ${fail} FAIL`);
  if (fail > 0) {
    console.log('Failures:');
    for (const f of failures) console.log(' - ' + f);
    process.exit(1);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
