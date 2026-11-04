# BUG-336 the refuge is a death trap when its seal is never built
Status: fixed (offline, live-untested)
Severity: critical
Found: 2026-11-04, Run 15b (Earthboat, i3, `runs/run-15b-earthboat/FR-BUGS.md` "FORT VERLOREN y387"), kernel main b35af6d
Module: `lua/dfllm/seal.lua` (choose, leave_why, publish, new refuge_open), `lua/dfllm/runner.lua` (focus, Q.idle_keep, new
Q.refuge_seal / Q.seal_escalate), `lua/dfllm/siege.lua` (deep_step text)

## Actual
Earthboat fell y387 spring d34-39, pop 92 -> 1. The refuge hatch 55,82,133 (seal y373s1b0, c1a1884b90c4405401, y383s0b0,
y384s1b0; plan y385b/y387 moved it to 55,82,135) was never built: events #6298 `y384s1b0 (seal) built nothing ... hatch
55,82,133: job 205434 not suspended, no builder has taken it`, #6345 `blocked: stalled ... job 282764 suspended by DF ... no
cause readable`, status `BLOCKED:stalled 0%` for 911 days. The siege (i3 `dfllm-runtime/r15-earthboat-site97/events.jsonl`):
- #8745/#8770 SIEGE_DEEP `4 (6) building destroyers in sight (TROLL x4/x5) ...; civilians to Tiefe+ (the separated refuge)`;
- #8746 REFUGE_FAIL `Tiefe+: no drink (drink 69<92)`: confining to Kern+ (by luck: the drink rule, not the open stair);
- #8890 SIEGE>BREACH `O1 destroyed`; #8907 REFUGE_SWITCH `Kern+ -> Tiefe+ during the BREACH: Kern+ breached (hostile inside at
  64,82,138)`, level BREACH;
- #9111 REFUGE_SWITCH `Tiefe+ -> none ... Tiefe+ breached (hostile inside at 54,82,132)`: the trolls came down the open stair
  55,82,132-138 after the citizens; SIEGE_STATUS `55 lost` (#9085), `91 lost` (#9173).

Root cause: the separation flood (seal.lua `expose`) starts at the fort's openings; a refuge whose stair head has no closer is
one room with Kern+, so it counts as separated exactly while Kern+ is. `refuge_trust` knew it (`no hatch at 55,82,133`, R0
refuge_trust), but `choose` (seal.lua:3460-3521, b35af6d) never asked: `rate` (:3412) checks the separation answer only, so the
BREACH-level fallback `try(refuge, 'BREACH')` (:3512) took the open dead end once Kern+ was breached, and SIEGE_DEEP
(siege.lua:2018) called it `the separated refuge`. The stalled hatch: SEAL_STUCK came once, the BUG-274 re-place ran once
(kern.log 154063044 `removed and placed again (once)`), then nothing asked anyone again; BUG-328 (runner.lua:4891) would now also
set it aside after idle_days (Q.idle_keep :4856 kept a seal only in SIEGE/BREACH).

## Fix
- seal `refuge_open` (public `M.refuge_open`): the refuge's stair head (M.refuge_stair) without a closer -> `open: no hatch at
  x,y,z (its seal is not built)`; no manifest stair or an unrevealed head (BUG-124 `hidden`): unknown (nil, as before). Per
  tick.
- `choose`: in a SIEGE or BREACH (the deep defense's BREACH ask too) an open refuge is refused at every level, the dead end
  included (REFUGE_FAIL `Tiefe+: open: no hatch at ...`): Kern+ or the best closed burrow, else no confinement (flee in a BREACH).
  `leave_why`: a held open refuge is left for the free pick (REFUGE_SWITCH why `unsealed`), never for no burrow. PEACE/ALERT
  (drills, lockdowns) unchanged.
- Loud: state `alert.ref.op` 1; status `| REFUGE OPEN: not used in a siege or breach, close its stair head (bp.place tpl=seal
  at=refuge)` beside `refuge NOT TRUSTED`; SIEGE_DEEP starts with `deep defense: Tiefe+ open: no hatch at ..., NOT the civilians'
  burrow: they stay in the best closed one` (d.ropen). R0 `refuge_trust` as before.
- runner: a stuck seal without progress for `seal_first.esc_days` (30, 1-60) asks DECISION_NEEDED `seal_stalled` (A): q = piece,
  days, SEAL_STUCK's cause, what the kernel tried (re-placed, doors walled) and, for the refuge's hatch, `the refuge is NOT the
  civilians' burrow in a fight until it stands`; d.cmd = the commands (refuge: build by hand, or `bp.cancel` + `bp.place tpl=seal
  at=refuge`; a perimeter piece: `bp.place ... close=wall`), d.proj, d.mat, d.n. Again every esc_days while it stays stuck
  (m.runner sf[<proj>].dn); a built piece resets it. Wake hint `seal_stalled_hint`. The refuge's seal (a piece on the refuge
  stair's x,y) is never set aside (Q.idle_keep `the refuge seal`); other seals may be set aside as before, the question comes
  anyway (the seal-first clock runs for set-aside seals too).
- Interaction: BUG-331's eased siege (`release`) still leaves a held refuge (`released` is checked before `unsealed`); BUG-330's
  care burrow is untouched (outside PEACE only on Kern+ tiles, which is where the civilians now are while the refuge is open).

## Tests (fail on b35af6d)
`tests/lua/test_seal_refuge.lua` (2: a BREACH in Kern+ with the open refuge -> flee, the built hatch -> Tiefe+ again; the deep
ask -> Kern+, a held open refuge -> REFUGE_SWITCH unsealed, PEACE unchanged), `tests/lua/test_intake.lua` (BUG-336 SIEGE_DEEP with
an open refuge), `tests/lua/test_bug336_seal_escalate.lua` (2: a perimeter door asks after esc_days and again, the refuge hatch is
never set aside), `tests/test_bug336_337_refuge.py` (4: brief, schema, config lint, wake hint).

## Live check
A fort with the refuge hatch missing: status `REFUGE OPEN`, state `alert.ref.op 1`; at a siege REFUGE_FAIL `Tiefe+: open: ...`
and the alert on Kern+; 30 days after the clock stopped DECISION_NEEDED seal_stalled with d.cmd. Uncertain: whether fleeing beats
the dead end once Kern+ is breached (the kernel now flees rather than confining to an open refuge); a refuge whose real stair is
not in the manifest (`stairs.civ`) stays unknown and is treated as before.
