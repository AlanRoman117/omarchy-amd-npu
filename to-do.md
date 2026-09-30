# To do

## Before going public
- [ ] Conversations first: decide whether this should be public, and in what form.
- [ ] Test on at least one more XDNA2 machine (Strix Point laptop, Framework 13 AMD AI 300, …).
- [ ] Test a clean install end to end: `install` → reboot → `enable` on a machine with no earlier setup.
- [ ] Screenshots of the widget states for the README.
- [ ] Decide whether the plugin id keeps the `alanroman117.` prefix.

## Private-repo install (verified 2026-09-30)
- `omarchy plugin add https://github.com/AlanRoman117/omarchy-npu-dictation.git --enable --yes`
  works on the Z13 while the repo is private. `git clone` authenticates through the `gh auth
  git-credential` helper, and Omarchy's installer disables password prompts.
- [ ] The helper in `~/.gitconfig` points at a versioned mise path
      (`.../mise/installs/gh/2.100.0/...`). After a `gh` upgrade, run `gh auth setup-git` again or
      private installs and updates will fail.

## Upstream idea (after it's public)
- [ ] Post to Omarchy Discussions → Suggestions: an NPU option in `omarchy voxtype install`,
      plus an `omarchy-hw-amd-npu` detection helper. Link this repo as the working proof, with the
      measured numbers.

## Own machine
- [ ] Optional: move the Z13 from the broad memlock drop-ins it was first set up with
      (`/etc/systemd/{system,user}.conf.d/99-npu-memlock.conf`,
      `/etc/security/limits.d/99-npu-memlock.conf`) to this repo's narrower
      `user@.service.d` version. Reboot and verify `flm validate`.

## Maybe later
- [ ] `status`: show NPU utilisation when FastFlowLM exposes it.
- [ ] Offer a small LLM on the NPU alongside Whisper (`flm serve <llm> --asr 1`) as an opt-in.
