#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rag_keyfwd — E6.3 WS-B2 consumer-key forwarder.

A minimal stdlib-only reverse proxy that sits between LiteLLM and the RAG
gateway. Its single job: strip any client-supplied ``x-consumer-key`` and
inject the correct registry consumer key, chosen by LISTENER (host:port), so
plaintext consumer keys no longer need to live in the LiteLLM model table
(``extra_headers``) or in litellm.yaml.

Design constraints (E6.3 B2):
  * stdlib only (runs in python:3.12-alpine, no pip installs).
  * One JSON key file, mode 600, hot-reloaded on mtime/size change (atomic
    key rotation without downtime). Format: {"consumers": {name: rc_...}}
    or a flat {name: rc_...} mapping.
  * Every other header (including ``Authorization: Bearer <service key>``)
    and the full body pass through unchanged. The forwarder therefore
    holds NO service key / master key.
  * Fail closed: missing key file or unknown consumer -> 503, never a
    forwarded request without a key.
  * No request/response bodies or key material are logged (digests only).
  * SSE-friendly: streaming responses are forwarded chunk by chunk with
    read1() (no 8KB buffering delay on token streams).

Usage:
  python3 rag_keyfwd.py \
      --listen 127.0.0.1:18211 --consumer radio \
      --listen 127.0.0.1:18212 --consumer portal \
      --keyfile /path/keys.json \
      --upstream http://127.0.0.1:18210
