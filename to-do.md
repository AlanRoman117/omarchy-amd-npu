# To do

## Before announcing it
- [ ] Test on at least one more XDNA2 machine (Strix Point laptop, Framework 13 AMD AI 300, …).
- [ ] Test a clean install end to end: `install` → reboot → `enable` on a machine with no earlier setup.
- [ ] Decide whether the plugin id keeps the `alanroman117.` prefix.

## Upstream idea
- [ ] Post to Omarchy Discussions → Suggestions: an NPU option in `omarchy voxtype install`,
      plus an `omarchy-hw-amd-npu` detection helper. Link this repo as the working proof, with the
      measured numbers.

## Own machine
- [ ] Optional: move the Z13 from the broad memlock drop-ins it was first set up with
      (`/etc/systemd/{system,user}.conf.d/99-npu-memlock.conf`,
      `/etc/security/limits.d/99-npu-memlock.conf`) to this repo's narrower
      `user@.service.d` version. Reboot and verify `flm validate`.

## Hardening (optional, from the 2026-09-30 security review)
- [x] 0.3.0: FastFlowLM on browser-blocked port 6669 behind `lib/proxy.py` on 52625 (refuses
      foreign origins, bad `Host`, plain-text bodies, missing models; strips CORS), and its models
      dir read-only. Supersedes 0.2.1's `--cors 0`, which FastFlowLM 1.0.4 only half honours.
- [ ] **For later, report upstream** (FastFlowLM 1.0.4):
      - with `--cors 0` it still sends `Access-Control-Allow-Origin: *` on every response and parses
        `text/plain` bodies as JSON. Fix: no CORS headers with `--cors 0`, and require
        `Content-Type: application/json`.
      - a request naming a catalog model triggers a download; when the download fails (e.g. a
        read-only models dir), the server hangs and stops answering everything, Whisper included.
        Fix: refuse unknown or missing models with an error, or add an opt-out of request-triggered
        downloads.
- [ ] Ask FastFlowLM upstream for an API key / token on `flm serve` (1.0.4 has none), so other
      local processes can't use the server. The proxy now checks `Host` (DNS rebinding) and could
      also require a token once Voxtype and `amd-npu` send one.
- [ ] Multi-user machines: another account could bind 52625 while the service is down and
      receive dictation audio. Only matters if multi-user setups become a supported case.

## Local models: ideas
- [ ] Dictation priority in share mode: FastFlowLM runs one request at a time, so a long LLM answer
      delays dictation. Options: ask FastFlowLM upstream for request priority, or have `amd-npu`
      switch Voxtype to the CPU model while an answer is streaming.
- [ ] More measured models for the README (`gemma4-it:e4b`, `qwen3.5:2b`, `lfm2.5-it:1.2b`,
      `gpt-oss:20b`).
- [ ] Context length picker in the card (`--ctx`); today it's CLI-only.
- [ ] Embeddings (`embed-gemma:300m`, `--embed 1`) for local RAG tools.
- [ ] `status`: show NPU utilisation when FastFlowLM exposes it.
