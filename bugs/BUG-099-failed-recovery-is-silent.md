# BUG-099 A restart that loads nothing is not an alarm: the supervisor logs "no dfllm fort loaded" and waits
Status: fixed in the K2 commit (offline, live-untested): the chain that cannot load raises `needs_click` (class A wake NEEDS_CLICK,
save, DFHack version, reason, screen rows), once and then at most every 30 minutes, and blocks nothing
Severity: high (the fort is down and the one report that exists says nothing a reader can act on)
Found: 2026-10-23, Run 14 note 71: with `load-save` broken (BUG-098) `supervise --once` printed `"why": "no dfllm fort loaded (title
screen or an unmarked save)"` and did nothing but a backup; Gordon's session found out because the game stayed on the title screen
Module: `dfpilot/supervise.py` (`_start_and_load`, `_pass`), `dfpilot/wake.py` (`_check_supervise`), `dfpilot/doctor.py`

## Actual
How supervise reports (all of it; line numbers of b2b9435 in this section): `supervise.json` (`said`, `last.alerts`), `supervise.log` (`ALERT key: msg`) and, only
while `dfllm follow` runs, one SUPERVISE wake. There is no event (the kernel is down when this matters), no push (RULES 2: chat
only), and `status`, `brief` and `doctor` never read `supervise.json` (grep: only `wake.py` does). The failure of a chain that
could not load was
- `fail("load-save did not start within 15 min")` (`dfpilot/supervise.py:843-844`): no save, no DFHack version, no reason, no screen;
- the `restart_failed` alert (`:1041-1042`) of the NEXT pass, said at most every `SAY_EVERY_S` (`:997-1001`), woken as a bare
  `SUPERVISE restart_failed: automatic restart failed: ... - human needed` whose `next:` is `dfllm supervise --once --dry-run`
  (`wake.py:76`), which prints exactly the quiet line above;
- lost entirely for a follow that starts after the alert was said: `wake.py:540-542` remembers the old `said` keys of the first look
  and wakes on none of them.
Nobody was told that the fort waits for one click, which save, under which DFHack, or what the screen showed.

## Cause
The alarm was an afterthought of the generic alert path: one text for every kind of failure, shown a pass late, no distinction
between "a human must click" and "the chain gave up on Steam", and no reader outside the wake line.

## Fix
- `dfpilot/supervise.py:1033` `_no_load`: when the chain cannot load after its retries (`LOAD_MAX_S` without a load, or `MAP_MAX_S`
  without a fort after the title run said it clicked through) it records `needs_click {save, ver, why, screen, wall, runs}` and
  fails with `... on DFHack 53.16-r3: <reasons>`; `screen` is what `embark.lua screen` shows at that moment (else the last run's
  rows). "Can't find save" keeps `restart_failed` (a different problem, no clicks).
- `:1305` `_alarms` runs after the chain in the SAME pass: `alert("needs_click", click_text(nc))` ("click Continue by hand: save
  'autosave 1', DFHack 53.16-r3; the automatic load failed: <why>; screen: <rows>"); `alert()` says it at once and then at most every
  `SAY_EVERY_S` (30 min), the summary line shows it in every pass; `restart_failed` does not repeat it. The alarm is information, not a
  latch: it sets no `norestart.flag`, no blocker, the next crash or DEGRADED restart runs as before and replaces it (`restart()`),
  and a live fort (a human click, a later restart) pops it.
- `dfpilot/wake.py:58-81,548-562`: `NEEDS_CLICK` is a follower wake type (class A treatment, rank after NO_DEPOT, first move "tell
  Gordon at once ... he clicks Continue and the save named"); a follow that starts while supervise's last pass (at most 10 min old)
  still carries the alarm wakes once; resolved or old alarms wake nobody. RULES section 7 has its row (with QUICKSAVE_FAILED).
- `dfpilot/doctor.py:256` `supervise_lines`: `dfllm doctor` lists "no fort runs: supervise could not load 'autosave 1' for 15m
  (DFHack ...: <why>); click Continue by hand; the screen showed: ..." as a problem, and the DFHack versions.
- `dfpilot/supervise.py:962` `_load_once` also logs every title run in `supervise.log` with its clicks (kind, text, pixel), the rows and the
  title screen fields, so the first live use can be calibrated from the log alone.

## Not decided offline
Whether a wake line of ~330 characters reads well in the orchestrator's chat (it is clipped to the 150-token budget; the save and
the version come first, the rows last); whether 30 minutes is the right repeat for a down fort (`SAY_EVERY_S`, shared by all
supervisor alerts); how `dfhack-run` words "cannot reach DFHack" on Windows (`UNREACHABLE_RE` knows the common spellings; a miss
only costs an unneeded title run that fails the same way). Live check: kill DF with the task running, break `tools/embark/embark.lua`
(rename it) and watch the chain end with the NEEDS_CLICK wake, `dfllm doctor` and `supervise.log`; put the file back, click Continue,
the next pass pops the alarm.

## Tests
`tests/test_supervise_k2.py` (fail on b2b9435: no `needs_click`): the alarm names save, version and screen rows in the SAME pass;
runs back off; 100 passes say it at most every `SAY_EVERY_S`; it clears when a fort is live; it does not stop later attempts (a
crash after the human's click restarts); a new attempt replaces it; one failure is one alarm (no `restart_failed` beside it); a
hung run is stopped; DFHack that never answers says so; a human who clicks meanwhile ends the chain without an alarm.
`tests/test_k2_surfaces.py`: NEEDS_CLICK in the wake line (rank, budget, hint), by the supervise cadence, for a late follow, quiet
when resolved or old, SUPERVISE for the other keys, `dfllm doctor`.

Related: BUG-098, FR-81, QUICKSAVE_FAILED (the same kind of follower wake, Run 10)
