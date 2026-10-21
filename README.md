# tts-guard

**A slow-speech guard for AI TTS narration pipelines — detect, repair, verify.**

AI text-to-speech engines occasionally return an entire narration that is
uniformly 2–4× too slow: no silence, no error, just stretched speech. Naive
checks (file exists, audio is non-silent) all pass, and the bad audio ships —
in our case, inside finished videos that had to be re-made.

`tts-guard` wraps your TTS engine and makes this silent failure impossible to
miss:

1. **Synthesize** the full text once.
2. **Verify** — measure the audio duration with `ffprobe`. Expected duration
   ≈ character count ÷ speaking rate (default 4.5 chars/sec for Mandarin).
   If actual > expected × 1.8, the take is flagged abnormal.
3. **Repair** — split the text at sentence boundaries (。！？), synthesize
   sentence by sentence with per-sentence verification (one retry each),
   and join with 0.4 s pauses.
4. **Final check** — the joined file must match the summed duration of its
   parts within tolerance, or the script exits non-zero for a human to look.

Exit code `0` means the audio passed. Anything else means it did not — your
pipeline can stop instead of shipping a bad video.

## Why this exists

This tool was born in a real daily production workflow (short-form narration
videos, produced every day). The slow-speech failure occurred three times in
one week — see [docs/INCIDENTS.md](docs/INCIDENTS.md) for the incident log,
including a subtle locale bug (`wc -m` counting bytes instead of characters
under the C locale) that briefly hid the failure from the guard itself.

## Usage

```bash
# TTS_BIN points to your TTS CLI; adapt the synth() function in the script
# to your engine's flags (the guard logic itself is engine-agnostic).
TTS_BIN=/path/to/your-tts ./tts_guard.sh output.mp3 narration.txt

# Force the sentence-by-sentence path (useful for testing):
FORCE_SPLIT=1 ./tts_guard.sh output.mp3 narration.txt
```

Requirements: `bash`, `ffmpeg`/`ffprobe`, `python3`, and a UTF-8 locale
(`C.utf8` is enough).

## Notes

- The default speaking-rate model (chars ÷ 4.5) is calibrated for Mandarin
  narration; adjust the rate and the 1.8× threshold in the script for other
  languages or voices.
- Character counting forces `LC_ALL=C.utf8` — under a plain C locale,
  byte-counting inflates the expected duration 3× for CJK text and the guard
  goes blind. This was a real bug; it is fixed and documented.

## Roadmap

- Provider adapters (edge-tts, Piper, OpenAI TTS) behind a stable `synth()` interface
- Language presets for speaking-rate models (en / ja / ko)
- Synthetic-audio regression tests in CI

## License

MIT — see [LICENSE](LICENSE).
