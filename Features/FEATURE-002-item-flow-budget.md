# FEATURE-002: `flow` - item flow budget (inflow, sinks, free capacity) instead of counting loose stacks

- **Status:** proposed (draft, written by the local agent "muell", not committed)
- **Priority:** P2 (no crash, but ~14 000 loose stacks, FPS complaints, and every cleanup so far was manual)
- **Requested by:** Gordon (player), 2026-10-02, via the local orchestrator
- **Area:** extends `df_llm_helper hygiene` (+ Lua `lua/pilot_hygiene.lua`), new `hygiene flow`, `hygiene bins`, `orders` audit; digest/wake integration

## Problem
`hygiene status` answers "how many loose stacks are there", but not the three questions that decide whether the pile can ever shrink:
1. **Where does it come from?** (inflow per item type and hour, and which standing order / event produces it)
2. **Where can it go?** (sinks: consumed by building, sold, destroyed by the garbage bridge, dumped; plus free stockpile capacity and bin capacity)
3. **Is the cap that should stop the inflow actually working?**

Incidents (Run 5, year 122, fort of 55 citizens):
1. **Counts polluted by unreachable items.** 1316-1340 `THREAD` (cavern spider webs, all outside the sealed fort), ~860 corpses/parts/remains in caverns and far below the fort show up in `claude/muell status` and in "loose stacks", but nobody can ever move them. The KPI looked like 15 900 but the real, reachable, actionable number is ~13 000 (of which 11 550 boulders that must stay).
2. **Legacy forbidden items nobody sees.** 163 reachable non-dwarf corpses/parts lay *forbidden* next to the garbage bridge (leftovers of removed dump zones: DF forbids items it carried onto a dump zone; plus the standing order `forbid_other_dead_items=1` forbids every enemy corpse/loot at the killbox). `muell dump` skipped forbidden items, `hygiene mark` skipped them too, so they were never marked and the counter never went down. It took a manual script (`claude/muell dump N freigeben`) to find them.
3. **Trade goods inflation.** ~2 900 crafts sit in 30 bins (one bin holds ~120 crafts!) plus ~400 loose, per-kind cap 450 was above the real stock so production never stopped; a caravan absorbs a fraction of that. Nothing reported "stock is 6x the sale capacity".
4. **Capacity is the real bottleneck, not the cap.** 369 goblets and 569 blocks lie loose because the finished-goods stockpiles (57+27+21 tiles, 1 item per tile without a bin) are full, while bins (1 log = ~120 stored items) are the cheap fix. `max_bins` was set on 12 stockpiles for 147+ bins while only 30 bins existed; no tool showed the gap.
5. **The garbage bridge fills up silently.** The dump landing (bridge, 9 tiles) held 391 items, 654 ten minutes later; whether the lever was ever pulled (the real sink) is not part of any report.

## Proposed behaviour
`python -m df_llm_helper hygiene flow [--hours 24]` (read-only), one compact block, ~10 lines:

