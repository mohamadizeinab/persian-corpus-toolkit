// Node tests for the khamenei YEAR-walk state machine in background.js.
//
// Site reality: ?page=N is ignored by the server; each Jalali year is ONE
// complete list page (/speech?nt=2&year=YYYY). Phase 1 opens unfiltered
// /speech (latest year only), then walks backwards year by year until
// 2 consecutive empty years or the MIN_YEAR floor.
//
// Run: node extension/test_khamenei_years.js
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const noop = () => {};
const sandbox = {
  chrome: {
    runtime: {
      onMessage: { addListener: noop },
      onStartup: { addListener: noop },
      onInstalled: { addListener: noop },
      sendMessage: noop,
      lastError: null,
    },
    tabs: {
      onUpdated: { addListener: noop },
      onRemoved: { addListener: noop },
      query: async () => [],
      create: async () => ({}),
      update: async () => {},
      sendMessage: noop,
    },
    storage: { local: { get: async () => ({}), set: async () => {} } },
    alarms: { onAlarm: { addListener: noop }, create: noop, clear: noop },
    scripting: { executeScript: async () => {} },
  },
  console,
  setTimeout,
  clearTimeout,
  URL,
  fetch: async () => { throw new Error("no network in test"); },
};
vm.createContext(sandbox);
vm.runInContext(
  fs.readFileSync(path.join(__dirname, "background.js"), "utf8"),
  sandbox,
  { filename: "background.js" }
);

const nextKhameneiYear = sandbox.nextKhameneiYear;
assert.strictEqual(typeof nextKhameneiYear, "function", "nextKhameneiYear must be exported from background.js");

let passed = 0;
let failed = 0;
const t = async (name, fn) => {
  try {
    await fn();
    passed++;
    console.log("PASS", name);
  } catch (e) {
    failed++;
    console.log("FAIL", name, "-", e.message);
  }
};

const fresh = () => ({ nextYear: null, emptyStreak: 0, MIN_YEAR: 1370 });
const urlOf = (o) => (o.url || null);
// Objects returned from the vm sandbox carry a different-realm prototype,
// which makes deepStrictEqual fail even when structure is identical.
// JSON round-trip normalizes them before comparing (same trick as test_next.js).
const eq = (a, b) =>
  assert.deepStrictEqual(JSON.parse(JSON.stringify(a)), b);

(async () => {
  await t("first scan: unfiltered /speech seeds latest year, next = maxYear-1", () => {
    const s = fresh();
    const r = nextKhameneiYear(s, { total: 39, maxYear: 1404 });
    eq(r, { url: "https://farsi.khamenei.ir/speech?nt=2&year=1403" });
    eq(s.nextYear, 1403);
  });

  await t("first scan without maxYear falls back to 1404", () => {
    const s = fresh();
    const r = nextKhameneiYear(s, { total: 39, maxYear: null });
    eq(r, { url: "https://farsi.khamenei.ir/speech?nt=2&year=1403" });
  });

  await t("non-empty year: reset streak, keep walking", () => {
    const s = { nextYear: 1400, emptyStreak: 1, MIN_YEAR: 1370 };
    const r = nextKhameneiYear(s, { total: 35, maxYear: 1400 });
    eq(r, { url: "https://farsi.khamenei.ir/speech?nt=2&year=1399" });
    eq(s.emptyStreak, 0);
  });

  await t("one empty year: streak=1, keep walking", () => {
    const s = { nextYear: 1405, emptyStreak: 0, MIN_YEAR: 1370 };
    const r = nextKhameneiYear(s, { total: 0, maxYear: null });
    eq(r, { url: "https://farsi.khamenei.ir/speech?nt=2&year=1404" });
    eq(s.emptyStreak, 1);
  });

  await t("two consecutive empty years: stop (reason=empty)", () => {
    const s = { nextYear: 1405, emptyStreak: 1, MIN_YEAR: 1370 };
    const r = nextKhameneiYear(s, { total: 0, maxYear: null });
    eq(r, { done: true, reason: "empty" });
  });

  await t("floor: MIN_YEAR itself is still walked", () => {
    const s = { nextYear: 1371, emptyStreak: 0, MIN_YEAR: 1370 };
    const r = nextKhameneiYear(s, { total: 30, maxYear: 1371 });
    eq(r, { url: "https://farsi.khamenei.ir/speech?nt=2&year=1370" });
  });

  await t("floor: stop when below MIN_YEAR (reason=floor)", () => {
    const s = { nextYear: 1370, emptyStreak: 0, MIN_YEAR: 1370 };
    const r = nextKhameneiYear(s, { total: 30, maxYear: 1370 });
    eq(r, { done: true, reason: "floor" });
  });

  await t("full walk shape: 1405(empty)→1404..1379→1378,1377 stop=empty", () => {
    // Simulate the real archive: 1405 empty, 1404..1379 non-empty, then empty.
    const s = fresh();
    const seq = [];
    let r = nextKhameneiYear(s, { total: 39, maxYear: 1404 }); // unfiltered page
    while (!r.done) {
      seq.push(urlOf(r));
      const y = s.nextYear;
      const empty = y > 1404 || y < 1379;
      r = nextKhameneiYear(s, { total: empty ? 0 : 40, maxYear: empty ? null : y });
    }
    eq(seq[0], "https://farsi.khamenei.ir/speech?nt=2&year=1403");
    eq(seq[seq.length - 1], "https://farsi.khamenei.ir/speech?nt=2&year=1377");
    eq(r, { done: true, reason: "empty" });
    eq(seq.length, 1403 - 1377 + 1); // 1403..1377 = 27 pages
  });

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})();
