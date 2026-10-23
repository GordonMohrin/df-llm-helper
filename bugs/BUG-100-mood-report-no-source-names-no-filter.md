# BUG-100 The mood report says "blocks: no source in the fort" with 225 blocks in the stock: no filter, no real count, no real blocker
Status: fixed in the K3 commit (offline, live-untested): every open slot of a mood job is reported with its filter, three counts
and the real blocker in a fixed vocabulary; BUG-101 is not used (the cloth wall is part of this fix)
Severity: high (a wrong report cost a citizen: the Weaponsmith died of thirst after 55 days of a message nobody could act on)
Found: 2026-10-23, Run 14 year 587, game session note 72 (strange mood of unit 35386, Weaponsmith, MetalsmithsForge)
Module: `lua/dfllm/care.lua` (`need_item`, `mood_report`, the thirst branch of `mood_seen`), `lua/dfllm/reserve.lua` (`need_of`)

## Actual
`MOOD_RISK` and `DECISION_NEEDED mood_material` said `blocks: no source in the fort` in every event from win d25 to win d80, while
the game session counted 225 free blocks. The job's `job_items` were: 1 BAR (met), 2 BLOCKS inorganic (not met), 1 ROUGH/boulder,
2 CLOTH of any material (not met: no thread, no plant cloth in the fort). The text named neither the filter the blocks had to
fit nor which of the unmet slots was the wall (the cloth), and it said "in the fort" for something that was a count at a filter.

