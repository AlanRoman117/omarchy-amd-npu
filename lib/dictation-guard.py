#!/usr/bin/env python3
"""Voxtype's pre_recording_command, set by `amd-npu enable`: runs as each recording starts.

Voxtype sends dictation audio to http://127.0.0.1:52625 and types whatever text comes back, and it
can't tell who is listening there. amd-npu-proxy.socket keeps that port bound for this account; if
anything else holds it (another account), or nothing does, this cancels the recording before any
audio is sent and says why. With Voxtype on its CPU model (NPU-only mode, released) it does nothing.

Stdlib only, no arguments. Exits 1 after cancelling (Voxtype logs the hook's failure and carries on;
the cancel is what stops the recording).
"""

import os
import subprocess
import sys
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
    subprocess.run(["voxtype", "record", "cancel"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if owner == "other":
        body = (f"Another account on this computer is listening on port {PORT}, where dictation goes. "
                "The recording was cancelled before any audio was sent. Run 'amd-npu doctor'.")
    else:
        body = (f"Nothing holds port {PORT} for this account (amd-npu-proxy.socket isn't running), so "
                "dictation could reach another account. Recording cancelled. Run 'amd-npu enable'.")
    subprocess.run(["notify-send", "-u", "critical", "-a", "AMD NPU", "Dictation cancelled", body],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"amd-npu dictation guard: port {PORT} is {owner}; recording cancelled", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
