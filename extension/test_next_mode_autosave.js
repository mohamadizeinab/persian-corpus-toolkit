// Node tests for the PCM-EXT-08.1 "no jump" fix in content_picker.js.
//
// Bug (user report): picking a "next page" mode in the panel (e.g. hash /
// «آیه بعد») was instantly reverted to the stored server value by the 4s
// poll (load -> render), because the choice was only saved by
// «آزمایش و شروع». Fix: any change to a rule field triggers a debounced
// autosave, and render() must not clobber the form while a change is
// unsaved (ruleDirty).
//
// These tests replay the exact race: user changes the select, a poll
// re-render lands BEFORE the autosave fires, then the autosave fires,
// then the next poll lands.
"use strict";
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const BASE = "https://gharaati.ir/تفسیر-نور/";

function makeElement() {
  const listeners = {};
  return {
    id: "",
    value: "",
    textContent: "",
    innerText: "",
    style: {},
    children: [],
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    appendChild(c) { this.children.push(c); return c; },
    append(...c) { this.children.push(...c); },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    dispatch(type) {
      const ev = { target: this, preventDefault() {}, stopPropagation() {} };
      (listeners[type] || []).slice().forEach((fn) => fn(ev));
    },
    focus() {},
    contains() { return false; },
    querySelector() { return null; },
    getAttribute() { return null; },
    setAttribute() {},
    remove() {},
  };
}

// Load content_picker.js in a vm with controllable timers + a fake backend.
function loadPicker({ href } = {}) {
  const els = new Map();
  const shadow = {
    _html: "",
    set innerHTML(v) { this._html = v; },
    get innerHTML() { return this._html; },
    getElementById(id) {
      if (!els.has(id)) els.set(id, makeElement());
      return els.get(id);
    },
  };
  const document = {
    createElement: () => {
      const el = makeElement();
      el.attachShadow = () => shadow;
      return el;
    },
    querySelectorAll: () => [],
    addEventListener() {},
    documentElement: makeElement(),
  };
  const chrome = {
    runtime: { onMessage: { addListener() {} }, sendMessage: async () => ({ ok: true }) },
    storage: { local: { get: async () => ({}), set: async () => {} } },
  };
  const location = {
    href,
    search: "",
    hash: href.includes("#") ? href.split("#").slice(1).join("#") : "",
  };

  // Fake backend: one project in "memory". POST updates it (additive fields).
  const serverProject = {
    id: 1,
    name: "تست گرااتی",
    host: "gharaati.ir",
    start_url: href,
    next_mode: "none",
    next_param: "",
    next_step: 1,
    pages_per_minute: 4,
    stop_number: "",
    stop_field: "",
    status: "created",
    saved_count: 0,
    skipped_count: 0,
    failed_count: 0,
    points: [
      { tag: "متن تفسیر", source: "css", selector: "#pre", transform: "text", attr: "", sample: "تفسیر..." },
    ],
  };
  const posts = [];
  const clone = (o) => JSON.parse(JSON.stringify(o));
  const fakeFetch = async (url, opts) => {
    const method = (opts && opts.method) || "GET";
    if (method === "GET") {
      return { ok: true, status: 200, json: async () => clone(serverProject) };
    }
    if (method === "POST") {
      const body = JSON.parse(opts.body);
      posts.push(body);
      Object.assign(serverProject, {
        next_mode: body.next_mode,
        next_param: body.next_param,
        next_step: body.next_step,
        pages_per_minute: body.pages_per_minute,
        stop_number: body.stop_number,
        stop_field: body.stop_field,
      });
      return {
        ok: true,
        status: 200,
        json: async () => ({ ok: true, project: clone(serverProject) }),
      };
    }
    throw new Error("unexpected fetch " + url);
  };

  // Controllable timers: autosave debounce (350ms) is a queued callback.
  const timers = [];
  let timerId = 0;
  const sandbox = {
    window: {},
    document,
    chrome,
    location,
    console,
    setTimeout: (fn, ms) => { timers.push({ id: ++timerId, ms, fn }); return timerId; },
    clearTimeout: (id) => {
      const i = timers.findIndex((t) => t.id === id);
      if (i >= 0) timers.splice(i, 1);
    },
    setInterval: () => 0,
    clearInterval: () => {},
    URL,
    URLSearchParams,
    CSS: { escape: (s) => s },
    fetch: fakeFetch,
  };
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, "content_picker.js"), "utf8"), sandbox, {
    filename: "content_picker.js",
  });

  // Run all due queued timers (in order); awaits async timer callbacks.
  const flushTimers = async () => {
    while (timers.length) {
      const t = timers.shift();
      await t.fn();
    }
  };
  return { sandbox, shadow, serverProject, posts, flushTimers };
}

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