## Cause (proven from the code; what stays open is under "Not decided offline")
1. **"no source" is a count at the filter, worded as a count of the fort.** `need_item` (care.lua:2346-2356 on b2b9435) counts
   `nd.src` only for an item that passes `R.match(alt, it)`, which applies the job_item's own veto
   (`dfhack.job.isSuitableItem` / `isSuitableMaterial`, reserve.lua:243, the part after the class rules) and the material of the
   filter. `mood_report` (care.lua:2479) names a need `nosrc` when that count is 0, and `stock_note` (care.lua:426) prints it as
   `<name>: no source in the fort`. So 225 stone blocks against a filter only metal serves print `blocks: no source in the fort`,
   and nothing in the text says "at this filter" or how many blocks do exist. Reproduced with a fixture (225 granite blocks,
   a BLOCKS filter with flags3.metal, DFHack's veto answering for it): the base prints `strange mood unit 1 (Fey) starts
   without blocks x2, cloth x2; blocks, cloth: no source in the fort`.
2. **One word for four different facts.** The same count skips every item that is `R.busy` (in a job, owned, claimed by another
   slot, artifact, rotten, built in, a trader's), forbidden items care could not free, items on tiles the fort has not seen, and
   items the dwarf cannot walk to (`nd.far`). "No source" was printed for all of them; `reachable` / walk-group state is only
   visible in the separate `far` count of MOOD_NEED. There was no way to tell "none exist" from "all in use" from "behind a wall".
3. **The thirst line could not name a typed item at all.** `nosrc_text` (care.lua:432-436) matches the names of `rec.nosrc`
   (`blocks`) against the classes of `rec.missing` (`other` for every item type that is not boulders, logs, bars, ...), so for
   BLOCKS, TOOL, DOOR and so on the `MOOD_RISK thirst` line never named the missing source.
4. **The other unmet slots were folded away.** `nseen[name]` (care.lua:2476) keeps one name per class name, the labels list says
   `blocks x2, cloth x2` without a blocker per slot, and a slot the dwarf could fill was not shown, so the reader could not see that
   the blocks might be fetchable and the cloth the actual wall.
5. **The weekly DECISION_NEEDED followed game time alone** (care.lua:2551, `now - u.woke >= rc.rewake_ticks`): at timestream speed a
   game week is about 20 s, so the same text could repeat every 20 s of real time (BUG-008 fixed this for MOOD_RISK only). It also
   never repeated for news, so a blocker that changed (none in the fort -> none reachable) waited for the weekly reminder.
Not a cause: the `kind` / vector choice. For an item type care does not classify (BLOCKS) `reserve.classify` returns `other` with
the vector of the type (`items.other.BLOCKS`), the right one.

## Fix
- `need_item` counts per need, at the real filter: **src** (in the fort: matches the filter, on a tile the fort has seen, not
  built in or gone), **free** (of those: not in use, owned, claimed by another slot, or forbidden where care cannot free it),
  **avail** (free and walkable to, by the same walk-group hook `snapshot.reach` as before), and **kind** (every item of the vector,
  whatever the filter), plus `frb` (forbidden, not freed) and `unseen` (matching, on tiles the fort has not seen). The items the
  dwarf already attached to the job (`m.att`) are in use for it: neither stock nor missing. `reserve.gone` / `R.GONE` split the
  "gone" flags of `R.BUSY` from "in the fort but not free".
- `reserve.words` / `slot_name`: the job_item's filter in a few words (cloth kind, a named material, flags `metal` `hard`
  `non_economic` `soap` `glass`, the material category bits, `ore`), read with the job_item (the pointer is valid in its frame only).
- `mood_report` builds one text per open slot: `blocks(metal) x2: none in the fort [0/0/0 of 225]`. Vocabulary (care.lua
  `blocker`): `none in the fort` (nothing, or no more than the dwarf can already fetch), `none free`, `none reachable` (free items,
  none the dwarf can walk to), `enough exist` (the dwarf has not fetched them yet: another slot blocks). Brackets: in the fort /
  free / reachable, `of N` = every item of the type, `, N forbidden`, `, N unseen`, `, thread N` on a cloth slot (the wall of note 72:
  a cloth slot with no thread says so). A slot the job already holds enough for is never reported; the blocked slots come first and
  the `enough exist` ones follow, so the OTHER unmet slots are always named.
- The texts go into MOOD_RISK (start and thirst/hunger), MOOD_NEED and the DECISION_NEEDED `q` (fit by whole slots, `+N more`),
  all within 200 bytes; `slots` (str[], 4 / 3 / the persisted `rec.sl` 8) is a new optional field of MOOD_RISK and MOOD_NEED
  (schema.py). The thirst line reads the persisted slots of the last full report and drops the filters the job no longer lacks.
- Cadence (util/cadence): MOOD_NEED repeats when the list of filters changes (as before) and now also when a blocker changed, at
  most every max(`mood_risk_every`, `wake_wall_s`); DECISION_NEEDED `mood_material` follows `CAD.due` for news (a new blocker
  token) and the weekly reminder needs the wall clock as well (`CAD.elapsed`, `wake_wall_s`). The same text for 55 days is still
  possible, but only as that reminder and only while the blockers are the same. An older state (a mood record without `bsig` /
  `wrec`) adopts its last announcement silently, no extra question after a reload.
- The cloth wall (item 4 of the package): no economy change. Proof that the kernel already acts at once: care's `mood_wants` lists
  the open cloth slot, `care_hooks` (economy.lua:1404-1440) writes `needs.cloth.care`, `urgent.cloth` makes `plan_cloth` the first
  planner of the slice (economy.lua:6475-6480, priority 1 against 3.5), and `plan_cloth` (economy.lua:1728-1768) orders WeaveCloth
  per thread kind and, with the Farmers workshop standing, SpinThread (the standing orders of FR-73 exist beside them, `T.stand`).
  A DF work order has no priority except its place in the list; only `order_top` (runner's seal) moves orders, and for cloth it
  would change nothing when the wall is "no thread and no plant to spin": the orders cannot run. What a mood can do there is
  fiber crops (BUG-084 / `fiber_plan`), gathering and trade, and the report now says which: `cloth x2: none in the fort [0/0/0,
  thread 0]` next to the route text.

## Not decided offline
- Whether the real filter of the two BLOCKS slots was metal-only, a named stone, or something else (`min_dimension`, a reaction
  class), and whether the 225 blocks passed it: the old report cannot tell, the new one prints it. Read-only live data that decides
  it for a standing mood: `dfhack-run lua` on `unit.job.current_job.job_items.elements[i]` (item_type, mat_type, mat_index, flags1..3,
  material_category, metal_ore, min_dimension, reaction_class) for the BLOCKS slots, and for five of the blocks `mat_type`,
  `mat_index`, `flags.in_job/owned/forbid/in_inventory`, `dfhack.items.getPosition`, `getContainer`, plus
  `dfhack.job.isSuitableItem(ji, type, subtype)` and `isSuitableMaterial(ji, mat_type, mat_index, type)` for them. Or just
  read the next mood's `MOOD_NEED.slots` in events.jsonl.
- The filter words use the job_item flag names `metal`, `hard`, `non_economic`, `soap`, `glass` and the material category bits;
  names that do not exist in 53.16 read as absent (DFHack raises, `get` catches it): a filter the words do not capture shows as
  the bare name, and `of N` still shows that items of the type exist.
- `order_top` for the cloth orders (above) is left out; whether a mood's orders ever stood behind a long queue is a live question:
  position of `dfllm:stand_*` and the weave/spin tags in `manager_orders.all` while a cloth mood is open.

## Tests
`tests/lua/test_care_mood_slots.lua` (new; ten of eleven fail on b2b9435, the eleventh guards the reload of an older state):
the note-72 fixture (225 stone blocks, metal filter, attached bar, boulder, cloth with no thread: the filter, `[0/0/0 of 225]`,
`enough exist` for the boulder, no bar, the cloth wall, the thirst line, the question), one fixture per blocker (none in the fort,
none free, none reachable, enough exist, two slots unmet), a metal block among 225 stone ones, the 200-byte and 1,024-byte limits
with eight long slots, the cadence (news waits for the clocks, the same blocker is quiet). `tests/lua/test_care_moods.lua` (text of the
five tests that quoted `no source in the fort`; the weekly reminder now needs the wall clock), `tests/test_k3_mood.py` (schema,
documents), `tests/test_care_fr_files.py` (the `slots` field).
Related: BUG-017 (the original `no source in the fort`), BUG-008 (cadence), BUG-063, FR-44, FR-73, BUG-084.
