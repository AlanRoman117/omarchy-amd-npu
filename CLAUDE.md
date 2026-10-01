# CLAUDE.md

Context for working on this repository. Read this before changing anything.

## What this is

An Omarchy shell plugin (bar card) plus a CLI that put the AMD XDNA2 NPU to work through
FastFlowLM: Whisper large-v3-turbo for Voxtype dictation, and optional small local LLMs next to it
or on their own. **Public since 2026-09-30.** Pitching it upstream to Omarchy is a later decision;
see `to-do.md`. Renamed from `omarchy-npu-dictation` in 0.2.0.

| Path | Role |
|---|---|
| `manifest.json` | Plugin manifest (`alanroman117.amd-npu`, `bar-widget`) |
| `Widget.qml` | Bar icon + popup card, built on Omarchy's `Panel` + `KeyboardPanel` (same pattern as `plugins/panels/power/Panel.qml`). IPC target `alanroman117.amd-npu`: `open`, `close`, `toggle`, `refresh` |
| `bin/amd-npu` | Setup, dictation and model commands (`amd-npu help`) |
| `lib/chat.py` | Terminal chat, stdlib only (its own file because an interactive script can't read the terminal if its code comes in on stdin) |
| `systemd/amd-npu.service` | User unit, copied by `enable`. Reads `~/.config/amd-npu/server.env` (`FLM_LLM`, `FLM_ASR`, `FLM_CTX`) |

Modes, all driven by `server.env`: **whisper** (`FLM_LLM=` empty), **share** (LLM + `FLM_ASR=1`),
**exclusive** (LLM + `FLM_ASR=0`, Voxtype switched to `backend = "local"`, notifications both ways).

## Current state (2026-10-01)

- Version 0.2.0. PRs #1-#6 are merged and `main` is what's installed. Public on GitHub since
  2026-09-30.
- The maintainer's Z13 normally runs **Whisper only** (`FLM_LLM=` empty), with Voxtype on the NPU.
  `qwen3.5:0.8b` and `qwen3.5:4b` are downloaded for testing.
- The installed plugin (`~/.config/omarchy/plugins/alanroman117.amd-npu/`) is a git clone of the
  public `main`. Keep it in sync after a merge with `omarchy plugin update alanroman117.amd-npu`.
  If `Widget.qml` changed, also run `omarchy restart shell`.
- `/security-review` of the whole repo ran on 2026-09-30: no HIGH or MEDIUM findings. Its optional
  follow-ups (CORS, server auth, multi-user port takeover) are under Hardening in `to-do.md`.
- Next up: the open items in `to-do.md` (test on another XDNA2 machine, a clean-install test, the
  plugin id prefix, the Omarchy Discussions pitch).

## FastFlowLM behaviour this relies on (1.0.4, read from `src/server/rest_handler.cpp`)

- One model per type (ASR, LLM, embedding) loaded at once; types coexist, so Whisper stays while
  LLMs swap.
- A request naming another LLM swaps it live (`ensure_model_loaded`), and **auto-downloads it if
  missing**. Never send a model name that isn't downloaded (`require_downloaded_llm`).
- A failed LLM load resets the NPU device, which can take Whisper with it. `load` pings Whisper
  afterwards and restarts the service if needed.
- **The server runs one request at a time.** In share mode, dictation queues behind a running LLM
  answer (measured: a 2 s clip waited 44 s). `--preemption 1` does not change this.
- No unload endpoint: unloading restarts the server Whisper-only.
- **With Whisper off, `/v1/audio/transcriptions` answers HTTP 200 with a body of `null`.** Check
  the body (`ping` does), not just the status.
- `/api/ps` returns an error JSON when no LLM is loaded (internal placeholder `model-faker`).
- Speeds (`prefill_speed_tps`, `decoding_speed_tps`) come back in each response's `usage`, only to
  the caller.
- Memory: the process RSS excludes NPU buffers. Those show as `drm-total-memory` in
  `/proc/<pid>/fdinfo/*`. FastFlowLM's `footprint` understates real use (4B: 5.0 listed vs ~6.1 GB
  measured system-wide).

## How it's tested (on the ROG Flow Z13, the only verified machine)

