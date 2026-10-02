# BUG-101: `overlay` (even without `--send`) consumes the orchestrator's digest delta, and the player display gets "No change since ..." lines

- **Status:** open
- **Severity:** S2
- **Area:** `df_llm_helper/cli.py:521-530` (`cmd_overlay`), `df_llm_helper/overlay.py:23-35` (`overlay_lines`), `df_llm_helper/pilot.py:104-127` (`digest` writes state)
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, mock `fixtures/run5` (repro) and live game (DF 53.16 + DFHack, **paused**, fort "Windrings", `27. Granite, Jahr 118`)

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-101/repro.py       # mock data + temp folder
```
By hand (mock): `python -m df_llm_helper --mock fixtures/run5 overlay` (without `--send`), then `python -m df_llm_helper --mock fixtures/run5 digest`.

## Expected
- `overlay` without `--send` is "display only" (OVERVIEW/MANUAL: "short text for claude/schau say, display only without --send"); it must not change what the orchestrator's next `digest`/`check` reports.
- When nothing changed, nothing is sent to the player (MANUAL: "no repetition within 10 min"). A line such as `No change since 12:16 (2 open: ...)` is not information for the player.

## Actual
`cmd_overlay` builds its text with `p.digest(include_warnings=False)`, i.e. the normal digest, which stores `digest.state.all`, appends a snapshot/KPI row
and marks inbox lines as seen. So after one `overlay` call the orchestrator's next report is empty:
```
$ python -m df_llm_helper --mock fixtures/run5 overlay
claude/schau say "Hunger>40k: Tekkud414=47k, Eral3473=40k" 3
claude/schau say "Caravan Muboomon: Approaching, 3055 ticks (prepare trade)" 3

$ python -m df_llm_helper --mock fixtures/run5 digest        <- the orchestrator never saw the hunger/caravan items
No change since 12:16 (2 open: Caravan, Hunger).
```
The next `overlay --send` then sends the digest's "no change" text to the player:
```
$ python -m df_llm_helper --mock fixtures/run5 overlay --send
claude/schau say "No change since 12:16 (2 open: Caravan, Hunger)." 3
```
(the live game gives the same: `claude/schau say "No change since 11:59 (14 open: Civilian alert, Danger, Drinks, Hunger, +10)." 3`; with the game unreachable it sends
`... "No change since 12:02 (1 open: Query)."`). In the control run (digest first, overlay second) the overlay is the "No change" text as well.
Because the text contains the current clock time, the 10-minute de-duplication (hash of the text) never suppresses it.

Side issue (same command): `claude/schau say "<text>" 3` is split with `shlex.split(..., posix=True)` in `RealClient._run`; a text ending in a backslash
(`Path C:\dir\`) gives `ValueError: No closing quotation` -> `Error: No closing quotation`, exit 2, nothing sent (section D of the output; only affects `--send` with a real client).

## Evidence
`Bugs/evidence/BUG-101/repro.py`, `Bugs/evidence/BUG-101/output.txt`.

## Analysis (reporter's hypothesis)
- `Pilot.digest()` always persists state (`self.store.set(key, new.to_dict())`, `add_snapshot`, `record_kpis`). `overlay` should use a read-only digest (a flag like `persist=False`) or build its lines from `snapshot` + `compute_alerts` directly.
- `overlay_lines()` falls back to the first row of the digest (`rows[:1]`) when there is no `!!`/`!` row; with a "No change" digest this is the "No change ..." text. It should return `[]` in that case.
- Related, same family: `check --dry-run` also advances the digest state (see BUG-117).

## Suggested fix (optional)
1. `Pilot.digest(..., persist=False)` for overlay; 2. `overlay_lines` ignores "No change"/"Status" rows unless explicitly asked; 3. escape/strip trailing `\` in `overlay_send` (or call `client.run` with an argument list).

## Info needed
Cloud session: should the overlay show only `!!`/`!` lines of the *current* snapshot (stateless), or "what is new since the last overlay" (own state key)? The current code mixes both.
