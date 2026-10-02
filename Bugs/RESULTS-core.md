# RESULTS-core: test of the core commands (BUG-100 .. BUG-199)

Tester: Claude (sub-agent "core"), 2026-10-02 11:50-12:35, commit `50cee52` (Python code identical to `6dedd96`), Windows 11 Pro, Python 3.14.3,
game running but **paused and never un-paused** (DF 53.16 + DFHack, fort "Windrings", `27. Granite, Jahr 118`, pop 174, 5 hostile thieves on the map, `pause.hold`=`alarm`).

How the variants were run
- **Mock**: `--mock fixtures/run5` (plus patched copies of it, `fixtures/run5_live` = "nothing readable", garbage fixtures) always with an isolated runtime (own `DF_LLM_HELPER_HOME` or temp `--config`).
- **Live**: real `config.yaml`, **read-only/`--dry-run`** commands against the running game (`digest`, `check --dry-run`, `cycle --dry-run`, `autopilot --dry-run`, `guard --dry-run`, `tempo status`, `heartbeat`, `overlay` (no `--send`), `wake`, `budget`, `metrics`, `record`, `plan ...`).
  Non-dry runs of `check/cycle/autopilot/guard/waechter` were done against a **private copy** of the live tools folder + `state.db` with `dfhack_run` replaced by a logging proxy that passes reads to the real game and **blocks every write** (every command was logged; no write reached the game).
  Not run live on purpose: `waechter` (a step erases popups / may `advance run`, `alert on`), `tempo on/off`, `guard ack-gate`, `autopilot enable`, `overlay --send`, any `--loop`.
- **Edge cases**: wrong/missing arguments, empty input, unknown names, 20 000-character text, `ä ö ü ☼`, paths with spaces and non-ASCII, unreadable game, garbage/BOM/truncated fixtures, concurrent runs (6 parallel `check`: no lock error), second run of every command.
- Side effects on the real installation caused by this test (all expected function of the commands): `dwarf-fortress/tools/heartbeat.txt` refreshed by `heartbeat`; `dfpilot-public/data/state.db` got digest/KPI rows and `wake.state` (see BUG-103: my own mistake reset `wake.state.events_n`, self-healed by the next `wake`). No flag file, `pause.hold`, game setting or game state was changed by me; the game stayed paused.
- Evidence for every bug: `Bugs/evidence/BUG-<n>/` (`repro.py` + `output.txt`, shared helper `Bugs/evidence/core_helper.py`).

Legend: ok = no finding, BUG-n = finding (see file). "n/a" = not applicable / not allowed.

