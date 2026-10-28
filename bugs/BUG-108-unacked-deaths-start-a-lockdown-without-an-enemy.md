# BUG-108 An unacked DEATHS_3PLUS starts a lockdown at threat 0: the clock clamp (and, with a configured `alert`, the civ alert) for a cause no enemy shares
Status: fixed in the M2 commit (offline, live-untested): `reflex.inner` (DEATHS_3PLUS): at threat 0 the ack timeout applies no default; the event alone wakes the player
Severity: high (Run 14 y707: fourteen lockdowns in a year from deaths by curse, patients and moods; the hospital lay outside Kern+)
Found: 2026-10-24 .. 28, Run 14 (Trussroads), game session note 88 and the post-mortem
Module: `lua/dfllm/reflex.lua` (`cfg`, `threat_zero`, `ack_step`), `config/reflex.json` (`inner`), `dfpilot/fairplay.py`

## Actual
Note 88 / post-mortem item 4: every wave of deaths emitted DEATHS_3PLUS; the loop acknowledged every 15 minutes, so the kernel applied the
interrupt's default after 60 s: "Takt 30, Zivilalarm nach Kern+", also with threat 0. The carers could not reach the hospital outside Kern+.

## Cause (proven from the code at 32994bb; what stays open is under "Not decided offline")
1. `ack_step` (reflex.lua:2109-2130) applies `c.defaults[r.type]` to every unacked interrupt whatever its cause and whatever the threat; there is
   no test for a visible hostile. DEATHS_3PLUS is one of five interrupt types (reflex.lua:122).
2. With the shipped defaults (`M.CFG.defaults.DEATHS_3PLUS = {'clock'}`, reflex.lua:122, config/reflex.json) the lockdown holds the **clock**
   only: `arbiter` clamps the FPS to `clock.siege_cap` 30 and every `holding()` asker sees a lockdown (`military.danger` 'lockdown' blocks the
   drill, the unstick and the rotation; the runner builds no peace-only repair; seal queues no bridge). No civ alert: `siege.alert_held` asks
   `holding('alert')` and the default has no `alert` (the existing test says so: "the clock-only default pulls no lever").
3. The note and the post-mortem say **Zivilalarm Kern+**. With the shipped config that cannot happen; it happens when the fort's
   `config/reflex.json` lists `alert` for DEATHS_3PLUS (a hand edit or an older default). Offline this cannot be told apart; the fix covers both.

## Fix
- New key `reflex.inner` (default `["DEATHS_3PLUS"]`, `[]` = the old rule; a bad entry keeps the built-in list; `fairplay.reflex_errors`).
  `ack_step` skips the default for a type in `inner` when `threat_zero(K)`: a fresh census (<= 200 ticks) with no visible hostile
  (`vis` 0), no invader, none inside, and `threat.armed` 0. The interrupt is marked `done = 2` (alarm.txt `far` = no default applied), kern.log
  says `inner cause at threat 0: no lockdown default, no civ alert`. No LOCKDOWN event, no clock clamp, no alert, whatever the config lists.
- With a visible hostile, a stale census, an armed threat scan, or a type outside `inner` the default applies as before (LOCKDOWN, clock 30).
- Unchanged: the event DEATHS_3PLUS (class A, wakes at once), `dfllm ack`, the other interrupts' defaults, an existing lockdown.

## Not decided offline
- Whether the live fort's reflex.json listed `alert` for DEATHS_3PLUS: read `config/reflex.json` `defaults.DEATHS_3PLUS` of the fort's runtime
  folder and the LOCKDOWN events' `d.alert`/`d.clock` of that year.
- Whether `census.h.vis` 0 holds at the moments the deaths came (curses: the werecreature is a visible hostile once transformed; then
  threat is not 0 and the old default applies).

## Tests
`tests/lua/test_m2_lockdown.lua` (3: threat 0 against a visible hostile; the config cases `[]`, a bad entry, another type). All fail on 32994bb;
`test_reflex.lua` "ack timeout" now has a visible hostile (the default still applies there).
