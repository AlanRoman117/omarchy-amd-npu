#!/usr/bin/env python3
"""Public front for the AMD NPU server: 127.0.0.1:52625 -> FastFlowLM on 127.0.0.1:6669.

FastFlowLM 1.0.4 has no authentication, sends `Access-Control-Allow-Origin: *` even with
`--cors 0`, accepts text/plain bodies, and downloads any catalog model a request names. It
therefore listens on 6669, a port browsers refuse to connect to (WHATWG Fetch "bad ports"), and
this proxy is the only way in on the normal port. It forwards only an allowlist of exact routes
(ROUTES; /api/pull, /load and anything unknown are refused) and refuses:

  - a Host header other than 127.0.0.1/localhost on this port (DNS rebinding)
  - request targets that aren't plain paths (absolute URLs, "//", "%" escapes, trailing "/")
  - browser requests (an Origin header, or Sec-Fetch-Site cross-site/same-site) from origins
    not listed in AMD_NPU_ALLOWED_ORIGINS ("*" is ignored)
  - JSON endpoints without Content-Type: application/json (the text/plain trick)
  - requests naming a model that isn't downloaded (FastFlowLM would download it, or hang if it
    can't write the models directory), including ambiguous multipart uploads
  - malformed lengths (negative, non-numeric, or both Content-Length and Transfer-Encoding)
  - forwarding to 6669 when that port isn't held by this user (another account on a shared
    machine could otherwise receive the audio and choose the text that gets typed)

It strips FastFlowLM's own CORS headers, adding proper ones only for allow-listed origins, sets
Content-Length itself, times out idle clients and caps concurrent requests. Request bodies are
never logged. Standard library only.
"""

import email.errors
import email.parser
import email.policy
import http.client
import http.server
import json
import os
import re
import socket
import socketserver
import subprocess
import sys
import threading
import time

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("AMD_NPU_PORT", "52625"))
UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = int(os.environ.get("AMD_NPU_UPSTREAM_PORT", "6669"))
_ORIGINS = set(os.environ.get("AMD_NPU_ALLOWED_ORIGINS", "").split())
ALLOWED_ORIGINS = _ORIGINS - {"*"}  # every website reading the replies is never what anyone wants
ALLOWED_HOSTS = {f"127.0.0.1:{LISTEN_PORT}", f"localhost:{LISTEN_PORT}"}

JSON_ENDPOINTS = ("/v1/chat/completions", "/v1/completions", "/v1/embeddings",
                  "/api/chat", "/api/generate", "/api/embed", "/api/embeddings", "/api/show")
MULTIPART_ENDPOINTS = ("/v1/audio/transcriptions",)
# Everything that may be forwarded, by method. Not here: /api/pull (downloads), /load (swaps
# models outside amd-npu), /api/cancel, /api/npu/status and whatever a later FastFlowLM adds.
ROUTES = {
    "GET": {"/api/version", "/api/tags", "/api/ps", "/v1/models", "/v1/version"},
    "POST": set(JSON_ENDPOINTS) | set(MULTIPART_ENDPOINTS),
}
ROUTES["HEAD"] = ROUTES["GET"]
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
              "trailer", "transfer-encoding", "upgrade", "host", "content-length"}
MAX_BODY = 512 * 1024 * 1024  # audio uploads can be large; anything bigger is refused
CLIENT_TIMEOUT = 120          # seconds a single read may stall
REQUEST_DEADLINE = 60         # seconds to deliver the whole request (headers and body)
MAX_REQUESTS = 16             # FastFlowLM answers one at a time; more than this is a flood
SLOTS = threading.BoundedSemaphore(MAX_REQUESTS)

_models_lock = threading.Lock()
_models_cache = (0.0, set())


def installed_models():
    """Names of downloaded models (LLMs, Whisper, embeddings), cached for 10 s."""
    global _models_cache
    with _models_lock:
        stamp, names = _models_cache
        if time.monotonic() - stamp < 10:
            return names
        try:
            out = subprocess.run(["flm", "list", "--json"], capture_output=True, text=True, timeout=10).stdout
            names = {m["name"] for m in json.loads(out).get("models", []) if m.get("installed")}
        except (OSError, ValueError, subprocess.SubprocessError):
            names = set()  # fail closed: no model passes the check if the list can't be read
        _models_cache = (time.monotonic(), names)
        return names


_owner_lock = threading.Lock()
_owner_cache = (0.0, False)


