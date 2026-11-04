# BUG-338 the army's war cave dragon is listed as a wild animal; 32 civilians stranded in the killing field, 10 killed there
Status: fixed (offline, live-untested), parts Open (see below)
Severity: critical
Found: 2026-11-04, Run 15c (Inkintense y379 sum d64-67, i1 r15c-inkintense-site97)
Module: `lua/dfllm/sense.lua` (citizen and hostile scan), `lua/dfllm/reflex.lua` (inside_scan), `lua/dfllm/threat.lua`
(assess), `lua/dfllm/gate.lua` (lockdown pass)

## Actual
events.jsonl (i1), in order:
- #2897/#2898 the arrival lockdown pulls B1 and O1 up in the same tick; #2899 siege popup ("... With them comes a war cave
  dragon from the dark goblin fortress of Lakeshates!", gamelog), `recall: 42 outside Kern+, 6 waiting for 33 citizens
  outside`; #2903 the 42 were gathering plants at 76-91,96-103,133 (outside O1).
- #2907 `PREDATOR_FAR 26704 at 17,74,133, nearest citizen 59 tiles: no lockdown` (the dragon, listed as a wild animal).
- #2920 `GATE_CRUSH_RISK B1 moving up with citizen 26562 on the footprint`; #2922 B1 up (before O1, #2926); #2924
  `33 citizens shut out from food by a raised bridge at 86,64,131` (B1); #2925 `citizens: 22 of 56 off the main group`.
- #2941 `3 of 42 still outside Kern+`: the 33 had come in through O1 and stood in the killing field K1 (83-89,66-72,131)
  between O1 (y91) and the raised B1 (y64). Kern+ in this fort is the box 60-106,30-73,z116-131 (FR-BUGS round 2), so it
  covers K1: for the census they were inside.
- #2943 SIEGE_DEEP (worn 37 %): civilians to Tiefe+ behind B1/B2; #2948 `41 of 42 still outside Tiefe+, 10 cannot come`.
- #2950/#2955 the dragon topples the raised O1 (ten ticks after SIEGE_DEEP); #2952/#2953 SIEGE>BREACH at once.
- #2962/#2964 B2 raised although it cuts 1-2 citizens off (forced, hostile 30 tiles); #2973 `32 of 42 citizens still outside
  Tiefe+ after 2420 ticks` with positions 83-86,66-72,131 (`down`/`group`: on another walk group than Tiefe+); #2984
  `31 cannot come`.
- #2983 `PREDATOR_FAR 26704 at 85,80,131, nearest citizen 63 tiles: no lockdown` while the 32 stood 8-11 tiles from it.
- #3004 `12 citizens on walk group 2 without drink and food: no rescue (a hostile inside)`.
- #3030-#3039 (revised deaths): 9 of the 10 citizen deaths lie at 84-87,66-72,131, in K1 (killed by cave dragon 26704 or
  bled), one (26470) was killed by a goblin at 148,113,133. Pop 56 -> 45.

Not a cavern breach: no cavern was opened (no cavern event in events.jsonl), the dragon came over the surface with
invasion 4. The FR-98 cavern sweep is not involved.

## Root cause (corrected after review)
The killer was the stranding, not the label:
1. `lua/dfllm/gate.lua:2124` (manifest_pass, FR-49/52): a lockdown wants every outer and inner bridge up in the same pass,
   whatever stands on the far side. B1 rose before O1 while 33 civilians walked in from the gathering; they stopped in K1,
   part of Kern+ here, so the Kern+ recall counted them inside (`lua/dfllm/sense.lua:146`, census.u.outside) and siege's own
   raise rules (T0..T0+450, the BUG-028 cut hold, siege.lua:1073-1104) never got a say: the lockdown had raised B1 already.
   The deep defense's recall to Tiefe+ could not reach them (B1 up), and the dragon that broke O1 found them in the killing
   field. The STRANDED rescue rightly refused to lower B1 with the dragon inside.
2. `lua/dfllm/sense.lua:487` / `lua/dfllm/reflex.lua:1773`: a wild danger's "far" test used dc, the distance to the nearest
   citizen *outside Kern+* (sense.lua:146 out_pos, from the last citizen census). With Kern+ over the killing field the 32
   stranded civilians did not count: PREDATOR_FAR `63 tiles` (the one citizen outside, at 148,113). The same blind spot hit
   every wild danger (beak dogs, jaguars, cavern predators) next to civilians in Kern+.
3. `lua/dfllm/sense.lua:444` (Run 11, ELK_BIRD): an invader whose raws cannot learn or speak is an `an` animal (`inv =
   false`, k `danger`). The war cave dragon (no CAN_LEARN/CAN_SPEAK, BUILDINGDESTROYER) left the invader count. In y379 this
   only changed the labels (#2907, #2983): SIEGE, the deep defense and BREACH came from the goblins and the destroyed O1
   anyway. The first version of this fix claimed it would bring the alarm sooner; it would not have for this incident.

## Fix
- gate (cause 1): a lockdown's first raise of a manifest inner bridge waits while sense counts civilians on its attack side
  (new census.u `atk`/`atk_ids`: non-soldier citizens outside Kern+ and the refuge, or on an intake tile, zones Z1/Z2 and the
  killboxes, even where Kern+ covers it); GATE (C) `held` names them, and the gate pass runs every 25 ticks meanwhile. It
  goes ahead at once with a hostile within 30 tiles of the bridge (60 while an outer bridge is not up yet), a hostile inside
  Kern+, a building destroyer or great danger in the intake area or past B1, a census older than 300 ticks or none, in
  BREACH, or once someone else (siege) wants it up. A wanted-up bridge is never lowered for it. In SIEGE, siege's raise
  rules (and the BUG-028 cut hold) decide again, as designed; siege.raise's `inside` reason ("nobody outside Kern+") now
  needs `atk` 0 for an inner bridge too (`lua/dfllm/siege.lua` raise), else B1 rises on the timer (T+450) or a hostile near.
- sense/reflex (cause 2): every hostile entry carries `da`, the distance to the nearest civilian anywhere (Kern+, killing
  field, refuge) within 3 z-levels; reflex's predator test uses min(dc, da). The 3-level band keeps a cavern under the fort
  from counting the citizens above it.
- sense (cause 3): an animal invader that is a building destroyer stays an invader (k `inv`, counted in `inv`, bd = 1).
- reflex (review): a wild building destroyer is never "far" only near the fort: in the intake area or past B1, within 30 xy
  tiles of a bridge on the bridges' levels (sense `db`), or walking into the fort (sense `pd`: DF's `unit.path.dest`, the last
  step of its path, on a Kern+ tile, in Z1-Z4 or a killbox, or within 30 tiles and 3 levels of a bridge). A troll or cave
  dragon deep in a connected cavern keeps the Run 10 PREDATOR_FAR rule (the first version locked the fort down for it at any
  distance, during a famine too).
- threat (review: "a building destroyer inside forces BREACH"): a building destroyer or great danger in zone 2 (Kern+, zones
  Z3/Z4) counts as inside: siege goes to BREACH at once from any mode, and the far/harmless lists never clear it. One on a
  Kern+ tile already did (siege.decide `inside`).

## Tests
`tests/lua/test_reflex.lua` (BUG-338 block; the 6 new tests and the changed Run 10 test fail on 038ef1b): the war cave dragon
is k inv; a wild building destroyer far from the fort is PREDATOR_FAR, near a bridge PREDATOR; its path into the fort makes it
PREDATOR, one in a cavern 20 levels below stays PREDATOR_FAR; a wild danger 38 tiles from a citizen in Kern+ is PREDATOR; Kern+
over the killing field: B1 held for the civilian in it (GATE held), O1 up, an invader within 30 of B1 raises it; B1 rises once
the civilian is in, the plain fort raises both at once; a building destroyer in the killbox raises B1 at once; a building
destroyer in Z3 off Kern+ is inside, BREACH. The Run 10 PREDATOR_FAR test and `tests/lua/test_siege_sense.lua` now expect
dc 87 (nearest civilian) and the new `da`/`db` fields. `tests/lua/test_siege.lua` (1 new, fails on 038ef1b): with Kern+
over the killing field and a civilian in it, O1 rises at T0, B1 only on the T+450 timer.

## Live check
- The next lockdown with citizens outside: kern.log `gate: B1 up held for N civilians on its attack side`, GATE `held`, O1
  rises first, B1 once they are in (`no longer held`) or a hostile comes within 30 tiles.
- A wild danger next to citizens in Kern+ gives PREDATOR, never PREDATOR_FAR `nearest citizen 60+ tiles`.
- A cavern building destroyer far below the fort: PREDATOR_FAR, no lockdown; one heading for the fort: PREDATOR.
- Uncertain [? live]: whether `unit.path.dest` of a wild cave dragon points into the fort before it breaks in; whether
  civilians in a killing field covered by Kern+ walk on into the core while B1 stays down (DF keeps them only inside the
  alert's burrow, which here includes K1); whether DF's raws give war cave dragons BUILDINGDESTROYER (both sources are read).

## Open
- **Kern+ covers the killing field (the structural cause).** While Kern+ includes K1, the Kern+ alert keeps civilians there
  as "inside"; only B1 staying down gives them a way on. The real fix is a Kern+ that ends at B1 (fortcore stage 1 / the
  burrows screen; siege already reports `Kern+ covers N tiles of the bailey, trap hall or field`). Not changed here: it is a
  live burrow write. Proposal: a readiness R0 blocker for Kern+ over an intake zone, or a recall that names the civilians in it.
- **Stranded in the field after a breach.** Once a building destroyer is through O1 and B1 is up, the civilians left in the
  field stay cut off (STRANDED `no rescue (a hostile inside)` is right: lowering B1 lets the dragon in). Only the earlier
  hold above prevents it.
- **Inner hold and civilians who cannot come.** A civilian who never comes in (lying, caged, at a far job) keeps B1 down
  during a lockdown until a hostile is within 30 tiles (60 with O1 not up). Safe while O1 is up; the raise takes 250-300 ticks
  after the pull, so a fast attacker can reach B1 first. Not tuned live.
- **FR: cavern openings sealed by default.** Asked in the round, not built: y379 had no cavern opening. Needs its own case.

## Review fix (merge15)
- Documentation only (gate.lua inner_wait): in a SIEGE the inner hold also ends when siege.raise's RAISE_BY timer (450 ticks,
  whatever census.u.atk says) wants B1 up; the hostile-distance releases decide alone only in an ALERT lockdown. Civilians
  still out after 450 ticks of a siege are shut out (crossers keep the footprint clear). Not changed: letting the hold beat the
  siege timer would keep B1 down with a siege under way; needs a live look first.

## Hotfix (live BREACH)
- **Live (Run 15 i2 Guildcleans y392, 66 -> 18):** kern.log (r15-guildcleans-site97, ~6407-6522): `B1 up held for 4-10
  civilians on its attack side`, each hold 6600-7320 ticks (`no longer held (after 7350 ticks)`), again and again, then the
  BREACH `B1 not up at T+900`, 63 lost.
- **Fix (gate.lua inner_wait):** one hold lasts at most `M.INNER_MAX` = 900 ticks; then B1 is wanted up (kern.log `up hold for
  civilians ends after N ticks (INNER_MAX 900), not held again for 12000 ticks`) and the inner hold does not come back for
  `M.INNER_REST` = 12000 ticks (r.iwx, runtime only: a reload forgets it), also not in the next lockdown.
- **Tests:** test_reflex.lua (+1: the hold ends after 900 ticks with citizen 6 still outside; the lockdown lifts, B1 goes
  down for PEACE, the lockdown comes again: B1 rises without a second hold; fails with INNER_REST 1).
- **Open:** civilians still outside after 900 ticks are shut out (the Open point above, now bounded). INNER_MAX/INNER_REST are
  constants, not config; not tuned live.
