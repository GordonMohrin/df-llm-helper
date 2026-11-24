# NEU1 P4: Growth follows safety (decision E1)

Package P4 of the realignment (leitung/PLAN-NEUAUSRICHTUNG.md, E1). Offline, live-untested.

## Old decision

- Pop cap 100 at R0, R1 and R2 (D-01 = B, 2026-10-24; `readiness.CAPS`). R0 slowed nothing. Several holds were added one by
  one afterwards (`defense_short` for traps and armour worn %, `open_perimeter`, `unsafe`, famine, the player's ceiling). Each
  one held max-pop *at the population of the day it started*, and each had a way to relax. None of them looked at whether a
  soldier actually holds a weapon.
- Evidence: the big wipe-outs came at pop 77-100 with readiness R0 and 0-46 % armour worn (GRUNDSATZ-REVIEW §3.2). Brotherarrow
  86 -> 2, Syrupobeyed 96 -> 1, Castletongs 100 -> 7, Basementflew 52 -> 7.
- Sorties: in SIEGE/BREACH a squad with fewer than 30 % of its soldiers holding a real weapon AND wearing body armour was refused
  (`unfit_text`, BUG-510), and the kernel's own kill order and the sortie advice wanted `worn >= 80 %`. Run 16d i4 Trumpetrealms
  y461: one goblin killed 49 of 69 citizens. Run 16c i3 y379: a lone goblin snatcher, "no sortie (worn 62 % < 80 %)". Run 16a
  i1 y396: "no sortie (worn 54 % < 80 %)" against one Megalania.

## New behaviour

### (a) The growth ladder (`readiness.growth_ladder`, ceiling why `growth`)

A fixed ladder of four pop caps. Each step needs every condition of all the steps below it:

| Cap | Needed to go higher (Halt key) |
|---|---|
| 30 (`base`) | `squad`: the first melee squad has `armed_min` (3) or more members and every one of them is armed (a real weapon in hand, or a training weapon while a real one waits for him, see below); `drink`: at least `drink_d` (30) days of drink inside Kern+/the refuge (seal's `alert.core_d`) |
| 50 (`armed_cap`) | `full`: `full_ready` (6) soldiers fully equipped (all five armour slots of the uniform worn + a real weapon); `share`: at least `share` (70) % of ALL soldiers fully equipped; `r0`: readiness level >= 1 (R0 passed); `lever`: a linked lever inside the core |
| 80 (`ready_cap`) | `metal`: `full_top` (10) soldiers fully equipped with metal armour in every slot; `share` still holds |
| 100 (`top_cap`) | none: the ladder does not hold; the level cap (`readiness.CAPS`, 250 at R3) applies |

- The halt is the FIRST failing condition of the next step, in the order of the table. It goes to `POPCAP` (`halt`, `need`),
  to the new event `GROWTH_HALT` (class B, whenever the step or the halt key changes), to the state (`ready.gh =
  {cap, next, halt, need}`) and to `pop.hold` (`growth 50 (share)`).
- The ladder is one more limit in `readiness.ceiling` (min with the level cap, plan, player, famine). All other holds stay as
  they were.
- Never evict: a lower ceiling never goes under the population (the existing freeze: max-pop = max(ceiling, min(old, citizens))).
  The cap only stops immigration.
- A step is given up only after the ladder has read lower for `drop_days` (5) game days in a row (a soldier dying or swapping
  kit must not flip max-pop). A rise is immediate (max-pop itself still rises only in PEACE).
- Fail closed: no military KPI / kit counts, no drink-in-core reading, no lever reading -> that condition fails.
- The lever: if gate (package P5) publishes `gate.core_lever(K) -> true|false`, that answer is used. Until then it is derived
  from readiness' own lever check: a manifest bridge with >= 2 linked levers (`check_levers` good) that is not in
  `lever_outside` (all its levers outside Kern+).
- The armour share is counted by `military.kit_stats` (per soldier via `dfllm.kit.soldier`): new fields `fullr` (all armour +
  armed), `metal` (fullr with every armour piece of metal), `sq_n` / `sq_w` (members of the first melee squad / those armed),
  `wb` (soldiers armed by a waiting real weapon).

### Armed under the training policy (verifier round)

The shipped training policy (FR-89/FR-100, `military.training.on`) puts a wooden training weapon in every melee hand in PEACE
and DRILL and gives the real ones back in any alert (`ensure_weapons`). The first round counted only real weapons in hand, so a
calm fort never cleared `squad` and sat at 30 for good (max-pop rises only in PEACE). Now one rule, in `military.kit_rows` /
`military.back_rows`, used by the ladder and by the small fight alike:

- a soldier of a melee squad on the policy (`tr = 1`, or `un = 1` while the wooden specs are being taken back) who holds a
  training weapon counts as armed while a real melee weapon of the fort waits for him;
- the waiting weapons are census.i `g_weapon` (economy: metal melee weapons, free or held by soldiers; no picks, axes or
  training weapons) minus the real weapons the melee soldiers hold now, handed out one per such soldier, the first melee squad
  first;
- fail closed: no census reading or no real weapon = a wooden weapon arms nobody. Conservative on purpose: battle axes (the
  woodcutters' tools) and non-metal weapons are not counted as waiting.
- `growth.wood = false` returns to "real weapon in hand only".

This holds in every mode, so an alert longer than `drop_days` does not pull the step back while the soldiers swap, and a small
fight in the first ticks of a BREACH is not refused while the swap is pending.

### (b) Small fights (`military.small_fight`)

A sortie against a small group is never refused for armour when a squad with weapons exists:

- small = census fresh and not cut, 1..`max` (3) visible hostiles in all, none a great danger, undead or building destroyer,
  and threat's siege flag is not `invaders` / `great` / `undead` (an invasion of up to 3 visible units is small);
- the squad has at least `armed` (2) members holding a real weapon.

Then: `squad.sortie` skips the BUG-510 `unfit` refusal (kill orders on those hostiles only), `military.kill_lone` skips
`worn < sortie.worn` and `unfit`, a kept sortie is not ended for `worn`, and `sortie_advice` recommends it (armour and
the odds not counted: the combat value counts armour, three untrained armed dwarves read `hopeless` against one goblin; the
odds stay in the text). The gate sortie (`siege.sortie`, SIEGE through O1) skips its `worn < sortie.worn`, `unfit` and
combat-value refusals for a small fight too (`small_fight.gate`; the evidence Run 16c i3 y379 and 16a i1 y396 were hostiles
OUTSIDE the gate); every other check there stays: hostiles past B1 / in the bailey, trap hall or field (`zin`), dangerous
hostiles in sight (`dz`), civilians in the zones, the airlock bridges. The intake waves and the stations keep their armour
rules: sieges and megabeasts are refused as before.

## Config switches (config/reflex.json)

- `growth`: `on` (true), `base` 30, `armed_cap` 50, `ready_cap` 80, `top_cap` 100, `armed_min` 3, `full_ready` 6,
  `full_top` 10, `share` 70, `drink_d` 30, `drop_days` 5. `on: false` = the old rule (no ladder).
- `growth.wood` (true): a training weapon with a real one waiting counts as armed; false = real in hand only.
- `small_fight`: `on` (true), `max` 3, `armed` 2, `gate` (true: the gate sortie too). `on: false` = the old refusals.
- A config without the section keeps the old behaviour (the unit-test harness's bare config); the shipped config has both on.

## Deliberately not done

- No new lever, no gate code (P5). No change of the R0..R3 levels, `CAPS`, the other holds or plan propose's ceiling.
- No eviction, no lowering of max-pop below the population.
- Squads are not re-staffed or re-equipped here; the ladder only names what is missing.
- Intake waves and the siege's station rules keep the 80 % / 60 % armour rules (they open the gate to an army).
- No per-position record of the real weapon each wooden position gave up (`nw_set` marks positions without a weapon, not
  the weapon): the fort-wide stock count is simpler and fails closed.
- No Python mirror of the ladder in `plan check` (the kernel publishes it in the state; package P1 shows it in the ladder line).

## Live-Erwartung

1. In a fort of 30+ citizens without a fully armed squad A, events.jsonl shows `POPCAP ... halt=squad` (or `drink`) and
   `GROWTH_HALT` with `cap 30`; no migrant wave takes the citizens above 30 + one wave.
2. `status` / state `ready.gh` names the halt at every moment; after squad A is armed and the core has 30 drink days, a
   `GROWTH_HALT` with `cap 50` follows within a game day.
3. No fort that starts on this version goes above pop 50 while fewer than 70 % of its soldiers are fully equipped (the plan's
   success criterion): every pop > 50 line in the logs has `ready.gh.cap >= 80` or a population that was above 50 before.
4. A lone goblin / snatcher / wild animal (<= 3 hostiles in sight) in SIEGE, BREACH or PEACE: `squad.sortie` and the kernel's
   kill order start (`SORTIE phase go`) with worn under 80 %, no `not equipped` / `worn N % < 80 %` refusal while a squad has
   2+ armed members (the gate sortie through O1 included: `small fight: 1 hostile` in its reply); a real siege (more than 3
   visible, or a building destroyer / great danger) is still refused with the old texts.
5. In a calm fort on the shipped training policy (state `mil.kit.wood` > 0, `mil.kit.tr` >= 1) with real weapons in stock,
   `ready.gh.halt` moves past `squad` (to `drink` or later) and `GROWTH_HALT cap 50` appears once the core holds 30 drink days; a cap
   that stays at 30 with `halt=squad` while `g_weapon` >= the first squad's size is a bug.
