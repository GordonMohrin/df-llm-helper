# Retest 2026-10-02 (HEAD 8e67f05): knowledge base / kb / runbook / brief / agents / journal / docs (BUG-300 .. BUG-330)

Method: every reproduction was re-run against the mock (`--mock fixtures/run5`), `--replay-file` and the evidence inputs in a throw-away `tmp_bug/` folder; nothing touched the live game. 31 bugs retested (there is no BUG-323).

| Bug | Verdict | Note |
|---|---|---|
| 300 | fixed | `runbook show` prints Params / Preconditions / Rollback; abort lists rendered rollback; `run --dry-run` of rb01b works (needs `--param item_ids=`, header `NOT approved`) |
| 301 | fixed | all 12 commands give exit 2 usage errors (unknown map exit 1). Cosmetic: `kb import` prints each per-file message twice (file list is passed twice, `args.query` + `args.files`) |
| 302 | fixed | no tracebacks; exit 2 (journal ingest dir: exit 1). Same cosmetic duplicate line for `kb import` |
| 303 | fixed | utf8 / BOM / UTF-16 / cp1252 file and stdin all `ok` |
| 304 | fixed | Fair Play / Commands / Report once, single format; long task marked `[task shortened: 400 of 769 characters]` |
| 305 | fixed | table column, total and "stuck?" warning use the same figure (429239 etc.) |
| 306 | fixed | `(dry-run) ... would restore`, file size unchanged |
| 307 | fixed | umlauts survive, no U+FFFD, reported size equals file size, LF kept |
| 308 | fixed | `../victim` and `x/../../../escape` refused (exit 2), nothing written outside |
| 309 | fixed | repeat call: `nothing new ... (all lines already there)`, file stays 50 lines |
| 310 | fixed | floodgate/dodge/quota/artifact gone; magma pool is `Info`, only death + info remain |
| 311 | fixed | `../metrics.csv`, `data/exceptions.jsonl`, `cli.py` refused; `runtime/*.csv` accepted |
| 312 | fixed | stale `a.html` rewritten, `--out <dir>` -> error exit 2 |
| 313 | fixed | 0 `\r\r\n` in the page (dashboard symptom; Result.stdout normalisation is out of scope per report) |
| 314 | fixed | no `warn=None` line in events table / postmortem |
| 315 | fixed | `Exception registered: FP08 ['187405', '187429'] (in exceptions.jsonl)` |
| 316 | fixed | bad dates, FP0/L99/FP1000, junk objects, max-uses 0 all refused; date-only expiry valid through end of day |
| 317 | fixed | non-object lines, BOM, string objects, text max_uses -> `Register error: ...`, no crash, `digest` works |
| 318 | fixed | 5 of 6 evasion files flagged; `L10_hidden_somewhere_else.lua` (`.hidden` on the next line) is now intentionally NOT flagged (documented decision: hidden check within 30 before / 10 after counts); a far-away `.hidden` is flagged |
| 319 | fixed | the six files give 0 findings |
| 320 | fixed | missing path -> error finding, exit 1; UTF-16 `dig-now` detected |
| 321 | fixed | rb05 / KB point to `waechter --loop`; no `autopilot log`, no `rb01c` in docs/data; LINT-FINDINGS table matches (test matches file+rule, line numbers move) |
| 322 | fixed | MANUAL/INTEGRATION say FP09 lives in `exceptions.local.jsonl`; `lint pilot_caravan.lua` still exit 1 by decision |
| 324 | fixed | all queries except the vague `Zwerge` have the expected entry first (`Zwerge` -> hospital, accepted in the report); `Holzkohle` -> koks_brennstoff; `Bestie` -> bestie_megabestie |
| 325 | fixed | BOM runbook and BOM scopes.yaml work; a broken runbook is skipped with a message, others stay usable |
| 326 | fixed | bullets keep content after the label; `## Memory age` warning shown (J90 vs Y102) |
| 327 | fixed | `bus import` after `post --md`: 0 new, 1 already present; single message |
| 328 | fixed | `python -m df_llm_helper.selftest` ran the complete pytest suite on this machine (pytest now installed): all green, only the Lua tests skipped (no lua5.4) |
| 329 | fixed | selftest checks real-size memory (max 1147 tokens), 38 KB entries, `--cov` runs own coverage counter; GREEN. (`--cov` without pytest not re-tested, pytest is installed) |
| 330 | fixed | UTF-16 log: 2 events; non-log: WARNING `0 of 7 lines recognised ...` exit 1; bad `--date` -> `--date must be a real date YYYY-MM-DD` |

Result: 31 verified fixed, 0 reopened, 0 live-only. Note: BUG-305's open player question (is `usage.output_tokens` the real total) and BUG-328's request to install lua5.4 and run the Lua tests on Windows remain player-side checks.