(async () => {
  await t("pick hash mode: poll before autosave must NOT reset the select (the jump)", async () => {
    const { sandbox, shadow, posts, flushTimers } = loadPicker({ href: BASE + "#numsooreh=1&numayeh=1" });
    const T = sandbox.window.__pctPickerTest;
    const nextMode = shadow.getElementById("nextMode");

    await T.load(1);
    assert.strictEqual(nextMode.value, "none", "initial render: no rule -> none");
    // The user picks «دکمهٔ آیه بعد» (hash):
    nextMode.value = "hash";
    nextMode.dispatch("change");
    // The 4s poll lands BEFORE the 350ms autosave fires (stale server state).
    await T.load(1);
    assert.strictEqual(nextMode.value, "hash", "poll must not clobber an unsaved choice");
    assert.strictEqual(posts.length, 0, "autosave still pending (debounce)");
    // Debounce fires -> the rule is saved:
    await flushTimers();
    assert.strictEqual(posts.length, 1, "autosave fired once");
    assert.strictEqual(posts[0].next_param, "hash");
    assert.strictEqual(posts[0].next_mode, "url_param");
    assert.strictEqual(T.project.next_param, "hash");
    // Next poll now reads the saved rule -> still hash, no jump back.
    await T.load(1);
    assert.strictEqual(nextMode.value, "hash", "next poll shows the saved rule");
  });

  await t("param mode: typing the detail is kept across polls and autosaved", async () => {
    const { sandbox, shadow, posts, flushTimers } = loadPicker({ href: BASE + "#numsooreh=2&numayeh=8" });
    const T = sandbox.window.__pctPickerTest;
    const nextMode = shadow.getElementById("nextMode");
    const detail = shadow.getElementById("nextDetailInput");
    await T.load(1);
    assert.strictEqual(nextMode.value, "none");

    nextMode.value = "param";
    nextMode.dispatch("change");
    detail.value = "item_index";
    detail.dispatch("input");
    // Poll lands while both changes are still unsaved:
    await T.load(1);
    assert.strictEqual(nextMode.value, "param", "mode kept while dirty");
    assert.strictEqual(detail.value, "item_index", "detail kept while dirty");
    await flushTimers();
    const last = posts[posts.length - 1];
    assert.strictEqual(last.next_param, "item_index");
    assert.strictEqual(last.next_mode, "url_param");
    await T.load(1);
    assert.strictEqual(nextMode.value, "param");
    assert.strictEqual(detail.value, "item_index");
  });

  await t("regex without a pattern: no save, no jump, then pattern saves cleanly", async () => {
    const { sandbox, shadow, serverProject, posts, flushTimers } = loadPicker({ href: BASE + "#numsooreh=3&numayeh=1" });
    const T = sandbox.window.__pctPickerTest;
    const nextMode = shadow.getElementById("nextMode");
    const detail = shadow.getElementById("nextDetailInput");
    await T.load(1);

    nextMode.value = "regex";
    nextMode.dispatch("change");
    await flushTimers();
    assert.strictEqual(posts.length, 0, "regex without pattern is not saved");
    assert.strictEqual(serverProject.next_param, "");
    // Poll keeps the user's (incomplete) choice instead of jumping:
    await T.load(1);
    assert.strictEqual(nextMode.value, "regex", "incomplete choice kept (dirty)");

    detail.value = "p_(\\d+)";
    detail.dispatch("input");
    await flushTimers();
    const last = posts[posts.length - 1];
    assert.strictEqual(last.next_param, "regex:p_(\\d+)");
    await T.load(1);
    assert.strictEqual(nextMode.value, "regex");
    assert.strictEqual(detail.value, "p_(\\d+)");
  });

  await t("none mode autosaves next_mode=none", async () => {
    const { sandbox, shadow, posts, flushTimers } = loadPicker({ href: BASE + "#numsooreh=1&numayeh=1" });
    const T = sandbox.window.__pctPickerTest;
    const nextMode = shadow.getElementById("nextMode");
    await T.load(1);
    // Simulate a rule that exists server-side, then the user removes it:
    nextMode.value = "hash";
    nextMode.dispatch("change");
    await flushTimers();
    assert.strictEqual(posts[posts.length - 1].next_param, "hash");
    nextMode.value = "none";
    nextMode.dispatch("change");
    await flushTimers();
    const last = posts[posts.length - 1];
    assert.strictEqual(last.next_param, "");
    assert.strictEqual(last.next_mode, "none");
    await T.load(1);
    assert.strictEqual(nextMode.value, "none");
  });

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
