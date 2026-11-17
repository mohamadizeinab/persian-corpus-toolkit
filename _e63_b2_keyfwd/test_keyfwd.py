#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Local test harness for rag_keyfwd (E6.3 B2).

Spawns a mock gateway upstream and the forwarder (subprocess), then runs
8 assertions: healthz, key injection per listener, caller header override,
Authorization passthrough, SSE streaming, key-file hot reload (rotation),
fail-closed 503 on missing key file, upstream 401 passthrough.

Run:  python test_keyfwd.py
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
FWD = os.path.join(HERE, "rag_keyfwd.py")

UP_PORT = 18402
RADIO_PORT = 18400
PORTAL_PORT = 18401
RADIO_KEY = "rc_testradio_" + "a" * 32
PORTAL_KEY = "rc_testportal_" + "b" * 31
NEW_RADIO_KEY = "rc_newradio_" + "c" * 33
SVC_KEY = "svc_master_test_key"

MOCK = {"last": None, "reject": False, "calls": 0}
PASS = 0
FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("PASS %s %s" % (name, detail))
    else:
        FAIL += 1
        print("FAIL %s %s" % (name, detail))


def free_port_try(port):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


class MockGateway(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _rec(self):
        body = b""
        cl = self.headers.get("Content-Length")
        if cl:
            body = self.rfile.read(int(cl))
        MOCK["calls"] += 1
        MOCK["last"] = {
            "method": self.command,
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body": body,
        }

    def _reply(self, status, obj=None, sse=False):
        self.send_response(status)
        if sse:
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            return
        body = json.dumps(obj if obj is not None else {"ok": True}).encode()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):  # noqa: N802
        self._rec()
        if MOCK["reject"]:
            self._reply(401, {"error": "invalid consumer key"})
            return
        if "streamtest" in self.path:
            self._reply(200, sse=True)
            for i in range(3):
                chunk = ("data: {\"i\": %d}\n\n" % i).encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
                time.sleep(0.05)
            self.wfile.write(b"0\r\n\r\n")
            return
        b = MOCK["last"]["body"]
        try:
            m = json.loads(b.decode()).get("model")
        except Exception:
            m = None
        self._reply(200, {"model": m, "reply": "mock-" + m})

    def do_GET(self):  # noqa: N802
        self._rec()
        if MOCK["reject"]:
            self._reply(401, {"error": "denied"})
            return
        self._reply(200, {"ok": True, "path": self.path})


def post(url_port, path, body, headers):
    import http.client
    conn = http.client.HTTPConnection("127.0.0.1", url_port, timeout=15)
    conn.request("POST", path, body=body, headers=headers)
    r = conn.getresponse()
    data = r.read()
    conn.close()
    return r.status, dict((k.lower(), v) for k, v in r.getheaders()), data


