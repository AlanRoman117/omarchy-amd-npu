-- Written by the AMD NPU card (alanroman117.amd-npu): F9 toggles dictation instead of push-to-talk.
-- Tap F9 to start recording, tap it again to stop. To go back to holding F9, switch it in the card,
-- or run `amd-npu f9 hold` (or delete this file and run `hyprctl reload`).
hl.unbind("F9")
o.bind("F9", "Toggle dictation (AMD NPU card)", "voxtype record toggle")
