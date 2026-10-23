# BUG-065 A gremlin in the caves holds the Kern+ lockdown for months: no clock on the lockdown, the cause not named, civ_alert sounded again within 15 s
Status: fixed in 6b20f22 (the lockdown, the cause, the limit, the offer, the need report) and 68627a8 (the FPS-cap log lines and
FR-75, the popups); offline, live-untested. The size field and the gremlin's race are not decided offline (below).
Severity: high (every project outside Kern+ stalled for months, no squad sent, drill blocked for more than an hour, a mood
dwarf neared lethal thirst inside the confinement, the last memorial slab stayed suspended)
Found: 2026-10-23 from the game session's notes 49, 54 (the alarm part) and 57 (runs 11-14, Run 14 y543-y557), kernel of
the base commit f17e2b3
Module: `lua/dfllm/reflex.lua` (engage, quiet_step, ack_step, release, far_scan), `lua/dfllm/siege.lua` (alert_held,
alert_wanted, set_alert, anchor_dist), `lua/dfllm/threat.lua` (assess), `lua/dfllm/sense.lua`, `lua/dfllm/military.lua`,
`lua/dfllm/arbiter.lua` (apply_cap), `dfpilot/brief.py`, `dfpilot/wake.py`

## Actual
- Note 49: a gremlin in the caves (z91, the fort's own walk group) kept the Kern+ lockdown on for months; every project
  outside Kern+ "stalled"; the kernel sent no squad, a `squad.sortie A [pos]` by hand was the only way out.
- Note 57: `gui/civ-alert clear_alarm()` set `civ_alert_idx` to 0, the kernel set it to 1 again within 15 s while the
  brief said `threat 0 vis`; the drill was blocked for more than an hour, the build job for the last memorial slab (ghost
  6121) stayed suspended, a mood dwarf neared lethal thirst (> 50000 of 75000) without rescue.
- Note 54 (alarm part): after every gremlin alarm the clock went down ("timestream 10 FPS") and `civ_alert` stayed on in
  PEACE (`alert Kern+ 1126t`); the citizens sat in the core.
- Decision 12 (DECISIONS.md, the dev session; Gordon 2026-10-15 "einzelne Diebe machst du richtig"): a lone thief still
  starts a lockdown, the confinement is bounded, the brief names the cause, a harmless intruder gets a sortie offer.

## Causes (from the code, f17e2b3)
1. **The lockdown has no clock of its own.** `hold.since` (reflex.lua:1382, set once in `engage`) is used only for the
   LOCKDOWN_END text. The one end is `quiet_step` (1761-1780): `hold_quiet_days` of an uninterrupted quiet clock. A visible
   invader within `lockdown_near` (40) of a citizen outside Kern+ (a woodcutter, a miner, a gatherer in the caves) makes
   `far_now` (647-657) false, so `quiet` is false at 1766 and `hd.qs` is cleared (1771-1773): for ever. A gremlin 10 tiles
   from a gatherer stops the clock as long as it lives. (Run 11's `far` rule frees only invaders beyond 40 tiles.)
2. **Every trigger restarts the quiet clock, the same intruder included.** `engage` (1379-1386) sets `h.last, h.qs = now,
   nil` for an arrival and for the ack default: `inside_scan` raises an INTRUDER for the unit once per `REARM` 1,200 ticks
   while it stays visible (1655), and an INTRUDER unacked for `ack_timeout_s` gets its `defaults` lockdown (ack_step
   1795-1803; `unit_far` only exempts units beyond `lockdown_near`). A gremlin that walks in and out of sight every few
   thousand ticks therefore keeps `now - hd.last >= ARM` (1764) false even with nothing in sight.
3. **`civ_alert` is a held, level-triggered decision.** `alert_held` (siege.lua:781-784) asks `reflex.holding('alert')`;
   `alert_wanted` returns true at once for a held lockdown (787) whatever threat says, and `set_alert` sounds the alert
   again whenever `civ_alert_idx` is 0 (866-868) in the next siege step. A hand-cleared alert is therefore set again within
   seconds in PEACE too (note 54 `alert Kern+ 1126t` in PEACE, note 57 "kein Stale-Flag"). In ALERT mode the hysteresis
   (`alert_wanted` 796-809) is fed by the raw census: `threat.assess` (147) hands `near_cit` and siege's `anchor_dist`
   (764-778) walks the whole census list, a unit the lockdown stopped counting would still hold the civ alert for 600 ticks
   and every pass while it stays near.
4. **The brief says `threat 0 vis` and never names the cause.** brief.py:365 prints the census `vis`; `line_alert` (395)
   the burrow; the lockdown line was `lockdown <why>` only (`why` = `arrival:invader`, no unit). A unit that drops out of
   sight (sense.lua: not visible or hidden, returns before it is counted) leaves `vis` 0 while `hd.last`/`armed` still hold
   the quiet clock, and nothing said so.
5. **No way out is offered.** `squad.sortie` exists (military.lua) but nothing in the kernel names the intruder, its
   position or a squad; the verb is only allowed in ALERT/SIEGE/BREACH/RECOVERY (schema.py VERBS), so the session found it by
   hand.
6. **A mood dwarf or patient behind the alert has no report.** siege `relax_step` (e) skips patients (`patient`, siege.lua
   338) and acts on a thirst over 30,000 only where the walk group has drink; a mood dwarf does not drink at all. Nothing
   told the player that he was dying inside the lockdown.
7. **`timestream 10 FPS`: not proven.** Nothing in the code writes 10 for a lockdown: the clamp holds the cap at
   `clock.siege_cap` 30 and timestream off (arbiter.lua `desired`/`clamp_why`); 10 is the floor of the setters. It follows
   from cause 1 (the clamp never lifts); the cap's changes had no log line (arbiter `apply_cap`).

## Fix
- **State and brief name the cause** (reflex `cause_scan`, `M.state`): `alarm.by` = the nearest counted hostile (id, race,
  kind, position, `dc` tiles to the nearest citizen outside Kern+, `de` to the nearest entrance, `hl` harmless, `n` counted,
  `sz` its body size), `alarm.age`/`lim` = the lockdown's age and limit in ticks, `alarm.qw` = why the quiet clock does not
  run (`near`, `inside`, `great`, `recent`, `armed`, `stale`, `run`; `quiet_step` and the state share `quiet_block`).
  `dfllm status`/`brief`: `lockdown arrival:invader 4.2 of 10 days: cause inv 300 GREMLIN at 110,20,91, 10 tiles from a
  citizen outside Kern+, 58 from an entrance, size 4000, harmless; quiet clock: a hostile is near` (or `no hostile in sight;
  quiet clock: a trigger within the last 2,400 ticks`); the threat line says `threat 0 vis (lockdown holds: quiet clock
  recent)`. The census list carries `sz` (the unit's own `body.size_info.size_cur`, cm3; a dwarf is 60000) and `pr`
  (LARGE_PREDATOR) for it.
- **The confinement limit** (`confine_step`, config/reflex.json `confine.max_days`, default 10 game days, 0 = off):
  `max_days` after the lockdown began, in PEACE/ALERT only (never SIEGE, BREACH, RECOVERY, DRILL), with a fresh census, no
  news trigger (an arrival popup/report, INVASION; not the same intruder's INTRUDER default) in the last 2,400 ticks, threat
  not armed, no great danger in reach, no undead wave, no siege-sized army, and no dangerous hostile within the near
  radius (inside Kern+, within `lockdown_near` of a citizen outside it or of an entrance, or of unknown distance), the
  lockdown ends: LOCKDOWN_END `cause` `limit`, the doors open, the clock clamp and the alert go (`release` calls
  arbiter/siege/gate as before), `civ_alert` goes off after ALERT's own 600-tick hold and is not sounded again.
  **Harmless** (`harmless`): not a great danger, undead, building destroyer, large predator, trap avoider or flier, and its
  body size <= `confine.harmless_size` (20000 cm3) or its race in `confine.harmless_races`; an unreadable size is no
  evidence (dangerous). At most `confine.lone_max` (2) hostiles near count as a harmless picture; more are a group.
- **The released intruders are cleared** (`hl_clear`; persisted `m.reflex` `far.hl`, a subset of `far.ids`, so threat,
  `sighting`, `inside_scan`, the ack default and `anchor_dist` skip them through the existing expired-far path): they count
  for nothing, so no arrival, INTRUDER or civ alert comes back for the same gremlin. They count again when another hostile
  is in sight (`far_scan`: any listed unit not on the list), when one is inside Kern+, or when it dies. `threat.assess`
  recomputes `near_cit`/`near_o1` without them and `anchor_dist` skips them, so ALERT ends 600 ticks after the release.
- **A sortie offer** (`offer_step`): DECISION_NEEDED `intruder_sortie` (A) with the unit, race, position, distances, the
  squad (`military.sortie_squad`: the melee squad with the most soldiers) and the command `dfllm cmd squad.sortie
  '{"squad":"A","target":[x,y,z],"approve":true}'`: for a harmless lone intruder after `confine.offer_days` (1) of
  lockdown, for a dangerous one past the limit (it says the lockdown stays while it is near); ALERT only (the verb's
  modes), once per `offer_days` (util/cadence). The wake line's next move (`wake.sortie_hint`) repeats the command and says
  the lockdown ends by itself. `approve:true` stays the player's decision.
- **A mood dwarf or patient in need** (`need_step`, every 300 ticks, 60 citizens a look): behind the sounding civ alert,
  over `confine.need_thirst` (40000) or `need_hunger` (60000): DECISION_NEEDED `confined_need` (A, once per news) with the
  units, thirst and hunger; with nothing dangerous near (the same picture as the limit) the lockdown ends for him
  (LOCKDOWN_END `cause` `need`); with a dangerous hostile near it only reports (siege's `relax_step`/STRANDED stays the
  rescue for the others, a sortie clears the cause).
- **The clock** returns with the release (arbiter unchanged); every change of the FPS cap is a kern.log line now:
  `fps cap 250 -> 30 (arrival:invader)`, `fps cap 30 -> 250 (free)`.
- Config `confine` (`max_days`, `harmless_size`, `harmless_races`, `lone_max`, `offer_days`, `need_thirst`,
  `need_hunger`) in config/reflex.json with `python -m dfpilot.lint --config` ranges (`fairplay.CONFINE_LIM`); contracts:
  state `alarm` (contract.lua, schema.py), census list `sz`/`pr`, LOCKDOWN_END causes `limit`/`need`, DECISION_NEEDED ids,
  CONTRACTS §6.2/§9.18/§12.
- Safety: no effect in SIEGE/BREACH/RECOVERY/DRILL; a fort of 7 and of 80 alike (a look is the census list, <= 40 entries,
  and 60 citizens per 300 ticks); an old state reloads (no `far.hl`, `cf`, `hold.fresh`: defaults); a reclaimed fort has no
  `sz` until the first scan; `max_days` 0 and `harmless_size` 0 give the old behaviour (the state still names the cause).

## Not decided offline
- **The gremlin's race and size on the live DF 53.16.** `u.body.size_info.size_cur` is DFHack's field for the unit's own
  body size (create-unit.lua writes it) but is unproven on this build; an unreadable or large size makes the gremlin
  "dangerous" and the limit does not free it. Decided by `dfllm status` once a gremlin is near: the line `cause: ... GREMLIN
  ... size N` (`size unknown` = the field is not readable; N > 20000 = raise `confine.harmless_size`). Then put the race token into
  `confine.harmless_races` (`["GREMLIN"]`) or raise the size; both are config (`dfhack-run dfllm reload`).
- **Whether a gremlin is an invader or a wild danger** (`by.k` `inv` or `danger`): it decides which rule counted it
  (arrival lockdown or the predator rules); the status line shows it.
- **Cause 7, the "10 FPS".** Decided by the new kern.log lines `fps cap A -> B (why)` and `dfllm status` `clock:` during a
  gremlin alarm, with `dfllm doctor` (ticks/s).
- Whether the sortie squad kills the gremlin (soldiers engage hostiles they see on a station order): the offer is the
  existing `squad.sortie` position order; its result is `dfllm events --type SORTIE` and the gremlin leaving `by`.

## Tests
- `tests/lua/test_reflex.lua` (5 tests, BUG-065): the lone small intruder (named in the state, sortie offered once, held
  inside the limit, hand-cleared civ_alert sounded again, LOCKDOWN_END `limit`, doors open, civ_alert off, ALERT over,
  cap 250 / timestream 500, no re-arm, `far.hl` persisted, another hostile brings it back); a big one, a group of three and
  `max_days` 0 keep the lockdown; no hostile in sight (`qw` recent/run); a mood dwarf and a patient in need (report, end /
  hold); a great danger keeps it.
- `tests/lua/test_military.lua`: `sortie_squad`. `tests/lua/test_kern_arbiter.lua`: the FPS-cap log lines.
- `tests/test_bug065.py`: state fields, brief lines, wake hints, config ranges.
- All new tests fail on f17e2b3 (checked in a pristine worktree).
