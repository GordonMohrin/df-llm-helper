# BUG-011 the arrival lockdown switches the civil alert on, the siege module switches it off a second later
Status: fixed in 4e2b43c (offline, live-untested). Live 2026-10-15 17:06 (95fe16d): CONFIRMED - one `siege act.civ_alert [true]`, never switched off until LOCKDOWN_END; fallback text works
Severity: high (the lockdown reports "alert on Kern+" but no citizen is ever confined; combined with BUG-001 the alert never works)
Found: 2026-10-15 14:50, Run 9 save autosave 1 (y370), dfpilot main 3edc277, forced test (popup injected with `dfhack.gui.showPopupAnnouncement`)
Module: `lua/dfllm/reflex.lua` (arrival lockdown, `act.civ_alert`) vs `lua/dfllm/siege.lua` / `seal.lua` (alert burrow audit)

## Reproduction
Inject the arrival text as a popup (the real DF text begins "A vile force of darkness has arrived!"):
```
dfhack-run lua "dfhack.gui.showPopupAnnouncement('A vile force of darkness has arrived!  The army is commanded by the goblin Test Commander. ...', COLOR_LIGHTRED)"
```
commands.log (tick, module, act):
```
149574239  siege   act.civ_alert [true]  ok
149574239  arbiter act.dismiss_popup ["siege"] ok
149574251  siege   act.civ_alert [false] ok      <- 12 ticks (~0.5 s) later
149574999  siege   act.civ_alert [true]  ok      <- repeats after the next frame batch
149575016  siege   act.civ_alert [false] ok
```
Events: `REFUGE_FAIL alert burrow Kern+ refused (Kern+: drink 0<45, food 2<45): no confinement, the whole fort` (BUG-001 makes the audit fail),
`LOCKDOWN ... alert on Kern+`. The probe (2 s samples) read `civ_alert=0` in every sample of the 3 minutes the lockdown held.

## Expected
Either the alert stays on in the best available burrow (fallback `Innen+` or the whole fort), or the lockdown does not claim "alert on Kern+".

## Fix proposal
One owner for the civil alert state during a lockdown: reflex asks, siege/seal decides which burrow and never writes `false` while a lockdown
holds; when no burrow passes, say `alert: none (REFUGE_FAIL)` in the LOCKDOWN text. Fix BUG-001 first.

Related: BUG-001, FR-37, FR-57, FR-52

## Cause
Two writers of one decision. `siege.hold_alert` (the reflex's kick at the lockdown's start, and again on every later
engage, ack timeout or deferred alert) sounded the alert on `Kern+` without asking seal; siege's own step 12 ticks
later asked `seal.alert_burrow`, got `nil` (Kern+ and Innen+ refused, BUG-001) and switched it off. Every later kick
repeated the pair. The ARRIVAL/LOCKDOWN text quoted the kick ("alert on Kern+"), not what held.

## Fix (4e2b43c, offline)
- `siege.alert_plan` is the one decision behind the civ alert; `apply` (the step) and `hold_alert` (the kick) both use
  it, so they cannot disagree. `set_alert` never writes `civ_alert(false)` while `reflex.holding('alert')`: no usable
  burrow means "not sounded", never "switched off". siege stays the only writer (`act.civ_alert`).
- Fallback when no burrow passes: the whole-fort interior `Innen+`, kept for the lockdown although it fails its audit,
  if it is big enough (`seal.alert_burrow(mode, default, hold)`, `choose(..., hold)`). Why Innen+ and not the largest
  burrow: seal paints it from the revealed inside tiles of the citizens' walk group (minus the attack path and kill
  boxes), so it holds every stockpile, bed and well inside the fort; confining to it takes nothing from the citizens
  but the surface, which is exactly what an arrival lockdown is for. If the audit fails it, the fort as a whole is
  short, which confinement does not cause. "No confinement" lets them walk out to meet the army (Run 9: 39 of 48 dead
  in 76 s); the largest other burrow may be a surface farm, a lever room or a refuge without supplies. A missing or
  too small Innen+ is painted at once (urgent scan, paint and audit, at most once a day) and the alert follows on
  the next step, without a flip. Outside a lockdown FR-37 is unchanged (no confinement when every burrow fails).
- The text says what holds: `hold_alert` returns it in full (`d.alert`) and short (the event text):
  `alert: Innen+ (REFUGE_FAIL Kern+, lockdown fallback)`, `alert: none (REFUGE_FAIL Kern+, Innen+ missing)`,
  `alert: Kern+`, `alert: after the gates (<= 450 ticks)`; kern.log `reflex: civ alert: <what holds> (gates up)`.
  REFUGE_FAIL names the fallback (`...; Innen+ kept for the lockdown although drink 0<45`). Event texts put clock,
  alert and doors first and drop whole parts that do not fit 200 bytes (Run 9's ARRIVAL text was cut).
- `inspect refuge` has `choice.LOCKDOWN`; state `alert` shows the lockdown's burrow while siege asks with `hold`.
- Regression test `tests/lua/test_lockdown.lua`: the real sense, threat, siege, gate, reflex and seal on a fort whose
  Kern+ and Innen+ both fail; 30+ frame batches of 100 ticks under the lockdown with civ_alert 1 on Innen+ in each and
  no `civ_alert(false)` until LOCKDOWN_END; the text matches the state; without Innen+ the text says none, nothing is
  written, and the alert follows once Innen+ is painted.

## Live check (the same forced popup on the Run 9 save)
Before: `dfllm cmd inspect '{"what":"refuge"}'` (`choice.LOCKDOWN`). Inject the popup as in §0h. Expected:
ARRIVAL `siege (popup) -> clock 30 t/s, alert: after the gates (<= 450 ticks), doors ...`; once the gates are up
kern.log `reflex: civ alert: Kern+ (gates up)` (BUG-001 fixed: Kern+ passes) or `Innen+ (REFUGE_FAIL ...)`.
commands.log: one `siege act.civ_alert [true] ok` and no `[false]` until after LOCKDOWN_END; the 2 s probe reads
`civ_alert=1` in every sample while `status` shows the lockdown, and `plotinfo.alerts.list[1].burrows` holds the burrow
the text names. After `dfllm ack` and 2 quiet days: LOCKDOWN_END, then one `[false]`, civ_alert 0.

## Retest 677bc3e (15:02-15:15)
With the BUG-001 fix the refuge audit passes (Kern+ drink 1031, food 912) and `civ_alert` stays 1 for the whole lockdown (probe 170 s), no flip-flop in commands.log. The flip-flop was therefore caused by BUG-001. New problem behind it: BUG-013 (lever pulls blocked by the alert).

## Live check 95fe16d (17:06-17:16, test fort y372)
Two runs: `act.alert_burrows [["Kern+"]]` + `act.civ_alert [true]` once each, `civ_alert=1` in every probe sample until `LOCKDOWN_END`
(`siege act.civ_alert [false]` at tick 150019169, the only `false`). No flip-flop.
