# BUG-047 plan check says ERROR "seal: nothing to close" for the refuge hatch that already stands
Status: fixed in 73b429d (offline, live-untested): a seal with nothing left to close is no error in plan check/apply;
its blueprint is left out and the kernel queues nothing for it
Severity: medium (a plan with `seal at=refuge` or `at=last` could not be checked or applied once the thing was closed;
the game session worked around it in its own script)
Found: 2026-10-17, Run 11 fort Kilrudrabed (site98), from the game session's note 8 (triage A1)
Module: `dfpilot/cmd.py:877` (seal_openings), `dfpilot/plan.py:1418-1462` (place_all, apply), `:1524` (check CLI),
`lua/dfllm/runner.lua:353` (sync_plan)

## Actual (live, game session, note 8)
"Seal 'nothing to close' blocks plan.check although seal at=refuge is finished: plan check ERROR 'seal: nothing to close'
for the refuge hatch that already stands (my yearly.py catches it)."

## Cause (proved from the code at f17e2b3)
`place_all` (the dry run of `plan check`, the first step of `plan apply`) calls `place()` for every new build; for a seal,
`cmd.seal_openings` raises `BpError("seal: nothing to close (...)")` when every opening it names is left out (cmd.py:877).
`at=refuge` with the hatch on the snapshot gives the note "the snapshot shows a door or hatch there (closed)"; `at=last` /
`audit` with nothing open give "the last entrance check names no open way in" / "the last audit names no wall"; a seal
project that builds or built the piece gives "builds its piece" / "sealed by". The CLI turns the exception into `ERROR
blueprint: ...` and `REJECTED` (plan.py:1524); `apply` refuses with "not applied" (1462). A closed seal is the goal, not a
fault. `bp.place` (the verb) rightly says it as an error; a plan is not a placement request.

## Fix
- `cmd.SealClosed(BpError)`: raised when the only reasons for "nothing to close" are closed ones (`CLOSED_NOTES`: the
  snapshot shows a door or hatch, a closed or non-floor tile, a seal project builds or built it) or no way in is open now
  (`last`, `all`, `audit` name none). A gap in what is known stays a plain `BpError`: no refuge stair head in the manifest,
  a tile not on the snapshot, a failed search, no tile that closes the route, no opening named.
- `plan.place_all(..., left_out)` leaves such a build out: no blueprint, a line `s0 seal@S1 left out: nothing to close
  (...)`, and (check) a warning `seasons[0].build[0] seal@S1: nothing to close (...); no blueprint is written`; `apply` writes
  the other blueprints and `plan.json` with the build kept (the ids `y<Y>s<S>b<I>` of the later builds stay), its
  message says `(1 seal left out: nothing to close)`.
- The kernel's `sync_plan` takes a missing blueprint of a **seal** build as that (kern.log `plan build y3s1b2 (seal): no
  blueprint, nothing was left to close when the plan was applied`), no PROJECT_BLOCKED; any other template's missing
  blueprint is still an error.
- `bp.place` and the other callers of `seal_openings` still get a `BpError` (SealClosed is one).

## Not decided offline
- Nothing the code leaves open; live-untested. Live check: a plan with `{"tpl":"seal","site":"S1","p":{"at":"refuge"}}`
  after the hatch stands: `dfllm plan check` prints the warning and `plan OK`; `plan apply` says `(1 seal left out ...)`;
  kern.log has the `no blueprint` line after `plan.reload`, no PROJECT_BLOCKED.

## Tests
`tests/test_plan_seal_closed.py` (the standing refuge hatch on the real templates, an open head still emitted, a gap in
what is known stays an error, `at=last` with no way in, the CLI check/apply with the plan kept and no bp written),
`tests/lua/test_runner_seal_door.lua` (the kernel: a seal build without a blueprint is logged once and queues
nothing, any other template's missing blueprint is still PROJECT_BLOCKED). Each test fails on f17e2b3.

## Related
BUG-031 (`seal at=refuge`), BUG-041, plan.py `_seal_at`/`refuge_projects` (which already treat BpError as "nothing")
