# Incident log — why tts-guard exists

Production workflow: daily short-form narration videos with AI-synthesized
Mandarin voice-over. Three slow-speech incidents in one week, all with the
same signature: the whole take uniformly ~2× too slow, no silence, no error
reported by the TTS engine.

| Date | Text | Expected | Actual | Outcome |
|---|---|---|---|---|
| 2026-10-11 | narration take | normal rate | ~2× slow | bad video shipped, re-made |
| 2026-10-15 | narration take | normal rate | ~2× slow | bad video shipped, re-made |
| 2026-10-17 | narration take | normal rate | ~2× slow | caught in production |
| 2026-10-19 | 281 chars | ≈ 62 s (4.5 chars/s) | 132.12 s (2.13 chars/s) | see below |

## The 2026-10-19 lesson

The guard initially *missed* the 132-second take. Root cause: the character
counter used `wc -m` under the C locale, where it counts **bytes**, not
characters. Mandarin characters are 3 bytes in UTF-8, so the expected
duration was inflated 3× and a 2× slowdown stayed under the alarm threshold.

Fix: force `LC_ALL=C.utf8` inside the counter. Verified after the fix:
132.12 s > 1.8 × expected (62.5 s) is correctly flagged, and a normal
62.30 s take passes.

Takeaway: a duration-based guard is only as good as its character counting —
and CJK text is exactly where byte/character confusion happens.