- `bin/amd-npu check`, `status` and `doctor` must pass.
- Dictation round trip: `disable` then `enable`. The Voxtype config must come back byte-identical,
  and a second `enable` must create no files or backups.
- Models: `load` (share) swaps live and Whisper still pings. `load --exclusive --yes` →
  `voxtype transcribe` logs **no** request in `journalctl --user -u amd-npu`. `unload` → Whisper pings
  and the Voxtype config is byte-identical again. `bench-llm` and piped `chat` answer.
- Safety: `load` of a model that isn't downloaded, an unknown name, or `whisper-v3:turbo` must be
  refused before any request is sent.
- Card: `omarchy plugin validate <dir>`, then **`omarchy restart shell`**. The shell logs "reloading"
  when a plugin file changes but can keep running the old compiled QML. Open the card with
  `omarchy-shell alanroman117.amd-npu open` and screenshot each state (`grim -g`): Whisper only,
  share, exclusive.
- Needs a human: live F9 dictation in each mode, and clicking through the card (the NPU-only
  confirmation row only appears on click).

The installed plugin is a separate copy at `~/.config/omarchy/plugins/alanroman117.amd-npu/` (a git
clone once installed with `omarchy plugin add`). Edits here don't reach it until you update it.

## README screenshots (`docs/screenshots/`)

Three card states: `card-whisper.png`, `card-share.png` (qwen3.5:4b shared) and `card-exclusive.png`.
To retake them:

1. Put the server in the state (`amd-npu load qwen3.5:4b [--exclusive --yes]`). After an
   exclusive switch, wait ~10 s for the desktop notification to clear before capturing.
2. `omarchy-shell alanroman117.amd-npu open`, wait ~3 s, then `grim -g "<x>,0 600x<h>"` over the
   right side of the screen, then `omarchy-shell alanroman117.amd-npu close`.
3. Crop exactly to the card so nothing behind it shows. The card has a 2 px border in the theme's
   accent colour (RGB 80,148,117 in the theme used for the current shots). Find the first column and
   row with a long straight run of that colour, which is the card's top-left corner, then follow the top
   edge right and the left edge down. Don't just take the colour's bounding box: terminal frames behind
   the card share the colour.
4. Check for privacy (only the card in frame, no PNG metadata) and keep the files small.

The current shots are 1x (about 380 px wide), taken on a 1080p external display. The Z13's own screen
(scale 2) gives sharper ones. In exclusive mode, LAST DICTATION reads "-" right after the switch,
because only NPU dictations are counted.

## Rules learned the hard way

- **Voxtype's `remote_endpoint` has no `/v1`**, because Voxtype appends it.
- **`mkdir -p` before writing into `/etc/security/limits.d`**: it doesn't exist on a fresh Omarchy.
- **Memlock must be unlimited for the user manager** (`user@.service`), not just in `limits.conf`.
  Hyprland runs under systemd, so PAM limits alone don't reach the service.
- **Never force NPU firmware or suggest `amdxdna-dkms`** on current kernels.
- **Only XDNA2 (PCI `1022:17f0`)** is supported; `check` must refuse XDNA1 (`1022:1502`).
- **Third-party widgets get a restricted bar API** (`PluginBarApi`: `run`, tooltips, popouts,
  `moduleWidgets`), with **no `shellQuote`**. Quote shell arguments locally (`quote()` in
  `Widget.qml`). Check `journalctl --user | grep omarchy-shell` for `TypeError` after any widget change.
- **Keep `Widget.qml` ASCII.** Some editors and tools turn `\uXXXX` escapes into literal glyphs;
  convert them back before committing (`grep -P '[^\x00-\x7F]' Widget.qml` must find nothing). The
  chip icon is `\udb81\ude1a` (U+F061A, nf-md-chip); the buttons use BMP Font Awesome glyphs.
- `Dropdown` opens its own popup; inside the card that risks clipping, so the model picker is a
  button list.
- **Never `pkill -f` a pattern that appears in your own command line.**

## Commits

Branch + PR, like the other repos in `~/Github/my-projects`, with merge commits (`gh pr merge --merge
--delete-branch`). The maintainer has OK'd merging PRs for this repo. Before pushing, check that
nothing personal is in the diff: no home-directory usernames, tokens or emails beyond the git author.
Commit messages end with the Co-Authored-By line for Claude.
