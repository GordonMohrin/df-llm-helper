# BUG-105: one failed `claude/config` query counts as "NEW GAME" and wipes guard acknowledgements, loop-protection state and unread warnings (twice: when it fails and when it is back)

- **Status:** fixed in 513db2e
- **Severity:** S2
- **Area:** `df_llm_helper/snapshot.py:166-170` (`Snapshot.game_id`), `df_llm_helper/pilot.py:57-70` (`_check_new_game`), `df_llm_helper/store.py:117-122` (`reset_game_state`)
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, mock `fixtures/run5` for the repro; the live game (DF 53.16 + DFHack, **paused**, fort "Windrings", `27. Granite, Jahr 118`) has `game_id = Windrings|100|263900`

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-105/repro.py       # mock + temp folder
```
1. `digest` (stores `game_id`), `guard ack-gate 60`, `guard` (creates `guard.state`), a rule marked disabled by loop protection.
2. `digest` again, but `claude/config` gets no answer (fixture without `config.txt`; live: timeout/error of that one script, `collect.timeout_s` is 40 s).
3. `digest` again with `claude/config` working.

## Expected
A failed/partial query changes nothing about the game identity. "NEW GAME" only when `fort`/embark data is *present and different*.

## Actual
`game_id` is `fort|embark[0]|embark[1]`, where `embark` comes from `claude/config`; if that query fails it becomes `Windrings|?|?`, which differs from the stored `Windrings|100|263900`:
```
! [pilot] NEW GAME detected (Windrings): counters/caches reset          <- step 2 (config failed)
   [state.db after the failed config query] game_id="Windrings|?|?"  guard.state gates_acked=<<deleted>>  rule_state=[]
! [pilot] NEW GAME detected (Windrings): counters/caches reset          <- step 3 (config is back): again
```
`reset_game_state()` deletes `snapshots`, `rule_state`, `warnings`, and all kv keys with prefix `digest.`, `guard.`, `autopilot.`. Effects in a live installation:
- acknowledged pop gates (`guard ack-gate 60/80`) are lost -> `tempo on` is refused again (and the "Pop gate reached" critical warnings reappear);
- rules that loop protection had switched off are silently re-enabled (the 6x/hour protection is reset, the warning is dropped);
- unread (crit) warnings are deleted before the orchestrator saw them;
- digest delta state is reset -> a full report; the digest shows `! [pilot] NEW GAME detected` (a wrong, alarming message for the orchestrator).
The same happens in the live game whenever `claude/config` is slow/fails once (e.g. while a heavy script runs), and again one cycle later.

## Evidence
`Bugs/evidence/BUG-105/repro.py`, `Bugs/evidence/BUG-105/output.txt` (the `state.db` lines show the wipe).

## Analysis (reporter's hypothesis)
`game_id` mixes two sources. Use only reliable data: if `snap.embark is None` (query failed) keep the old id (`game_id` should return `None` or the stored value then),
require N consecutive differing snapshots, or compare `report-id`/fort name + `max_report_id` drop (the existing `reset_report_id` logic) before wiping state.

## Suggested fix (optional)
In `Snapshot.game_id` return `None` unless both `fort` and `embark` are known; `_check_new_game` already ignores `None`. Add a test: snapshot with missing `claude/config` after a normal one must not reset.

## Info needed
Cloud session: is `fort|embark` the intended identity of a save? (A reload of an older save of the same fort keeps the same id, so "load" is detected only through the report-id drop in `reboot.detect_loaded`.)

## Fix
`Snapshot.game_id` is `None` unless fort AND embark (year, tick) are known; `_check_new_game` already ignores `None`, so a failed `claude/config` neither triggers `NEW GAME` nor wipes acks/rule state/warnings (and no second reset when it is back). Answer to the Info question: yes, `fort|embark` is the save identity; a reload of an older save is detected by `reboot.detect_loaded`. Test: `test_bug105_*`.
