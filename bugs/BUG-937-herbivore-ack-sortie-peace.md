# BUG-937 A plant eater inside the fort got the 10 s lockdown default before the ack, and the sortie against it ended 'the mode is PEACE' while it lived
Status: fixed (offline, live-untested)
Severity: medium (clock clamped to 30 t/s, recall, civ alert for a harmless plant eater; the animal is not killed)
Found: Run 17 i3 Orangering y500 sum d11-d15 (E:/DF-test3 region1-site97 `events.1.jsonl` lines 8759-8773, `commands.log` 5314-5316): #53454 PREDATOR (CENOZOIC_MEGACEROPS 32221, 301263 cm3, `hb` 1, `da` 9, `zn` 1) at tick 201716349; #53460 LOCKDOWN 'unacked for 10 s' at 201716829; the player's `ack` is #53464 at tick 201717675 (commands.log wall 1795696617); `squad.sortie` #53465 at 201717775; #53462 HOSTILE_RELEASED (passive); #53469 ALERT>PEACE; #53473 `SORTIE sortie A ended: the mode is PEACE`.
Module: `lua/dfllm/reflex.lua` (`pred_close`, `ack_step`), `lua/dfllm/military.lua` (`squad.sortie`, `sortie_pass`)

## Cause (from the live lines and the code path)
1. The ack DID count: it was simply later than the default. ack_step's quick path (BUG-729, `PRED_NEAR_S` 10 s) applies to a PREDATOR whose unit is inside Kern+ (`zn` 2) or within `PRED_NEAR` (15) tiles of a citizen (`da` 9 here). The default came at tick +480 (~10 s at ~48 t/s), the ack at tick +1326 (about 22 s real by the commands.log walls: wake -> tool call latency). No wrong key and no other event id: `ack` is a global "up to n".
2. The sortie began in ALERT (`pe` not set: BUG-675 set it only for a sortie begun in PEACE); the megacerops was cleared as passive (HOSTILE_RELEASED, `passive_days`), the hostile count fell to 0, the mode went to PEACE and `sortie_pass` (military.lua `mode == 'PEACE' and not so.pe`) ended the sortie at its next look although the target lived and the squad was on its way.

## Change
- `reflex.pred_close`: an animal the census marks a plant eater that never killed (`hb == 1`, `kl ~= 1`) does not get the quick 10 s default; it waits the full `ack_timeout_s` (60 s). The quick default stays for everything that can kill (BUG-729's smilodon; an animal that killed has no `hb`). JUDGMENT, not shown by a log line: that 60 s is the right wait for a plant eater (the 10 s were meant for killers). A plant eater unacked after 60 s still gets the same default.
- `military.lua` `squad.sortie`: a kill sortie begun in ALERT / RECOVERY against ONE wild animal (`unit` given, census `k == 'danger'`, not a building destroyer) carries `pe = true` like a PEACE sortie, so the mode falling to PEACE does not end it; it ends by its own rules (target dead, out of sight `idle_ticks`, timeout, worn, squad empty). A group or an invader keeps the old rule; SIEGE / BREACH untouched.

## Tests
`tests/lua/test_bug937_herbivore_ack.lua` (3: no default at 20 s and the ack honoured; the 60 s default still comes; a killer keeps the 10 s), `tests/lua/test_bug937_sortie_alert.lua` (3: survives PEACE; ends 'gone' when out of sight; a group still ends with the mode). Siege traffic: test_bug729_predator_quick.lua (a real army at O1 plus a predator: SIEGE, O1 / B1 up and held, one default, no double pull), the *15b* suites, test_bug905_909_b1b.lua, test_bug907_*.lua, test_bug928_*.lua unchanged and green (counts in the CHANGELOG / report).

## Live-Erwartung
A big plant eater inside Kern+ or near a citizen: PREDATOR (A) wakes the player, no LOCKDOWN for 60 s; `ack` within the minute: no LOCKDOWN at all. A `squad.sortie` against it started in ALERT keeps running after ALERT>PEACE until `SORTIE dead` / `gone` / timeout. Not proven: that the squad reaches and kills it before `hold_ticks`; the passive clearing is unchanged.
