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
- [ ] Consider `--cors 0` in the unit. FastFlowLM enables CORS by default, so a web page can call
      the server and read the answers. Voxtype, `amd-npu` and server-side clients don't need CORS,
      but browser-only chat UIs would stop working.
- [ ] Ask FastFlowLM upstream for an API key / token on `flm serve` (1.0.4 has none), so other
      local processes can't use the server. If it lands, set it in `server.env` and pass it from
      Voxtype and `amd-npu`.
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