```
FLOW 24h   type        stock  reachable_loose  inflow/h  sink/h  free_slots  state
           BOULDER     11553  11553            -3        0       -           flat (no inflow), never dump
           CORPSE+PIECE  1050  455              +12       +25     dump zone   shrinking (bridge not pulled: 654 on landing)
           GOBLET      369    369              0         0       0 (no bins)  stuck: order cap 60 ok, needs 4 bins
           CRAFTS(7)   3300   410              +9        +2      0            GROWING: cap 450 > stock 3300/7 -> lower cap
           BLOCKS      569    569              0         -5      105 tiles    ok (cap 400 exceeded, no production)
           unreachable 2200   -                -         -       -            ignored (caverns/webs)
```
Rules:
1. **Reachable vs unreachable.** Count a loose item as actionable only if its walk group equals the fort reference group (as `claude/muell` already does for corpses) and the tile is not hidden. Everything else goes to one line `unreachable N (webs/cavern/surface)` and is excluded from KPIs and wake lines.
2. **Inflow/sink per type** from successive snapshots (state.db already stores them; add per-type columns) plus event counters where the game gives them: `BuildingConstructed`/`ConstructBuilding` jobs finished (boulder/block sinks), `DumpItem` jobs finished, trade sales (existing trade logs), bridge pulls.
3. **Capacity per type:** free stockpile tiles accepting the type (reachable, not full), bins needed = ceil(loose_finished_goods / 100), wood cost = bins needed (config `flow.wood_reserve`).
4. **Cap audit** (`hygiene flow --caps`): for each standing manager order with an item-count condition, compare the cap with the real stock (all items of that type that are not in buildings/removed). Flag `cap above stock` (production never stops), `cap exceeded` (fine), `cap counts differently` (container contents). Source of the order list: `world.manager_orders.all` (same data `claude/orders status` reads).
5. **Forbidden legacy.** `hygiene status` shows `forbidden reachable non-dwarf corpses: N`. `hygiene mark ... --unforbid` sets `flags.forbid=false` and `flags.dump=true` on exactly those (own items, UI actions "forbid off" + "dump"), never on dwarf/named corpses, never on trade goods. Warn when `standing_orders_forbid_other_dead_items=1` (documented source of future forbidden loot; do not change it automatically: it protects haulers during sieges).
6. **Bones are craft material.** The marker must keep bone/skull/shell/horn/tooth/hide classes out of the dump (the current `hygiene mark` has the protection; the local `claude/muell dump` does not, it dumps every non-dwarf CORPSEPIECE incl. ~200 goblin/troll bones). Either route `muell dump` through the same filter or report `bones dumped N` so the player can decide whether to feed the bone crafters instead.
7. **Bin planner** `hygiene bins [--apply]`: needed bins per finished-goods stockpile (loose + planned), existing bins (empty/full/outside a stockpile), wood available; with `--apply` (needs an exception-register entry) create ONE one-off `ConstructBin` order of N bins (wood gate, never a standing order: a standing order with `LessThan N BIN empty` ran away 13 -> 25 in one minute, see the comment in `claude/orders`) and set `max_bins` of the named stockpile (UI container setting). Warn when sum of all `max_bins` > bins that exist (here 147+ vs 30: new bins go to random stockpiles, e.g. a block stockpile that wants 105).
8. **Garbage bridge health** in `hygiene zones`: bridge raised/lowered, items on the landing by type, lever id, "lever last pulled" (from the bridge `gate_flags`/event log if available; otherwise "unknown"), warning when the landing holds > 300 items: "pull the lever (player action)". The lever stays a player action.
9. Wake line only on state change (`CRAFTS growing`, `bridge landing > 300`), once per transition.

## Data needed from the game
- `world.items.other.*` loose scan (exists), walk groups (exists), per-type counters between snapshots (small addition to the existing snapshot rows).
- `world.manager_orders.all` item conditions; `building_stockpilest.storage.max_bins/max_barrels`, `settings.finished_goods.type[...]`.
- `df.global.standing_orders_*` (read only).
- Bridge/lever state: `building_bridgest.gate_flags.raised`, items on the 9 landing tiles.

## Safety / fair play
Reading is free. Writes only through existing UI-equivalent actions: `flags.dump` (exists), `flags.forbid=false` on own non-dwarf remains, a one-off manager order, a stockpile `max_bins` value. No item is moved, created, removed or teleported; boulders and dwarf corpses are never touched; no change to standing orders, alert, squads or walls. Everything with `--apply` needs an entry in the exception register (as `hygiene mark` does).

## Acceptance criteria (fixture based)
1. Fixture "post siege": 1340 THREAD + 850 cavern corpses unreachable, 13 000 reachable -> `flow` prints the unreachable line, KPIs use 13 000, no wake line for the unreachable part.
2. Fixture "legacy forbidden pile": 160 forbidden reachable animal corpses/parts next to the dump zone + 134 dwarf corpses -> `status` reports 160 forbidden, `mark --unforbid --dry-run` lists exactly the 160, `--apply` sets dump+unforbid on them and on no dwarf corpse.
3. Fixture "caps": cap 450 per craft kind, stock 3300 over 7 kinds -> state `GROWING`/`cap above sale capacity` (needs config `flow.sale_capacity`, default 800 trade goods per caravan season).
4. Fixture "bins": 30 bins, 147 requested by stockpiles, 369 loose goblets + 410 loose crafts -> planner proposes ceil(779/100)=8 bins, shows wood cost, warns about the 147/30 mismatch; `--apply` without exception entry is refused; with entry creates exactly one order of N bins.
5. Fixture "bridge": raised bridge, 654 items on landing -> `zones` prints the landing count and the player-action hint; second run without change prints no wake line.
6. Unit test: inflow/sink arithmetic from two snapshots, including a type that appears or vanishes.

## Info needed
- Decision (player): how many trade goods per kind is enough (`flow.sale_capacity`; local value now 300 per kind, was 450).
- Does the cloud session want per-type columns in `snapshots` (schema change) or a separate table? The local agent can supply two recorded `hygiene status` snapshots 1 h apart from the live game on request.
- Recorded answer of `claude/muell status` and `claude/report` (fields `lager_voll`, `kadaver_lose`, `leichenteile_lose`) from the live game: available in `Bugs/evidence`-style files on request.
