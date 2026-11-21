// PCM-EXT-07 M6 — real browser screenshot of the Staging dashboard
// "🎤 بیانات" (Khamenei) tab, logged in, headless Edge via CDP (no deps).
//
// Steps: launch edge headless + CDP -> open /dashboard/ ->
// log in via the same-origin /api/auth/login (password from local temp .env,
// never printed) -> reload -> switchTab('khamenei') -> wait ->
// screenshot PNG + dump key DOM text for verification (no vision needed).
"use strict";
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");

const EDGE = "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe";
const URL_ = "https://pct-staging.ai.ismc.ir/dashboard/";
const ENVFILE = process.argv[2];
const OUT = process.argv[3] || "evidence/pcm-ext07-m6-khamenei-tab.png";
const PORT = 9334;

function getJson(p) {
  return new Promise((res, rej) => {
    http.get({ host: "127.0.0.1", port: PORT, path: p }, (r) => {
      let b = "";
      r.on("data", (c) => (b += c));
      r.on("end", () => res(JSON.parse(b)));
    }).on("error", rej);
  });
}

function waitPort(ms = 20000) {
  return new Promise((res, rej) => {
    const t0 = Date.now();
    (function tick() {
      getJson("/json/version")
        .then(res)
        .catch(() => {
          if (Date.now() - t0 > ms) rej(new Error("CDP port not up"));
          else setTimeout(tick, 300);
        });
    })();
  });
}

class CDP {
  constructor(wsUrl) { this.wsUrl = wsUrl; this.id = 0; this.pending = new Map(); }
  connect() {
    return new Promise((res, rej) => {
      this.ws = new WebSocket(this.wsUrl);
      this.ws.onopen = () => res();
      this.ws.onerror = (e) => rej(new Error("ws error " + (e.message || "")));
      this.ws.onmessage = (m) => {
        const msg = JSON.parse(m.data);
        if (msg.id && this.pending.has(msg.id)) {
          const p = this.pending.get(msg.id);
          this.pending.delete(msg.id);
          msg.error ? p.rej(new Error(msg.error.message)) : p.res(msg.result);
        }
      };
    });
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((res, rej) => {
      this.pending.set(id, { res, rej });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  close() { try { this.ws.close(); } catch (_) {} }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const env = fs.readFileSync(ENVFILE, "utf8").replace(/\r/g, "");
  const m = env.match(/^\s*PCT_DASHBOARD_PASSWORD=(.+)$/m);
  if (!m) throw new Error("password line not found");
  const pw = m[1].trim().replace(/^["']|["']$/g, "");

  const udd = fs.mkdtempSync(path.join(os.tmpdir(), "pct-cdp-"));
  const edge = spawn(EDGE, [
    "--headless=new",
    `--remote-debugging-port=${PORT}`,
    "--ignore-certificate-errors",
    "--no-first-run",
    "--no-default-browser-check",
    `--user-data-dir=${udd}`,
    "--window-size=1280,900",
    "about:blank",
  ], { stdio: "ignore" });
  console.log("edge pid", edge.pid);
  try {
    await waitPort();
    const targets = await getJson("/json/list");
    const page = targets.find((t) => t.type === "page");
    if (!page) throw new Error("no page target");
    const cdp = new CDP(page.webSocketDebuggerUrl);
    await cdp.connect();
    await cdp.send("Page.enable");
    await cdp.send("Runtime.enable");
    await cdp.send("Emulation.setDeviceMetricsOverride", {
      width: 1280, height: 900, deviceScaleFactor: 1, mobile: false,
    });

    const ev = async (expression) => {
      const r = await cdp.send("Runtime.evaluate", {
        expression, awaitPromise: true, returnByValue: true,
      });
      if (r.exceptionDetails) {
        throw new Error("page exception: " +
          JSON.stringify(r.exceptionDetails.exception || r.exceptionDetails.text));
      }
      return r.result.value;
    };

    await cdp.send("Page.navigate", { url: URL_ });
    await sleep(4000);
    const pre = await ev(`({ url: location.href,
      overlay: (document.getElementById('loginOverlay')||{}).style ? document.getElementById('loginOverlay').style.display : 'n/a' })`);
    console.log("after nav:", JSON.stringify(pre));

    const login = await ev(`
      (async () => {
        try {
          const r = await fetch('/api/auth/login', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ password: ${JSON.stringify(pw)} }),
            credentials: 'same-origin',
          });
          const d = await r.json().catch(() => ({}));
          return { status: r.status, ok: !!d.ok, cookie: document.cookie.slice(0, 20) };
        } catch (e) { return { error: String(e) }; }
      })()`);
    console.log("login:", JSON.stringify(login));
    if (!login || login.error || !login.ok) throw new Error("login failed: " + JSON.stringify(login));

    await cdp.send("Page.reload", { ignoreCache: true });
    await sleep(4500);
    const post = await ev(`({
      overlay: (document.getElementById('loginOverlay')||{style:{display:'?'}}).style.display,
      authState: (typeof authState !== 'undefined') ? JSON.stringify(authState) : 'n/a'
    })`);
    console.log("after reload:", JSON.stringify(post));

    await ev(`switchTab('khamenei')`);
    await sleep(4500);

    const dom = await ev(`({
      h1: (document.querySelector('#tab-khamenei h1')||{}).textContent || 'MISSING',
      tabVisible: (document.getElementById('tab-khamenei')||{}).style
        ? (document.getElementById('tab-khamenei').style.display !== 'none') : true,
      stats: (document.getElementById('khameneiStats')||{}).innerText || 'EMPTY',
      rows: (document.getElementById('khameneiTable')||{rows:[]}).rows.length,
      firstRow: (document.getElementById('khameneiTable')||{rows:[]}).rows[0]
        ? document.getElementById('khameneiTable').rows[0].innerText : 'none',
      status: (document.getElementById('khameneiStatus')||{}).innerText || 'n/a'
    })`);
    console.log("KHAMENEI-TAB-DOM:", JSON.stringify(dom, null, 1));

    const shot = await cdp.send("Page.captureScreenshot", { format: "png" });
    fs.mkdirSync(path.dirname(OUT), { recursive: true });
    fs.writeFileSync(OUT, Buffer.from(shot.data, "base64"));
    console.log("saved", OUT, fs.statSync(OUT).size, "bytes");
    cdp.close();
    if (!dom.tabVisible || dom.h1 === "MISSING" || dom.rows < 1) {
      throw new Error("khamenei tab not verified visible with rows");
    }
  } finally {
    try { edge.kill(); } catch (_) {}
    try { fs.rmSync(udd, { recursive: true, force: true }); } catch (_) {}
  }
}

main().then(() => process.exit(0)).catch((e) => { console.error("FAIL", e); process.exit(1); });
