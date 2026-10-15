# BUG-011 the arrival lockdown switches the civil alert on, the siege module switches it off a second later
Status: open
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

## Retest 677bc3e (15:02-15:15)
With the BUG-001 fix the refuge audit passes (Kern+ drink 1031, food 912) and `civ_alert` stays 1 for the whole lockdown (probe 170 s), no flip-flop in commands.log. The flip-flop was therefore caused by BUG-001. New problem behind it: BUG-013 (lever pulls blocked by the alert).
