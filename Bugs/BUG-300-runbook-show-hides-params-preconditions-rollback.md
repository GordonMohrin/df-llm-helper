# BUG-300: `runbook show` omits params, preconditions and rollback although `runbook run` refers to it for the rollback

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S3
- **Area:** `runbook show`, `df_llm_helper/cli.py:cmd_runbook`, `df_llm_helper/runbooks.py:run_runbook`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
python -m df_llm_helper --mock fixtures/run5 runbook show rb01_e18_pick
python -m df_llm_helper --mock fixtures/run5 runbook run rb01_e18_pick --param squad_id=1      # not --dry-run, mock only
python -m df_llm_helper --mock fixtures/run5 runbook run rb01b_e18_foreign --dry-run
```
1. Show the runbook. 2. Run it for real against the mock (no fixture for `claude/mil status`, so a step fails). 3. Dry-run a runbook that needs consent.

## Expected
`show` prints the complete recipe: parameters (`--param squad_id=<value>` is mandatory for rb01), preconditions (`not danger`) and the **rollback**
steps. The abort message of `runbook run` says "Check the rollback: ... runbook show <id>", so the rollback must be visible there.

## Actual
```
$ python -m df_llm_helper --mock fixtures/run5 runbook show rb01_e18_pick
rb01_e18_pick: Pickaxes are not picked up (E18) - militia miners
Symptom: dig_jobs is not None and dig_jobs >= 30 and diggers * 20 < dig_jobs and len(miners) > diggers
KB: e18_pick, e18_release
Player consent needed: False
 1. cmd: claude/mil status, why: Check squad/leader; without a leader the squad accepts no add (then claude/mil create <name> <leader> --apply)
 2. cmd: claude/mil workmode {squad_id} on --apply, why: Uniform = pickaxe only, labor MINE, work detail Miners
 3. wait_s: 90
 4. cmd: claude/mil equip --squad {squad_id}, why: check assigned vs. carried
Verify: pick_holders >= 2 or diggers >= 3
Note: Do NOT run workmode repeatedly (it wipes assignments). If assigned but not picked up: release the stale item IDs (runbook rb01c_e18_release, the player's decision), then run workmode exactly ONCE more. A squad without a leader accepts no add.
[exit 0]

$ python -m df_llm_helper --mock fixtures/run5 runbook run rb01_e18_pick --param squad_id=1
rb01_e18_pick: step_failed
  ERROR: claude/mil status (no fixture for 'claude/mil status')
  Aborted. Check the rollback: python -m df_llm_helper runbook show rb01_e18_pick
[exit 1]

$ python -c "...load data/runbooks/rb01_e18_pick.yaml and print params / preconditions / rollback"
params       : {'squad_id': {'default': None, 'desc': 'Squad ID of the miners (claude/mil status)'}}
preconditions: [{'when': 'not danger', 'msg': 'not during danger (reorganise the squad only in peacetime)'}]
rollback     : [{'cmd': 'claude/mil workmode {squad_id} off --apply'}]
[exit 0]

$ python -m df_llm_helper --mock fixtures/run5 runbook run rb01b_e18_foreign --dry-run
rb01b_e18_foreign: approval
  refused: rb01b_e18_foreign needs the player's yes in the exception register (action FP08). Without an entry it is not executed.
[exit 1]
```

`show` prints only id/title/symptom/KB/consent/steps/verify/notes. For rb01 the YAML has `params` (squad_id), `preconditions` (`not danger`) and
`rollback` (`claude/mil workmode {squad_id} on|off --apply`), none of which is shown. The `{squad_id}` placeholder in the steps is therefore unexplained, and the
abort message sends the reader to a place where no rollback is listed. A runbook that needs player consent (rb01b) cannot be previewed at all with `run --dry-run` (it refuses with exit 1).

## Evidence
`Bugs/evidence/BUG-300/*.txt` (raw outputs).

## Analysis (reporter's hypothesis)
`df_llm_helper/cli.py:305-313` (`show` branch) prints only `rb.steps`, `rb.verify`, `rb.notes`; `rb.params`, `rb.preconditions`, `rb.rollback` are loaded (`runbooks.py:89-145`) but never printed.

## Suggested fix (optional)
Print `Params:` (name, default/required, description), `Preconditions:` (when + msg) and `Rollback:` in `show`. Let `--dry-run` of a consent-gated runbook print the plan with a `needs player consent` header instead of refusing.

## Info needed
Question for the cloud session: is the refusal of `run --dry-run` for `needs_player_approval` runbooks intended (the agent cannot preview the steps) or should it only block the real run? (`runbook show rb01b_e18_foreign` works, so the steps are readable anyway.)

## Fix
`runbook show` prints Params (required/default), Preconditions and Rollback; an aborted run lists the rendered rollback steps. Answer to the question: a consent-gated runbook can now be previewed with `run --dry-run` (header `NOT approved: ...`, nothing runs); the real run is still refused without the register entry.
