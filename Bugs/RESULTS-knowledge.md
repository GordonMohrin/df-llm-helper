# Test results: knowledge / agents / reports / fair play (tester "knowledge", BUG-300..330)

Commit `50cee52` (code identical to `6dedd96`), Windows 11, Python 3.14, 2026-10-02. Game: running, **paused the whole time, nothing written to it**
(live = read-only queries of the real fort, fort date Y118 Granite 27). Mock = `--mock fixtures/run5`. All state/outputs went to temp folders
(own `state.db`, scopes copy, data copy); the real exception registers, `data/state.db`, `runtime/` and the game folder were not changed.
Legend: ok = works as documented; n/a = not meaningful live / not applicable; BUG-NNN = see `Bugs/BUG-NNN-*.md`.

| Command | Mock | Live | Edge cases | Result |
|---|---|---|---|---|
| `runbook list` | ok (19) | ok | extra arg ignored; YAML with BOM/CRLF/tab file | ok; BOM -> BUG-325 |
| `runbook show <id>` (all 19) | ok | n/a | unknown id, no id (`Unknown runbook: None`), upper case, prefix, `ä☼` | BUG-300 (params/preconditions/rollback not shown), BUG-301 (message), BUG-321 (rb05 old watcher, rb01c), rb06 steps 7/8 identical on purpose |
| `runbook diagnose` | ok (4 hits) | ok (5 hits, rb19 verified correct: 10 of 12 repeat-util jobs really stopped) | - | ok |
| `runbook run <id> --dry-run` (all 19) | ok | ok (8 runbooks incl. rb19/rb08/rb07/rb04/rb20/rb09/rb10) | missing/`x`/`=5` params, `--param x`, `ä☼` value, consent-gated rb01b refused with exit 1 | BUG-301 (`--param x`), BUG-300 (rb01b cannot be previewed) |
| `runbook run <id>` (no dry-run) | ok (mock only; fails on missing fixture with "Aborted. Check the rollback") | not run (writes) | - | BUG-300 (rollback not shown by `show`) |
| `kb search` (~90 queries, DE+EN) | ok | ok (same data) | empty, `a`, `the`, `ä ö ü`, `☼`, 5000 chars, SQL-like text, `-k 0/1/-1/abc`, `--all` | BUG-324 (German gaps, `Holzkohle` order, no beast entry), BUG-301 (`-k -1`) |
| `kb get <id>` (all 37) | ok (<= 724 chars, < 400 tokens) | n/a | unknown id, no id, `ä☼` | BUG-301 (message) |
| `kb list [--all]` | ok | n/a | after import: unreviewed shown only with `--all` | ok |
| `kb import <md...>` | ok (temp data dir) | n/a | CRLF, cp1252, empty, binary, missing file, no file, path with spaces and `ä` in the name, `--files` | BUG-302 (traceback; same class as BUG-113/214), BUG-301 (binary/empty accepted, no-file silent) |
| `brief <scope>` (12 scopes) | ok (451-608 tokens) | ok (641-1165 tokens, all <= 1500) | `--budget` 100/300/700/0/-5/abc/99999, unknown scope, `BAU`, `ä☼`, `../x`, no scope; no duplicate lines in any brief | BUG-326 (label-only bullets, stale memory), BUG-301 (`--budget 0/-5`), BUG-304 |
| `agents prompt <scope> --task` | ok (12 scopes, 746-903 tokens) | ok | same task twice (refused, exit 1), `--force`, empty task, 750-char task, unknown scope, no scope | BUG-304 (duplicate/contradicting sections, silent truncation at 400 chars) |
| `agents lint-report <file|->` | ok | n/a | good, German aliases (`Ergebnis`/`Messwerte`/`Geändert`), CRLF, lower case, markdown bold/bullets, 35 lines (truncated + archived), empty, missing file, directory, stdin, UTF-8 BOM/UTF-16/cp1252, `--scope ../..` | BUG-303 (encodings), BUG-302 (traceback), BUG-308 (`--scope` traversal) |
| `agents cost [--dir] [--compare]` | ok (fixtures/subagents) | ok (128 real transcripts, 1.8 s) | missing dir, dir without transcripts, empty `--dir` | BUG-305 (Out~ vs warning) |
| `memory compact <scope|all> [--dry-run]` | ok (copy of the 27 live memory files in temp) | ok (`--dry-run` only, real files untouched) | idempotent re-run, CRLF, BOM, empty file, cp1252, unknown scope, `../x`, no scope | BUG-307 (cp1252 corruption, size misreport), BUG-308 (traversal) |
| `memory restore <scope|all>` | ok | not run | `--dry-run` (restores anyway!), no archive, byte-identical restore verified | BUG-306 |
| `bus post / read / ack` | ok (temp state.db) | ok (temp state.db) | dedupe `--key` (x2), prio guess (KRITISCH, `stirbt`), explicit prio, `ä☼` names, empty text, no `--from`, no `--to`, bogus prio, `ack` abc/999, `--limit 0/-1` | BUG-301 (empty text, default sender, negative limit) |
| `bus import [files]` | ok (CRLF inbox, 4 lines; idempotent) | ok (read of the real 13 inbox files: 299 messages, into temp db) | missing file, unparsable lines | BUG-302 (traceback), BUG-327 (`--md` round trip duplicates) |
| `bus post --md` | ok | n/a | umlauts, CRLF line written | BUG-327 |
| `journal ingest [--events --date]` | ok (fixtures/run5_live/events_run3.log: 318 events, idempotent) | ok (real `events.log`: 306 events, into temp db) | `--date` empty/dotted/month 13, missing log, directory, empty, UTF-16, CRLF, garbage file | BUG-330 (UTF-16/garbage silent, raw date error), BUG-302 (directory traceback) |
| `journal chronik [--append]` | ok | ok | append twice | BUG-309 (duplicates), BUG-310 (misclassification) |
| `journal lessons [--accept]` | ok (2 lessons; accept writes KB draft to temp) | ok | unknown key, accept twice | ok |
| `journal metrics [--out]` | ok (header + 1 row after `check`) | ok (header only: temp db has no KPI rows) | `--out` outside / `../metrics.csv` | BUG-311 |
| `journal postmortem [--out]` | ok | ok | `--out` outside / `../POSTMORTEM-runN.md` / `data/exceptions.jsonl` (throw-away copy) | BUG-311, BUG-314 (`guard/warn=None`) |
| `dashboard [build] [--out --offline]` | ok (3-7 KB, balanced HTML, no external resources, escaped names, light/dark CSS, < 200 KB) | ok (2-3 KB; reads `claude/buildings` only) | default path, `--out ""`, new nested dir, file already current, directory as `--out`, stale second file | BUG-312 (stale file / directory reported "unchanged"), BUG-314 |
| `dashboard map <name> x y z w h` | ok | ok (10x6 read at z130) | name with `ä☼ <b> & "`, too few args, non-numeric, size 0 / negative / 500x500 (the Lua clamps to 100) | BUG-313 (live CRLF -> `\r\r\n` in the page), BUG-301 |
| `dashboard unmap <name>` | ok | ok | unknown name, no name (silent) | BUG-301 |
| `exception list` | ok | ok | BOM/CRLF register, broken JSON line, missing fields, non-object line | BUG-317 (crash on `[1,2]`, BOM, string `objects`, text `max_uses`) |
| `exception add <rule> ...` | ok (temp register only) | n/a | no rule, `fp08`/`FP8`/`FPxx`/`FP1000`/`L99`/`FP0`/`FP08;rm`, no/blank `--ja`, expires in 9 formats, `--max-uses` 0/-1/abc/1.5/2, objects with blanks/umlauts, quotes/umlauts in the consent text | BUG-315 (prints wrong entry), BUG-316 (invalid dates/ids accepted) |
| `lint <paths>` L01-L30 (146 cases, LF and CRLF) | ok (30 rules, direct forms all detected) | n/a | block comments, `--[==[`, long strings, `--` in strings, escaped quotes, BOM, CRLF, cp1252, UTF-16, upper-case `.LUA`, spaces/umlauts in path, missing file/dir, no path, empty file | BUG-318 (6 evasions), BUG-319 (6 false positives), BUG-320 (missing path exit 0, UTF-16) |
| `lint lua/` and live `dwarf-fortress/lua/claude` (read only) | ok (6 findings: 5x L10 warning, `pilot_caravan.lua:21` L07 error as documented) | ok (62 live files; same 6 findings, `mood.lua:214` instead of 213) | - | BUG-321 (`LINT-FINDINGS.md` stale: mil.lua:297, raster.lua:106), BUG-322 (exit 1 by the documented finding) |
| `python -m df_llm_helper.selftest [--quick] [--cov]` | ok (9 quick checks green, 0.7 s) | n/a | `--bogus`, `--cov` without pytest | BUG-329 (new points); exit code / durations: already BUG-119 item 3 |
| `tests/` (2040 tests, mini pytest stand-in `Bugs/evidence/BUG-328/mini_pytest/`) | 2014 pass, 4 fail, 22 skip | n/a | clean checkout without `config.yaml`; tmp dir with a space | BUG-328 (4 red = test portability, none is a product error; 22 skipped need `lua5.4`) |
| Documentation check (README, COMPANION, MANUAL, OVERVIEW, AGENT-PROMPT, INTEGRATION, manual-v3, specs) | 159 `python -m df_llm_helper <cmd> <sub>` mentions run with `-h`: all exist except `autopilot log`; 247 file references checked | n/a | rename leftovers: `grep -i dfpilot`, `dfpilot/` folder, `__pycache__`, config keys, Lua texts, help texts | BUG-321, BUG-322; Python 3.11/3.12, selftest timing, `df-llm-helper/` folder name, `dfpilot/` leftover folder, `LINT-BEFUNDE.md`: already BUG-119 (not repeated). Old-name hits: only `CHANGELOG`, the README note, the `DFPILOT_HOME` fallback, the ignored `dfpilot/__pycache__` and old rows in `state.db`; none in Lua output, help texts or config keys |

## Duplicate check against the other testers' reports
- Merged into existing reports instead of new ones: Python version / selftest duration and exit code / `LINT-BEFUNDE.md` / leftover `dfpilot/` folder -> **BUG-119**; the `lint lua` exit 1 caused by the shipped register -> **BUG-418** (BUG-322 adds only the MANUAL claim).
- Same root cause as, but different commands than: **BUG-113 / BUG-214** (tracebacks, my BUG-302), **BUG-114** (argument validation, my BUG-301).
- Number BUG-323 is intentionally unused (its content was already BUG-119).

## Not tested / limits
- `runbook run` without `--dry-run`, `memory restore` on the real memory files, `exception add` on the real registers, `trade`, `siege`, `caravan` and all other autopilots belong to other testers or write to the game.
- Lint rule L31 (water forbid_dig) is checked by `water lint-cmd` (water tester).
- 22 Lua-mock tests are skipped because `lua5.4` is not installed here (see BUG-328, "Info needed").
- Live checks were read-only; nothing was published or committed.
