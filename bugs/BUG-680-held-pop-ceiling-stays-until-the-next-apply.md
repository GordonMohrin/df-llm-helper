# BUG-680 A plan's held pop ceiling stays all year after the defence gap closed; the status names the old number after a plan.reload
Status: fixed (offline, live-untested)
Severity: high (no migrants for a year)
Found: 2026-11-10, Run 16d i4 Trumpetrealms y447 (FR-BUGS 'Pop-Ceiling bleibt nach Ruestungs-Anstieg im Jahr haengen'): plan y447 spr d1 'ceiling 31 (held, policy 100: defence short, armor worn 10 %)', a month later worn 57 % and 'migrants blocked: max-pop 31 on 32 citizens (plan 31)' until a second propose + apply (plan-y447b, ceiling 100); y455: the plan applied with ceiling 66, the status said 'plan 60' (STAND.md:341)
Module: `dfpilot/plan.py` (`ceiling_refresh`, `HELD_RE`, `defense_cap`), `dfpilot/wake.py` (`_check_ceiling`), `lua/dfllm/readiness.lua` (`hold_text`, `plan_changed`), `lua/dfllm/kern.lua` (`plan.reload`)

## Actual
`plan propose` writes `policy.pop_ceiling` once (`defense_cap`: the citizens now while a gap holds). The kernel takes min(level cap, plan ceiling, ...) (`readiness.ceiling`); nothing looked at the plan's number again until the next apply. The kernel holds armor and traps itself (BUG-481 / BUG-601), but a ceiling the plan took stays at the day's number. After `plan.reload` the max-pop and the 'plan N' hold text followed at the next readiness step, and `hold_text` printed `st.cap` (the max-pop last written), not the ceiling that holds.

## Root cause
`plan.py` (the draft only), `readiness.lua` `hold_text` (used `st.cap`; no refresh on `plan.reload` in `kern.lua`).

## Fix
- `plan.ceiling_refresh(save_dir, state)` (follow, `wake._check_ceiling`, every 300 s, PEACE, not `--no-auto`): the applied plan's held ceiling (the note 'pop_ceiling N held (policy P)', N = the plan's ceiling) is compared with `defense_cap` of now; raised when the gaps are closed (to the policy) or have become soft (room for a wave), never lowered, capped by the readiness level. plan.json is rewritten (note 'BUG-680: ceiling N -> M by follow'), `plan.reload` is sent, a PLAN_AUTO wake says so.
- `readiness.plan_changed` (refresh at once) is called by `kern.lua` after every `plan.reload`; `hold_text` names `rt.gate_cap` (the ceiling that holds), falling back to `st.cap`.

## Tests
`tests/test_bug679_684_f44_proj.py` (a held ceiling is raised when the armor gap closes, once; none outside PEACE or without a hold), `tests/lua/test_bug680_ceiling_display.lua` (plan 60 -> 66: gate and text follow at `plan_changed`).

## Live check
After an apply that holds the ceiling for 'armor worn N %': once worn is back over 60 % (or the gap is soft) follow writes PLAN_AUTO 'ceiling 31 -> 100' within 5 minutes and `status` shows `ceiling` gone / the new number; `plan apply` of a higher ceiling shows it in the same minute.

## Open
The kernel needs a reload for `plan_changed` (the Python side works without); the plan file is written by follow without `plan check` (only the ceiling and the note change; the cap is the level's). The display fix alone could not be shown to fail on the old code in the test (st.cap and the gate agree once apply_cap ran); the refresh at `plan.reload` is what the test pins.
Related: BUG-377, BUG-533, BUG-601
