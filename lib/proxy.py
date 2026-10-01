#!/usr/bin/env python3
"""Public front for the AMD NPU server: 127.0.0.1:52625 -> FastFlowLM on 127.0.0.1:6669.

FastFlowLM 1.0.4 has no authentication, sends `Access-Control-Allow-Origin: *` even with
`--cors 0`, accepts text/plain bodies, and downloads any catalog model a request names. It
therefore listens on 6669, a port browsers refuse to connect to (WHATWG Fetch "bad ports"), and
this proxy is the only way in on the normal port. It refuses:

  - a Host header other than 127.0.0.1/localhost on this port (DNS rebinding)
  - browser requests (an Origin header, or Sec-Fetch-Site cross-site/same-site) from origins
    not listed in AMD_NPU_ALLOWED_ORIGINS
  - JSON endpoints without Content-Type: application/json (the text/plain trick)
  - requests naming a model that isn't downloaded (FastFlowLM would download it, or hang if it
    can't write the models directory)

and strips FastFlowLM's own CORS headers, adding proper ones only for allow-listed origins.
Request bodies are never logged. Standard library only.
"""

import http.client
import http.server
import json
import os
import re
import socketserver
import subprocess
import sys
import threading
import time

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("AMD_NPU_PORT", "52625"))
UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = int(os.environ.get("AMD_NPU_UPSTREAM_PORT", "6669"))
ALLOWED_ORIGINS = set(os.environ.get("AMD_NPU_ALLOWED_ORIGINS", "").split())
ALLOWED_HOSTS = {f"127.0.0.1:{LISTEN_PORT}", f"localhost:{LISTEN_PORT}"}

JSON_ENDPOINTS = ("/v1/chat/completions", "/v1/completions", "/v1/embeddings",
                  "/api/chat", "/api/generate", "/api/embed", "/api/embeddings")
MULTIPART_ENDPOINTS = ("/v1/audio/transcriptions",)
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
              "trailer", "transfer-encoding", "upgrade", "host"}
MAX_BODY = 512 * 1024 * 1024  # audio uploads can be large; anything bigger is refused

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


def model_from_multipart(body, content_type):
    match = re.search(r"boundary=\"?([^\";]+)\"?", content_type)
    if not match:
        return None
    for part in body.split(b"--" + match.group(1).encode()):
        if b'name="model"' in part.split(b"\r\n\r\n", 1)[0]:
            value = part.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in part else b""
            return value.rstrip(b"\r\n-").decode("utf-8", "replace").strip()
    return None


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "amd-npu-proxy"
    sys_version = ""

    # --- helpers -------------------------------------------------------------

    def log_message(self, fmt, *args):  # quiet: only refusals are logged (see refuse)
        pass

    def origin(self):
        return self.headers.get("Origin")

    def allowed_origin(self):
        origin = self.origin()
        return origin is not None and ("*" in ALLOWED_ORIGINS or origin in ALLOWED_ORIGINS)

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
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            chunks, total = [], 0
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    break
                total += size
                if total > MAX_BODY:
                    return None
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
            return b"".join(chunks)
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            return None
        return self.rfile.read(length) if length else b""

    # --- policy --------------------------------------------------------------

    def check_request(self):
        """Returns (code, reason) to refuse, or None to forward."""
        if self.headers.get("Host", "") not in ALLOWED_HOSTS:
            return 421, "unexpected Host header"
        if self.origin() is not None and not self.allowed_origin():
            return 403, "browser origin not allowed (see AMD_NPU_ALLOWED_ORIGINS)"
        site = self.headers.get("Sec-Fetch-Site", "")
        if site in ("cross-site", "same-site") and not self.allowed_origin():
            return 403, "cross-site browser request not allowed"
        return None

    def check_body(self, path, body):
        content_type = self.headers.get("Content-Type", "").lower()
        if path in JSON_ENDPOINTS:
            if not content_type.startswith("application/json"):
                return 415, "JSON endpoints need Content-Type: application/json"
            try:
                model = json.loads(body or b"{}").get("model")
            except (ValueError, AttributeError):
                return 400, "body is not a JSON object"
        elif path in MULTIPART_ENDPOINTS:
            if not content_type.startswith("multipart/form-data"):
                return 415, "transcription needs multipart/form-data"
            model = model_from_multipart(body, self.headers.get("Content-Type", ""))
        else:
            return None
        if model and model not in installed_models():
            return 404, f"model '{model}' isn't downloaded (amd-npu pull {model})"
        return None

    # --- forwarding ------------------------------------------------------------

    def forward(self, body):
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
        refusal = self.check_request()
        if refusal:
            return self.refuse(*refusal)
        path = self.path.split("?")[0]
        body = None
        if self.command in ("POST", "PUT", "PATCH"):
            body = self.read_body()
            if body is None:
                return self.refuse(413, "request body too large")
            refusal = self.check_body(path, body)
            if refusal:
                return self.refuse(*refusal)
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
    sys.stderr.write(f"amd-npu proxy on {LISTEN_HOST}:{LISTEN_PORT} -> {UPSTREAM_HOST}:{UPSTREAM_PORT}; "
                     f"allowed origins: {' '.join(sorted(ALLOWED_ORIGINS)) or 'none'}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
