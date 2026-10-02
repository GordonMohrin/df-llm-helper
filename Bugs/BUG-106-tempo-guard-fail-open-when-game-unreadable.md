# BUG-106: with an unreadable game `tempo status` / `guard` / `tempo on` say "no blockers, time lapse allowed" (fail-open); `plan armor/supply` print zeros as real results

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S2
- **Area:** `df_llm_helper/cli.py:229-257` (`cmd_tempo`), `df_llm_helper/guard.py:84-100` (`tempo_blockers`) and `GuardRunner.inputs` (`getattr(snap, "drink_days", None)` etc.), `df_llm_helper/cli.py:629-652` (`plan armor/supply`)
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3; repro with an empty mock (every `claude/*` query fails, like a dead `dfhack-run`); the same appears with a wrong `dfhack_run` path (`Status ?` / `Query failed: ... dfhack-run not found`)

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-106/repro.py      # temp folder, mock only
```
(`heartbeat` first, so the supervision blocker is gone; then every query fails.)

## Expected
If the snapshot could not be read (`Query failed`), the time-lapse decision must be **refused** with a blocker such as `no_data`/`game_unreadable`, `tempo status` must say `unknown`, and `plan armor/supply`
must say `no data (query failed)` instead of computing with 0.

## Actual
```
$ digest                  ->  Status ?  /  !! Query failed: claude/status: no fixture for 'claude/status' (check DF/dfhack-run)
$ tempo status            ->  Time lapse: off, fps ? (normal ?), running
                              Guard: no blockers, 'tempo on' would be allowed
$ guard                   ->  Target fps 100, time lapse allowed: True
$ tempo on --dry-run      ->  [dry] claude/tempo on (no blockers)
$ tempo on                ->  Time lapse on (claude/tempo on)
$ plan armor              ->  Quota 0 soldiers (now 0, missing 0); bars needed 0, available 0, missing 0
$ plan supply             ->  drink: stock 0, no shortage within the horizon / food: stock 0, no shortage within the horizon
```
Every blocker input (`drink_days`, `food_days`, `danger`, `moods`, `caravan_active`, `pop`) is `None`/`False` when the snapshot failed, so none of the blockers fires. Against the real game, `claude/status` timing
out while `claude/tempo on` still works (game busy, one script slow) would switch time lapse on blind. `plan supply` printing "no shortage" with stock 0 is the opposite of the truth.
Also visible: `fps ? (normal ?), running` - an unknown pause state is shown as "running".

Same family (`waechter`, one step, game unreadable): no output, exit 0, but `out/waechter.alive` is refreshed first (`waechter.py` `step()` -> `_alive()` before any query), so `guard` afterwards no longer says "Watcher is not running" - a watcher that cannot see the game counts as alive.
Expected: `Watcher error: cannot read reports (dfhack-run not reachable)` on stderr, exit 1, and no alive refresh when the very first query failed.

## Evidence
`Bugs/evidence/BUG-106/repro.py`, `Bugs/evidence/BUG-106/output.txt`.

## Analysis (reporter's hypothesis)
`snap.failed` already lists the failed commands (the digest uses it for `Query failed`). `tempo_blockers`/`GuardInputs` ignore it. Add a blocker (e.g. `"no_data"` when `snap.failed` contains `claude/status` or `claude/report`,
or when `drink_days`/`food_days` are `None`), print `unknown` in `tempo status`, and make `plan armor/supply` return exit 1 with `no data` when `snap.pop_total is None`.

## Suggested fix (optional)
See above; add a test with an empty `MockClient`.

## Info needed
Cloud session: should `waechter` not running / `events.log` stale (the guard warns about them) also block `tempo on`? In time lapse nobody pauses on an ambush if the watcher is down; MANUAL section 8 lists the blockers (deadman, danger, mood, caravan, supplies, no supervision, pop gate) but not the watcher.

## Fix
Fail closed: `GuardInputs.no_data` (snapshot missing, `claude/status` failed or no population) adds the tempo blocker `no_data` (`tempo on` refused, `guard` says not allowed); `tempo status` prints `unknown`/`pause state unknown`; `plan armor/supply` print `Error: no data from the game ...` and exit 1; `waechter` raises `cannot read reports` (exit 1 in one-step mode) and refreshes `waechter.alive` only after a successful report query. Not done: blocking `tempo on` when the watcher is down (Info question left to Gordon). Tests: `test_bug106_*`.
