#!/usr/bin/env python3
"""Voxtype's pre_recording_command, set by `amd-npu enable`: runs as each recording starts.

Voxtype sends dictation audio to http://127.0.0.1:52625 and types whatever text comes back, and it
can't tell who is listening there. amd-npu-proxy.socket keeps that port bound for this account; if
anything else holds it (another account), or nothing does, this cancels the recording before any
audio is sent and says why. With Voxtype on its CPU model (NPU-only mode, released) it does nothing.

Stdlib only, no arguments. Exits 1 after cancelling (Voxtype logs the hook's failure and carries on;
the cancel is what stops the recording).

Why it polls for the trigger file instead of waiting for `voxtype record cancel`: Voxtype awaits this
hook inline, with no timeout. The CLI waits up to 2 s for the daemon to acknowledge the cancel, and
the daemon can't acknowledge while it is blocked in this hook, so waiting on the CLI stalled every
cancel by 2 s. Instead the CLI is started and not waited for. The cancel trigger file being on disk
before the hook returns is what guarantees the cancel wins over a queued stop, so the hook polls for
that file (up to 1 s) and returns. The CLI exits by itself after its own timeout.
"""

import os
import subprocess
import sys
import time
import tomllib

PORT = 52625
URL = f"http://127.0.0.1:{PORT}"
# Listeners that would receive 127.0.0.1:<port> traffic: 127.0.0.1, 0.0.0.0, ::, ::1, ::ffff:127.0.0.1.
ADDRESSES = {a + f":{PORT:04X}" for a in (
    "0100007F", "00000000", "0" * 32, "0" * 24 + "01000000", "0" * 16 + "FFFF0000" + "0100007F")}


def voxtype_sends_here():
    home = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    try:
        with open(os.path.join(home, "voxtype", "config.toml"), "rb") as f:
            whisper = tomllib.load(f).get("whisper", {})
    except (OSError, tomllib.TOMLDecodeError):
        return False  # Voxtype can't read it either
    mode = whisper.get("mode") or whisper.get("backend") or "local"
    return mode == "remote" and str(whisper.get("remote_endpoint", "")).rstrip("/") == URL


def port_owner():
    """"own", "other" or "none", for listeners on the addresses above."""
    own = other = False
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(path) as f:
                next(f, None)
                for line in f:
                    fields = line.split()
                    if len(fields) > 7 and fields[1] in ADDRESSES and fields[3] == "0A":
                        if fields[7] == str(os.getuid()):
                            own = True
                        else:
                            other = True
        except OSError:
            pass
    return "other" if other else ("own" if own else "none")


def main():
    if not voxtype_sends_here():
        return 0
    owner = port_owner()
    if owner == "own":
        return 0
    cancel_file = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}",
                               "voxtype", "cancel")
    try:
        proc = subprocess.Popen(["voxtype", "record", "cancel"], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
    except OSError:
        proc = None  # voxtype missing: still notify
    if proc is not None:
        deadline = time.monotonic() + 1.0
        while not os.path.exists(cancel_file) and time.monotonic() < deadline:
            time.sleep(0.01)
        if not os.path.exists(cancel_file):
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
    if owner == "other":
        body = (f"Another account on this computer is listening on port {PORT}, where dictation goes. "
                "The recording was cancelled before any audio was sent. Run 'amd-npu doctor'.")
    else:
        body = (f"Nothing holds port {PORT} for this account (amd-npu-proxy.socket isn't running), so "
                "dictation could reach another account. Recording cancelled. Run 'amd-npu enable'.")
    try:
        subprocess.run(["notify-send", "-u", "critical", "-a", "AMD NPU", "Dictation cancelled", body],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
    except (subprocess.TimeoutExpired, OSError):
        pass
    print(f"amd-npu dictation guard: port {PORT} is {owner}; recording cancelled", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
