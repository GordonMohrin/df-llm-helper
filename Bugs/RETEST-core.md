# RETEST-core: BUG-100 .. BUG-124 (retest 2026-10-02, HEAD 8e67f05)

Method: evidence `repro.py` scripts re-run (temp folder / `--mock fixtures/run5`), plus direct CLI checks of the "Expected" behaviour, `tests/test_planners.py`, `tests/test_digest.py`, `tests/test_metrics_cli2.py` and `-k "bug10 or bug11 or bug12"` (all green). The live game was not touched (no pause/advance/lua/trade); the only live-data access was a read-only sqlite query of `data/state.db` and a mock run with `--config config.yaml` (state.db mtime unchanged).

| Bug | Verdict | Note |
|---|---|---|
| BUG-100 | fixed | repro with 5100 filler lines now prints `WAKE critical [FEATURE_BEAST]` |
| BUG-101 | fixed | overlay (also `--send`) leaves the digest delta alone; no "No change" line is sent (second `--send`: "nothing new for the display") |
| BUG-102 | fixed | threat names readable (`Threat: Snodub Emgen "Jackalluster", Goblin Thief; Smunstu ...`) |
| BUG-103 | fixed | missing `--config` file, directory, missing `--mock` folder / `--replay-file` -> one-line error, exit 2 |
| BUG-104 | fixed | `mock_overrides("config.yaml")` returns the isolated runtime/mock paths; mock run with the real config.yaml leaves `data/state.db` untouched. Live `state.db` snapshots 1 and 4 (mock rows) are already gone. The evidence repro.py still shows a flag deletion only because its private temp config deliberately keeps its own non-live paths (by design, see report) |
| BUG-105 | fixed | failing `claude/config` keeps game_id, gates_acked and rule_state; no NEW GAME |
| BUG-106 | fixed | `no_data` blocker, `tempo status` says unknown, `tempo on` refused (exit 1), plan armor/supply exit 1. waechter: the CLI mock client fakes the report-id lua call (ok), so verified with the real client and a dead dfhack-run: `Watcher error: cannot read reports (...)`, exit 1, no `waechter.alive` |
| BUG-107 | fixed (limited) | miners excluded ("1 pick carriers not counted"), UPPER BOUND note printed; exact per-slot planning still needs a per-slot Lua output (known, in the report). Mock still plans for 5 soldiers with quota 2 |
| BUG-108 | fixed | `food: stock 72 (meals 52, fish 20, meat 0; raw plants 25 not counted)` plus note about the digest's food_days |
| BUG-109 | fixed | all 487 real blueprints in dfhack-config/blueprints/claude: 0 errors; 10 evidence samples ok; bad fixtures still exit 1 |
| BUG-110 | fixed | `--map-size 192x192` gives E_BOUNDS (exit 1); without it a note says bounds are not checked |
| BUG-111 | fixed | 4 omitted inbox lines stay unread and come with the next `digest --full`/digest; hint text is accurate |
| BUG-112 | fixed | under cp1252 `overlay "Test ☼ ok"` and `plan trade` with ☼ work; wake with ☼ prints (UTF-8) |
| BUG-113 | fixed | all 17 error cases give `Error: ...` exit 2, empty replay = FAIL (exit 1), `--interval x` rejected by argparse |
| BUG-114 | fixed | all 9 cases are errors (exit 2), no junk rows (`rule_state` empty, `gates_acked` None) |
| BUG-116 | fixed | only the 2 CITIZEN_DEATH lines wake; mojibake repaired (`îton Uristelbel`) |
| BUG-117 | fixed | A age shown (`(4h ago)`), B `check --dry-run` no longer consumes, C no "resolved" for deaths, D `verify ok`, E `dig ?`, F unknown scope error + status on first call. "Drop warnings whose source re-measured OK" intentionally not done |
| BUG-119 | fixed | docs consistent (3.11+, `--record` first, LINT-FINDINGS.md, Lua install line); error text explains global options; selftest without pytest -> `Self-test INCOMPLETE`, exit 2 (simulated by blocking the pytest import). SPEC.md:24 still says "Python 3.12+ is available" (an availability statement, not a requirement) |
| BUG-120 | fixed | 0 options without help, `--once` honoured, `--version`, `help [cmd]`, global-option hint, `--mock` missing folder/file is an error |
| BUG-121 | fixed | no duplicate row for 3 quick digests, no empty columns (tierkadaver/sawdeadbody/death/ghosthaunt filled), budget header `Bytes sent/printed`. Live `metrics` output not run |
| BUG-123 | fixed | `priorities` honoured (gem bought), friendly errors with allowed fields, skipped items named in the note, format in PLANNERS.md. `plan trade --help` itself shows only the option line + example command, the JSON example is in PLANNERS.md and the error text |
| BUG-124 | fixed | guard loop 3402 bytes, autopilot loop 154 bytes received through the pipe within 3 s |

Summary: 22 retested (BUG-115, 118, 122 do not exist), 22 verified fixed, 0 reopened, 0 live-only.
