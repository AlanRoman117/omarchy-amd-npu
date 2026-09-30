# NPU Dictation for Omarchy

Run Omarchy's dictation (Voxtype) on the **AMD XDNA2 NPU** instead of the CPU or GPU. Whisper
large-v3-turbo runs on the NPU through [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM).
Voxtype sends its audio there, and a small bar widget shows whether the NPU server is up.

Why bother: most Ryzen AI laptops have a 50 TOPS NPU sitting idle. Putting speech-to-text on it:

- gives you **large-v3-turbo quality** instead of the small `base.en` model Voxtype would run on the
  CPU
- leaves the CPU and GPU free. A local LLM on the iGPU keeps its speed while you dictate.

## Measured on a ROG Flow Z13 (Ryzen AI MAX+ 395, Omarchy 4)

| | |
|---|---|
| Dictation (hold F9, speak, release) | ~2.7 s from release to typed text |
| 3 min 19 s recording | transcribed in 34.9 s (**5.7× faster than real time**) |
| CPU / GPU while transcribing | 1–2% / 1% |
| LLM on the GPU (Gemma 4 26B-A4B) while the NPU transcribes | 57.2 → 56.1 tok/s (−2%) |
| Server memory | ~440 MB |

## Requirements

- **An AMD XDNA2 NPU:** Ryzen AI 300 (Strix Point), Ryzen AI MAX (Strix Halo), Krackan Point or
  Gorgon Point. Older XDNA1 NPUs (Phoenix, Hawk Point) aren't supported by FastFlowLM, and
  `npu-dictation check` says so.
- **Omarchy (Arch)** with a kernel that has the in-tree `amdxdna` driver (6.14+) and NPU firmware
  ≥ 1.1.0.0 (from `linux-firmware-other`).
- **Voxtype**, for dictation: `omarchy voxtype install`. The NPU server also works on its own for
  transcribing files.

**Tested so far on one machine only: ROG Flow Z13 GZ302EA.** Reports from other XDNA2 laptops are
welcome.

## Install

```bash
# 1. The bar widget (an Omarchy shell plugin; lands disabled so you can review it)
omarchy plugin add https://github.com/AlanRoman117/omarchy-npu-dictation.git --enable

# 2. The NPU runtime (sudo), then reboot
~/.config/omarchy/plugins/alanroman117.npu-dictation/bin/npu-dictation install

# 3. After the reboot: download Whisper, start the NPU server, point Voxtype at it
~/.config/omarchy/plugins/alanroman117.npu-dictation/bin/npu-dictation enable
```

Then **hold F9** (or **Super + Ctrl + X**) to dictate, as usual.

Omarchy's plugin installer never runs code or sudo, which is why steps 2 and 3 are separate
commands you run yourself.

## Commands

| Command | What it does |
|---|---|
| `npu-dictation check` | Is this machine supported, and what's installed? |
| `npu-dictation install` | Installs `xrt`, `xrt-plugin-amdxdna` and `fastflowlm`, and lifts the memlock limit for your user session (sudo; reboot after) |
| `npu-dictation enable` | Downloads Whisper (620 MB), starts `flm-asr.service`, and switches Voxtype to it (backs up the config first). Safe to re-run. |
| `npu-dictation status` | Service, server, model, firmware, Voxtype backend, last dictation time (`--json` for scripts) |
| `npu-dictation ping` | Quiet live request: `ok <seconds>` or `fail <code>` (used by the card's Test button) |
| `npu-dictation doctor` | `status` plus a live transcription request |
| `npu-dictation disable` | Voxtype back to its local model; stops the server and frees the NPU |
| `npu-dictation remove` | `disable` + delete the service; asks before deleting the model, packages and memlock settings |

## The bar widget

A chip icon on the right of the bar: bright when the NPU server is up, dimmed when it's stopped,
hidden when it isn't set up. Click it for a card in the same style as Omarchy's Wi-Fi, Bluetooth and
power panels:

- **Header:** state (READY / LOCAL MODEL / STOPPED) and how long your last dictation took.
- **Dictate on the NPU:** a switch. On runs `npu-dictation enable`; off runs `npu-dictation disable`,
  which puts Voxtype back on its local model and frees the NPU.
- **Details:** model, NPU firmware, server address, Voxtype backend.
- **Test NPU:** sends a live request and shows the result in the card. **Full status** opens the
  terminal view.

Recording and transcribing are already shown by Omarchy's built-in dictation indicator, so this
widget doesn't repeat them.

## What it changes on your system

- **Packages:** `xrt`, `xrt-plugin-amdxdna`, `fastflowlm` (all from Arch `extra`).
- **Memlock:** the NPU runtime needs unlimited locked memory. This is scoped to your user session:
  - `/etc/systemd/system/user@.service.d/90-npu-dictation-memlock.conf`
  - `/etc/systemd/user.conf.d/90-npu-dictation-memlock.conf`
  - `/etc/security/limits.d/90-npu-dictation-memlock.conf`
- **Service:** `~/.config/systemd/user/flm-asr.service` (`flm serve --asr 1` on `127.0.0.1:52625`).
- **Model:** `~/.config/flm/models/Whisper-V3-Turbo-NPU2/`.
- **Voxtype config:** in `~/.config/voxtype/config.toml`, `[whisper]` gets `backend = "remote"` and
  `remote_endpoint = "http://127.0.0.1:52625"`. The endpoint has no `/v1`; Voxtype adds it.

## Good to know

- **The server holds the NPU exclusively.** To use the NPU for something else (for example an LLM
  through `flm`), run `npu-dictation disable` or `systemctl --user stop flm-asr` first.
- **If the server is stopped, dictation fails** until it's started again or you run
  `npu-dictation disable`, which puts Voxtype back on its local model.
- **Don't force NPU firmware versions or install `amdxdna-dkms`** on a current kernel. A mismatch
  can make the NPU disappear.
- The server listens only on `127.0.0.1`.

## Uninstall

```bash
~/.config/omarchy/plugins/alanroman117.npu-dictation/bin/npu-dictation remove
omarchy plugin remove alanroman117.npu-dictation
```

## Licences

This repo is MIT. FastFlowLM's orchestration code is MIT, and its NPU kernels ship under
FastFlowLM's own free-to-use binary licence (installed from Arch's `extra` repo, not bundled here).
Whisper is OpenAI's model (MIT).
