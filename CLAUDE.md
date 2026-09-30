# CLAUDE.md

Context for working on this repository. Read this before changing anything.

## What this is

An Omarchy shell plugin (bar widget) plus a setup CLI that runs Voxtype dictation on the AMD XDNA2
NPU through FastFlowLM's Whisper large-v3-turbo server. **Private for now.** Going public, and
pitching it upstream to Omarchy, are later decisions; see `to-do.md`.

| Path | Role |
|---|---|
| `manifest.json` | Plugin manifest (`alanroman117.npu-dictation`, `bar-widget`) |
| `Widget.qml` | Bar icon: ready / stopped (dimmed) / hidden. IPC target `alanroman117.npu-dictation` → `refresh` |
| `bin/npu-dictation` | check / install / enable / status / doctor / disable / remove |
| `systemd/flm-asr.service` | User unit, copied by `enable` |

## How it's tested (on the ROG Flow Z13, the only verified machine)

- `bin/npu-dictation check`, `status` and `doctor` must pass.
- Round trip: `disable` then `enable`. The Voxtype config must come back byte-identical, and a second
  `enable` must create no files or backups.
- `voxtype transcribe <16 kHz wav>` must log a request in `journalctl --user -u flm-asr`.
- Widget: `omarchy plugin validate <dir>`. Stop and start `flm-asr`, run
  `omarchy-shell alanroman117.npu-dictation refresh`, and check the icon dims and brightens.
- The live mic test (hold F9) needs a human.

The installed plugin is a separate copy at `~/.config/omarchy/plugins/alanroman117.npu-dictation/`
(a git clone once installed with `omarchy plugin add`). Edits here don't reach it until you
update it.

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
- The icon is written as an ASCII escape (`\udb81\ude1a` = U+F061A, nf-md-chip). Keep `Widget.qml` ASCII.
- **Never `pkill -f` a pattern that appears in your own command line.**

## Commits

Branch + PR, like the other repos in `~/Github/my-projects`. Commit messages end with the
Co-Authored-By line for Claude.