| Command | Mock | Live | Edge cases | Result |
|---|---|---|---|---|
| `digest` | ok | ok (numbers checked against `claude/status`, `claude/report`, `claude/essen`, `claude/mood status`: pop, adults, idle %, drink/food days, hunger list, danger, flags all plausible) | scope/inbox/bus/new-game/garbage fixtures: no traceback | BUG-102, BUG-104, BUG-111, BUG-112, BUG-117 |
| `digest --full` | ok | ok | repeat 2x ok | ok |
| `digest --scope <s>` | ok | ok | unknown scope, empty, `ä ö ü ☼`, 20 000 chars | BUG-117 (F), BUG-120 |
| `check` | ok | ok (private copy, writes blocked) | unreadable game, missing config query | BUG-105, BUG-106, BUG-117 |
| `check --dry-run` | ok | ok | repeat | BUG-117 (B) |
| `cycle` / `cycle --dry-run` | ok | ok | | BUG-117 |
| `autopilot` (run) | ok (loop protection 7x/h works, `enable` re-arms) | ok (dry + private copy) | | BUG-117 (D), BUG-124 |
| `autopilot rules` / `conflicts` | ok | ok | extra args | ok |
| `autopilot enable <id>` | ok | n/a | missing / unknown / `ä☼` id | BUG-114 |
| `autopilot --loop` | 3 s bounded mock run | n/a | `--interval x` | BUG-124, BUG-113 |
| `guard` / `guard --dry-run` | ok (deadman 20 min -> fps 30 -> back < 10 min, hysteresis ok) | ok (dry; private copy) | no heartbeat, unreadable game | BUG-105, BUG-106 |
| `guard ack-gate N` | ok | n/a (changes a decision) | missing / negative / unknown gate | BUG-114 |
| `guard --loop` | 3 s bounded mock run | n/a | | BUG-124 |
| `waechter` (one step) | ok via `--replay-file` (ambush/siege flags, pause.hold, caravan, low food, report-id reset, popup focus) | ok on private copy with read-only proxy (no new reports; would send popup-erase only) | DF unreadable | BUG-106 (silent, alive refreshed) |
| `tempo status` | ok | ok | DF unreadable | BUG-106 |
| `tempo on` / `off` (+ `--dry-run`) | ok (mock only; blockers, pop gates, ack) | n/a (not allowed) | DF unreadable | BUG-106 |
| `heartbeat` | ok | ok | path with spaces/umlauts ok; tools path = file / bad drive / 300-char path | BUG-113 |
| `wake` | ok (flags, text change, re-creation, noise/dedupe, crit warnings, mojibake, BOM) | ok (printed ~100 old events after my BUG-103 mistake) | `events.log` > 5000 lines, rotated log, huge flag text, flag = directory, no tools dir | BUG-100, BUG-112, BUG-116, BUG-103 |
| `wake --emit-existing` | ok (first run only, as documented) | n/a | | ok |
| `overlay` | ok | ok (no `--send`) | quotes, `$()`, backslash, 500 chars, multi-line, empty | BUG-101, BUG-112 |
| `overlay --send` | ok (mock write, de-dupe 10 min works) | n/a | | BUG-101 |
| `replay` (all 10 scenarios, `-v`) | ok | n/a | missing file, directory, empty file, bad JSON | BUG-113 |
| `record` | ok (append mode, parent dirs created, fair-play block `createitem`) | ok (default read list, temp file) | path with spaces/`ä☼`, no commands, long text | BUG-119 (OVERVIEW form) |
| `budget` | ok | ok | budget values: 100 / huge / abc / -5 / 0 / '' / 1.5 | BUG-121 |
| `metrics` / `metrics --out` | ok | ok | `--out` missing dir / directory / unicode path | BUG-121, BUG-104, BUG-113 |
| `plan blueprint` | ok (10 ok + 10 bad files match EXPECTED except E_BOUNDS) | ok on all 475 real blueprints (402 ok, 32 false errors) | no files, missing file, directory | BUG-109, BUG-110, BUG-113, BUG-114 |
| `plan trade` | ok (arithmetic verified by hand) | n/a (needs hand-made JSON) | empty/negative/bad ratio/list root/missing fields | BUG-123, BUG-113, BUG-112 |
| `plan dig` | ok | ok (`claude/area` plausibility checked) | bad targets, `--picks 0/x`, missing file | BUG-113, BUG-114 |
| `plan armor` | ok | ok | `--bars` malformed/negative/huge | BUG-107, BUG-114, BUG-106 |
| `plan supply` | ok | ok (drink 49 d = status) | negative/huge/bogus | BUG-108, BUG-114, BUG-106 |
| `--help` of all 15 core commands | ok | n/a | | BUG-120 |
| README/MANUAL/OVERVIEW examples (check, runbook diagnose, dashboard, selftest --quick, record, ...) | ok | n/a | | BUG-119 |
| `selftest --quick` / `selftest` | ok (GREEN 0.7 s; no pytest -> exit 0 without verdict) | n/a | `--bogus` | BUG-119 |
| global `--config` / `--mock` / `--replay-file` handling | ok | n/a | missing config, dir as config, wrong types, mock + config, mock folder missing | BUG-103, BUG-104, BUG-113, BUG-120 |

Bug list (22): S2: 100, 101, 102, 103, 104, 105, 106, 107, 109, 111, 112, 113. S3: 108, 110, 114, 116, 117, 119, 120, 121, 123, 124.

Only verifiable with a running game / by Gordon locally: see `Bugs/TESTPLAN-live-core.md`.