"""

import argparse
import hashlib
import http.client
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOP_BY_HOP = {
    "connection",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "keep-alive",
}
# Never trust the caller with these; the forwarder is the single source.
INJECTED = {"x-consumer-key"}
HEALTHZ = "__healthz"

STATE_LOCK = threading.Lock()
STATE = {"keys": {}, "mtime": None, "size": None, "error": None}


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]


def load_keys(path: str) -> None:
    """(Re)read the key file if it changed. Never logs key material."""
    st = os.stat(path)
    with STATE_LOCK:
        if st.st_mtime == STATE["mtime"] and st.st_size == STATE["size"]:
            return
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    if isinstance(data, dict) and isinstance(data.get("consumers"), dict):
        data = data["consumers"]
    if not isinstance(data, dict):
        raise ValueError("key file must be a JSON object of consumer: key")
    cleaned = {str(k): str(v) for k, v in data.items() if v}
    with STATE_LOCK:
        STATE["keys"] = cleaned
        STATE["mtime"] = st.st_mtime
        STATE["size"] = st.st_size
        STATE["error"] = None
    sys.stderr.write(
        "keyfwd: key file reloaded consumers=%s digests=%s\n"
        % (
            ",".join(sorted(cleaned)) or "<none>",
            {k: _digest(v) for k, v in sorted(cleaned.items())},
        )
    )


def make_handler(consumer: str, kf_path: str, uhost: str, uport: int,
                 to_s: int):
    """Build a handler class bound to ONE listener (consumer + upstream)."""

    class Bound(Handler):
        consumer_name = consumer
        keyfile = kf_path
        upstream_host = uhost
        upstream_port = uport
        upstream_timeout = to_s

    return Bound


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "rag-keyfwd/1.0"
    # bound per listener by make_handler()
    consumer_name = ""
    keyfile = ""
    upstream_host = ""
    upstream_port = 0
    upstream_timeout = 300

    # ------------------------------------------------------------------ #
    def log_message(self, fmt: str, *args) -> None:  # noqa: N802
        sys.stderr.write("keyfwd: %s\n" % (fmt % args))

    def _fail(self, status: int, code: str, message: str) -> None:
        body = json.dumps({"error": {"code": code, "message": message}}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def _healthz(self) -> None:
        with STATE_LOCK:
            names = sorted(STATE["keys"])
            digests = {k: _digest(v) for k, v in STATE["keys"].items()}
            err = STATE["error"]
        body = json.dumps({
            "ok": err is None,
            "consumer": self.consumer_name,
            "consumers": names,
            "key_digests": digests,
            "keyfile_error": err,
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _current_key(self) -> str | None:
        try:
            load_keys(self.keyfile)
        except Exception as exc:  # fail closed
            self.log_message("keyfile error: %r", exc)
            with STATE_LOCK:
                STATE["error"] = repr(exc)
            return None
        with STATE_LOCK:
            return STATE["keys"].get(self.consumer_name)

    def _forward(self) -> None:
        if HEALTHZ in self.path:
            self._healthz()
            return

        key = self._current_key()
        if not key:
            self._fail(503, "key_unavailable",
                       "consumer key not loaded; refusing to forward")
            return

        method = self.command
        path = self.path
        body = b""
        cl = self.headers.get("Content-Length")
        if cl:
            try:
                n = int(cl)
            except ValueError:
                n = 0
            if n > 0:
                body = self.rfile.read(n)
        elif self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            self._fail(411, "length_required",
                       "chunked request bodies are not supported")
            return

        headers = {}
        for k, v in self.headers.items():
            lk = k.lower()
            if lk in HOP_BY_HOP or lk in INJECTED or lk == "content-length":
                continue
            if lk in headers:  # first occurrence wins for duplicates
                continue
            headers[lk] = v
        headers["x-consumer-key"] = key
        if body:
            headers["content-length"] = str(len(body))

        model = ""
        try:
            if body:
                model = str(json.loads(body.decode("utf-8", "ignore")).get("model", ""))
        except Exception:
            model = ""

        try:
            conn = http.client.HTTPConnection(self.upstream_host, self.upstream_port,
                                              timeout=self.upstream_timeout)
            conn.request(method, path, body=body or None, headers=headers)
            upstream = conn.getresponse()
        except Exception as exc:
            self.log_message("upstream error model=%s: %r", model, exc)
            self._fail(502, "upstream_unreachable", "gateway upstream error")
            return

        # Inspect raw upstream response attributes BEFORE filtering headers.
        raw_te = ""
        raw_ct = ""
        for k, v in upstream.getheaders():
            if k.lower() == "transfer-encoding":
                raw_te = v
            elif k.lower() == "content-type":
                raw_ct = v
        cl_out = upstream.length  # int or None (from Content-Length)

        resp_headers = {}
        for k, v in upstream.getheaders():
            if k.lower() in HOP_BY_HOP or k.lower() == "content-length":
                continue
            resp_headers[k] = v

        is_stream = upstream.status == 200 and (
            raw_te.lower() == "chunked"
            or "text/event-stream" in raw_ct
            or cl_out is None
        )

        self.log_message("%s model=%s status=%s stream=%s",
                         method, model or "-", upstream.status, is_stream)

        self.send_response(upstream.status, upstream.reason)
        if is_stream:
            for k, v in resp_headers.items():
                self.send_header(k, v)
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                while True:
                    chunk = upstream.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                try:
                    conn.close()
                except Exception:
                    pass
            self.close_connection = True
            return

        out_body = upstream.read()
        for k, v in resp_headers.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(out_body)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(out_body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        conn.close()
        self.close_connection = True

    def do_GET(self):  # noqa: N802
        self._forward()

    def do_POST(self):  # noqa: N802
        self._forward()

    def do_PUT(self):  # noqa: N802
        self._forward()

    def do_PATCH(self):  # noqa: N802
        self._forward()

    def do_DELETE(self):  # noqa: N802
        self._forward()

    def do_OPTIONS(self):  # noqa: N802
        self._forward()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="E6.3 B2 consumer-key forwarder")
    ap.add_argument("--listen", action="append", default=[],
                    help="host:port to listen on (repeatable)")
    ap.add_argument("--consumer", action="append", default=[],
                    help="consumer name for the preceding --listen (repeatable)")
    ap.add_argument("--keyfile", required=True, help="JSON consumer key file (600)")
    ap.add_argument("--upstream", required=True,
                    help="gateway http://host:port (no path)")
    ap.add_argument("--timeout", type=int, default=300,
                    help="upstream socket timeout seconds (default 300)")
    args = ap.parse_args(argv)

    if len(args.listen) != len(args.consumer):
        ap.error("--listen and --consumer must be given in pairs")
    if not args.listen:
        ap.error("at least one --listen/--consumer pair is required")

    up = args.upstream
    if not up.startswith("http://"):
        ap.error("upstream must be http://host:port")
    rest = up[len("http://"):]
    hp, _, tail = rest.partition("/")
    if tail:
        ap.error("upstream must not include a path (use http://host:port)")
    uhost, _, uport = hp.partition(":")

    try:
        load_keys(args.keyfile)
    except Exception as exc:
        sys.stderr.write("keyfwd: cannot load keyfile: %r\n" % (exc,))
        return 2

    servers = []
    for addr, consumer in zip(args.listen, args.consumer):
        h, _, p = addr.rpartition(":")
        bound = make_handler(consumer, args.keyfile, uhost,
                             int(uport) if uport else 80, args.timeout)
        srv = ThreadingHTTPServer((h or "127.0.0.1", int(p)), bound)
        srv.daemon_threads = True
        servers.append(srv)
        sys.stderr.write("keyfwd: listening %s consumer=%s\n" % (addr, consumer))

    def serve_first():
        try:
            servers[0].serve_forever()
        except KeyboardInterrupt:
            pass

    for s in servers[1:]:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    sys.stderr.write("keyfwd: up listeners=%d upstream=%s\n"
                     % (len(servers), args.upstream))
    serve_first()
    return 0


if __name__ == "__main__":
    sys.exit(main())