def upstream_owned():
    """True if the listener on the upstream port belongs to this user (cached 5 s).

    On a shared machine another account could bind 6669 while the server is down; forwarding
    to it would hand over the dictation audio and let it choose the text Voxtype types.
    Under PrivateUsers=, other accounts' sockets show up as the overflow UID, never ours."""
    global _owner_cache
    with _owner_lock:
        stamp, owned = _owner_cache
        if time.monotonic() - stamp < 5:
            return owned
        owned, want = False, f"0100007F:{UPSTREAM_PORT:04X}"
        try:
            with open("/proc/net/tcp") as f:
                next(f)
                for line in f:
                    fields = line.split()
                    if fields[1] == want and fields[3] == "0A":  # local address, LISTEN
                        owned = int(fields[7]) == os.getuid()
                        break
        except (OSError, ValueError, IndexError, StopIteration):
            owned = False
        _owner_cache = (time.monotonic(), owned)
        return owned


_BAD_MULTIPART = (email.errors.NoBoundaryInMultipartDefect, email.errors.StartBoundaryNotFoundDefect,
                  email.errors.CloseBoundaryNotFoundDefect, email.errors.MultipartInvariantViolationDefect)


def multipart_models(body, content_type):
    """Every value of a form part named "model" (file parts included), parsed with the email
    package's strict MIME parser. None if the body isn't a complete, well-formed multipart."""
    try:
        msg = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
            b"Content-Type: " + content_type.encode("latin-1") + b"\r\n\r\n" + body)
    except (UnicodeError, ValueError):
        return None
    if not msg.is_multipart() or any(isinstance(d, _BAD_MULTIPART) for d in msg.defects):
        return None
    parts = list(msg.iter_parts())
    if not parts or any(isinstance(d, _BAD_MULTIPART) for p in parts for d in p.defects):
        return None
    models = []
    for part in parts:
        if part.get_param("name", header="content-disposition") == "model":
            value = part.get_payload(decode=True) or b""
            models.append(value.decode("utf-8", "replace").strip())
    return models


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "amd-npu-proxy"
    timeout = CLIENT_TIMEOUT
    sys_version = ""

    # --- helpers -------------------------------------------------------------

    def setup(self):
        super().setup()
        # A client gets REQUEST_DEADLINE seconds for its whole request, not per read, so slow
        # drip-feeding can't hold a thread or a request slot.
        self._deadline = threading.Timer(REQUEST_DEADLINE, self._expire)
        self._deadline.daemon = True
        self._deadline.start()

    def _expire(self):
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def finish(self):
        self._deadline.cancel()
        super().finish()

    def log_message(self, fmt, *args):  # quiet: only refusals are logged (see refuse)
        pass

    def origin(self):
        return self.headers.get("Origin")

    def allowed_origin(self):
        origin = self.origin()
        return origin is not None and origin in ALLOWED_ORIGINS

    def cors_headers(self):
        if not self.allowed_origin():
            return []
        return [("Access-Control-Allow-Origin", self.origin()), ("Vary", "Origin"),
                ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
                ("Access-Control-Allow-Headers", "Content-Type, Authorization")]

    def refuse(self, code, reason):
        sys.stderr.write(f"refused {code} {self.command} {self.path.split('?')[0]}: {reason}"
                         f"{' (origin ' + self.origin() + ')' if self.origin() else ''}\n")
        body = json.dumps({"error": {"message": f"amd-npu proxy: {reason}", "code": code}}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def read_body(self):
        """The request body, or (code, reason) to refuse it."""
        te = self.headers.get_all("Transfer-Encoding") or []
        cl = self.headers.get_all("Content-Length") or []
        if te and cl:
            return 400, "both Content-Length and Transfer-Encoding"
        if te:
            if [v.strip().lower() for v in te] != ["chunked"]:
                return 400, "unsupported Transfer-Encoding"
            chunks, total = [], 0
            while True:
                line = self.rfile.readline(1024).split(b";")[0].strip()
                if not re.fullmatch(rb"[0-9A-Fa-f]{1,8}", line):
                    return 400, "malformed chunk size"
                size = int(line, 16)
                if size == 0:
                    self.rfile.readline(1024)
                    break
                total += size
                if total > MAX_BODY:
                    return 413, "request body too large"
                chunks.append(self.rfile.read(size))
                self.rfile.readline(1024)
            return b"".join(chunks)
        if len(cl) > 1 or (cl and not re.fullmatch(r"\d{1,12}", cl[0].strip())):
            return 400, "malformed Content-Length"
        length = int(cl[0]) if cl else 0
        if length > MAX_BODY:
            return 413, "request body too large"
        return self.rfile.read(length) if length else b""

    # --- policy --------------------------------------------------------------

    def check_request(self):
        """Returns (code, reason) to refuse, or None to forward."""
        if self.headers.get("Host", "") not in ALLOWED_HOSTS:
            return 421, "unexpected Host header"
        path = self.path.split("?")[0]
        if not path.startswith("/") or "//" in path or "%" in path or (len(path) > 1 and path.endswith("/")):
            return 400, "request target must be a plain path"
        if path not in ROUTES.get(self.command, ()):
            return 404, f"{self.command} {path} isn't available through amd-npu"
        if self.origin() is not None and not self.allowed_origin():
            return 403, "browser origin not allowed (see AMD_NPU_ALLOWED_ORIGINS)"
        site = self.headers.get("Sec-Fetch-Site", "")
        if site in ("cross-site", "same-site") and not self.allowed_origin():
            return 403, "cross-site browser request not allowed"
        return None

    def check_body(self, path, body):
        if len(self.headers.get_all("Content-Type") or []) > 1:
            return 400, "more than one Content-Type header"
        content_type = self.headers.get("Content-Type", "").lower()
        if path in JSON_ENDPOINTS:
            if not content_type.startswith("application/json"):
                return 415, "JSON endpoints need Content-Type: application/json"
            try:
                data = json.loads(body or b"{}")
                models = [data.get(k) for k in ("model", "name") if data.get(k) is not None]
            except (ValueError, AttributeError):
                return 400, "body is not a JSON object"
            if any(not isinstance(m, str) for m in models):
                return 400, "model must be a string"
        elif path in MULTIPART_ENDPOINTS:
            if not content_type.startswith("multipart/form-data"):
                return 415, "transcription needs multipart/form-data"
            models = multipart_models(body, self.headers.get("Content-Type", ""))
            if models is None:
                return 400, "malformed multipart body"
            if len(models) > 1:
                return 400, "more than one model field"
        else:
            return None
        for model in models:
            if model and model not in installed_models():
                return 404, f"model '{model}' isn't downloaded (amd-npu pull {model})"
        return None

    # --- forwarding ------------------------------------------------------------

    def forward(self, body):
        if not upstream_owned():
            return self.refuse(502, f"port {UPSTREAM_PORT} isn't held by this user's NPU server")
        upstream = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=900)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        headers["Host"] = f"{UPSTREAM_HOST}:{UPSTREAM_PORT}"
        if body is not None:
            headers["Content-Length"] = str(len(body))
        try:
            upstream.request(self.command, self.path, body=body, headers=headers)
            response = upstream.getresponse()
        except OSError:
            return self.refuse(502, "the NPU server isn't answering")

        self.send_response(response.status, response.reason)
        length = response.getheader("Content-Length")
        for key, value in response.getheaders():
            if key.lower() in HOP_BY_HOP or key.lower().startswith("access-control-") or key.lower() == "content-length":
                continue
            self.send_header(key, value)
        for key, value in self.cors_headers():
            self.send_header(key, value)
        chunked = length is None and self.command != "HEAD"
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", length or "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            while True:
                data = response.read1(65536) if hasattr(response, "read1") else response.read(65536)
                if not data:
                    break
                if chunked:
                    self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
                else:
                    self.wfile.write(data)
                self.wfile.flush()
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass  # client went away (e.g. Ctrl+C in a chat)
        finally:
            upstream.close()

    # --- methods -------------------------------------------------------------

    def handle_any(self):
        # Slots are taken only once a request has fully arrived, so idle connections can't
        # lock clients out.
        refusal = self.check_request()
        if refusal:
            return self.refuse(*refusal)
        if not SLOTS.acquire(blocking=False):
            return self.refuse(503, "too many requests at once")
        try:
            self.handle_allowed()
        finally:
            SLOTS.release()

    def handle_allowed(self):
        path = self.path.split("?")[0]
        body = None
        if self.command == "POST":
            body = self.read_body()
            if isinstance(body, tuple):
                return self.refuse(*body)
            refusal = self.check_body(path, body)
            if refusal:
                return self.refuse(*refusal)
        self._deadline.cancel()  # the request is in; streaming the answer may take minutes
        self.forward(body)

    def do_OPTIONS(self):
        if self.allowed_origin() and self.headers.get("Host", "") in ALLOWED_HOSTS:
            self.send_response(204)
            for key, value in self.cors_headers():
                self.send_header(key, value)
            self.send_header("Access-Control-Max-Age", "600")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.refuse(403, "preflight from an origin that isn't allowed")

    do_GET = do_POST = do_HEAD = do_PUT = do_PATCH = do_DELETE = handle_any


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    server = Server((LISTEN_HOST, LISTEN_PORT), Handler)
    if "*" in _ORIGINS:
        sys.stderr.write("AMD_NPU_ALLOWED_ORIGINS: '*' ignored (it would let every website use the API)\n")
    sys.stderr.write(f"amd-npu proxy on {LISTEN_HOST}:{LISTEN_PORT} -> {UPSTREAM_HOST}:{UPSTREAM_PORT}; "
                     f"allowed origins: {' '.join(sorted(ALLOWED_ORIGINS)) or 'none'}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
