# NEU4: DF's own reason is the source of truth (BUG-841..846)

Status: offline, live-untested. Branch `neu4-ursache`, base main 6e337e1e. Lead's live look 24.11.2026: `leitung/neu3/LIVE-DIAGNOSE-2026-11-24.md`.

## What the live look proved

DF itself creates the jobs and cancels them with a reason: i2 gamelog 86,405 x "cancels Brew drink from plant: Needs empty food storage item."; i1 2,729 x the same plus
hundreds of "Make wooden door / bucket / cabinet / crafts: Needs logs.". The kernel saw "no job yet". Its census counted what DF cannot use: i1 wood 183 while 198 of 204 logs lie
on tiles with no walk group; i2 7 "free" empty barrels that DF has not used for ~700 game days (322 of 348 barrels full, 8 forbidden, 11 in buildings, 4 trader).

## Rules (no new special-case maze)

1. DF's reason wins. `cancelwhy.lua` keeps a persisted rolling tally of `<job kind> x <reason>` per game day (7 d window, 14 d kept, bounded). Source: the CANCEL_JOB announcements
   eventful delivers (`economy.cancel`, the path that already produced the live `CANCEL_LOOP` events); text parsed by `orderlib.cancel_parts`. A verdict is called proven only when DF's
   reason supports it (`M.df_supports`).
2. The census counts only what DF could use (wood, empty barrels and pots). Usable and total are shown where they differ.
3. A cure acts only with DF's reason in the window (`economy.cancel`): no reason, no cure.

## Where DF's reason shows

| Place | Text |
|---|---|
| `dfpilot why <key>` / `inspect what=why` | first words: `DF cancelled brew drink from plant 412x in 7 d: Needs empty food storage item (last 2 d ago)`, then the old cause; a guessed cause (`unknown`, `conditions`) becomes `df_reason`; result field `df` |
| brew_watch / ORDER_STUCK 'brewing stalled' | `no empty barrel or pot ...; DF cancelled Brew 420x in 7 d: ...` (no 'by my count'); without DF's reason the container verdict stays 'by my count'; a guessed cause (`untaken`, `nojob`, `suspended`) is replaced by DF's words, another verdict gets them appended |
| stale-order ORDER_STUCK, kern.log | the jobwhy line carries DF's words first |
| PROJECT_BLOCKED (set aside / stale) | construction cancels lead the `waits` text |
| weekly `raw stall` line | `raw stall brew: DF: <text or 'no cancel reason seen'> | orders=...` |
| state `stock.dwhy`, brief 'drink:' | `DF cancels Brew 412x in 7 d: Needs empty food storage item; ...`; flag `stock.dcx` |
| ladder NAECHST (Versorgung) | with `dcx`: `order.add MakeBarrel` instead of `bp.place ... only=Still` |

## The census

`classify` (economy.lua): WOOD, empty barrels and empty pots call `far(it, true)` (strict: a tile with NO walk group is out of reach; `snapshot.far` answers `true, 'nowalk'`). Logs held by a job
(`wood_busy`), logs DF skips (in a building, trader's, rotten: `wood_skip`) and the unwalkable ones (`wood_nw`) are counted apart. Cost: nothing added per item (the same snapshot call, strict flag;
the flag word is read once per item as before, the in_job bit comes from it). Plants are unchanged (their far read stays as is).

State `stock.wood/woodt`, `stock.cont/contt` only where they differ; brief: `wood 0 usable of 204`, `containers 0 usable of 7 empty`.

## Cures (BUG-844)

`economy.diag.cx_cure` default ON, gated by `cx_gate`: >= `cancel.cx_min_n` (5) brew cancels 'Needs empty food storage item' within `cancel.days` (7).
- the census' free-container count is not trusted (phantom at once); verdict `nobarrel` proven by DF;
- plant piles' barrel limit frozen (`act.pile_barrels`; never a pile with no barrel); restored when the reason leaves the window, or after `cancel.cx_pile_days` (14) days and not renewed for 14 more;
- CARPENTER on 3..6 reachable citizens (2 + brews/10), STONE_CRAFT on 2; direct MakeBarrel tasks as before;
- the ONE relief for drink 0: rock pots beside the barrels (<= 6 at once). Why this one: the plant piles take barrels, never a large pot (the container pool they cannot eat), no food is dumped
  or cooked (the cook takes only EDIBLE_COOKED plants the kernel bans from the kitchen on purpose and the piles refill an emptied barrel at once), the order path exists (BUG-772, `plan_pots`),
  and pots need no logs (i1 has no usable log).
`mgr_chores` and `still_pin` stay off.

## Needs logs (BUG-845)

The truthful census makes i1's wood 0 usable, so the existing treeless path (caravan wood wants, autochop target, wood floors) follows. `labor.set woodcutter` is a player verb. Nothing digs, channels or
moves tree felling: the cause of the 198 unwalkable logs is not proven. The sample (BUG-843) must show per log: the tile type / shape / material (a tree-top or branch tile, water = logs fall where no unit stands:
then chop only trees whose trunk is on the citizens' walk group), liquid depth, building and stockpile (a sealed stockpile), group 0 vs a number (walled in). Only then the felling rule changes.

## Dumps (BUG-843, BUG-846)

`items:<k>` prints up to 10 sampled items (2 of every first reason, 3 free): id, tile (snapshot.tile: char, shape, material, liquid, building), stockpile (id, name, max_barrels), walk group, container,
contents, flags, general refs, reasons. Dumps are paged (<= 6000 bytes, `--page N`, inspect arg `page`); `brew` lists orders first (2 in full), Stills one line each; an empty CLI reply is an error, not silence.

## Config

`economy.cancel` = `{days 7 (1..14), cx_min_n 5, cx_pile_days 14}`; `economy.diag.cx_cure` true. `lint --config` checks both.

## Residual risks

- Counts are lower bounds (eventful queue drops when full; a message DF folds into a repeat count is one report).
- The wording `Needs empty food storage item` is matched as 'empty food storage' / 'empty barrel' / 'empty pot' / 'empty container'; another DF version's wording is not a container reason (no cure, only reporting).
- Large pots are assumed to be taken for a Still job (BUG-772 counted them as containers; not proven live).
- The 7 phantom barrels stay counted free by the census (no flag explains them); DF's reason overrides the count.
- Unreachable citizens are skipped for the container labors by one snapshot.far read each (a citizen in an unknown place counts as reachable).
