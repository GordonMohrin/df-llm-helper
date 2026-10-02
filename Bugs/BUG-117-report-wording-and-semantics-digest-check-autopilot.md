# BUG-117: report wording/semantics problems in `digest` / `check` / `autopilot` (stale warnings without age, `--dry-run` consumes the report, deaths "resolve", verify lines identical for pass/fail, raw keys, `None`)

- **Status:** fixed in 513db2e
- **Severity:** S3 (several small items, one file; split if you prefer)
- **Area:** `df_llm_helper/pilot.py:104-127,185-186` (digest persists state, also on `dry_run`), `df_llm_helper/digest.py:117-121,255,128,278-331`, `df_llm_helper/rules.py:257-259` (`ActionRecord.line`), `rules.py:395-400` (warn key), `df_llm_helper/store.py` (`take_warnings`)
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3; mock + temp folders; item A also seen live (game paused, `27. Granite, Jahr 118`)

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-117/repro.py        # sections A-F
```

## Actual / Expected per item (`output.txt`)
**A. Queued warnings have no age.** A crit warning stored 3.5 h ago is printed as a normal current line: `!! [reach] UNREACHABLE: Well (cause unknown)`. Live: the first `digest` of the session (11:53) showed
`!! [reach] UNREACHABLE: Well (cause unknown)`, `! [mood] Mood reserve missing: bone 1/5, leather 2/3, metal 0/3 ...` (stocks are 226/260/86 now), `!! [siege] pilot_siege status not readable`, `! [tools] pickfix refused: ... (dfpilot exception add FP08 ...)` - all stored 08:07-08:45 and never shown before,
three of them obsolete by then (`reach` says Kitchens now). Expected: print the age (`(3h ago)`) and drop warnings whose source re-measured OK (or expire them after N minutes).
**B. `check --dry-run` / `cycle --dry-run` are not dry for the report.** They run `Pilot.digest()` which stores the delta state, marks inbox lines read, adds a snapshot/KPI row and `take_warnings()` marks warnings shown: after `check --dry-run` the real `check` prints no hunger/caravan/warning lines (section B). README/MANUAL only promise "no writing DF command in dry run", so this may be intended; if so say it in `--help`, otherwise add `persist=False`. (Same family, other commands: BUG-203 `--dry-run` writes warnings for `mood reserve`/`siege`/`caravan`.)
**C. Deaths "resolve" immediately.** `!! Population -2 (24->22): deaths?` appears once; the next call (pop still 22) prints `ok resolved: Losses` - a death is not resolved. The loss alert is derived from `prev_facts`, so it disappears after one report.
**D. `autopilot`/`cycle` action lines:** `stale_flag_generic: verify - -> not flags[item.name].exists` shows the *expression* but not whether the check passed (live copy: the three `service_restart: verify ...` lines are identical to passing ones although all three failed, `live_copy_autopilot_output.txt`); `drink_low_trinken: warn warn:Drinks 25 days: claude/trinken started ( -> Drinks 25 days: claude/trinken started (plants 25, empty barrels 7)` prints the internal key (`warn:<first 30 chars>`) and the text twice, and the same text a third time as `! [autopilot] ...` in the digest.
**E. `None` leaks:** `Jobs 199 (dig None, 3 digging)` and `!! Mood active: 1, None` when a value is missing (use `?`/skip).
**F. Scoped digest:** the first call for a scope, and an unknown scope (`digest --scope no_such_scope`), print `No change since last check.` although nothing was ever reported / the scope does not exist. Expected: the status line on the first call; `Error: unknown scope 'x' (known: trinken, essen, ...)`.
**G. Naming:** the flag file `pause.hold` is shown as `pause.hold.flag open (6 min): alarm` (`digest.py:151`: name + `.flag`).

## Evidence
`Bugs/evidence/BUG-117/repro.py`, `output.txt`, `live_copy_autopilot_output.txt`.

## Analysis (reporter's hypothesis)
Mostly presentation; B and A change what an orchestrator sees and are the ones I would decide first (see BUG-101 for the overlay variant of B).

## Suggested fix (optional)
A: store `ts` in the warning line and render `(Nh ago)`; B: `persist=not dry_run`; C: keep a loss alert for N minutes (key on the lowest pop seen); D: `ActionRecord.line()` appends `ok`/`FAILED`; E: skip `None` parts; F: validate against `brief.SCOPES`; G: don't append `.flag` for `pause.hold`.

## Info needed
Cloud session: confirm which of A-G are intended behaviour.

## Fix
A: queued warnings older than 30 min carry `(Nh ago)`/`(N min ago)`. B: `check/cycle --dry-run` use a read-only digest (`persist=False`). C: `Losses` is an event and never listed as `resolved`. D: `ActionRecord.line()` prints `verify ok|FAILED (...)`, warn/propose lines without the internal key, `FAILED` for failed actions. E: no `None` in the status/mood line. F: unknown `--scope` -> `Error: unknown scope ...`; the first call for a scope shows the status line. G: `pause.hold open (...)`. Not done in A: dropping warnings whose source re-measured OK. Test: `test_bug117_*`.