def main():
    if not all(free_port_try(p) for p in (UP_PORT, RADIO_PORT, PORTAL_PORT)):
        print("ABORT: test ports busy")
        return 2

    tmp = tempfile.mkdtemp(prefix="keyfwd_test_")
    keyfile = os.path.join(tmp, "keys.json")
    with open(keyfile, "w") as fh:
        json.dump({"consumers": {"radio": RADIO_KEY, "portal": PORTAL_KEY}}, fh)
    os.chmod(keyfile, 0o600)

    upstream = ThreadingHTTPServer(("127.0.0.1", UP_PORT), MockGateway)
    import threading
    threading.Thread(target=upstream.serve_forever, daemon=True).start()

    fwd = subprocess.Popen(
        [sys.executable, FWD,
         "--listen", "127.0.0.1:%d" % RADIO_PORT, "--consumer", "radio",
         "--listen", "127.0.0.1:%d" % PORTAL_PORT, "--consumer", "portal",
         "--keyfile", keyfile,
         "--upstream", "http://127.0.0.1:%d" % UP_PORT,
         "--timeout", "15"],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        time.sleep(1.2)
        if fwd.poll() is not None:
            print("FWD EXITED EARLY rc=%s\nstderr:\n%s"
                  % (fwd.returncode, fwd.stderr.read()))
            return 3

        # T1: healthz on radio port
        import http.client
        c = http.client.HTTPConnection("127.0.0.1", RADIO_PORT, timeout=5)
        c.request("GET", "/__healthz")
        r = c.getresponse()
        hz = json.loads(r.read())
        check("T1 healthz", r.status == 200 and hz.get("ok") is True
              and hz.get("consumers") == ["portal", "radio"],
              "consumers=%s" % hz.get("consumers"))

        chat_body = json.dumps({"model": "rag-mizan",
                                "messages": [{"role": "user", "content": "hi"}],
                                "stream": False}).encode()
        hdrs = {"Authorization": "Bearer " + SVC_KEY,
                "x-consumer-key": "rc_attacker_" + "z" * 33,
                "X-Request-Id": "e63-test-1",
                "Content-Type": "application/json"}

        # T2: radio port injects RADIO key (attacker header overridden)
        st, hd, data = post(RADIO_PORT, "/v1/chat/completions", chat_body, hdrs)
        check("T2 radio injection", st == 200
              and MOCK["last"]["headers"]["x-consumer-key"] == RADIO_KEY
              and MOCK["last"]["headers"]["authorization"] == "Bearer " + SVC_KEY
              and MOCK["last"]["headers"]["x-request-id"] == "e63-test-1"
              and json.loads(data)["model"] == "rag-mizan",
              "status=%s" % st)

        # T3: portal port injects PORTAL key
        st, hd, data = post(PORTAL_PORT, "/v1/chat/completions", chat_body, hdrs)
        check("T3 portal injection", st == 200
              and MOCK["last"]["headers"]["x-consumer-key"] == PORTAL_KEY,
              "status=%s" % st)

        # T4: SSE stream passthrough
        st, hd, data = post(RADIO_PORT, "/v1/chat/completions/streamtest",
                            chat_body, hdrs)
        got = data.decode().split("data: ")
        check("T4 sse", st == 200 and "text/event-stream" in hd.get("content-type", "")
              and len(got) == 4, "chunks=%d" % (len(got) - 1))

        # T5: hot reload (rotation) — rewrite keyfile, next request uses new key
        time.sleep(1.05)  # mtime granularity on Windows is coarse
        with open(keyfile, "w") as fh:
            json.dump({"consumers": {"radio": NEW_RADIO_KEY, "portal": PORTAL_KEY}}, fh)
        os.chmod(keyfile, 0o600)
        st, hd, data = post(RADIO_PORT, "/v1/chat/completions", chat_body, hdrs)
        check("T5 hot-reload", st == 200
              and MOCK["last"]["headers"]["x-consumer-key"] == NEW_RADIO_KEY,
              "status=%s" % st)

        # T6: fail-closed on missing keyfile (remove file)
        calls_before = MOCK["calls"]
        os.remove(keyfile)
        st, hd, data = post(RADIO_PORT, "/v1/chat/completions", chat_body, hdrs)
        err = json.loads(data) if data else {}
        check("T6 fail-closed", st == 503
              and err.get("error", {}).get("code") == "key_unavailable",
              "status=%s code=%s" % (st, err.get("error", {}).get("code")))
        check("T6b not forwarded", MOCK["calls"] == calls_before,
              "upstream calls unchanged (%d)" % MOCK["calls"])
        # restore
        with open(keyfile, "w") as fh:
            json.dump({"consumers": {"radio": NEW_RADIO_KEY, "portal": PORTAL_KEY}}, fh)
        os.chmod(keyfile, 0o600)
        time.sleep(1.05)

        # T7: upstream 401 passthrough
        MOCK["reject"] = True
        st, hd, data = post(PORTAL_PORT, "/v1/chat/completions", chat_body, hdrs)
        check("T7 upstream401", st == 401 and "invalid" in data.decode(),
              "status=%s" % st)
        MOCK["reject"] = False

        # T8: GET /health passthrough
        c = http.client.HTTPConnection("127.0.0.1", PORTAL_PORT, timeout=5)
        c.request("GET", "/health")
        r = c.getresponse()
        ok = json.loads(r.read())
        c.close()
        check("T8 get-health", r.status == 200 and ok.get("ok") is True
              and MOCK["last"]["method"] == "GET",
              "status=%s" % r.status)
    finally:
        fwd.terminate()
        try:
            fwd.wait(timeout=5)
        except subprocess.TimeoutExpired:
            fwd.kill()
        err_tail = ""
        try:
            err_tail = (fwd.stderr.read() or "")[-400:]
        except Exception:
            pass
        upstream.shutdown()
        shutil.rmtree(tmp, ignore_errors=True)

    print("-" * 60)
    print("KEYFWD LOCAL: %d PASS / %d FAIL" % (PASS, FAIL))
    if err_tail:
        print("fwd stderr tail:\n" + err_tail)
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
