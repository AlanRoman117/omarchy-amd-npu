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
| `CountdownOverlay.qml` | The dictation countdown: its own layer-shell window (namespace `amd-npu-countdown`) in Omarchy's OSD style, placed above Voxtype's waveform |
| `Widget.qml` | Bar icon + popup card, built on Omarchy's `Panel` + `KeyboardPanel` (same pattern as `plugins/panels/power/Panel.qml`). IPC target `alanroman117.amd-npu`: `open`, `close`, `toggle`, `refresh`, `chat`. Chat opens a plain floating terminal (`xdg-terminal-exec --app-id=org.omarchy.terminal`), not `omarchy-launch-floating-terminal-with-presentation`, whose logo and "press any key" don't suit a chat |
| `bin/amd-npu` | Setup, dictation and model commands (`amd-npu help`) |
| `lib/chat.py` | Terminal chat, stdlib only (its own file because an interactive script can't read the terminal if its code comes in on stdin). Turns readline's bracketed paste back on (Python disables it), so a multi-line paste is one message; test with a pty sending `ESC[200~...ESC[201~` |
| `systemd/amd-npu.service` | FastFlowLM on `127.0.0.1:6669` (a browser "bad port"), `--cors 0`. Reads `%E/amd-npu/server.env` (`FLM_LLM`, `FLM_ASR`, `FLM_CTX`); `%E` = `$XDG_CONFIG_HOME`, which FastFlowLM also uses. Sandboxed (0.8.0): `PrivateUsers`, read-only models dir, `ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp`, `SystemCallFilter=@system-service`, empty capability set, `RestrictAddressFamilies`, `ProtectProc=invisible` and more; both units score 1.8 in `systemd-analyze --user security`. FastFlowLM writes nothing in `$HOME` at runtime. `Wants=` the proxy |
| `lib/proxy.py` + `systemd/amd-npu-proxy.service` | The public API on `127.0.0.1:52625`. `enable` copies `proxy.py` to `~/.local/share/amd-npu/`. Default-deny: only the exact method+path pairs in `ROUTES` are forwarded (`/api/pull`, `/load`, `/api/cancel`, `/api/npu/status` are refused); non-plain targets (`%`, trailing `/`, absolute form) get 400 (Python itself collapses a leading `//`). Refuses foreign `Origin`/`Sec-Fetch-Site` (allowlist `AMD_NPU_ALLOWED_ORIGINS`, `*` ignored), bad `Host`, non-JSON bodies on JSON endpoints, models that aren't downloaded (JSON `model` and `name`; multipart must have at most one real `model` field), duplicate/negative/CL+TE lengths. Sets Content-Length itself, 60 s per whole request, 16 concurrent requests (taken after the request arrives), and only forwards to 6669 if `/proc/net/tcp` shows it owned by this UID. `PartOf=amd-npu.service` |

Modes, all driven by `server.env`: **whisper** (`FLM_LLM=` empty), **share** (LLM + `FLM_ASR=1`),
**exclusive** (LLM + `FLM_ASR=0`, Voxtype switched to `backend = "local"`, notifications both ways).

## Current state (2026-10-02)

- Version 0.8.0. PRs #1-#21 are merged and `main` is what's installed. Public on GitHub since
  2026-09-30.
- **This is already the "proper" plugin.** Omarchy has no plugin store or registry: a plugin is a
  git repo with `manifest.json`, installed with `omarchy plugin add <git url>`, and sharing means
  posting that line (Omarchy Discussions, Discord). Omarchy never runs plugin install hooks or
  sudo, and plugins land disabled, so the card guides setup instead (see the setup states below).
- The maintainer's Voxtype config has **no `[osd]` section** (default `top_margin` 0.85) since
  0.6.0; the countdown positions itself.
- The maintainer's Z13 normally runs **Whisper only** (`FLM_LLM=` empty), with Voxtype on the NPU.
  `qwen3.5:0.8b` and `qwen3.5:4b` are downloaded for testing.
- The installed plugin (`~/.config/omarchy/plugins/alanroman117.amd-npu/`) is a git clone of the
  public `main`. Keep it in sync after a merge with `omarchy plugin update alanroman117.amd-npu`.
  If `Widget.qml` changed, also run `omarchy restart shell`.
- `/security-review` ran on 2026-09-30 (no HIGH or MEDIUM). 0.2.1's `--cors 0` turned out to be
  partial in FastFlowLM 1.0.4, so 0.3.0 put FastFlowLM on browser-blocked port 6669 behind
  `lib/proxy.py`, and made its models dir read-only. `FLM_CORS` is retired: `enable` drops it and
  points at `AMD_NPU_ALLOWED_ORIGINS`. What's still upstream's job (an API token, the CORS/plain-text
  and hang bugs) is in `to-do.md`.
- Next up: the open items in `to-do.md` (test on another XDNA2 machine, a clean-install test, the
  Omarchy Discussions pitch).

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
- **CORS is `*` and any `Host` header is accepted, even with `--cors 0`** (which only drops the
  OPTIONS handler). Every response carries `Access-Control-Allow-Origin: *`, and a `text/plain` POST
  is parsed as JSON. Never expose FastFlowLM's own port to browsers: it stays on 6669, and the proxy
  handles everything on 52625.
- **With the models dir read-only, a request for a missing model hangs the whole server** (download
  fails with "Read-only file system", then nothing answers, Whisper included; the unit stays
  "active"). The proxy refuses such requests on 52625; `enable` and `load` run `flm pull` first
  (20 ms when up to date) so an outdated model is refreshed outside the sandbox.
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
  refused before any request is sent. `load --ctx 100` is refused. A load whose restart fails
  restores the previous `server.env` (tested by hiding `~/.local/share/amd-npu/proxy.py`).
- Proxy: `amd-npu doctor` covers foreign `Origin` → 403, `text/plain` → 415, no CORS header. The full
  curl list: `Origin: null` and `Sec-Fetch-Site: cross-site` → 403; missing model in JSON, the Ollama
  API or an audio upload → 404 with the models dir unchanged; bad `Host` → 421; foreign preflight →
  403; an allow-listed origin gets 204/200 naming that origin. Browser check: serve a test page with
  `python3 -m http.server` and load it in headless Chrome with a throwaway `--user-data-dir`. Fetches
  to `:6669` fail in Chrome (unsafe port), and those to `:52625` show up as 403s in
  `journalctl --user -u amd-npu-proxy`.
- Card: `omarchy plugin validate <dir>`, then **`omarchy restart shell`**. The shell logs "reloading"
  when a plugin file changes but can keep running the old compiled QML. Open the card with
  `omarchy-shell alanroman117.amd-npu open` and screenshot each state (`grim -g`): Whisper only,
  share, exclusive.
- Needs a human: live F9 dictation in each mode, and clicking through the card (the NPU-only
  confirmation row only appears on click).

The installed plugin is a separate copy at `~/.config/omarchy/plugins/alanroman117.amd-npu/` (a git
clone once installed with `omarchy plugin add`). Edits here don't reach it until you update it.

## README screenshots (`docs/screenshots/`)

`preview.png` at the repo root (README top and the marketplace's card image) is a real 1920x1080 shot in Osaka Jade: card open, countdown with live waveform, bar chip timer. Retake it on an empty workspace (`hyprctl dispatch 'hl.dsp.focus({ workspace = "9" })'`), open the card, `voxtype record start`, someone talking, capture within ~3 s (before the silence warning), `record cancel`, switch back; strip metadata with `magick -strip -define png:exclude-chunks=date,time`.

Card states: `card-whisper.png`, `card-share.png`, `card-exclusive.png` (qwen3.5:0.8b) and
`card-setup.png` (the forced `install` state), all retaken in 0.7.0 in a dark theme on the 1080p HDMI
screen. To retake them:

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

The current shots are 1x (376 px wide), taken with `grim -s 1` (logical pixels) and cropped
just inside the card's border. Never put a countdown screenshot in the README without checking what's
behind it: the overlay is transparent around the card, and terminal text shows through. The Z13's own screen
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
- **Don't churn files in the installed plugin folder while the shell runs.** Every change there
  hot-reloads the plugin. On 2026-10-03 a `git checkout -- .` plus `omarchy plugin update` (about 10
  files, screenshots included) fired ~17 reloads in half a second, and Quickshell 0.3.1 segfaulted
  in `qs::io::ipc::IpcHandler::updateRegistration` from `onPostReload` (ipchandler.cpp:318): a
  use-after-free of a torn-down engine generation. The shell relaunched itself and nothing was lost,
  but the user saw the crash. To test, copy only the files that changed, then `omarchy restart shell`.
  Any plugin's `omarchy plugin update` can in principle hit the same upstream bug.
- **Never `pkill -f` a pattern that appears in your own command line** (bit twice). Stop test servers
  by port: `ss -ltnpH 'sport = :PORT'`.
- **Dictation countdown (`Widget.qml`):** follows `voxtype status --follow --format json` (run
  under `setpriv --pdeathsig TERM`, as Omarchy does) and reads `max_duration_secs` from the
  Voxtype config with a watched `FileView` (`parseVoxtypeConfig`: `[audio] max_duration_secs` and
  the `[osd]` keys). It no longer uses Omarchy's OSD, which is pinned bottom-centre with no position
  option and overlapped Voxtype's waveform at the default `top_margin` 0.85. `CountdownOverlay.qml`
  places its own card instead. Voxtype's rule, measured with `hyprctl layers -j` during
  `record start`: for any centred position the waveform is at
  `y = clamp(H * top_margin, margin_px, H - height_px - margin_px)` in logical pixels from the very
  top of the screen (0.78 → y 780 on a 1000 px high screen). The countdown goes 8 px above it, or
  below it if there's no room; for a corner position, or `[osd] enabled = false`, it takes Omarchy's
  OSD spot (`Style.space(67)` from the bottom). Only the bar instance on `Hyprland.focusedMonitor`
  shows it.
- **Microphone (`Widget.qml`, 0.7.0):** Voxtype's `[audio] device = "default"` (also `pipewire`,
  `pulse`) follows the system default input at record time, so the card shows
  `Pipewire.defaultAudioSource` and the picker sets the default exactly like Omarchy's audio panel
  (`Pipewire.preferredDefaultAudioSource` + `omarchy-audio-input-set-default <id> <name>`). Any other
  `device` is an ALSA name that locks dictation; the card then shows it and hides the picker. Rules
  copied from Omarchy's panel to keep Quickshell's Pipewire service stable: never read
  `node.properties` (only `nickname`/`description`/`name`), feed the Repeater a snapshot
  (`refreshMicInputs`, every 2 s while the card is open, skipped while recording) rather than the
  live node list. The countdown's mic line binds `Pipewire.defaultAudioSource` live (as Omarchy's
  `bar/widgets/Microphone.qml` does), so it follows an unplug mid-recording; 0.7.0 captured it once
  at record start and went stale. Internal
  inputs (`alsa_input.pci-*`) are labelled "Built-in mic (...)", since their nickname is the codec.
  **No-sound warning (0.7.2):** a `PwNodePeakMonitor` on the default input, enabled only while
  recording and armed 500 ms after it starts (so it doesn't open its stream at the same moment as
  Voxtype's). `peak` is on a perceptual scale, not linear: the built-in mic's room noise reads ~0.34
  while its raw samples peak at 127/32767. Anything above 0.02 counts as sound, so the warning means
  "no signal" (a dead, muted or reconnecting mic, or a noise-gated headset in a pause), not "you
  paused". The delay (`silenceWarnSec`: 0 = off, 3, 5, 10; default 3) lives in
  `~/.config/amd-npu/card.json`, written with `sh -c 'mkdir -p ... && printf ...'`, because plugins
  can't write their own `shell.json` settings. Found on 2026-10-03: replugging the wireless
  headset's receiver mid-recording moved the stream to a headset that sent pure zeros for a while,
  and Whisper then made up "Okay. Thank you." from the silence. To check a mic's real level without
  the shell: `timeout -s INT 2 pw-record --target <source> --rate 16000 --channels 1 --format s16
  /tmp/x.wav`, read the max sample, delete the file. Second test the same day: unplug then replug
  within one recording; after the replug the moved stream stayed silent for 9+ s while new
  recordings on the headset worked at once. It's documented in the README as a known limitation:
  the maintainer chose not to change PipeWire/WirePlumber or Voxtype device settings to work
  around it.
  To test switching without clicking: run `omarchy-audio-input-set-default <id> <name>` (ids from
  `wpctl status`), `voxtype record start`, check `pactl list source-outputs` shows Voxtype's stream
  on that source, `cancel`, then switch back.
- **Security review, 2026-10-03 (0.8.0)** fixed everything it found:
  - **Voxtype consent and restore:** `enable` prints the exact `[whisper]` changes and asks (`--yes`
    from the card's switch, whose click is the consent). The original values go to
    `~/.config/amd-npu/voxtype/original-whisper.json` on the first change, and `disable`/`remove`
    restore them (removing keys that weren't there). Copies `config.toml.first`/`.latest` sit beside it.
    `voxtype_cfg` edits the symlink target through a temp file + `os.replace`, and accepts
    `[whisper]  # comment` headers. A user's own `remote_timeout_secs` is only raised, never lowered.
    "On the NPU" means backend remote *and* our endpoint. Installs from before 0.8 have no recorded
    original, so `disable` falls back to `backend = "local"`; originals are never recorded while
    Voxtype already points at the NPU or mid NPU-only round trip (`$VOX_STATE/exclusive`), and are
    deleted after a restore. `voxtype_cfg` reads with `tomllib`, writes strings with `json.dumps`
    (`k:=json` keeps types), so `#`, quotes and decimal timeouts survive; `timeout_ok` never lowers
    a timeout. NPU-only mode switches Voxtype only if it was on the NPU, and back only if the
    marker says amd-npu switched it.
  - **Second review (same day)** also made the proxy parse multipart with the `email` package
    (strict MIME: closing delimiter required, every `name="model"` part counted, one Content-Type
    only), take request slots only after a request fully arrives, and give each connection 60 s for
    its whole request. `port_owner`/the card probe also catch `0.0.0.0`, `::`, `::1` and
    `::ffff:127.0.0.1` listeners (`/proc/net/tcp6`).
  - **Memlock:** only `/etc/security/limits.d/90-amd-npu-memlock.conf` (this user). PAM applies it to
    the user manager, whose hard limit is then unlimited. That's verified here: no `user@` drop-in,
    yet `/proc/<user systemd>/limits` shows unlimited. `enable` runs `flm validate` as
    `systemd-run --user --wait --pipe -p LimitMEMLOCK=infinity`. The old global drop-ins are deleted by
    `install`/`remove`. (The maintainer's machine still uses the lab's `99-npu-memlock.conf` files.)
  - **No silent downloads:** the `flm pull` refreshes in `load`/`enable` are gone. Whisper is pulled
    only after asking. A saved `FLM_LLM` that's no longer fully installed is dropped by `enable`
    (an updated model with new files shows as not installed).
  - `status --json` has `portOk` and `stale`. The card probe reports `foreign` when another UID owns
    52625 (**PORT TAKEN**). The card shows **Apply plugin update** when `install_stale`.
  - `status --json` used to crash when the proxy was stopped (variables were only set in that
    branch); fixed.
  - The CLI exports `no_proxy` for 127.0.0.1, the probe uses `curl --noproxy '*'`, and `chat.py` uses
    `ProxyHandler({})` and strips C0/C1 control characters from model output.
  - The card decodes the plugin path (`decodeURIComponent`) and quotes it twice for
    `omarchy-launch-floating-terminal-with-presentation`, which re-runs `"$*"` through `bash -c`.
- **Setup states:** when `amd-npu.service` doesn't exist, the probe asks `amd-npu setup-state`:
  `unsupported` (chip hidden), `driver`, `install`, `reboot` (`ulimit -l` isn't unlimited yet),
  `enable`, or `installed`. The card shows a short explanation, plus Set up / Finish setup / Check
  buttons that open `amd-npu install|enable|check` in a floating terminal. To screenshot a state,
  temporarily prefix the installed copy's `probe` with `echo <state>; exit;`, restart the shell, then
  copy the repo's `Widget.qml` back.
- **Testing the countdown without typing into a window:** `voxtype record start`, screenshot,
  then `voxtype record cancel` (discards). For the "Transcribing..." state, `voxtype record stop`,
  screenshot within ~0.3 s, then `cancel`; check the journal says "Transcription cancelled". To see
  the warning state, temporarily lower `max_duration_secs` in the file. The card re-reads it, but
  the running daemon keeps its old limit until restarted, so it won't auto-stop and type. To test
  placement, add a temporary `[osd]` block (`top_margin = 0.5`; `position = "top-center"` with
  `top_margin = 0.05`; `position = "bottom-right"`), restart Voxtype, then `record start` and
  `cancel`, and restore the file.
- **`lib/proxy.py` runs from `~/.local/share/amd-npu/`**, not the repo: re-run `amd-npu enable` after
  changing it.

## Commits

Branch + PR, like the other repos in `~/Github/my-projects`, with merge commits (`gh pr merge --merge
--delete-branch`). The maintainer has OK'd merging PRs for this repo. Before pushing, check that
nothing personal is in the diff: no home-directory usernames, tokens or emails beyond the git author.
Commit messages end with the Co-Authored-By line for Claude.
