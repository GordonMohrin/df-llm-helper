# BUG-357 door deadlock: workshops and farms wait for a door that only a Carpenter's workshop (that does not exist) makes
Status: fixed (offline, live-untested): measure_build does not wait for a planned door while no Carpenters or Masons workshop
stands built (rooms, farms; seals keep theirs); a new fort asks for the mandatory shops; the startup shops (BUG-356) remove the cause
Severity: high
Found: 2026-11-04, Run 16b (i2 region1-site97 y372 d28-60, `runs/run-16b/FR-BUGS.md` "Werkstatt-Deadlock"), 16c, main 595364a
Module: `lua/dfllm/runner.lua` (measure_build, Q.no_door_shop, Q.sync)

## Actual
c1a1a6b627ff281106 (farms) stalled 33 d at build 50 %, c1a1a6b6d5abebe40b and c1a1a6b6d6d60f1b0c (workshops) 32 d at build 50 %:
'waits: Door 61,101,129: job 745 suspended by buildingplan: waits for door x1 (0 free, 3 ordered)' (kern.log 150133567-150143167);
economy 'stone queued for door: behind the other rock orders, no Carpenters (door x1 wait)'; no Carpenters, Masons, Kitchen or
Craftsdwarfs workshop for 130 days, 32 orders stuck ('no Carpenters workshop', 'no Masons workshop'). i3: the same, pop 13.

## Root cause
A door is made at a Carpenter's (wood) or a Mason's (stone) workshop. runner.lua measure_build counted every unbuilt
building of a build stage as pending (`if built(b) then done else pend`), so a stage with a door in a fort without either shop
waited for ever, and a project that is itself the way to a shop (workshops: the door is in the same stage as its shops) or a
farm behind a door could not go on. BUG-273 handled only a seal's door; the mandatory-shops request (Q.sync) fired only for a
reclaimed fort (`ad.rec == 1`), never in a new one.

## Fix
- measure_build: while `Q.no_door_shop()` (neither a Carpenters nor a Masons workshop is BUILT; unreadable = no claim) a planned
  Door of a project that is not defense class and not seal/plug/repair counts as done: the stage goes on, the planned door stays
  on the map and DF builds it once a shop makes the item. kern.log warn '1 door(s) not awaited ... (BUG-357)' once per count.
- Q.sync: a deferred door (S.rt.dd) makes a new fort ask for the mandatory shops like a reclaimed one: PROJECT_REQUEST workshops
  why=mandatory (Carpenters, Masons, Craftsdwarfs, Still, Kitchen, as far as missing and not under way) after `rec.ask_days`.
- BUG-356: the startup set builds a Carpenters and a Masons on the surface in the first days, with no door.

## Tests (fail on 595364a)
tests/lua/test_bug357_door_shop.lua (5): farms defers, a built Carpenters keeps the wait, an unbuilt one is no shop, a seal keeps
its doors, the request of a new fort.

## Live check
A new fort without shops: farms/workshops pass their build stage (kern.log 'door(s) not awaited'), PROJECT_REQUEST workshops
why=mandatory after 3 d; once a Carpenters stands the planned door gets its order and is built.
