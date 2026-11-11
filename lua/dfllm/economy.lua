-- economy (WP8): item census K.census.i (CONTRACTS Ã‚Â§6.3), stock days with a 7-day moving average,
-- staged orders-library imports, dfllm-tagged supply orders, the PLUMP_HELMET kitchen exclusion,
-- the cancel-loop detector, labormanager starvation KPI and the idle rule D-03 (DESIGN Ã‚Â§5.5, Ã‚Â§5.9, Ã‚Â§5.11),
-- and since live L4 the supply chains and the soldiers' gear (below).
-- Reads: items.other vectors (sliced), buildings.other vectors, manager orders, citizens by census id,
-- the material raws of items the fort holds (ore, flux, seeds), military.targets/kpi, care's naked count
-- (K.view) and care's reserve hooks. Writes only through K.act (orders_import, orders, workorder, order_suspend,
-- kitchen_exclude, appoint, work_detail, order_material, run). Since live L1b economy is the sole writer of the
-- builtin tool work details; since L4 it also owns autochop's target after boot (baseline sets 150/60 at boot,
-- economy raises it with the wood ordered) and the autofarm thresholds of the fiber crops.
--
-- Supply chains (live L3: 10 of 13 strange moods failed, all fatal, with 0 bone, shell, leather and bars and 4
-- cloth; worn 15 % without any armor; 24 % naked; dfllm:barrel made 34 barrels in L1b). Work orders, work
-- details and the autochop/autofarm settings only (UI-equivalent); nothing is created, moved or read hidden:
--   wood    autochop target = floor + wood ordered + margin (never below baseline's 150/60); every wood order
--           of economy carries an AtLeast WOOD > floor condition, so the reserve stays in the fort;
--   barrels MakeBarrel only while drink days < 150 % of the plan's target, fewer than 4 empty barrels and
--           the barrel total below clamp(cit / 2, 8, 30) (30 while drink is below the target, and up to 80 while
--           fewer than 4 are empty then, live L6; below 30 drink days the barrels may take economy's own wood
--           floor); bins alike (no drink gate);
--   leather hunters (1, 2 while a need is open) while leather, bone or shell is short, from P1, in PEACE and
--           only with bolts; 10 days without a new hide/bone/leather/shell -> 20 days off (no visible game);
--           leaving PEACE takes them off the detail at once (MODE rushes the next run); famine hunters only in
--           PEACE and RECOVERY; a dead citizen's remains are no bone/shell/hide stock;
--           raw hides waiting 2 days -> TAN_A_HIDE (DF 53 tans automatically, this only adds jobs);
--   cloth   target = max(mood stock, needs, care's naked x 3 in free cloth): WeaveCloth per thread kind,
--           ProcessPlants for thread, autofarm thresholds up for the fiber crops the fort has seeds of;
--   metal   SmeltOre per ore kind, BRONZE_MAKING (ores) / BRONZE_MAKING2 (bars), MakeCharcoal sized by the
--           smelt and forge jobs; no ore: PROJECT_REQUEST explore (seasonal) and DECISION_NEEDED metal
--           (yearly), since economy may not designate digs (an exploration dig is a runner/LLM action);
--   gear    every wanted squad position (military.targets): body, head, pants, gloves, shoes, plus shield and
--           weapon (melee) or crossbow, quiver and bolts (squad C); crossbows and bolts for the hunters too.
--           Metal by preference (steel, iron, bronze, bismuth bronze, copper), else leather, else wood or
--           bone. The inputs of worn % (wanted, at hand, ordered, route per slot) are logged when they change
--           and kept in persist m.economy.gear. At hand, body/head/pants count only true armor ([ARMORLEVEL]
--           >= 1), never a dropped cloak, hood or trousers.
-- At most `orders_per_day` new orders a day, one DF command per frame (`slice_cmds`; live L3: the 20 ms daily
-- step got economy demoted x8, so the daily run is a task list over several frames).
--
-- Hook API (K.call('economy', fn, ...); care's moods are the first user):
--   need(key, n, who[, days]) -> ok, route   a short-term need: the key's target becomes >= n at once (orders,
--       hunters, tanning, weaving, smelting, charcoal, autochop), the key's floor too (economy's own consumers
--       keep n), for `days` (default need_days, 1..112); n = 0 clears it. A new or larger need makes the next
--       run come within rush_ticks. ok = false when economy has no production route (rock: a stone dig;
--       gems: mining/trade; bars without ore: exploration/trade); the need still counts as a floor.
--   reserve(key, n, who) -> ok, floor   a standing floor of key that economy's consumers (wood furniture,
--       charcoal, barrels, bins, gear, bolts, idle blocks and crafts) never go below; the floor is the max of
--       config `reserve`, every holder and every open need; n = 0 drops the holder.
--   supply() -> {key = {have, held, want, floor, route}}   read-only status (brief, tests)
--   mat_for(kind, n) -> via | nil, why   Run 11: can the fort make n of a seal piece now (door, hatch, grate, wall;
--       runner's seal remake): 'item', 'rock', 'wood', a building material, nil + 'no material for door: no rock, no logs'
--   trade_wants() -> {{buy, n, why, metal?}}   Run 11: tokens trade asks the caravans for (picks for the Miners; while
--       metal is short for the soldiers picks, axes, bars and metal gear, metal = 1)
--   metal() -> {short, worn, bars, ore, need, melt} | nil   Run 11: is metal short for the soldiers (M.metal_plan)
--   keys: wood, rock, bone, shell, leather, cloth, thread, bars, gems, fuel, hides (care's class names
--   logs, boulders, rough, glass are accepted as aliases).
-- Pull hooks economy reads when care has them (live L4, care.lua/reserve.lua): care.reserved() -> {class = n}
-- items care holds forbidden as the mood reserve (counted as stock; the floor economy keeps on top of them is
-- max(0, floor - held)), care.mood_wants() -> what open moods still miss ({{cls, n}} or {class = n}): a need.
--
-- Orders, jobs and food gaps (FR-01, FR-10, FR-16, FR-17, FR-23, FR-25, FR-39, FR-40, FR-50; Run 9):
--   * order guard (every run): a make-item order without item_subtype (orderlib.SUBTYPE_JOBS) crashes DF 53.16
--     when a dwarf takes it: it is removed at once (act.order_remove, the work orders screen) and ORDER_BAD (A)
--     names it; state orders.bad counts what is left (doctor flags it). act.workorder and the inbox verb
--     order.add refuse such orders before they exist;
--   * order sanity (daily): per open order the built workshop, the input on the citizens' walkable group and a
--     worker with the labor (orderlib); an order that cannot run for orders.stuck_days -> ORDER_STUCK (B);
--     an order whose jobs cancelled `orders.needs_drop` times with "Needs ..." is removed (ORDER_STUCK dropped);
--   * suspended ConstructBuilding jobs (daily): the ones nobody keeps suspended (suspendmanager's
--     preventblocking, buildingplan's planned buildings) are resumed (act.job_resume), the rest reported by
--     reason (JOBS_SUSPENDED, inspect workload); suspendmanager's preventblocking is the fort's decision (verb
--     jobs.release preventblocking=..., persisted), never forced by baseline. BUG-009/004/005 (Run 9 live test):
--     forbidden items on a building's footprint (revealed tiles) and forbidden loose items of the class a planned
--     building waits for are unforbidden first; a resume is verified a frame later and counted per job; repeated
--     failures raise DECISION_NEEDED build_blocked and move a stuck trade depot inside the entrance (see T.jobs);
--   * work details keep no ids of dead or departed citizens (act.work_detail_prune), so "detail full" is true;
--   * farm plots: every empty season slot gets a crop that grows then and there (underground crops all year),
--     a crop with usable seeds first (act.farm_crop, the plot sheet);
--   * forbidden containers of drink and food (any item type: barrels, pots, bags) and forbidden seeds and seed
--     bags are unforbidden on revealed, reachable tiles in PEACE/RECOVERY; seeds in a forbidden item or
--     container count as unusable (census seeds_forb);
--   * starvation (food_d <= starve.days with hungry citizens): reachable visible edible shrubs are marked for
--     gathering (act.plant_gather), the planters and plant gatherers details get members, forbidden food is
--     unforbidden, and DECISION_NEEDED starvation names the citizens who cannot reach food;
--   * Run 11 (Kilrudrabed): cook ingredients counted as a kitchen does (cook_in), ORDER_STUCK names why a kitchen
--     cooks nothing, a fishery request for raw fish, the fishing zone on safe revealed water, and the food_low/famine
--     decisions name the blockers and the options (section "fishing and the food blockers");
--   * B2 (lua/dfllm/orderfix.lua; Run 13 y508/y523, Run 14 y558-y577): at most slabs.max_orders EngraveSlab orders, never
--     more than there are unengraved slabs, ConstructSlab first (T.slabs, M.slab_pass); a workshop type whose slots are
--     full of jobs that cannot run is the reason of the orders behind it (M.jam_scan, orders.jam); one-time orders with
--     no job in any workshop (job.order_id) for stale.days go wood, are made again or reported (T.stale); the standing
--     thread and cloth orders from P1 and the farmer's workshop request (T.stand, M.farmers_request).
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local OL = require('dfllm.orderlib')
local CAD = require('dfllm.util.cadence')   -- BUG-008: when a standing class-A condition is announced again

local M = {name = 'economy', every = {ticks = 1200}, on = {}, verbs = {}, inspect = {}, MASK_CHECK = 300,
           reports = {MIGRANT_ARRIVAL = true, MIGRANT_ARRIVAL_NAMED = true, D_MIGRANTS_ARRIVAL = true,
                      CANCEL_JOB = true}}
M.OF = require('dfllm.orderfix')   -- B2: slab census, workshop job lists, the stale-order rules (a library, a field: no new local)
M.citizen = require('dfllm.util.who').citizen    -- BUG-103: a citizen of the player (a field: economy sits at the 200-locals limit)
local DAY = C.TICKS.DAY
local EVERY = 1200
local COAL = 7                       -- df.builtin_mats.COAL: charcoal and coke bars (fuel)

-- mirror of config/baseline.json "economy" (tests/lua/test_economy.lua checks they agree)
M.DEFAULTS = {
  per_slice = 200,
  -- live L3: one daily step of ~20 ms (two labormanager commands, workorders, imports) demoted economy x8
  slice_cmds = 1, orders_per_day = 6, rush_ticks = 100, need_days = 30,
  seed_milli = {drink = 53, food = 24},          -- Run 6 rates per dwarf and day, x1000 (DESIGN Ã‚Â§5.11)
  spike_x = 3,
  food_cats = {'FOOD', 'MEAT', 'FISH', 'CHEESE', 'EGG', 'PLANT', 'PLANT_GROWTH'},
  mood_keys = {'cloth', 'leather', 'bone', 'shell', 'gems', 'bars'},
  mood_from_phase = 'P1',          -- live L1b: two dwarves died after failed moods; the mood stock is a P1 goal
  -- the plant and its seeds: seedwatch never manages these plants (baseline), so its seeds need the ban
  kitchen = {{plant = 'MUSHROOM_HELMET_PLUMP', mat = 'STRUCTURAL', item = 'PLANT', what = 'Cook'},
             {plant = 'MUSHROOM_HELMET_PLUMP', mat = 'SEED', item = 'SEEDS', what = 'Cook'}},
  famine_days = 10,
  -- supply alarm (live L1: two dwarves died of hunger and thirst): >= units citizens over the thirst or
  -- hunger timer, or drink/food below `days`, holds arbiter's brake and wakes the LLM (weekly)
  -- live L1b: 25000 is DF's plain "thirsty" (dwarves at work reach it daily: the brake flapped and woke the
  -- LLM weekly with 135 drink days); 40000 leaves 10000 ticks to dehydration (50000), 35000 to death.
  -- live L3: 50000 is DF's plain "hungry" (dwarves eat only then): 2-3 hungry citizens with 150 food days held
  -- the brake on and off all season (47 brake switches); 65000 leaves 10000 ticks to "starving" (75000)
  alarm = {thirst = 40000, hunger = 65000, units = 2, days = 10},
  -- live L3: quickfort `orders` makes every door, cabinet, coffer, coffin, table and chair a rock order; on this soil
  -- embark 43 such buildings waited two years (8 boulders, 82 logs). Below `boulders_below` free boulders, open
  -- one-time rock orders of these jobs are re-entered in wood while logs beyond max(`wood_min`, the wood floor),
  -- minus the wood already ordered, cover their amount; at most `per_day` orders a day
  wood_orders = {boulders_below = 20, wood_min = 30, per_day = 8,
                 jobs = {'ConstructDoor', 'ConstructCabinet', 'ConstructChest', 'ConstructCoffin', 'ConstructTable',
                         'ConstructThrone', 'ConstructArmorStand', 'ConstructWeaponRack', 'ConstructHatchCover',
                         'ConstructGrate', 'ConstructFloodgate'}},
  -- Run 11 (Kilrudrabed y432: 1 boulder, ~110 orders 'no rock', `seal at=last` ended build_lost for its door): the
  -- item a planned building waits for (doors, hatches, grates, furniture: M.PIECES; buildingplan waits for the item,
  -- never for raw rock) is ordered in a material the fort has (T.jmake, at most max_n per kind): rock while the free
  -- stone covers it and the open rock orders, else wood (doors, hatches, grates and floodgates down to the moods' wood
  -- floor only), else rock behind the other rock orders while stone is free; the walls' building material is what
  -- buildingplan allows (its logs/boulders/blocks setting goes on when that is all the fort has; never bars); nothing
  -- makes it, or a seal piece queues behind the rock orders: MATERIAL_SHORT (B) once per set (util/cadence,
  -- report_days). rock: a "Needs rock" cancel while the stone is short of the rock orders re-enters the order in wood,
  -- with no free stone at all removes it (drop_per_day); no orders recheck for a rock cancel loop then; rock below the
  -- need while the miners have nothing to dig: PROJECT_REQUEST bedrooms why=rock (rooms) at most every request_days
  -- BUG-607 (Run 16c i3 Wallfree: an embark without a tree, doors and beds waited 32 days for logs): treeless_days with no log (or no tree on
  -- the map) is a treeless fort: doors, chests, tables ... are made of stone even while DF denies hard stone (a bounded probe, M.HARD.sticky),
  -- a bed (wood only) is named and the caravans are asked for logs
  pieces = {max_n = 6, report_days = 28, tag = 'dfllm:piece_', treeless_days = 20},
  rock = {drop_per_day = 20, request_days = 7, rooms = 4},
  -- Run 11: 2 picks for the Miners' target and 1 iron bar: a pick from the first metal with a spare bar at a forge,
  -- else economy.trade_wants asks the caravans for picks (trade puts it before plan.trade.want)
  picks = {tag = 'dfllm:pick', metals = {'COPPER', 'BISMUTH_BRONZE', 'BRONZE', 'IRON', 'STEEL'}, max_jobs = 2},
  -- BUG-707: the same for the Woodcutters' axes (a battle axe)
  axes = {tag = 'dfllm:axe', metals = {'COPPER', 'BISMUTH_BRONZE', 'BRONZE', 'IRON', 'STEEL'}, max_jobs = 2},
  -- Run 11 (Kilrudrabed y431-y441: no metal ore on the site, bars 0 for ten years, the caravans were never asked for
  -- iron; 10 soldiers at worn 58 % lost siege 8): metal is short while soldiers are wanted, they wear < `worn` %, no ore
  -- boulder of a gear metal lies in the fort and the gear-metal bars are below what the soldiers' metal slots want
  -- (M.metal_plan). Then trade_wants asks every caravan for `wants` in this order (n = the bars short, or that slot's
  -- missing pieces) after picks and axes up to `tools` (military's tools-first minimum), and the fort keeps `crafts`
  -- crafts to sell for it (MakeCrafts in free stone, else wood above idle.wood_min; at most `craft_jobs` an order)
  -- BUG-582 (Run 16a i1 Basementflew y426-y428: three caravans 'nothing_to_sell' beside 511 bones and a Craftsdwarfs shop, `sell: crafts` in the
  -- plan and no MakeCrafts order anywhere; Run 16d i4 the same): a trade depot stands and crafts are on the sell list: the fort keeps `min`
  -- crafts to sell (M.trade_goods), made of bone (a corpse leftover; `bone_keep` stay for the gear), else wood above idle.wood_min, else
  -- free stone (not while stone is short of the rock orders), at most `jobs` an order; the metal-short rule below has its own order
  trade_goods = {min = 30, jobs = 10, bone_keep = 10, tag = 'dfllm:trade_goods', ws = {'workshop:Craftsdwarfs'}},
  metal_short = {worn = 80, tools = 3, crafts = 40, craft_jobs = 10, craft_tag = 'dfllm:trade_crafts',
                 craft_ws = {'workshop:Craftsdwarfs'},
                 wants = {{buy = 'bar:iron', n = 'bars'}, {buy = 'bar:steel', n = 'bars'},
                          {buy = 'armor:metal', n = 'body'}, {buy = 'weapon:metal', n = 'weapon'},
                          {buy = 'helm:metal', n = 'head'}, {buy = 'shield', n = 'shield'},
                          {buy = 'pants:metal', n = 'pants'}, {buy = 'gloves:metal', n = 'gloves'},
                          {buy = 'shoes:metal', n = 'shoes'}, {buy = 'bar:bronze', n = 'bars'},
                          {buy = 'bar:bismuth_bronze', n = 'bars'}, {buy = 'bar:copper', n = 'bars'}}},
  -- supply labors labormanager (modern) starved for >= cycles (LABOR_STARVED): a tool labor with a builtin
  -- detail (Miners, Woodcutters, Hunters, Fisherdwarves) left unmanaged becomes managed, so it staffs the
  -- detail; any other starved one makes baseline fall back to monitor mode (live L1: BREWER starved 243
  -- cycles, no brewer; 'unmanaged' left each such labor to a single dwarf outside the auto: details)
  labor = {cycles = 100,
           supply = {'BREWER', 'PLANT', 'COOK', 'HERBALIST', 'PROCESS_PLANT', 'MILLER', 'BUTCHER', 'CARPENTER',
                     'MASON', 'FEED_WATER_CIVILIANS', 'RECOVER_WOUNDED', 'MINE', 'CUTWOOD', 'HUNT', 'FISH'},
           builtin = {'MINE', 'CUTWOOD', 'HUNT', 'FISH'}},
  -- live L2/L3: labormanager monitor counted 504 Gather Plants postings from L1 (oldest 295,072 ticks) every day.
  -- While the oldest posting is older than stale_age, the smallest count of the earlier days (>= min_days
  -- samples, the last `keep`) is a stale floor: the KPI counts only the postings above it
  starving = {stale_age = 12000, min_days = 3, keep = 7},
  -- builtin tool details (live L1b): in labormanager's monitor mode nobody staffs them (L1: one miner for
  -- the whole fort), so economy is their sole writer whenever the engine is not modern. Miners follow the
  -- dig backlog (runner + designation jobs), woodcutters the log stock against autochop's band (wood:
  -- {below -> n[1], below -> n[2], else n[3]}; the band follows economy's autochop target), hunters the
  -- leather/bone/shell need or a famine; each capped by its tools (hunters also need bolts).
  -- Run 10 (Handlelock, 120 citizens): 29-33 dig jobs waited with the target at 2 (backlog / 40), six of eight miners
  -- held no pick and sat in Planters (everybody does this). Miners: one per `tiles_per` dig jobs (one per `runner_per`
  -- of the runner's dig tiles), `ore` more while metal is wanted and the fort has no ore, never more than the free
  -- tools plus the ones the members hold; `only`: a miner leaves the everybody-does-this details (act.work_detail opts.only,
  -- `keep_labors` stay). Every detail: members lacking its `labor` get it again through act.work_detail (at most every
  -- `repair_days`); members the kernel did not add (the player's) stay, count toward the target and make no WORK_DETAIL.
  -- A member without its `tool` in hand for `block_days` while `jobs` wait and free tools exist: TOOL_BLOCKED (A).
  -- equip_update [live-untested, BUG-023]: act.work_detail also requests the equipment update. On since Gordon's yes
  -- (2026-10-16, a fair-play exception: RULES §1.1, docs/v2/DECISIONS.md).
  -- BUG-128: a kernel-added member of a tool detail stays `keep_days` and never leaves while he holds the tool or DF
  -- lists a work tool pair for him; the target never falls to 0 while the detail's jobs exist.
  -- BUG-053 (Run 11 y487: 16 free picks 'loose' for 1081 days; Run 12 y501, a reclaimed fort: pick_free 100 for 144 days):
  -- free tools a detail's members lack for `stale_days` (no member-side cause: labor, tool2) stop counting as stock
  -- (plan_picks, metal_plan: the forge and the caravans make up the picks); usable ones that lie loose get a weapons
  -- stockpile `dfllm-tools` after `pile_days` (act.tool_pile, `pile_w` x `pile_h`, on revealed plain floor within
  -- `pile_r` tiles of the open jobs, at most `pile_reads` tile reads, one attempt per `pile_every` days); `pile` false = none
  tools = {shrink_days = 3, block_days = 3, repair_days = 7, equip_update = true, keep_days = 14,
           stale_days = 14, pile = true, pile_days = 7, pile_w = 3, pile_h = 2, pile_r = 12, pile_reads = 300,
           pile_every = 28,
           keep_labors = {'FEED_WATER_CIVILIANS', 'RECOVER_WOUNDED'},
           key_labors = {'MASON', 'CARPENTER', 'BREWER', 'PLANT', 'COOK', 'MECHANIC', 'DIAGNOSE', 'SMELT',
                         'FORGE_WEAPON', 'FORGE_ARMOR'},
           details = {{name = 'Miners', skill = 'MINING', labor = 'MINE', melee = {'MINING'}, tool = 'pick', jobs = 'dig',
                       min = 2, max = 6, max_pop = 20, tiles_per = 10, runner_per = 40, ore = 1, only = true},
                      {name = 'Woodcutters', skill = 'WOODCUTTING', labor = 'CUTWOOD', melee = {'AXE'}, tool = 'axe',
                       jobs = 'fell', wood = {60, 150}, n = {2, 1, 0}},
                      -- live L3: 9 of 10 strange moods failed with 0 bone, shell and leather in the fort; one
                      -- hunter in PEACE from mood_from_phase while one of them is short (two for an open need)
                      {name = 'Hunters', skill = 'CROSSBOW', labor = 'HUNT', ranged = {'CROSSBOW', 'BOW'}, famine = 2,
                       mood = 1, need = 2, ammo_min = 1, mood_keys = {'bone', 'shell', 'leather'}},
                      -- live L5: one fisher per `per` citizens (at most `max`) while food is below food.want_days
                      -- and a fishing zone exists (zones are the runner's or the LLM's); outside PEACE/RECOVERY none
                      -- BUG-057 (Run 13/14): a fishing zone with raw fish or open Fish jobs wants `min` fishers (one per
                      -- `min_per` citizens, at least one) whatever the food stock says
                      -- BUG-697 (Run 16c i3 Wallfree: 3 fishers for 49 citizens in a famine, 23 of 30 adults idle): in a famine one
                      -- fisher per `famine_per` citizens up to `famine_max`, never more than the idle adults (M.famine_scale)
                      {name = 'Fisherdwarves', skill = 'FISH', labor = 'FISH', fish = true, per = 15, max = 3,
                       min = 3, min_per = 6, famine_per = 6, famine_max = 8}}},
  -- live L3: the hunter caught nothing for a year; no visible game is no unit census economy may read, so a
  -- hunt without a new hide, bone, leather or shell for trial_days pauses for backoff_days
  hunt = {trial_days = 10, backoff_days = 20},
  stages = {
    {lib = 'library/basic', any = {'migrants', 'cit>=10'}},
    -- live L6 (Laborkings): with only flux boulders (chalk) rockstock and smelting queued 98 orders that
    -- could never start and cancelled all year ("Needs non-economic hard stone boulders"); each now waits
    -- for its input: `stone` = 60 free furniture-grade boulders (live L6 Paddletribes: imported at 10, it
    -- turned two quarries into 72 blocks, 56 mechanisms and 42 tools while 30 tables waited), `ore` = any ore
    {lib = 'library/rockstock', all = {'workshop:Masons', 'stone'}},
    {lib = 'library/furnace', any = {'furnace:Smelter', 'furnace:WoodFurnace'}},
    {lib = 'library/smelting', all = {'furnace:Smelter', 'fuel', 'ore'}},
    {lib = 'library/military', all = {'workshop:MetalsmithsForge'}},
  },
  signatures = {   -- an order only that library creates (hack/data/orders/*.json): already imported
    ['library/basic'] = {job = 'CustomReaction', reaction = 'BREW_DRINK_FROM_PLANT'},
    ['library/furnace'] = {job = 'MakeCharcoal'},
    ['library/smelting'] = {job = 'SmeltOre', mat = 'INORGANIC:GARNIERITE'},
    ['library/military'] = {job = 'MakeQuiver'},
    ['library/rockstock'] = {job = 'ConstructArmorStand', mat = 'INORGANIC'},
    ['library/glassstock'] = {job = 'ConstructArmorStand', mat = 'GLASS_GREEN'},
  },
  -- live L6: famine / food_low slaughter of surplus tame animals (T.slaughter)
  slaughter = {keep_f = 1, keep_m = 1, max = 10, every_days = 7, mood_days = 3, ws = {'workshop:Butchers'}},
  fish = {tag = 'dfllm:fish', min = 5, max = 30, ws = {'workshop:Fishery'},
          spec = {job = 'PrepareRawFish', frequency = 'OneTime'}},
  -- Run 11 (Kilrudrabed: nobody fished, no fishing zone): the fishing zone search (M.fish_start): r tiles around the
  -- citizens' median, at most `levels` levels, `tiles` tiles read a frame, water of depth >= min_flow, a side x side
  -- zone, again after scan_days; `reads` tile reads a frame, `checks` water tiles looked at, `max_water` kept
  -- BUG-698 (Run 16c i3 Wallfree y431-y433: the fishers stood at the pond with 'job none' for a year, raw fish 2600 -> 6, the zone
  -- never moved): fishers wanted, a zone standing, no Fish job and no raw fish for dry_days days in a row = the water is fished out
  -- (p.fishdry): the next scan paints a second zone on another water body, the old zone stays
  fishing = {r = 48, levels = 6, tiles = 1500, min_flow = 2, side = 3, scan_days = 7, reads = 200, checks = 160,
             max_water = 3000, dry_days = 20},
  -- live L5 (Castlerisen y295: pop 41 -> 53 on the same 80 farm tiles, food 105 -> 15 days in a year): food follows
  -- the population. DF gives about `yield` crops per farm tile and season; a citizen uses about `per_dwarf` plants
  -- a season (about 2 eaten, 1 brewed into 5 drinks), so the fort wants cit * per_dwarf / yield farm tiles. Below
  -- want_days of food, or when the food stock fell over trend_days, and with fewer tiles than that and no farms
  -- project pending: PROJECT_REQUEST farms (plots of plot_tiles, at most plots_max; follow places it), at most
  -- every request_days. Below pre_days a weekly class-A pre-alarm (DECISION_NEEDED food_low) before the famine.
  -- autofarm thresholds of the food crops: cit * crops_per_dwarf within [crops_min (or autofarm's default),
  -- crops_max] in steps of crops_step (autofarm's default 50 stopped planting with 40 helmets for 53 dwarves).
  -- Cooking: meals_per_dwarf prepared meals per citizen (meals keep; raw fruit and meat rot), the dfllm:food
  -- order's job cap grows with the citizens (one job per cit_per_job).
  -- BUG-629 (Run 16a/16b y459-y377: meals 0 beside 2,398 cook ingredients / beside 1-9 of them and 13 hungry): the meal order waits for
  -- cook_floor cook ingredients (the planner's gate and the order's DF item condition) only while nobody is hungry and food lasts
  -- (M.cook_floor: 2, the ingredients of one meal, otherwise); a food order without a meal for cook_stall_days days while the kitchen
  -- stands and cook ingredients lie there is taken down and made again without any item condition (M.cook_watch).
  food = {yield = 1, per_dwarf = 3, plot_tiles = 35, plots_max = 4, want_days = 90, trend_days = 14,
          request_days = 14, pre_days = 30, crops_per_dwarf = 4, crops_min = 50, crops_max = 400, crops_step = 10,
          status_days = 7, meals_per_dwarf = 2, cit_per_job = 2, cook_floor = 10, cook_stall_days = 6,
          gap_days = 110},    -- BUG-716: autumn and winter: below this many food days the fort acts as at food_low (M.gap_low)
  -- BUG-042 (Run 11, y471: 3079 plant growths, 275 plants, drink 93 -> 32 days): the drink deficit is brewed from what
  -- the census finds brewable (`src`: brew_p = PLANT with DRINK_MAT, plump helmets always; brew_g = PLANT_GROWTH with
  -- DRINK_MAT, fruit), split by their stock (M.brew_share); with neither in the fort the plant order takes it all
  supply = {
    {tag = 'dfllm:drink', key = 'drink_d', per_job = 5, max_jobs = 30, src = 'brew_p',
     spec = {job = 'CustomReaction', reaction = 'BREW_DRINK_FROM_PLANT', frequency = 'OneTime',
             item_conditions = {{condition = 'AtLeast', flags = {'unrotten'}, item_type = 'PLANT', reaction_product = 'DRINK_MAT', value = 2},
                                {condition = 'AtLeast', flags = {'empty', 'food_storage'}, value = 1}}}},
    {tag = 'dfllm:drink_fruit', key = 'drink_d', per_job = 5, max_jobs = 30, src = 'brew_g',
     spec = {job = 'CustomReaction', reaction = 'BREW_DRINK_FROM_PLANT_GROWTH', frequency = 'OneTime',
             item_conditions = {{condition = 'AtLeast', flags = {'unrotten'}, item_type = 'PLANT_GROWTH', reaction_product = 'DRINK_MAT', value = 2},
                                {condition = 'AtLeast', flags = {'empty', 'food_storage'}, value = 1}}}},
    {tag = 'dfllm:food', key = 'food_d', per_job = 4, max_jobs = 20,
     spec = {job = 'PrepareMeal', meal_ingredients = 2, frequency = 'OneTime',
             item_conditions = {{condition = 'AtLeast', flags = {'unrotten', 'cookable'}, value = 10}}}},
  },
  -- live L4: floors economy's own consumers keep (wood: the furniture fallback took 70 of 82 logs in L3); care's
  -- forbidden mood reserve counts against them (economy keeps max(0, floor - held) of the free items)
  -- Run 10: a fey mood needed two leather and died with none in the fort; economy's leather gear keeps two back
  reserve = {wood = 20, rock = 0, bone = 0, shell = 0, leather = 2, cloth = 0, thread = 0, bars = 0, gems = 0,
             fuel = 0},
  wood = {chop_min = 60, chop_max = 150, margin = 20, band = 90, cap = 400, step = 10},
  -- live L1b: brewing stalled without empty barrels; then dfllm:barrel made 34 barrels (logs 183 -> 66). Below the
  -- drink target the cap is max_total, below nofloor_days of drink barrels may use the wood floor
  -- live L6: while drink is short and fewer than min_empty barrels are empty, the cap grows up to grow_total
  -- BUG-042 (Run 11, y471: 60 brews waited for 12 empty barrels among 85): below the drink target the brews the open
  -- BREW_ orders still want (at most brew_wait) are empty barrels wanted too, past grow_total
  barrels = {tag = 'dfllm:barrel', min_empty = 4, drink_pct = 150, cit_pct = 50, min_total = 8, max_total = 30,
             grow_total = 80, nofloor_days = 30, max_jobs = 4, brew_wait = 30, ws = {'workshop:Carpenters'},
             spec = {job = 'MakeBarrel', material_category = {'wood'}}},
  bins = {tag = 'dfllm:bin', min_empty = 1, cit_pct = 25, min_total = 4, max_total = 20, max_jobs = 2,
          ws = {'workshop:Carpenters'}, spec = {job = 'ConstructBin', material_category = {'wood'}}},
  -- Run 10 (Handlelock): no tannery stood and a fey mood died for two leather. Without a tanner's shop, while hides lie
  -- or a mood missed leather within memory_days: PROJECT_REQUEST workshops why=tannery (follow places the missing
  -- moodable shops) at most every request_days; a mood that missed leather (memory_days) with 0 leather hunts like an
  -- open need (through the no-game pause)
  leather = {from_phase = 'P1', tag = 'dfllm:tan', after_days = 2, max_jobs = 10, ws = {'workshop:Tanners'},
             request_days = 14, memory_days = 336,
             spec = {job = 'CustomReaction', reaction = 'TAN_A_HIDE',
                     item_conditions = {{condition = 'AtLeast', value = 1, flags = {'unrotten'},
                                         reaction_product = 'TAN_MAT'}}}},
  -- BUG-117 (Run 14 note 80: a miner died in a fey mood waiting for cloth, the game session added a private watch): `floor`
  -- = free cloth the kernel itself keeps from from_phase on, whatever the mood stock target says (0 = off); it moves the weave
  -- orders only, the fiber crops follow the target
  cloth = {from_phase = 'P1', per_naked = 3, max_jobs = 10, floor = 20, loom = {'workshop:Loom'},
           -- BUG-574: a silk mood (cloth or thread) with no silk thread: a CollectWebs work order at the Loom (webs the citizens reach)
           webs = {tag = 'dfllm:webs', max_jobs = 5, extra = 2},
           weave = {{kind = 'plant', tag = 'dfllm:cloth'}, {kind = 'silk', tag = 'dfllm:cloth_silk'},
                    {kind = 'yarn', tag = 'dfllm:cloth_yarn'}},
           thread = {tag = 'dfllm:thread', ws = {'workshop:Farmers'},
                     spec = {job = 'ProcessPlants',
                             item_conditions = {{condition = 'AtLeast', value = 1, flags = {'unrotten', 'processable'},
                                                 item_type = 'PLANT'}}}},
           -- autofarm thresholds of the fiber crops: fiber_on while cloth is short (at least autofarm's default),
           -- then back to autofarm's default (status); fiber_off only when status names no default
           fiber = {'GRASS_TAIL_PIG', 'REED_ROPE', 'FLAX', 'HEMP', 'JUTE', 'KENAF', 'RAMIE', 'COTTON'},
           fiber_on = 100, fiber_off = 50},
  -- Run 11 (Kilrudrabed, no gem vein: every year the first mood that wanted gems died): raw green glass from sand for
  -- the moods' raw-glass and cut-gem filters (M.glass_plan): from_phase = the standing stock without a mood miss, raw =
  -- raw glass kept, bags = empty bags made for CollectSand, report_days = the GLASS_BLOCKED cadence
  -- BUG-573: gems = the CutGems order for the rough gems beyond rough_keep (cut gems below the reserve's gems target or a mood's
  -- cut-gem want), the glass chain only for what no rough gem covers
  glass = {from_phase = 'P3', raw = 3, bags = 2, max_jobs = 5, request_days = 14, report_days = 28, rough_keep = 2,
           gems = {tag = 'dfllm:cutgems', spec = {job = 'CutGems'}},
           furnace = {'furnace:GlassFurnace', 'furnace:MagmaGlassFurnace'}, magma = 'furnace:MagmaGlassFurnace',
           jeweler = {'workshop:Jewelers'}, fuel_tag = 'dfllm:glass_fuel',
           sand = {tag = 'dfllm:sand', spec = {job = 'CollectSand'}},
           make = {tag = 'dfllm:glass', spec = {job = 'MakeRawGlass', material = 'GLASS_GREEN'}},
           cut = {tag = 'dfllm:cutglass', spec = {job = 'CutGlass', material = 'GLASS_GREEN'}},
           bag = {tag = 'dfllm:bag', ws = {cloth = 'workshop:Clothiers', leather = 'workshop:Leatherworks'}}},
  metal = {from_phase = 'P2', max_jobs = 10, ores_per_day = 2, smelter = {'furnace:Smelter', 'furnace:MagmaSmelter'},
           charcoal = {tag = 'dfllm:charcoal', buffer = 4, cap = 40, ws = {'furnace:WoodFurnace'}},
           bronze = {tag = 'dfllm:bronze', ore = 'BRONZE_MAKING', bars = 'BRONZE_MAKING2', max_jobs = 5},
           -- Run 10: orders waiting for steel bars get the chain (plan_steel)
           steel = {tag = 'dfllm:steel', pig_tag = 'dfllm:pig_iron', pig = 'PIG_IRON_MAKING', make = 'STEEL_MAKING',
                    max_jobs = 5},
           explore = {tpl = 'explore', request_every = 100800, decide_every = 403200},
           -- economy owns stockpile settings (DESIGN Ã‚Â§3): a pile named so (template or UI) takes metal ore only
           ore_pile = {names = {'dfllm-ore'}, import = 'metalore'}},
  -- live L2/L3: worn 15 %; the uniform slots per position (military.UNIFORM) and the job per material
  gear = {metals = {'STEEL', 'IRON', 'BRONZE', 'BISMUTH_BRONZE', 'COPPER'}, max_jobs = 5,
          forge = {'workshop:MetalsmithsForge', 'workshop:MagmaForge'}, leatherworks = {'workshop:Leatherworks'},
          bolts_xbow = 100, bolts_hunter = 25, bolts_max = 300,
          items = {
            {cat = 'body', who = 'all', metal = {job = 'MakeArmor', sub = 'ITEM_ARMOR_BREASTPLATE', bars = 3},
             leather = {job = 'MakeArmor', sub = 'ITEM_ARMOR_LEATHER', n = 1}},
            {cat = 'head', who = 'all', metal = {job = 'MakeHelm', sub = 'ITEM_HELM_HELM', bars = 1},
             leather = {job = 'MakeHelm', sub = 'ITEM_HELM_HELM', n = 1},
             bone = {job = 'MakeHelm', sub = 'ITEM_HELM_HELM', ws = {'workshop:Craftsdwarfs'}}},   -- FR-100: bone last
            {cat = 'pants', who = 'all', metal = {job = 'MakePants', sub = 'ITEM_PANTS_GREAVES', bars = 2},
             leather = {job = 'MakePants', sub = 'ITEM_PANTS_LEGGINGS', n = 1},
             bone = {job = 'MakePants', sub = 'ITEM_PANTS_GREAVES', ws = {'workshop:Craftsdwarfs'}}},
            {cat = 'gloves', who = 'all', per = 2, out = 2, metal = {job = 'MakeGloves', sub = 'ITEM_GLOVES_GAUNTLETS', bars = 1},
             leather = {job = 'MakeGloves', sub = 'ITEM_GLOVES_GLOVES', n = 1},
             bone = {job = 'MakeGloves', sub = 'ITEM_GLOVES_GAUNTLETS', ws = {'workshop:Craftsdwarfs'}}},
            {cat = 'shoes', who = 'all', per = 2, out = 2, metal = {job = 'MakeShoes', sub = 'ITEM_SHOES_BOOTS', bars = 1},
             leather = {job = 'MakeShoes', sub = 'ITEM_SHOES_BOOTS', n = 1}},
            {cat = 'shield', who = 'melee', metal = {job = 'MakeShield', sub = 'ITEM_SHIELD_SHIELD', bars = 2},
             wood = {job = 'MakeShield', sub = 'ITEM_SHIELD_SHIELD', ws = {'workshop:Carpenters'}}},
            {cat = 'weapon', who = 'melee', metal = {job = 'MakeWeapon', sub = 'ITEM_WEAPON_SPEAR', bars = 1}},
            {cat = 'xbow', who = 'ranged', wood = {job = 'MakeWeapon', sub = 'ITEM_WEAPON_CROSSBOW', ws = {'workshop:Bowyers'}}},
            {cat = 'quiver', who = 'xbow', leather = {job = 'MakeQuiver', n = 1}},
            {cat = 'bolts', who = 'bolts', out = 25,
             wood = {job = 'MakeAmmo', sub = 'ITEM_AMMO_BOLTS', ws = {'workshop:Craftsdwarfs', 'workshop:Bowyers'}},
             bone = {job = 'MakeAmmo', sub = 'ITEM_AMMO_BOLTS', ws = {'workshop:Craftsdwarfs'}}},
          }},
  -- FR-89 (Run 14 note 82, Gordon: "drills only with wooden weapons, build enough"): squads on the training policy
  -- (military.training_need) get the training weapons they lack made at the carpenters from wood: need + `spare`, at most
  -- `max_jobs` per order; on = false never orders them
  training = {on = true, from_phase = 'P1', spare = 2, max_jobs = 5, tag = 'dfllm:train', ws = {'workshop:Carpenters'}},
  idle = {
    -- live L4: `combine all -q` took 16-28 ms and demoted economy x8 every few days: weekly now. Without stone
    -- the fort had nothing to sell (the dwarven caravan failed on 'ratio'): wooden crafts once logs pass wood_min
    pct = 40, days = 3, boulders_min = 30, blocks_cap = 200, crafts_cap = 60, combine_every = 8400, wood_min = 60,
    craft_cats = {'FIGURINE', 'AMULET', 'RING', 'EARRING', 'BRACELET', 'SCEPTER', 'CROWN', 'TOTEM'},
    backlog = {
      {id = 'blocks', tag = 'dfllm:idle_blocks', amount = 10,
       spec = {job = 'ConstructBlocks', material = 'INORGANIC', frequency = 'OneTime'}},
      {id = 'crafts', tag = 'dfllm:idle_crafts', amount = 5,
       spec = {job = 'MakeCrafts', material = 'INORGANIC', frequency = 'OneTime'}},
      {id = 'wood_crafts', tag = 'dfllm:idle_wcrafts', amount = 5,
       spec = {job = 'MakeCrafts', material_category = {'wood'}, frequency = 'OneTime'}},
      {id = 'combine'},
    },
  },
  cancel_loop = 5,
  -- FR-39: make-item orders without item_subtype are removed at once (drop = false: only ORDER_BAD + state)
  order_guard = {drop = true, per_run = 4},
  -- FR-01/FR-10: an order that cannot run (workshop, input on the citizens' walk group, worker) for stuck_days is
  -- reported (ORDER_STUCK, at most report_per_day a day); needs_drop "Needs ..." cancels remove it, and an own
  -- dfllm order is not entered again for backoff_days. Run 11: an unvalidated order while the manager cannot validate
  -- (injured, in a mood, gone) names that reason; after manager_days of it DECISION_NEEDED manager_absent
  -- BUG-042 (Run 11, y471: the manager's office held no chair and no table; 112 of 446 orders, the brew orders among
  -- them, waited unvalidated while 334 older ones were validated): an order unvalidated for unval_days with a manager
  -- who could validate is DECISION_NEEDED manager_office with the reason (M.unval_watch), and the manager's office gets
  -- its chair and table (M.office_check: `office`). BUG-231 (live Guildcleans y373: 22 orders unvalidated ~330 days, the
  -- office's chair and table were among them): orders unvalidated (or the office short of its chair/table) for
  -- bypass_days (0 = off) make the kernel add the items as workshop tasks (M.mgr_bypass: at most bypass_max a day,
  -- bypass_open such tasks queued at once)
  -- BUG-315 (Run 15 Drillchamber: 192-194 open orders, 73-95 stuck, the mood's bag and charcoal behind them for 30 days):
  -- the daily prune (M.order_prune) removes duplicates of a stuck order after stuck_days and, above `cap` open orders,
  -- the longest stuck ones past prune_days, at most prune_per_day a day; never a piece, mood, seal or care order
  -- BUG-450 (Run 16a i1 Syrupobeyed y386: 35 orders unvalidated for 149 days with an appointed manager, a complete office and
  -- 'none vacant'): mgr_stuck_days (0 = off) of validation that does not happen with an able manager and a complete office is
  -- DECISION_NEEDED manager_stuck with the facts about him and the commands that look further (M.mgr_stuck)
  orders = {stuck_days = 3, needs_drop = 10, backoff_days = 10, report_per_day = 3, manager_days = 3, unval_days = 2,
            bypass_days = 5, bypass_max = 4, bypass_open = 8, cap = 120, prune_days = 30, prune_per_day = 30,
            mgr_stuck_days = 5},      -- BUG-585: 14 -> 5 (Run 16b i2 Brotherarrow y406: the warning came after 24 days)
  -- BUG-042: the manager's Office zone needs a chair (and a table: the live fix was both) to validate work orders; a
  -- missing one is placed on a free floor tile of the zone (runner.repair: quickfort build, buildingplan waits for the
  -- item) at most every retry_days; zones larger than max_tiles are searched only that far. BUG-232: `zone` = with no
  -- Office zone at all, one is drawn over a built chair (and its table) that stands outside every room zone
  office = {table = true, retry_days = 7, max_tiles = 400, zone = true},
  -- BUG-061 (Run 13 y523: 31 EngraveSlab orders, "Needs unengraved slab", filled the masons' slots with jobs that
  -- cancelled at once; doors, coffins, tables and blocks waited ten game years; autoslab.cpp queues one EngraveSlab order
  -- per ghost every 1289 ticks and no ConstructSlab): at most `max_orders` EngraveSlab orders stand, never more than
  -- there are unengraved slabs, the rest are removed (at most `drop_per_day`; again at the first "unengraved slab"
  -- cancel past `trigger_ticks`); ConstructSlab is ordered first for the ghosts and the open engrave orders (at most
  -- `restock_cap` blank slabs, BUG-133: and never more than the ghosts that still want one); `jam_min` blocked jobs in a
  -- workshop type's slots (half of them at least) are a jam
  slabs = {max_orders = 3, restock_cap = 20, drop_per_day = 60, trigger_ticks = 600, scan_max = 2000, jam_min = 3,
           engrave_days = 3},
  -- BUG-060 (Run 13 y508: 11 ConstructDoor INORGANIC orders, validated, made no job for months, five builds waited for
  -- doors; wood doors ordered by hand were built at once): a one-time validated order with no job in any workshop and an
  -- unchanged amount for `days` days (`wait_days` when a planned building waits for that piece) is stale: a stone
  -- furniture order is re-entered in wood, else a simple order is made again, else it is reported; at most `per_day`
  -- a day, only in PEACE and RECOVERY; `jobs_max` workshop jobs are read
  -- (I3: `redo_max` = how often one order may be made again in a row; the made-again order starts its own clock, so an
  -- order nothing can run was entered, removed and entered again every `days` days for ever; 0 = never made again)
  stale = {days = 10, wait_days = 3, per_day = 6, jobs_max = 2000, redo_max = 2},
  -- FR-73 (Run 14 y558-y561: silk, yarn and plant cloth missing in three moods in a row, no standing thread or cloth
  -- order): from `from_phase` (the moodable workshops' phase) each entry is ordered once, `amount` a `frequency`, when
  -- its workshops stand (`ws`, none: always); the farmer's workshop comes with the plan (P1 workshops, or economy's
  -- PROJECT_REQUEST workshops why=farmers every `request_days`)
  standing = {from_phase = 'P1', amount = 30, frequency = 'Monthly', request_days = 14,
              list = {{tag = 'dfllm:stand_spin', ws = {'workshop:Farmers'}, spec = {job = 'SpinThread'}},
                      {tag = 'dfllm:stand_weave_plant', ws = {'workshop:Loom'},
                       spec = {job = 'WeaveCloth', material_category = {'plant'},
                               item_conditions = {{condition = 'AtLeast', value = 1, item_type = 'THREAD',
                                                   flags = {'collected', 'plant'}}}}},
                      {tag = 'dfllm:stand_weave_silk', ws = {'workshop:Loom'},
                       spec = {job = 'WeaveCloth', material_category = {'silk'},
                               item_conditions = {{condition = 'AtLeast', value = 1, item_type = 'THREAD',
                                                   flags = {'collected', 'silk'}}}}},
                      {tag = 'dfllm:stand_weave_yarn', ws = {'workshop:Loom'},
                       spec = {job = 'WeaveCloth', material_category = {'yarn'},
                               item_conditions = {{condition = 'AtLeast', value = 1, item_type = 'THREAD',
                                                   flags = {'collected', 'yarn'}}}}},
                      {tag = 'dfllm:stand_process', ws = {'workshop:Farmers'},
                       spec = {job = 'ProcessPlants',
                               item_conditions = {{condition = 'AtLeast', value = 1, item_type = 'PLANT',
                                                   flags = {'unrotten', 'processable'}}}}},
                      {tag = 'dfllm:stand_shear', spec = {job = 'ShearCreature'}}}},
  -- BUG-042: below low_d drink days (and above alarm.days, where the thirst decision speaks) a class-A DECISION_NEEDED
  -- drink_low names why the stills do not brew (M.drink_why) and what the kernel did; again with news after 7 days
  -- BUG-424 (Run 16a i1 Manorsubtle: 211 drink days at the start, the brook in a rock gully 8 tiles away, nobody asked for a way to it): from
  -- access_d drink days down, with no reachable water and no brewable plant, no_water also asks PROJECT_REQUEST cistern why=no_water with
  -- the nearest water tile (follow places the piped cistern with its sealed intake when the planner finds a safe one); 0 = never
  drink = {low_d = 60, access_d = 400},
  -- FR-16: resumed per day; a job kept suspended held_days asks for the preventblocking decision;
  -- preventblocking 'keep' leaves suspendmanager's own setting until jobs.release decides
  -- BUG-009/004/005: footprints scanned and items unforbidden per day, items read per missing class, failed resumes
  -- before DECISION_NEEDED build_blocked and before a trade depot moves (at most every move_days); the depot site
  -- search: move_r tiles around an entrance on its level and move_dz below, at least move_gap from every entrance,
  -- move_probes tile reads a frame
  jobs = {release_per_day = 20, held_days = 3, preventblocking = 'keep', sites_per_day = 40, unforbid_per_day = 60,
          mat_scan = 2000, fail_alarm = 3, depot_move_after = 5, move_days = 28, move_r = 12, move_dz = 2,
          move_gap = 3, move_probes = 150},
  -- FR-17 farm season slots filled per day; FR-23/FR-50/FR-25 unforbids per day (containers, seeds, food)
  -- BUG-058 (Run 13 y512: 8 plots had plant_id -1 for the running season and autofarm emptied what the kernel set):
  -- `now_max` slots of the running season are filled at once (T.slotnow, right after the census); autofarm: 'auto' =
  -- the kernel disables it below `af_off_days` food days or when a slot it filled was emptied again, and enables it
  -- again from `af_on_days` food days after `af_hold_days`; 'off' = disabled at every boot; 'keep' = never touched
  -- (I3: with autofarm off for good -- 'off', or two wipes -- nothing planted the fiber crops the thread and cloth chain
  -- lives on; `fiber_slots` = at most that many empty slots of a season take a fiber crop (c.cloth.fiber) while cloth is
  -- short and food is not; 0 = never)
  -- BUG-381 (Run 16 i1/i2/i4: 0 meals beside 2,000 plump helmets, the kitchen built and nothing it may cook): `cook_slots` =
  -- at most that many empty slots of a season take a crop the kitchen may cook while it has fewer ingredients than
  -- citizens (plump helmets are brewed, never cooked: D-09); 0 = never
  farms = {per_day = 16, now_max = 24, autofarm = 'auto', af_off_days = 30, af_on_days = 90, af_hold_days = 14,
           fiber_slots = 2, cook_slots = 2},
  forbid = {per_day = 30,
            -- FR-76 (Run 12 Trussroads, a reclaimed fort: 3026 of 3058 drinks, all food and 61 barrels forbidden, the
            -- status said "drink 46d!"): from burst_min forbidden drink + food units the items themselves are
            -- unforbidden whatever their reason (the 30 a day and "food only in a starvation" kept them forbidden for
            -- ever), burst_per_day a day, M.BURST_SLICE per frame; 0 = never a burst
            burst_per_day = 400, burst_min = 100,
            -- BUG-594 (Run 16b i2 Brotherarrow y405, Run 16a i1: 5 forbidden food items 'the kernel has not freed them' 21-30 days after SIEGE_END):
            -- loose forbidden food (not drink, not a container) was freed only in a starvation; for after_days days after the last SIEGE / BREACH
            -- day it is freed too (a lockdown and the invaders' fights leave it forbidden), 0 = off
            after_days = 14},
  -- FR-25: below `days` food days with citizens over `hunger` (DF's "hungry" is 50000)
  -- BUG-697: gatherers_max = the plant gatherers a starvation adds when many adults are idle (M.famine_scale)
  starve = {days = 0, hunger = 50000, plants_max = 200, plants_per_slice = 400, report_days = 2, gatherers = 4, gatherers_max = 10,
            planters = 4, plants = {'GRASS_WHEAT_CAVE', 'MUSHROOM_HELMET_PLUMP', 'POD_SWEET', 'BUSH_QUARRY',
                                    'MUSHROOM_CUP_DIMPLE'},
            details = {planters = {'Planters'}, gatherers = {'Plant gatherers', 'Gatherers', 'Herbalists'}}},
  -- BUG-038 (Run 11, y451: food_low at 26 days, 450 unclaimed GatherPlants jobs, nobody gathered): below food.pre_days
  -- (the food_low line, famine included) with >= min_jobs unclaimed GatherPlants jobs, the plant gathering detail
  -- (starve.details.gatherers) gets members up to n (M.gather_low); the ones economy added leave at off_days food days
  -- BUG-042: also below drink_d drink days while the brewable plants (census brew_p + brew_g) cannot brew the deficit
  -- to the drink target (5 drinks a plant); the members stay until food >= off_days and drink >= drink_off (or enough
  -- brewable plants)
  gather = {n = 4, min_jobs = 10, off_days = 60, drink_d = 60, drink_off = 100, drink_early = 120},
  -- BUG-057/FR-72 (Run 12-14: PlantSeeds 122-421 and GatherPlants 250-565 unclaimed for years, 30-70 % of the adults idle,
  -- Planters / Fisherdwarves / Plant gatherers at 0 members): the details follow the demand (M.cover_run, daily).
  -- Farmers (PLANT, detail Planters) for PlantSeeds + HarvestPlants unclaimed above `min_jobs` (one per `farm_per`,
  -- `farm_min`..`farm_max`), gatherers (HERBALIST, detail Plant gatherers) for GatherPlants above `gather_jobs` (one per
  -- `gather_per`, `gather_min`..`gather_max`), kept apart; any other job type of `labors` (type -> labor) with
  -- more than `min_jobs` unclaimed jobs and no citizen holding the labor gets `min`..`other_max` idle citizens through a
  -- detail that grants the labor. All these details together hold at most `share` percent of the adults, `step` added a
  -- day to one detail. The details
  -- never shrink while unclaimed jobs exist; the members the kernel added leave after `idle_days` days without any.
  -- GatherPlants designations nobody worked on for `stale_days` days, and the ones off the citizens' walk group, are
  -- withdrawn (at most `unmark_max` a day)
  cover = {on = true, min_jobs = 20, gather_jobs = 10, farm_per = 10, farm_min = 2, farm_max = 12, gather_per = 25,
           gather_min = 2, gather_max = 8, other_per = 20, other_max = 3, share = 50, step = 4, idle_days = 7,
           stale_days = 30, unmark_max = 200,
           labors = {GatherPlants = 'HERBALIST', PlantSeeds = 'PLANT', HarvestPlants = 'PLANT'}},
  -- BUG-340 (Run 15c Inkintense y378-y383: famine for weeks, 2 of 39 idle, 4417 unclaimed jobs, the FarmPlot job
  -- 'no builder has taken it', Planters and Plant gatherers everybody-does-this): in a famine (or below famine_days of
  -- drink) the kernel makes a food crew of specialists (M.fcrew_run): `farmers` (Planters, while a farm plot stands or is
  -- placed), `cooks` (a COOK detail, kitchen and ingredients), `brewers` (a BREWER detail, still and brewable plants, drink
  -- below gather.drink_d), `gatherers` (only while the gathering detail is everybody-does-this: gather_low staffs it
  -- otherwise). A crew member keeps the food labors (FCREW_KEEP) and gives up the everybody-does-this labors (hauling,
  -- cleaning, building...), so the food jobs are his. At most `share` percent of the adults, `step` a day, only in
  -- PEACE/RECOVERY; each goes back once the shortage he was named for (food; drink for a brewer named below famine_days of
  -- drink) stands at `off_days` (review fix merge15: not food AND drink), at once when drafted, moody, off his detail,
  -- above `share` or `on` false
  famine_crew = {on = true, farmers = 3, cooks = 1, brewers = 1, gatherers = 2, share = 25, step = 2, off_days = 30,
                 pre_days = 20},      -- BUG-618: the food crew starts below pre_days of food, not only in the famine (0 = famine only)
}

local st = {}

local function copy(t)
  if type(t) ~= 'table' then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = copy(v) end
  return setmetatable(r, getmetatable(t))
end

local function int(v) return math.tointeger(type(v) == 'string' and tonumber(v) or v) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function fmt(n) return string.format('%d', math.tointeger(n) or 0) end

function M.conf(K)
  local c = type(K.cfg.baseline) == 'table' and K.cfg.baseline.economy
  if type(c) ~= 'table' then return M.DEFAULTS end
  local r = {}
  for k, v in pairs(M.DEFAULTS) do r[k] = v end
  for k, v in pairs(c) do r[k] = v end
  return r
end

local function decision(K, id) return tostring((K.cfg.decisions or {})[id] or C.DECISIONS[id] or '') end

local function phase_ok(K, from) return M.phase_ok(K, from) end

-- BUG-156 (live i4 y717: pop 52, PLAN NONE, phase P0 for good): the P1 features (mood shops, the mood stock, the cloth
-- floor, training weapons, leather, standing orders) wait for the plan's phase P1, which a fort without an applied plan
-- (persist plan.plan null) never reaches: its P0 deliverables are never built. Such a fort of offices.mood_ws_pop
-- citizens or more counts as P1 for them; the later phases (metal P2, glass P3) stay gated
-- BUG-185 (live i4 y725: the kernel held an old y712 plan doc, phase_target P0, phase P0 since 92M ticks; brief said PLAN
-- NONE): a persisted plan that never aims past P0 (phase_target <= P0) or whose phase has stayed at P0 for more than
-- M.PLAN_STUCK_YEARS game years counts as no plan here, as brief.plan_flag's STALE rule (plan.STALE_SHOW = 1 year)
M.PLAN_STUCK_YEARS = 1
function M.plan_stuck(K, doc)
  local pt = doc.phase_target
  if type(pt) == 'string' and pt <= 'P0' then return 'target' end
  local ph = K.persist.get('phase')
  local since = type(ph) == 'table' and math.tointeger(ph.since) or nil
  if type(ph) == 'table' and type(ph.phase) == 'string' and ph.phase <= 'P0' and since and
     K.now().tick - since > M.PLAN_STUCK_YEARS * C.TICKS.YEAR then return 'stuck' end
  return nil
end
function M.planless(K)
  local pp = K.persist.get('plan')
  local doc = type(pp) == 'table' and pp.plan or nil
  if type(doc) == 'table' and doc ~= json.null and not M.plan_stuck(K, doc) then return false end
  local c = type(K.cfg.baseline) == 'table' and K.cfg.baseline.offices
  local pop = type(c) == 'table' and math.tointeger(c.mood_ws_pop) or 20
  local cu = K.census and K.census.u
  return (type(cu) == 'table' and math.tointeger(cu.cit) or 0) >= math.max(pop, 1)
end
function M.phase_ok(K, from)
  if from == nil then return true end
  local ph = (K.view() or {}).phase
  if type(ph) ~= 'string' then return false end
  return ph >= from or (from <= 'P1' and M.planless(K))
end

-- persist m.economy; maps are re-tagged as objects (a decoded empty map is an array, json.lua:104)
local MAPS = {'imported', 'orders', 'low', 'tools', 'meta', 'needs', 'reserves', 'explore', 'ostuck', 'ocancel',
              'badseen', 'jres', 'tblk', 'mseen', 'cover', 'af', 'ostale'}
local function pstate(K)
  local p = K.persist.get('m.economy')
  if type(p) ~= 'table' then
    p = {v = 2, hist = {drink = {}, food = {}}, prev = json.object{}, idle_days = 0, migrants = 0, cit = 0}
    K.persist.set('m.economy', p)
  end
  for _, k in ipairs(MAPS) do p[k] = json.object(type(p[k]) == 'table' and p[k] or {}) end
  for _, k in ipairs({'needs', 'reserves'}) do
    for key, v in pairs(p[k]) do p[k][key] = type(v) == 'table' and json.object(v) or nil end
  end
  if type(p.hist) ~= 'table' then p.hist = {} end
  p.hist.drink, p.hist.food = p.hist.drink or {}, p.hist.food or {}
  p.prev = json.object(type(p.prev) == 'table' and p.prev or {})
  if type(p.stale) ~= 'table' then p.stale = {} end
  return p
end

---------------------------------------------------------------- item census (sliced, items.other)
local CATS = {'DRINK', 'FOOD', 'MEAT', 'FISH', 'FISH_RAW', 'CHEESE', 'EGG', 'PLANT', 'PLANT_GROWTH', 'CLOTH', 'SKIN_TANNED',
              'CORPSEPIECE', 'SMALLGEM', 'ROUGH', 'BAR', 'AMMO', 'WOOD', 'BARREL', 'BIN', 'BOULDER', 'THREAD',
              'SEEDS', 'WEAPON', 'ARMOR', 'HELM', 'PANTS', 'GLOVES', 'SHOES', 'SHIELD', 'QUIVER', 'BAG',
              'DOOR', 'HATCH_COVER', 'GRATE', 'BLOCKS', 'CHAIR', 'TABLE'}
local SKIP = {'trader', 'garbage_collect', 'removed', 'dump', 'hostile', 'in_building', 'construction', 'rotten'}
-- FR-62 (Run 9: 18.7k items, economy 12-14 ms/s): one read of the flag word (bitfield `whole`) against the mask of
-- the SKIP bits instead of eight bitfield reads per item. The first M.MASK_CHECK items of a boot are cross-checked
-- against the flag reads; any disagreement (or no df.item_flags/`whole`, as in the fakes) means per-flag reads.
local skip_mask, mask_check, mask_bad = nil, 0, nil
local function make_skip_mask()
  local ok, m = pcall(function()
    local m = 0
    for _, k in ipairs(SKIP) do
      local bit = df.item_flags[k]
      if math.type(bit) ~= 'integer' or bit < 0 or bit > 31 then return nil end
      m = m | (1 << bit)
    end
    return m
  end)
  return ok and m or nil
end
local function skipped(f)
  for _, k in ipairs(SKIP) do if f[k] then return true end end
  return false
end
local GEAR_CAT = {ARMOR = 'body', HELM = 'head', PANTS = 'pants', GLOVES = 'gloves', SHOES = 'shoes',
                  SHIELD = 'shield', QUIVER = 'quiver'}
-- body, head and pants count only true armor (raws [ARMORLEVEL] >= 1: breastplate, mail shirt, leather armor, helm,
-- greaves, leggings): a dropped leather cloak, robe, hood or trousers is clothing, not a soldier's slot
local ARMORLEVEL = {ARMOR = true, HELM = true, PANTS = true}

local mcache, tcache, bolt_sub, wdef, orec, adef = {}, {}, {}, {}, {}, {}
-- raws and plugin caches of the order, farm and starvation checks (per boot: another save may hold other raws)
local rcache, pinfo, pidx, ecache, plugins = {}, {}, nil, {}, {}
-- an item's material: the mat_type/mat_index fields, else the virtual getActualMaterial(Index) (live L5: prepared
-- fish, item_fishst, has no mat_type field; the census dropped every one as "unreadable", so no fish was food)
local function mat_fields(it) return it.mat_type, it.mat_index end
local function mat_actual(it) return it:getActualMaterial(), it:getActualMaterialIndex() end
local function item_mat(it)                     -- no closure per item: the census reads thousands a day
  local ok, t, i = pcall(mat_fields, it)
  if ok and t ~= nil then return t, i end
  local ok2, t2, i2 = pcall(mat_actual, it)
  if ok2 then return t2, i2 end
  return -1, -1
end

local function mat_flags(it)                    -- material flags, cached per census (Lua API.txt:808)
  local t, i = item_mat(it)
  local row = mcache[t]
  if not row then row = {}; mcache[t] = row end
  local f = row[i]
  if f == nil then
    local mi = dfhack.matinfo.decode(t, i)
    f = mi and mi.material and mi.material.flags or false
    row[i] = f
  end
  return f or nil
end

local function mat_token(t, i)                  -- 'INORGANIC:IRON', 'PLANT:GRASS_TAIL_PIG:SEED'
  local row = tcache[t]
  if not row then row = {}; tcache[t] = row end
  local s = row[i]
  if s == nil then
    local ok, tok = pcall(function()
      local mi = dfhack.matinfo.decode(t, i)
      return mi and mi:getToken()
    end)
    s = ok and type(tok) == 'string' and tok or false
    row[i] = s
  end
  return s or nil
end

-- BUG-665 (Run 16b i2 Valleyhame: CONGLOMERATE, SANDSTONE, CHERT, SHALE 'hard, not economic' by the raws and the stone-use screen, every rock
-- job and every mood still 'none hard stone'; Run 16d i4 MUDSTONE / CLAYSTONE / KAOLINITE the same): the census does not guess what DF takes
-- as 'non-economic hard stone', it asks the game. A job_item for a BOULDER with the flags the rock furniture and mechanism jobs carry (non_economic,
-- hard) goes through dfhack.job.isSuitableMaterial (act.mat_refused; the check the strange-mood filters already use, reserve.lua R.match); a material it refuses
-- is counted `rock_bad` (and named in kern.log 'free boulders by material': refused by the game). `M.ASK_DF = false` skips the question.
-- Returns true only on a definite 'no'; any fault, an unknown field or a missing API answers false (the old census stands).
M.ASK_DF = true
function M.df_refuses(idx)
  if not M.ASK_DF or not M.act then return false end
  local ok, yes = pcall(function() return M.act.mat_refused(idx) end)         -- act.lua I.mat_refused
  return ok and yes == true
end

-- an inorganic boulder material: ore (token, metal tokens) and flux; raws only (the item is in the fort)
local function ore_of(idx)
  local r = orec[idx]
  if r then return r end
  r = {}
  pcall(function()
    local mi = dfhack.matinfo.decode(0, idx)
    local inorg = mi and mi.inorganic
    if not inorg then return end
    r.token = mi:getToken()
    local v = inorg.metal_ore.mat_index                       -- quickfort/stockflow.lua:149
    if v and #v > 0 then
      r.metals = {}
      for _, m in ipairs(v) do r.metals[#r.metals + 1] = mat_token(0, m) or '' end
    end
    for _, rc in ipairs(mi.material.reaction_class) do if rc.value == 'FLUX' then r.flux = true end end
    -- live L6: masons cancel rock furniture for "non-economic hard stone"; economic stone (DF's stone use
    -- setting) and soft stone (chalk: no ITEMS_HARD) are no furniture stone
    local es = df.global.plotinfo.economic_stone
    if es and es[idx] ~= nil and es[idx] ~= 0 and es[idx] ~= false then r.econ = true end
    if mi.material.flags.ITEMS_HARD ~= true then r.soft = true end
    -- BUG-665: the game's own verdict on a plain building stone (hard, not economic, no ore, no flux) as furniture / mechanism stone
    if not (r.econ or r.soft or r.metals or r.flux) and M.df_refuses(idx) then r.refused = true end
  end)
  orec[idx] = r
  return r
end

local function subtype(it)                      -- item:getSubtype() (virtual on every item), else the field
  local ok, s = pcall(function() return it:getSubtype() end)
  if ok and s ~= nil then return s end
  return it.subtype
end

local function is_bolt(it)                      -- items.getSubtypeDef (Lua API.txt:2015)
  local s = subtype(it)
  if bolt_sub[s] == nil then
    local def = dfhack.items.getSubtypeDef(df.item_type.AMMO, s)
    bolt_sub[s] = def ~= nil and def.id == 'ITEM_AMMO_BOLTS'
  end
  return bolt_sub[s]
end

-- itemdef armorlevel (raws [ARMORLEVEL], 0 when absent); an unknown def counts (never hide a real piece)
local function is_armor(it, cat)
  if not ARMORLEVEL[cat] then return true end
  local s = subtype(it) or -1
  local row = adef[cat]
  if not row then row = {}; adef[cat] = row end
  local v = row[s]
  if v == nil then
    local ok, lvl = pcall(function()
      local def = dfhack.items.getSubtypeDef(df.item_type[cat], s)
      if def == nil then return nil end
      return def.armorlevel
    end)
    v = not ok or lvl == nil or (math.tointeger(lvl) or 0) >= 1
    row[s] = v
  end
  return v
end

-- pick, axe, xbow, bow, melee (any other melee weapon) or other; crossbows carry a melee skill too
local function weapon_kind(it)
  local s = subtype(it)
  local k = wdef[s]
  if k == nil then
    local def = dfhack.items.getSubtypeDef(df.item_type.WEAPON, s)
    local js = df.job_skill
    k = 'other'
    if def then
      if def.skill_ranged == js.CROSSBOW then k = 'xbow'
      elseif def.skill_ranged == js.BOW then k = 'bow'
      elseif def.skill_melee == js.MINING then k = 'pick'
      elseif def.skill_melee == js.AXE then k = 'axe'
      elseif (def.skill_ranged or -1) < 0 then k = 'melee' end
    end
    wdef[s] = k
  end
  return k
end

local function holder(it)                       -- the unit carrying the item, or nil (Lua API.txt items.getHolderUnit)
  if not it.flags.in_inventory then return nil end
  local gh = dfhack.items.getHolderUnit
  return gh and gh(it) or nil
end

-- gear a soldier may wear: free (not owned, melting or carried by a civilian) or carried by a soldier
local function gear_ok(it)
  local f = it.flags
  if f.owned or f.melt then return false end
  local u = holder(it)
  return u == nil or (u.military.squad_id or -1) >= 0
end

-- BUG-689 (Run 16d i4 Trumpetrealms y447-y456: 'gear: body 28/10 ok' with 24 pieces made by another race (loot sized for goblins) among the
-- 36 + 24 + 29 pieces 'lying free but out of reach', B at armor 0, no armor order beside 32 bars; Run 16a i1: every slot 'ok', 'metal: 0 forge
-- jobs'): the gear count was every piece a soldier holds or nobody owns, wearable or not. A piece made by another race than the fortress'
-- (armor is sized for its maker) or lying on another walk group than the citizens' (flooded levels, cut-off caves: nobody fetches it) is no
-- piece of the fort's gear: the slot counts it missing and the forge or the leatherworks makes one (`g_unusable` counts what was left out).
-- Worn pieces always count.
function M.wearable(a, it)
  local f = it.flags
  if f.in_inventory then return true end
  local mr, race = it.maker_race, df.global.plotinfo.race_id
  if mr ~= nil and race ~= nil and mr >= 0 and race >= 0 and mr ~= race then return false end
  if a.far and a.far(it) then return false end
  -- BUG-743: a piece DF keeps assigned to a squad position and nobody fetches (released twice and still lying, or out of the soldiers' reach)
  -- is no piece of the fort's gear either: the slot counts it missing and a fresh one is ordered
  if a.stuck and a.stuck[it.id] then return false end
  return true
end

-- an item (or its container) to unforbid later (FR-23/FR-25/FR-50): ids only, the flags are read again then
M.BURST_SLICE = 25                -- FR-76: unforbids per frame in a burst (T.forbid)
local FIX_MAX = 500                -- FR-76: a reclaimed fort's forbidden stock (T.forbid burst) needs more than 200
local WEB_PROBES = 200               -- BUG-024: webs a census probes for the citizens' walk group
local function fix(a, it, why)
  local id = it and it.id
  if not id or a.fix_seen[id] or #a.fix >= FIX_MAX then return end
  local f = it.flags
  if f.trader or f.in_building or f.garbage_collect or f.removed then return end
  a.fix_seen[id] = true
  a.fix[#a.fix + 1] = {id = id, why = why}
end

-- an input of an order lies on the citizens' walkable group (FR-01): one reachable item per key is enough
local function reach_mark(a, it, key)
  if a.reach[key] then return end
  if it.flags.in_inventory or not (a.far and a.far(it)) then a.reach[key] = true end
end

function M.sandy(it) return it:isSandBearing() end      -- Run 11: a bag of sand (no closure per census item)

-- Run 11 (Kilrudrabed y432: both kitchens idle, PrepareMeal 'no cook' for 8 days beside 1566 plant growths): is this
-- EDIBLE_COOKED food item on the kitchen's Cook ban? The config ban (`kitchen`: plump helmets, Gordon's rule) or a
-- kitchen exclusion (the kitchen screen; ban-cooking writes the same list): dfhack.kitchen.findExclusion with the item's
-- type, subtype (a plant growth's growth index; -1 matches too) and material. Cached per census (a.kc).
-- BUG-345: true = the config ban; a kitchen exclusion returns its row {cat, sub, t, i, tok, n} (a.kx: M.cook_repair)
function M.cook_banned(a, cat, it)
  local t, i = item_mat(it)
  if t == nil or i == nil then return false end
  local sub = cat == 'PLANT_GROWTH' and (math.tointeger(subtype(it)) or -1) or -1
  local ck = sub == -1 and cat or (cat .. sub)          -- one string a growth kind, none for the rest
  local rows = a.kc[ck]
  if not rows then rows = {}; a.kc[ck] = rows end
  local row = rows[t]
  if not row then row = {}; rows[t] = row end
  local v = row[i]
  if v == nil then
    v = false
    if cat == 'PLANT' and next(a.nocook) then
      local tok = mat_token(t, i)
      local plant = tok and tok:match('^PLANT:([^:]+):')
      v = plant ~= nil and a.nocook[plant] == true
    end
    local kit = dfhack.kitchen
    if not v and kit and kit.findExclusion then
      local itype = df.item_type[cat]
      local ok1, k1 = pcall(kit.findExclusion, {Cook = true}, itype, sub, t, i)
      local ex = ok1 and (math.tointeger(k1) or -1) >= 0
      local esub = sub
      if not ex and sub ~= -1 then
        local ok2, k2 = pcall(kit.findExclusion, {Cook = true}, itype, -1, t, i)
        ex, esub = ok2 and (math.tointeger(k2) or -1) >= 0, -1
      end
      if ex then
        v = {cat = cat, sub = esub, t = t, i = i, tok = mat_token(t, i), n = 0}
        a.kx[#a.kx + 1] = v
      end
    end
    row[i] = v
  end
  return v
end

-- BUG-345: a material token as the kitchen lines name it: 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL' -> 'MUSHROOM_HELMET_PLUMP',
-- 'PLANT:STRAWBERRY:FRUIT' -> 'STRAWBERRY:FRUIT'
function M.short_mat(tok)
  return (tostring(tok):gsub('^PLANT:', ''):gsub(':STRUCTURAL$', ''))
end

-- BUG-042: does a material have the DRINK_MAT reaction product (a still brews it)? (material.reaction_product.id, a
-- vector of strings; DFHack gives string pointers with .value)
function M.drink_mat(t, i)
  local mi = dfhack.matinfo.decode(t, i)
  local rp = mi and mi.material and mi.material.reaction_product
  if not rp or not rp.id then return false end
  for _, id in ipairs(rp.id) do
    local v = type(id) == 'string' and id or id.value
    if v == 'DRINK_MAT' then return true end
  end
  return false
end

-- BUG-042: a brewable plant item: DRINK_MAT, or a plump helmet (the kitchen's Cook ban, Gordon's rule: brewed, never
-- cooked); cached per census and material (a.bc)
function M.brew_ok(a, cat, it)
  local t, i = item_mat(it)
  if t == nil or i == nil then return false end
  local row = a.bc[t]
  if not row then row = {}; a.bc[t] = row end
  local v = row[i]
  if v == nil then
    v = false
    if cat == 'PLANT' and next(a.nocook) then
      local tok = mat_token(t, i)
      local plant = tok and tok:match('^PLANT:([^:]+):')
      v = plant ~= nil and a.nocook[plant] == true
    end
    if not v then
      local ok, yes = pcall(M.drink_mat, t, i)
      v = ok and yes == true
    end
    row[i] = v
  end
  return v
end

-- a small tally {key = n} (at most 16 keys; '#' counts them) and its k largest entries {{key, n}}
function M.tally(t, key, n)
  if key == nil then return end
  if t[key] == nil then
    if (t['#'] or 0) >= 16 then return end
    t['#'] = (t['#'] or 0) + 1
  end
  t[key] = (t[key] or 0) + n
end
function M.top(t, k)
  local r = {}
  for key, n in pairs(type(t) == 'table' and t or {}) do if key ~= '#' then r[#r + 1] = {key, n} end end
  table.sort(r, function(x, y) if x[2] ~= y[2] then return x[2] > y[2] end return x[1] < y[1] end)
  while #r > (k or 3) do table.remove(r) end
  return r
end


-- BUG-023 (Run 11): a forbidden pick or axe nobody carries is no free tool, but the tool details may want it: counted
-- (w_pick_forb, w_axe_forb) and listed (tool_items, forb) so T.forbid unforbids it while a member lacks that tool
M.TOOL_LIST = 8                       -- tools of each kind the census lists (free first come, forbidden too)
-- BUG-053: a free tool on another walk group gives its place in the list to one on the citizens' group (the first eight in
-- the item vector were the unreachable ones: the report and the unforbid saw nothing the members could use)
-- BUG-706 (Run 16a i1 Basementflew: 20 free axes, 17 usable, the 3 lowest ids reserved by squad uniforms: the list and TOOL_BLOCKED's sample held
-- those three and the report said 'axes not in DF's free equipment list' for 567 days): a reserved tool gives its place like a far one
function M.tool_listed(a, k, e, isfar)
  local list = a.tool_items[k]
  if #list < M.TOOL_LIST then list[#list + 1] = e; return end
  if isfar or e.res then return end
  for i = #list, 1, -1 do
    if list[i].far or list[i].res then list[i] = e; return end
  end
end
-- the order the diagnosis reads the listed tools in: free on the citizens' group, free on another, forbidden, reserved by a squad uniform
function M.tool_rank(e) return e.res and 4 or (e.forb and 3 or (e.far and 2 or 1)) end
-- the listed tools of a kind (tests, inspect): copies of {id, forb?, far?, bin?, own?, ...}
function M.tool_list(kind)
  local r = {}
  for i, e in ipairs((st.tool_items or {})[kind] or {}) do
    local c = {}
    for k2, v in pairs(e) do c[k2] = v end
    r[i] = c
  end
  return r
end
function M.tool_forb(a, it)
  local k = weapon_kind(it)
  if (k ~= 'pick' and k ~= 'axe') or holder(it) then return end
  a['w_' .. k .. '_forb'] = a['w_' .. k .. '_forb'] + 1
  local list = a.tool_items[k]
  if #list < M.TOOL_LIST then list[#list + 1] = {id = it.id, forb = true} end
end

-- Run 11 (bars 0 for ten years beside eight sieges of invaders' gear): a metal weapon, armor piece or ammo marked for
-- melting (the dfllm-melt pile's automelt) is bars to come; census `melt` counts them, so plan_metal orders the fuel a
-- smelter's melt jobs burn even while the fort holds no ore and no bar
function M.melt_mark(a, it)
  local mf = mat_flags(it)
  if mf and mf.IS_METAL then a.melt = a.melt + 1 end
end
local function classify(it, a, cat)
  local f = it.flags
  local w = skip_mask and f.whole
  a.fw = w                                       -- BUG-665: the boulder branch reads in_job from the same word
  if math.type(w) == 'integer' then
    local skip = w & skip_mask ~= 0
    if mask_check > 0 then
      mask_check = mask_check - 1
      if skip ~= skipped(f) then skip_mask, mask_bad, skip = nil, true, skipped(f) end
    end
    if skip then return end
  elseif skipped(f) then return end
  local n = math.tointeger(it.stack_size) or 1
  if cat == 'DRINK' or cat == 'SEEDS' or a.food_set[cat] then
    -- FR-50 (Run 9: 1392 drinks in forbidden TOOL pots read as "0 days"): a forbidden container of any item type
    -- makes drink, food and seeds unusable; FR-23: seeds in a forbidden item or bag are unusable seeds
    local cont = dfhack.items.getContainer(it)  -- Lua API.txt:2035
    local outer = cont and dfhack.items.getContainer(cont)
    local cf = cont and cont.flags.forbid
    local of = outer and outer.flags.forbid
    if f.forbid or cf or of then
      if cat == 'DRINK' then a.drink_forb = a.drink_forb + n
      elseif cat == 'SEEDS' then a.seeds_forb = a.seeds_forb + n
      else a.food_forb = a.food_forb + n end
      local why = cat == 'SEEDS' and 'seeds' or 'container'
      if cf then fix(a, cont, why) end
      if of then fix(a, outer, why) end
      if f.forbid then fix(a, it, cat == 'SEEDS' and 'seeds' or 'food') end
      return
    end
  elseif f.forbid then
    if cat == 'WEAPON' then M.tool_forb(a, it)
    elseif cat == 'WOOD' then a.wood_forb = a.wood_forb + n end     -- BUG-705: forbidden logs, counted apart (not `wood`)
    return
  end
  if f.melt and (cat == 'WEAPON' or cat == 'AMMO' or GEAR_CAT[cat]) then M.melt_mark(a, it) end   -- Run 11
  -- live L7 (Paddletribes): 117 of 137 "edible" fruit lay in cut-off caves; the fort read 101 food days while 35 of
  -- 42 dwarves starved. Food and drink on another walkable group than the citizens' feed nobody.
  if (cat == 'DRINK' or a.food_set[cat]) and not f.in_inventory and a.far and a.far(it) then
    a.unreach = (a.unreach or 0) + n
    if cat ~= 'DRINK' then a.food_far = a.food_far + n end     -- Run 11: the kitchen's view (M.cook_why)
    return
  end
  if cat == 'DRINK' then a.drink = a.drink + n
  elseif a.food_set[cat] then
    -- food = what a dwarf can eat now: meals and raw-edible items. Cook-only items (egg yolks, raw fish,
    -- flour) feed nobody without a kitchen job (live L1: 34 yolks reported as 250 food days while a
    -- dwarf starved), so they count as `cookable`.
    -- BUG-042: the brewable ones (DRINK_MAT; plump helmets always) are the stills' input (brew_p plants, brew_g fruit)
    if (cat == 'PLANT' or cat == 'PLANT_GROWTH') and M.brew_ok(a, cat, it) then
      if cat == 'PLANT' then a.brew_p = a.brew_p + n else a.brew_g = a.brew_g + n end
    end
    if cat ~= 'FOOD' then
      local mf = mat_flags(it)
      -- Run 11 (Kilrudrabed: PrepareMeal 'no cook' beside 1566 plant growths): a kitchen cooks what is EDIBLE_COOKED
      -- and not on its Cook ban (cook_in; cook_ban the banned ones); neither flag is no food at all (food_inedible)
      if mf and mf.EDIBLE_COOKED then
        local ban = M.cook_banned(a, cat, it)
        if not ban then a.cook_in = a.cook_in + n
        else
          a.cook_ban = a.cook_ban + n
          if cat == 'PLANT_GROWTH' then a.cook_ban_g = a.cook_ban_g + n end   -- M.food_unban
          -- BUG-345: which material, and whose ban (the config's `kitchen` rule, D-09, or a kitchen exclusion)
          if ban == true then M.tally(a.cban, 'D-09 ' .. M.short_mat(mat_token(item_mat(it))), n)
          else
            ban.n, a.cook_ban_x = ban.n + n, a.cook_ban_x + n
            M.tally(a.cban, M.short_mat(ban.tok), n)
          end
        end
      elseif not (mf and mf.EDIBLE_RAW) then
        a.food_inedible = a.food_inedible + n
        M.tally(a.ined, mat_token(item_mat(it)), n)
      end
      if not (mf and mf.EDIBLE_RAW) then
        if mf and mf.EDIBLE_COOKED then a.cookable = a.cookable + n end
        return
      end
      -- live L5: raw food a cook may not use (the kitchen ban of `kitchen`: plump helmets, Gordon's rule)
      if a.nocook and cat == 'PLANT' then
        local tok = mat_token(item_mat(it))
        local plant = tok and tok:match('^PLANT:([^:]+):')
        if plant and a.nocook[plant] then a.food_nocook = a.food_nocook + n end
      end
    end
    a.food = a.food + n
    if cat == 'FOOD' then a.meals = a.meals + n; a.kinds[subtype(it) or -1] = true end
    if #a.food_pos < 8 and not f.in_inventory then           -- FR-25: where reachable food lies
      local x, y, z = dfhack.items.getPosition(it)
      if x then a.food_pos[#a.food_pos + 1] = {x = x, y = y, z = z} end
    end
  elseif cat == 'CLOTH' then a.cloth = a.cloth + n; reach_mark(a, it, 'cloth')
  elseif cat == 'FISH_RAW' then a.fish_raw = a.fish_raw + n   -- live L4: 199 raw fish, no fishery, famine
  elseif cat == 'SKIN_TANNED' then a.leather = a.leather + n; reach_mark(a, it, 'leather')
  elseif cat == 'CORPSEPIECE' then
    -- a dead citizen's remains are nobody's material (deteriorate.lua is_usable_corpse_piece; care's reserve
    -- skips them too): L1-L3 left 16 dead, and their bones must not read as the moods' bone stock
    local cf = not f.dead_dwarf and it.corpse_flags
    if cf and not cf.unbutchered then
      if cf.bone then a.bone = a.bone + n; reach_mark(a, it, 'bone') elseif cf.shell then a.shell = a.shell + n
      elseif cf.leather then a.hides = a.hides + n end      -- a raw hide (deteriorate.lua usable_types)
    end
  -- Run 11: raw glass (ROUGH of GLASS_GREEN/CLEAR/CRYSTAL, builtin mats 3-5) is no gem (a rough-gem mood filter wants an
  -- inorganic); cut glass is a cut gem ("cut gems" filters take any material) and also counted as gems_glass
  elseif cat == 'SMALLGEM' then
    a.gems = a.gems + n
    a.gems_cut = a.gems_cut + n                    -- BUG-573: the cut form alone (the reserve's `gems`, the glass chain's stock)
    local mt = it.mat_type
    if mt == 3 or mt == 4 or mt == 5 then a.gems_glass = a.gems_glass + n end
  elseif cat == 'ROUGH' then
    local mt = it.mat_type
    if mt == 3 or mt == 4 or mt == 5 then a.glass = a.glass + n; reach_mark(a, it, 'glass')
    else
      a.gems = a.gems + n
      a.gems_rough = a.gems_rough + n              -- BUG-573: rough gems apart: economy cuts those beyond glass.rough_keep
    end
  elseif cat == 'BAG' then
    -- Run 11: a bag of sand (the glass furnace's input; item:isSandBearing, DF's "glassable") or an empty bag (CollectSand)
    local okb, sandy = pcall(M.sandy, it)
    if okb and sandy == true then a.sand = a.sand + 1; reach_mark(a, it, 'sand')
    elseif #dfhack.items.getContainedItems(it) == 0 then a.bags = a.bags + 1; reach_mark(a, it, 'bags') end
  elseif cat == 'BAR' then
    if it.mat_type == 0 then
      a.bars = a.bars + n
      local tok = mat_token(0, it.mat_index)
      if tok then a.bars_by[tok] = (a.bars_by[tok] or 0) + n; reach_mark(a, it, 'bars:' .. tok) end
      reach_mark(a, it, 'bars')
    elseif it.mat_type == COAL then a.fuel = a.fuel + n end
  elseif cat == 'AMMO' then
    if is_bolt(it) then
      a.bolts = a.bolts + n
      -- bolts a hunter can take: not in a soldier's hands or quiver (a hunter without ammo fights in melee)
      local u = holder(it)
      if not u then
        local okc, cont = pcall(dfhack.items.getContainer, it)
        u = okc and cont and holder(cont) or nil
      end
      if not (u and (u.military.squad_id or -1) >= 0) then a.bolts_free = a.bolts_free + n end
    end
  elseif cat == 'WOOD' then
    -- BUG-705 (Run 16b i2 Whirledrampart y420-y423: census wood 210 beside DF's "Needs logs" on every carpenter, mason's and bowyer's job, the
    -- mood unit's own scan said 'none reachable [210/210/0]'): a log on another walk group than the citizens' is no log for any job (DF's
    -- job picker takes only an item a worker can walk to); it is counted apart (wood_far) and is not `wood`, so floors, orders, treeless
    -- and the caravans' wood want see the fort's real stock
    if not f.in_inventory and a.far and a.far(it) then a.wood_far = a.wood_far + n
    else a.wood = a.wood + n; reach_mark(a, it, 'wood') end
  elseif M.PIECE_INV[cat] then
    -- Run 11: free doors, hatch covers, grates and blocks (not built in, not taken by a job): what a seal piece or a
    -- planned building can use now (T.jmake, economy.mat_for)
    -- BUG-544 (Run 16a i1 Basementflew: 13 'free' blocks lay in the flooded z117 complex, the aqshaft ring waited 600 days beside 255
    -- logs): a piece on another walk group than the citizens' is no piece anybody can carry; `<key>_far` counts it
    local key = M.PIECE_INV[cat]
    if not f.in_job then
      local fk = key:gsub('_free$', '') .. '_far'
      if a.far and a.far(it) then a[fk] = a[fk] + n
      else a[key] = a[key] + n end
    elseif key == 'blocks_free' then
      -- BUG-736 (Run 16c i3 Doorwings y382: census blocks 132, blocks_free 0, nobody could say where they were): a block a job holds is counted
      -- apart (`blocks_busy`), so the wall stock names the claimed ones instead of showing a bare 0
      a.blocks_busy = a.blocks_busy + n
    end
  elseif cat == 'BARREL' or cat == 'BIN' then  -- live L1b: brewing stalled for want of an empty barrel
    local empty = #dfhack.items.getContainedItems(it) == 0
    if cat == 'BARREL' then
      a.barrels = a.barrels + 1
      if empty then a.barrels_empty = a.barrels_empty + 1 end
    else
      a.bins = a.bins + 1
      if empty then a.bins_empty = a.bins_empty + 1 end
    end
  elseif cat == 'BOULDER' then
    -- BUG-544 (Basementflew: census rock 32, every boulder in the flooded z117 complex, masons and mechanics never worked): a
    -- boulder on another walk group than the citizens' is no stone for any job; `rock_far` counts it, `rock` and `ore` do not
    -- BUG-665 (Run 16a i1 Basementflew: 30 boulders 'usable' beside DF's "Needs non-economic hard stone" for 100+ days, they lay in the flooded
    -- z117; Run 16b i2 Valleyhame: 46 of 84 for 200 days): DF's job picker takes a boulder that no job holds and that a worker can walk to.
    -- A boulder on a tile with NO walkable group (flooded, walled in; the plain `far` read calls group 0 near) is out of reach, one a job
    -- already holds (`in_job`: a hauler's or a builder's claim that never ends) is no free stone: both are counted apart, not in `rock`
    if a.far and a.far(it, true) then a.rock_far = a.rock_far + n; return end   -- (no flag read: the census reads one flag word)
    -- (the in_job bit comes from the flag word the census already read; one more flag read only without the mask)
    local busy
    if math.type(a.fw) == 'integer' and M.JOB_BIT then busy = a.fw & M.JOB_BIT ~= 0 else busy = f.in_job == true end
    if busy then a.rock_busy = a.rock_busy + n; return end
    a.rock = a.rock + n
    if it.mat_type == 0 then
      local r = ore_of(it.mat_index)
      -- BUG-733: one boulder counted once as unusable, however many reasons it has (ore and economic, flux and economic: the old
      -- max(ore + flux, rock_bad) took the larger of two sets that overlap only in part and gave a mason's stone away to the ore)
      if r.metals or r.flux or r.econ or r.soft or r.refused then a.rock_nouse = (a.rock_nouse or 0) + n end
      if r.metals and r.token then
        a.ore = a.ore + n
        local o = a.ores[r.token]
        if not o then o = {n = 0, metals = r.metals}; a.ores[r.token] = o end
        o.n = o.n + n
        reach_mark(a, it, 'ore:' .. r.token)
      end
      if r.flux then a.flux = a.flux + n end
      if r.econ or r.soft or r.refused then a.rock_bad = (a.rock_bad or 0) + n
      elseif not (r.metals or r.flux) then reach_mark(a, it, 'rock') end
    end
  elseif cat == 'THREAD' then
    -- BUG-024 (Handlelock: 8657 THREAD items, every one a loose spider web 80 levels under the fort): a web is no
    -- thread until a weaver collects it (CollectWebs), so webs are no cloth input; `webs` counts them, `webs_near`
    -- those on the citizens' walk group (the first WEB_PROBES webs of a census are probed)
    if f.spider_web then
      a.webs = a.webs + n
      if a.web_probes < WEB_PROBES then
        a.web_probes = a.web_probes + 1
        if not (a.far and a.far(it)) then
          a.webs_near = a.webs_near + n
          if not a.web_pos and not f.in_inventory then
            local x, y, z = dfhack.items.getPosition(it)
            if x then a.web_pos = {x, y, z} end
          end
        end
      end
    else
      local mf = mat_flags(it)
      a.thread = a.thread + n
      reach_mark(a, it, 'thread')
      if mf and mf.SILK then a.thread_silk = a.thread_silk + n
      elseif mf and mf.YARN then a.thread_yarn = a.thread_yarn + n
      else a.thread_plant = a.thread_plant + n end
    end
  elseif cat == 'SEEDS' then
    local tok = mat_token(it.mat_type, it.mat_index)
    local plant = tok and tok:match('^PLANT:([^:]+):')
    if plant then a.seeds[plant] = (a.seeds[plant] or 0) + n end
    a.seeds_ok = a.seeds_ok + n
  elseif (cat == 'WEAPON' or GEAR_CAT[cat]) and f.trader then
    -- live L6: merchant goods are no tool or gear of the fort. Not flags.foreign: DF 53 sets it on the
    -- embark wagon's own picks and axes too (Perplexrooms: 0 tools counted, every miner released)
    return
  elseif cat == 'WEAPON' then
    local k = weapon_kind(it)
    if k == 'pick' or k == 'axe' then
      a['w_' .. k] = a['w_' .. k] + 1
      if not holder(it) then                                         -- FR-40: nobody carries it (a bin may)
        a['w_' .. k .. '_free'] = a['w_' .. k .. '_free'] + 1
        -- BUG-023: where the free tools lie (in a container, reserved for a squad uniform), for TOOL_BLOCKED
        local okc, cont = pcall(dfhack.items.getContainer, it)
        cont = okc and cont or nil
        local res = a.res[it.id] == true
        if cont then a['w_' .. k .. '_bin'] = a['w_' .. k .. '_bin'] + 1 end
        if res then a['w_' .. k .. '_res'] = a['w_' .. k .. '_res'] + 1 end
        -- BUG-023 (Run 11): marked for melting (L1b: the melt pile's marks kept the spare picks from the miners for a
        -- year) or owned by a dwarf: no work tool for anybody else
        if f.melt then a['w_' .. k .. '_melt'] = a['w_' .. k .. '_melt'] + 1 end
        if f.owned then a['w_' .. k .. '_own'] = a['w_' .. k .. '_own'] + 1 end
        -- BUG-053: on another walk group than the citizens (members and haulers cannot reach it): _far; free, reachable,
        -- unowned and not marked for melting: _use (what a member could be handed)
        local isfar = a.far ~= nil and a.far(it) == true
        if isfar then a['w_' .. k .. '_far'] = a['w_' .. k .. '_far'] + 1
        -- BUG-706: a tool a squad uniform reserved is no work tool for a member (DF hands none out): not `use`
        elseif not f.owned and not f.melt and not res then a['w_' .. k .. '_use'] = a['w_' .. k .. '_use'] + 1 end
        M.tool_listed(a, k, {id = it.id, bin = cont and cont.id or nil, res = res or nil, melt = f.melt or nil,
                             own = f.owned or nil, far = isfar or nil}, isfar)
      end
    elseif k == 'xbow' or k == 'bow' then
      local u = holder(it)
      if not (u and (u.military.squad_id or -1) >= 0) then a['w_' .. k] = a['w_' .. k] + 1 end   -- for hunters
      if k == 'xbow' and not (f.owned or f.melt) then a.g_xbow = a.g_xbow + 1 end   -- soldiers' and hunters'
    elseif k == 'melee' and gear_ok(it) then
      local mf = mat_flags(it)
      if mf and mf.IS_METAL then a.g_weapon = a.g_weapon + 1 end
    end
  elseif GEAR_CAT[cat] then
    local g = GEAR_CAT[cat]
    if gear_ok(it) and is_armor(it, cat) then
      if g == 'shield' or g == 'quiver' then a['g_' .. g] = a['g_' .. g] + 1
      elseif not M.wearable(a, it) then a.g_unusable = a.g_unusable + 1     -- BUG-689
      else
        local mf = mat_flags(it)
        if mf and mf.IS_METAL then a['g_' .. g] = a['g_' .. g] + 1; a['gm_' .. g] = a['gm_' .. g] + 1; a.g_metal = a.g_metal + 1
        elseif mf and mf.LEATHER then a['g_' .. g] = a['g_' .. g] + 1 end
      end
    end
  end
end

local ZERO = {'drink', 'food', 'meals', 'cloth', 'leather', 'bone', 'shell', 'gems', 'bars', 'bolts', 'wood', 'fuel',
              'drink_forb', 'food_forb', 'cookable', 'barrels', 'barrels_empty', 'bins', 'bins_empty', 'rock', 'ore', 'rock_bad',
              'flux', 'hides', 'thread', 'thread_plant', 'thread_silk', 'thread_yarn', 'bolts_free', 'w_pick', 'w_axe',
              'w_xbow', 'w_bow', 'g_body', 'g_head', 'g_pants', 'g_gloves', 'g_shoes', 'g_shield', 'g_weapon', 'g_xbow',
              'g_quiver', 'g_metal', 'gm_body', 'gm_head', 'gm_pants', 'gm_gloves', 'gm_shoes', 'g_unusable', 'fish_raw', 'food_nocook', 'seeds_ok', 'seeds_forb', 'w_pick_free', 'w_axe_free',
              'w_pick_bin', 'w_axe_bin', 'w_pick_res', 'w_axe_res', 'webs', 'webs_near', 'glass', 'gems_glass', 'gems_cut', 'gems_rough', 'sand',
              'bags', 'doors', 'hatches', 'grates', 'blocks_free', 'cook_in', 'cook_ban', 'cook_ban_g', 'cook_ban_x', 'food_inedible', 'food_far',
              'w_pick_forb', 'w_axe_forb', 'w_pick_melt', 'w_axe_melt', 'w_pick_own', 'w_axe_own', 'melt',
              'w_pick_far', 'w_axe_far', 'w_pick_use', 'w_axe_use',
              'brew_p', 'brew_g', 'chairs', 'tables',
              'rock_far', 'doors_far', 'hatches_far', 'grates_far', 'blocks_far', 'chairs_far', 'tables_far',   -- BUG-544
              'rock_busy',   -- BUG-665
              'rock_nouse',  -- BUG-733: boulders no mason may take (ore, flux, economic, soft, refused): each counted once
              'blocks_busy', -- BUG-736
              'wood_far', 'wood_forb'}   -- BUG-705
local function new_acc(c)
  local fs = {}
  for _, k in ipairs(c.food_cats or {}) do fs[k] = true end
  local nocook = {}
  for _, e in ipairs(c.kitchen or {}) do
    if e.what == 'Cook' and e.item == 'PLANT' and type(e.plant) == 'string' then nocook[e.plant] = true end
  end
  local a = {kinds = {}, food_set = fs, bars_by = {}, ores = {}, seeds = {}, nocook = nocook, fix = {}, fix_seen = {},
             reach = {}, food_pos = {}, res = {}, tool_items = {pick = {}, axe = {}}, web_probes = 0, kc = {}, ined = {},
             bc = {}, kx = {}, cban = {}}
  for _, k in ipairs(ZERO) do a[k] = 0 end
  -- BUG-023: weapons a squad uniform reserved (equipment screen; DF hands no reserved pick or axe out as a work tool)
  pcall(function()
    for _, id in ipairs(df.global.plotinfo.equipment.items_assigned.WEAPON) do a.res[id] = true end
  end)
  return a
end

-- one slice: at most per_slice items; true when every category is done
local function census_slice(c)
  local cs = st.census
  local left = math.max(1, math.tointeger(c.per_slice) or 200)
  local other = df.global.world.items.other
  while left > 0 and cs.ci <= #CATS do
    local cat = CATS[cs.ci]
    local okv, vec = pcall(function() return other[cat] end)   -- unknown enum names raise in DFHack
    local n = okv and vec and #vec or 0
    while left > 0 and cs.idx < n do
      local it = vec[cs.idx]
      cs.idx, left = cs.idx + 1, left - 1
      if it then
        local ok, err = pcall(classify, it, cs.acc, cat)
        if not ok then cs.errs = cs.errs + 1; cs.err = cs.err or tostring(err) end
      end
    end
    if cs.idx >= n then cs.ci, cs.idx = cs.ci + 1, 0 end
  end
  return cs.ci > #CATS
end

local function vlen(cat)
  local ok, n = pcall(function() return #df.global.world.items.other[cat] end)
  return ok and n or 0
end

local function publish(K, c, a)
  local kinds = 0
  for _ in pairs(a.kinds) do kinds = kinds + 1 end
  local crafts = 0
  for _, cat in ipairs(c.idle.craft_cats or {}) do crafts = crafts + vlen(cat) end
  -- Ã‚Â§6.3 fields plus WP8 extras (fuel, *_forb, blocks, crafts, the chain stocks and the gear at hand: g_<slot> =
  -- metal or leather pieces free or carried by soldiers); replaced wholesale. `boulders` stays the whole BOULDER
  -- vector (care's mood reserve sizes its held boulders from it); `rock` = free boulders (not forbidden, not
  -- built in), what economy may spend
  local i = {tick = K.now().tick, meal_kinds = kinds, boulders = vlen('BOULDER'), blocks = vlen('BLOCKS'), crafts = crafts}
  for _, k in ipairs(ZERO) do i[k] = a[k] end
  if st.farm then i.farm_plots, i.farm_empty = st.farm.plots, st.farm.empty end   -- FR-17 (T.farmslots)
  K.census.i = i
  st.bars_by, st.ores, st.seeds = a.bars_by, a.ores, a.seeds
  st.seeds_known = true                              -- BUG-256: st.seeds is the census' now (init holds an empty one)
  st.fix, st.reach, st.food_pos, st.unreach = a.fix, a.reach, a.food_pos, a.unreach or 0
  st.tool_items, st.web_pos = a.tool_items, a.web_pos
  st.ined = M.top(a.ined, 3)                         -- Run 11: the inedible food materials (M.cook_why)
  st.cban, st.kx = M.top(a.cban, 3), a.kx            -- BUG-345: the cook-banned materials, the exclusions behind them
end

---------------------------------------------------------------- stock days (7-day moving average)
-- a day's consumption sample (milli-units): the observed net decrease, floored at the seeded
-- per-dwarf rate and capped at spike_x times it (trade sales, spoilage)
function M.sample(prev, now_n, base, spike)
  local dec = (prev and prev > now_n) and (prev - now_n) * 1000 or 0
  return math.max(base, math.min(dec, base * spike))
end

function M.days(stock, hist)
  local sum = 0
  for _, v in ipairs(hist) do sum = sum + v end
  if sum <= 0 then return 9999 end
  return math.min(9999, stock * 1000 * #hist // sum)
end

local function push(hist, v)
  hist[#hist + 1] = v
  while #hist > 7 do table.remove(hist, 1) end
end

---------------------------------------------------------------- orders
local function orders_all() return df.global.world.manager_orders.all end

local function order_by_id(id)
  if math.type(id) ~= 'integer' then return nil end
  for _, o in ipairs(orders_all()) do if o.id == id then return o end end
end

local function live(id)
  local o = order_by_id(id)
  if o ~= nil and (o.amount_left or 0) <= 0 and (st.jobord or {})[o.id] then return true end   -- BUG-315: its job is out
  return o ~= nil and (o.amount_left or 0) > 0
end

-- own: ids of our dfllm-tagged orders (a dfllm:drink order brews like library/basic does)
local function has_signature(sig, own)
  if type(sig) ~= 'table' then return false end
  for _, o in ipairs(orders_all()) do
    if not own[o.id] and df.job_type[o.job_type] == sig.job and (not sig.reaction or o.reaction_name == sig.reaction) then
      if not sig.mat then return true end
      local mi = dfhack.matinfo.decode(o.mat_type, o.mat_index)
      if mi and mi:getToken() == sig.mat then return true end
    end
  end
  return false
end

local function built(b)
  local ok, done = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
  return not ok or done
end

local function facts(K, p)
  local i = K.census.i or {}
  local f = {migrants = p.migrants == 1, fuel = (i.fuel or 0) > 0, ore = (i.ore or 0) > 0,
             stone = M.usable_n(i) >= 60}
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      local n = df.workshop_type[b.type]
      if n and built(b) then f['workshop:' .. n] = true end
    end
  end)
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.FURNACE_ANY) do
      local n = df.furnace_type[b.type]
      if n and built(b) then f['furnace:' .. n] = true end
    end
  end)
  -- BUG-654: a workshop type whose every shop stands off the citizens' walk groups (M.cut_scan, confirmed) is no workshop: its jobs
  -- sit at a shop nobody walks to; f['cut:<Type>'] says why the type is missing
  local cw = type(p) == 'table' and type(p.cutws) == 'table' and p.cutws or nil
  for t in pairs(cw or {}) do
    if f['workshop:' .. t] then f['workshop:' .. t], f['cut:' .. t] = nil, true end
  end
  return f
end

local function holds(f, cit, cond)
  local n = tostring(cond):match('^cit>=([0-9]+)$')
  if n then return cit >= math.tointeger(tonumber(n)) end
  return f[cond] == true
end

function M.stage_ready(stage, f, cit)
  if stage.all then
    for _, cond in ipairs(stage.all) do if not holds(f, cit, cond) then return false end end
    return true
  end
  for _, cond in ipairs(stage.any or {}) do if holds(f, cit, cond) then return true end end
  return false
end

-- BUG-202: whether library lib may be imported now: a library of a config stage only once that stage is ready (its
-- workshops, citizens, stone), any other one at once; a held one is said in kern.log once per boot
function M.lib_ready(K, c, lib, f, cit)
  for _, s in ipairs(c.stages or {}) do
    if s.lib == lib and not M.stage_ready(s, f or {}, cit) then
      st.lib_held = st.lib_held or {}
      if not st.lib_held[lib] then
        st.lib_held[lib] = true
        K.log('info', 'orders %s of the plan held until its stage is ready (config economy.stages)', tostring(lib))
      end
      return false
    end
  end
  return true
end

-- BUG-524 (Run 16c i3 Sealcertain: phase P3 'waits for orders_rockstock' for 8+ years, the status said nothing more): the gate
-- of a library's config stage is why it is not imported (library/rockstock: Masons + 60 free furniture-grade boulders). Returns
-- the short text of what is missing ('no Masons,stone 12/60'), or nil when the library is imported, has no stage, or its stage
-- is ready (then the plan simply does not list it)
function M.held_why(K, lib)
  local ok, res = pcall(function()
    local p = K.persist.get('m.economy')
    if type(p) ~= 'table' or (type(p.imported) == 'table' and p.imported[lib] ~= nil) then return nil end
    local c = M.conf(K)
    for _, s in ipairs(c.stages or {}) do
      if s.lib == lib then
        local f, cit = facts(K, p), math.tointeger(p.cit) or 0
        if M.stage_ready(s, f, cit) then return nil end
        local i = K.census.i or {}
        local miss = {}
        for _, cond in ipairs(s.all or s.any or {}) do
          if not holds(f, cit, cond) then
            local n = tostring(cond):match('^cit>=([0-9]+)$')
            if cond == 'stone' then
              miss[#miss + 1] = string.format('stone %d/60', M.usable_n(i))
            elseif n then miss[#miss + 1] = string.format('cit %d/%s', cit, n)
            else miss[#miss + 1] = 'no ' .. tostring(cond):gsub('^%a+:', '') end
          end
        end
        return table.concat(miss, ',')
      end
    end
    return nil
  end)
  return ok and res or nil
end

local function ws_any(f, list)
  for _, w in ipairs(list or {}) do if f[w] then return true end end
  return false
end
M.FISHERY = {'workshop:Fishery'}

-- the census' cook ingredients: cook_in (Run 11), else (an older census) raw-edible food that is no meal and not
-- plump helmet plus the cook-only items
function M.cook_n(inv)
  if inv.cook_in ~= nil then return inv.cook_in end
  return (inv.food or 0) - (inv.meals or 0) - (inv.food_nocook or 0) + (inv.cookable or 0)
end

-- Run 11: why a kitchen has nothing to cook (ORDER_STUCK PrepareMeal said 'no cook', read as a missing cook; it was
-- the input check): 'cook ingredient (883 raw fish need a fishery, 1566 inedible (OAK:LEAF), 30 cut off, 11
-- cook-banned)'
function M.cook_why(inv, f)
  local parts, raw, ined_at = {}, inv.fish_raw or 0, nil
  if raw > 0 then
    parts[1] = string.format('%d raw fish %s', raw, ws_any(f or {}, M.FISHERY) and 'to clean' or 'need a fishery')
  end
  if (inv.food_inedible or 0) > 0 then
    local t = st.ined and st.ined[1]
    -- BUG-618 (Run 16b i2 Valleyhame: '135 inedible (CABBAGE:LEAF)' beside 0 food days): a leaf, flower or bud of a crop is a plant growth
    -- with no EDIBLE flag (vanilla CABBAGE: the cabbage itself, STRUCTURAL, is edible; its LEAF has no flag, no ALCOHOL, no MILL reaction):
    -- no kitchen, still or quern can use it; the food is the crop the farm plot grows
    local tok = t and tostring(t[1]):gsub('^PLANT:', '') or nil
    local soft = tok and (tok:find(':LEAF$') or tok:find(':FLOWER$') or tok:find(':BUD$'))
    parts[#parts + 1] = string.format('%d inedible%s', inv.food_inedible, tok and (' (' .. tok .. ')') or '')
    if soft then ined_at = #parts end
  end
  if (inv.food_far or 0) > 0 then parts[#parts + 1] = string.format('%d cut off', inv.food_far) end
  if (inv.food_forb or 0) > 0 then parts[#parts + 1] = string.format('%d forbidden', inv.food_forb) end
  if (inv.cook_ban or 0) > 0 then
    local t = st.cban and st.cban[1]                -- BUG-345: 'D-09 MUSHROOM_HELMET_PLUMP' or the exclusion's material
    parts[#parts + 1] = string.format('%d cook-banned%s', inv.cook_ban, t and (' (' .. tostring(t[1]) .. ')') or '')
  end
  -- the note only while the whole text stays under the 120 characters the stuck-order reasons keep
  if ined_at and #table.concat(parts, ', ') + #': no food use' <= 90 then parts[ined_at] = parts[ined_at]:gsub('%)$', ': no food use)') end
  return 'cook ingredient' .. (#parts > 0 and (' (' .. table.concat(parts, ', ') .. ')') or '')
end

-- open orders: our tags still live (amount left), the inputs they still hold (meta.uses x left) and the wood
-- any other open order still needs (material category wood, MakeCharcoal)
local function scan_orders(p)
  local own = {}
  for tag, id in pairs(p.orders) do own[id] = tag end
  local s = {live = {}, used = {}, brew = M.brew_orders()}
  st.brew = s.brew
  for _, o in ipairs(orders_all()) do
    local left = o.amount_left or 0
    -- BUG-315: DF counts amount_left down as it hands out the jobs; an own order at 0 whose job is still out is open (else
    -- the planner entered it again while that job waited)
    if left <= 0 and own[o.id] and (st.jobord or {})[o.id] then s.live[own[o.id]] = s.live[own[o.id]] or 0 end
    if left > 0 then
      local tag = own[o.id]
      if tag then
        s.live[tag] = left
        local meta = p.meta[tag]
        for key, per in pairs(type(meta) == 'table' and type(meta.uses) == 'table' and meta.uses or {}) do
          s.used[key] = (s.used[key] or 0) + left * (math.tointeger(per) or 0)
        end
      else
        local mc = o.material_category
        if (mc and mc.wood) or df.job_type[o.job_type] == 'MakeCharcoal' then
          s.used.wood = (s.used.wood or 0) + left
          s.xwood = (s.xwood or 0) + left                -- BUG-497: wood other owners' orders want (a seal door goes before them)
        end
      end
    end
  end
  for tag in pairs(p.meta) do if not s.live[tag] then p.meta[tag] = nil end end
  return s
end

-- BUG-042: the open brew orders (CustomReaction BREW_*, any owner): {n, left (brews they still want), valid (validated
-- ones), unval (their brews waiting for the manager)}
function M.brew_orders()
  local b = {n = 0, left = 0, valid = 0, unval = 0}
  for _, o in ipairs(orders_all()) do
    local left = math.tointeger(o.amount_left) or 0
    if left > 0 and tostring(o.reaction_name or ''):sub(1, 5) == 'BREW_' then
      b.n, b.left = b.n + 1, b.left + left
      local okv, valid = pcall(function() return o.status.validated end)
      if okv and valid == false then b.unval = b.unval + left else b.valid = b.valid + 1 end
    end
  end
  return b
end

---------------------------------------------------------------- needs, reserves, floors (hook API)
-- Run 11: glass = raw glass (care's class `glass`: a glassmaker's mood, the extra raw glass), no alias of gems any more
local KEYS = {wood = true, rock = true, bone = true, shell = true, leather = true, cloth = true, thread = true,
              bars = true, gems = true, fuel = true, hides = true, glass = true}
local ALIAS = {logs = 'wood', log = 'wood', boulders = 'rock', boulder = 'rock', stone = 'rock', rough = 'gems',
               gem = 'gems', bar = 'bars', skin = 'hides'}
M.KEYS = KEYS
local function key_of(k)
  k = tostring(k or ''):lower()
  return ALIAS[k] or k
end

-- the largest open need of key (expired records are dropped)
local function need_n(p, key, now)
  local best, m = 0, p.needs[key]
  for who, rec in pairs(type(m) == 'table' and m or {}) do
    if type(rec) == 'table' and (math.tointeger(rec.untl) or 0) >= now then best = math.max(best, math.tointeger(rec.n) or 0)
    else m[who] = nil end
  end
  return best
end

local function holder_floor(p, key)
  local best = 0
  for _, n in pairs(type(p.reserves[key]) == 'table' and p.reserves[key] or {}) do best = math.max(best, math.tointeger(n) or 0) end
  return best
end

-- the stock economy's own consumers keep of key (free items): max(config, holders, open needs) minus what care
-- already holds forbidden
local function floor_of(c, p, r, key)
  local f = math.max(math.tointeger((c.reserve or {})[key]) or 0, holder_floor(p, key), need_n(p, key, r.now))
  return math.max(0, f - (r.held[key] or 0))
end

local function stock_of(r, key)
  local kind, tok = key:match('^([a-z]+):(.+)$')
  if kind == 'bars' then return st.bars_by[tok] or 0 end
  if kind == 'ore' then return st.ores[tok] and st.ores[tok].n or 0 end
  return r.inv[key] or 0
end

-- what economy may still spend of key in this run: stock - floor - open orders - planned this run
local function left(c, r, key)
  local fl = key:find('[_:]') and 0 or floor_of(c, r.p, r, key)
  return math.max(0, stock_of(r, key) - fl - (r.s.used[key] or 0) - (r.planned[key] or 0))
end

-- stock incl. care's forbidden reserve (what a mood can be given)
local function have(r, key) return (r.inv[key] or 0) + (r.held[key] or 0) end

-- Run 10: a strange mood missed `key` (care.mood_wants) within leather.memory_days game days (a pure helper; a field,
-- not a local: the main chunk is at Lua's 200-local limit)
function M.mood_missed(c, p, key, now)
  local t = math.tointeger((p.mseen or {})[key])
  return t ~= nil and now - t <= ((c.leather or {}).memory_days or 336) * DAY
end

local function mood_target(K, c, key)
  if not phase_ok(K, c.mood_from_phase or 'P1') then return 0 end
  for _, k in ipairs(c.mood_keys or {}) do
    if k == key then return math.tointeger((K.plan.supply or {}).mood_stock) or 10 end
  end
  return 0
end

local function target(K, c, r, key) return math.max(mood_target(K, c, key), need_n(r.p, key, r.now)) end

local function count_of(v)
  if math.type(v) == 'integer' then return v end
  if type(v) == 'number' then return math.tointeger(v) end
  if type(v) == 'table' then return math.tointeger(v.n) or #v end
end

-- a care hook; one that faults (a different signature) is not called again this boot: K.call counts the fault
-- against care, and a daily call would back care off every 10 minutes
local function care_hook(K, fn)
  st.hookbad = st.hookbad or {}
  if st.hookbad[fn] then return nil end
  local ok, v = K.call('care', fn)
  if ok then return v end
  local why = tostring(v)
  if why ~= 'no module' and why ~= 'disabled' and not why:find('^no function') then
    st.hookbad[fn] = true
    K.log('warn', 'care.%s failed (%s): not called again this boot', fn, why)
  end
end

M.MOOD_FAR_CAP = 100                -- BUG-341: unreachable items counted on top of a mood need at most
-- care's pull hooks (live L4): reserved() -> {class = n}, mood_wants() -> {{cls, n, far?}} | {class = n}
local function care_hooks(K, r)
  r.held = {}
  local res = care_hook(K, 'reserved')
  if type(res) == 'table' then
    for k, v in pairs(res) do
      local key, n = key_of(k), count_of(v)
      if KEYS[key] and n and n > 0 then r.held[key] = (r.held[key] or 0) + n end
    end
  end
  local wants, farmax = {}, {}
  r.glass_cut = 0                                -- Run 11: "cut gems" the moods miss (cut glass serves them)
  r.silk_cloth, r.silk_thread = 0, 0             -- BUG-574: silk cloth / silk thread the moods miss (webs -> thread -> cloth)
  local w = care_hook(K, 'mood_wants')
  if type(w) == 'table' then
    for k, v in pairs(w) do
      local key, n
      if type(k) == 'number' and type(v) == 'table' then key, n = key_of(v.cls or v.class or v.key), count_of(v.n or 1)
      else key, n = key_of(k), count_of(v) end
      -- BUG-341 (Run 15 Guildcleans y376: a Possessed carpenter needed logs x1, 89 free logs lay on another walk group
      -- [89/89/0], the need of 1 stood under the stock of 89, autochop felled nothing, the mood failed and the dwarf killed):
      -- the free items the moody dwarf cannot reach (care's `far`) are no stock for the need, so its floor stands above them
      -- (autochop's min over the log count: the reachable trees are felled; more tanning, hunting, weaving the same way)
      -- review: the far items are added once per class (the most any one need of the class misses), not per need: two
      -- wood needs with 89 far logs each made a floor of ~180 and held every wood order for the mood
      if n and n > 0 and type(v) == 'table' and KEYS[key] then
        farmax[key] = math.max(farmax[key] or 0, math.min(M.MOOD_FAR_CAP, count_of(v.far) or 0))
      end
      if KEYS[key] and n and n > 0 then
        wants[key] = (wants[key] or 0) + n
        if type(v) == 'table' and v.glass == 'cut' then r.glass_cut = r.glass_cut + n end
        if type(v) == 'table' and v.sub == 'silk' then
          if key == 'cloth' then r.silk_cloth = r.silk_cloth + n elseif key == 'thread' then r.silk_thread = r.silk_thread + n end
        end
      end
    end
  end
  for key, n in pairs(farmax) do if wants[key] then wants[key] = wants[key] + n end end
  for key in pairs(KEYS) do
    local m = r.p.needs[key]
    if wants[key] then
      if type(m) ~= 'table' then m = json.object{}; r.p.needs[key] = m end
      local prev = m.care
      m.care = {n = wants[key], untl = r.now + 2 * DAY}
      r.p.mseen[key] = r.now                     -- Run 10: the moods' misses outlive the mood (state stock.mood_miss)
      if not prev or (prev.n or 0) < wants[key] then K.log('info', 'need %s %d (care: mood)', key, wants[key]) end
    elseif type(m) == 'table' then m.care = nil end
  end
end

---------------------------------------------------------------- candidates (planned work orders)
local function add(r, cd)
  if cd.n <= 0 then return false end
  r.cands[#r.cands + 1] = cd
  for key, per in pairs(cd.uses or {}) do r.planned[key] = (r.planned[key] or 0) + per * cd.n end
  return true
end

local function open(r, tag) return r.s.live[tag] ~= nil end

local function cond(n, itype, extra)
  local x = {condition = 'AtLeast', value = math.max(1, n)}
  if itype then x.item_type = itype end
  for k, v in pairs(extra or {}) do x[k] = v end
  return x
end

local function wood_spec(c, r, base)
  local s = copy(base)
  s.material_category = s.material_category or {'wood'}
  s.item_conditions = {cond(floor_of(c, r.p, r, 'wood') + 1, 'WOOD')}
  return s
end

-- drink and food (days targets) or a minimum stock (generic supply entries)
-- live L4 (Castlerisen y294, famine at 9 food days): 199 raw fish lay in the stockpiles, uncleaned, because the
-- fort had no fishery. Raw fish are food once a fisherdwarf prepares them: with a fishery, one PrepareRawFish
-- order for what lies there (the famine wake names the missing fishery otherwise).
local function plan_fish(K, c, r)
  local f = c.fish
  local raw = r.inv.fish_raw or 0
  if type(f) ~= 'table' or raw < (f.min or 5) or open(r, f.tag) or not ws_any(r.f, f.ws) then return end
  -- live L5: a bigger fort lands more fish; one order holds up to one fish per citizen (at least f.max)
  add(r, {tag = f.tag, spec = f.spec, n = math.min(raw, math.max(f.max or 30, r.cit or 0)), why = 'fish_raw'})
end

-- BUG-042: the part of the drink deficit's brew jobs one brew order takes (e.src: the census key of its brewable
-- plants): split by the brew_p / brew_g stock, at most one job a plant; with neither in the fort the plant order takes
-- it all (DF's item condition waits for plants, drink_low names them missing)
function M.brew_share(r, e, jobs)
  if jobs <= 0 then return 0 end
  local bp, bg = math.tointeger(r.inv.brew_p) or 0, math.tointeger(r.inv.brew_g) or 0
  if bp + bg <= 0 then return e.src == 'brew_p' and jobs or 0 end
  local mine = e.src == 'brew_g' and bg or bp
  return math.min(mine, (jobs * mine + bp + bg - 1) // (bp + bg))
end

-- cooking keeps food (live L5: gathered fruit and butchered meat rot; meals keep): meals_per_dwarf prepared meals
-- per citizen, and the job cap of the food order grows with the fort
-- BUG-629 (Run 16b i2 Valleyhame y377: 'kitchen has 4 cook ingredients and 0 meals', 13 hungry, food 0 days; the order waited for 10 of them):
-- the ingredients the meal order waits for. cook_floor (10) keeps the cooks from a job per handful while the fort eats well; a hungry
-- citizen, a food stock below the pre-alarm line or a famine cooks what is there (the 2 ingredients of one meal)
M.COOK_MIN = 2
function M.cook_urgent(c, r)
  local fc = type(c.food) == 'table' and c.food or M.DEFAULTS.food
  if (st.hungry_n or 0) > 0 or r.p.famine ~= nil then return true end
  return ((r.days or {}).food_d or 9999) < (fc.pre_days or 30)
end
function M.cook_floor(c, r)
  local fc = type(c.food) == 'table' and c.food or M.DEFAULTS.food
  if M.cook_urgent(c, r) then return M.COOK_MIN end
  return math.max(M.COOK_MIN, math.tointeger(fc.cook_floor) or 10)
end

-- BUG-629: the food order's spec for this run: the DF item condition 'cookable' waits for the same floor as the planner (a spec from
-- the config still says 10), and after a cook stall (M.cook_watch: p.cookw.relax) the order carries no item condition at all and goes first
function M.food_spec(c, r, e)
  local spec = copy(e.spec)
  local cw = r.p.cookw
  if type(cw) == 'table' and cw.relax then
    spec.item_conditions, spec.top = nil, true
    return spec
  end
  local floor = M.cook_floor(c, r)
  for _, x in ipairs(spec.item_conditions or {}) do
    if type(x.flags) == 'table' then
      for _, f in ipairs(x.flags) do if f == 'cookable' then x.value = floor end end
    end
  end
  return spec
end

local function meal_jobs(c, r, e)
  local fc = c.food
  if e.key ~= 'food_d' or type(fc) ~= 'table' then return 0, e.max_jobs or 20 end
  local cit, inv = r.cit or 0, r.inv
  local want = cit * (fc.meals_per_dwarf or 0) - (inv.meals or 0)
  -- what a cook may use: EDIBLE_COOKED food that is no meal and not on the kitchen's Cook ban (plump helmets)
  local ingredients = M.cook_n(inv)
  local jobs = (want > 0 and ingredients >= M.cook_floor(c, r)) and (math.min(want, ingredients) + e.per_job - 1) // e.per_job or 0
  return jobs, math.max(e.max_jobs or 20, (cit + (fc.cit_per_job or 2) - 1) // math.max(1, fc.cit_per_job or 2))
end

local function plan_supply(K, c, r)
  plan_fish(K, c, r)
  local sup = K.plan.supply or {}
  for _, e in ipairs(c.supply or {}) do
    if phase_ok(K, e.from_phase) and not open(r, e.tag) then
      local jobs = 0
      if r.days[e.key] then
        local tgt, d = math.tointeger(sup[e.key]) or 0, r.days[e.key]
        if d < tgt then jobs = ((tgt - d) * (st.rate[e.key] or 0) // 1000 + e.per_job - 1) // e.per_job end
        if e.src then jobs = M.brew_share(r, e, jobs) end              -- BUG-042: plants and fruit
      else
        local tgt, hv = math.tointeger(e.min) or math.tointeger(sup.mood_stock) or 10, r.inv[e.key] or 0
        if hv < tgt then jobs = (tgt - hv + e.per_job - 1) // e.per_job end
      end
      local mj, cap = meal_jobs(c, r, e)
      local why = e.key
      if mj > jobs then jobs, why = mj, 'meals' end
      add(r, {tag = e.tag, spec = e.key == 'food_d' and M.food_spec(c, r, e) or e.spec, n = math.min(jobs, cap), why = why})
    end
  end
end

-- barrels only while brewing is due, bins always; both capped by a total per citizen (live L1b runaway). Drink is
-- survival: below the drink target the barrel cap is max_total (food stockpiles fill barrels too, and a full set
-- of barrels must not stall the stills), and below nofloor_days of drink the barrels may take the logs of
-- economy's own wood floor (care's forbidden mood logs stay untouched either way)
local function plan_containers(K, c, r, which)
  local b = c[which]
  if type(b) ~= 'table' or open(r, b.tag) or not ws_any(r.f, b.ws) then return end
  local inv = r.inv
  local short, dry = false, false
  if which == 'barrels' then
    local tgt = math.tointeger((K.plan.supply or {}).drink_d) or 170
    local d = r.days.drink_d or 0
    if d * 100 >= tgt * (b.drink_pct or 150) then return end
    short, dry = d < tgt, d < (b.nofloor_days or 30)
  end
  local cap = short and (b.max_total or 30) or clamp(r.cit * (b.cit_pct or 50) // 100, b.min_total or 0, b.max_total or 30)
  local empty_miss = (b.min_empty or 0) - (inv[which .. '_empty'] or 0)
  -- BUG-042 (Run 11, y471: 60 brews, 12 empty barrels among 85): the brews the open BREW_ orders want are empty
  -- barrels wanted too while drink is short; the cap grows past grow_total by them (they end with the orders)
  local bw = short and math.min((r.s.brew or {}).left or 0, b.brew_wait or 0) or 0
  if bw - (inv.barrels_empty or 0) > math.max(0, empty_miss) then
    empty_miss = bw - (inv.barrels_empty or 0)
    cap = math.max(cap, (inv.barrels or 0) + empty_miss)
    if r.day then K.log('info', 'drink %d days: %d brews wait, %d of %d barrels empty: barrels wanted %d',
                        r.days.drink_d or 0, bw, inv.barrels_empty or 0, inv.barrels or 0, empty_miss) end
  elseif short and empty_miss > 0 and b.grow_total then
    local grown = math.min(b.grow_total, (inv[which] or 0) + empty_miss)
    if grown > cap then
      cap = grown
      if r.day then K.log('info', 'drink %d days, %d of %d barrels full: barrel cap %d', r.days.drink_d or 0,
                          (inv[which] or 0) - (inv[which .. '_empty'] or 0), inv[which] or 0, cap) end
    end
  end
  local want = math.min(empty_miss, cap - (inv[which] or 0))
  -- dry: other open wood orders hold no claim on the logs either (the first job takes them)
  local wood = dry and math.max(0, (inv.wood or 0) - (r.planned.wood or 0)) or left(c, r, 'wood')
  local n = math.min(want, wood, b.max_jobs or 4)
  local spec = wood_spec(c, r, b.spec)
  if dry then spec.item_conditions = {cond(1, 'WOOD')} end
  if add(r, {tag = b.tag, spec = spec, n = n, uses = {wood = 1}, why = which}) and dry then
    K.log('warn', 'drink %d days: barrels x%d may use the wood floor (%d logs)', r.days.drink_d or 0, n, inv.wood or 0)
  end
end

-- the soldiers' slots (military.targets) and the hunters' crossbows and bolts; `hunt` = hunters wanted
local function gear_pre(K, c, r, hunt)
  local g = c.gear
  local melee, xb = 0, 0
  local ok, _, per, _, _, gx = K.call('military', 'targets')
  if ok and type(per) == 'table' then
    for key, v in pairs(per) do
      local n = math.tointeger(v) or 0
      if key == 'C' then xb = xb + n else melee = melee + n end
    end
  end
  -- Run 11: metal short, the melee positions the gear cannot fill go to the crossbows (military.targets' gear.xbow):
  -- crossbows, quivers and bolts for them; their armor is already counted with the melee positions they stand in for
  local xa = xb
  if ok and type(gx) == 'table' then xb = xb + math.max(0, math.tointeger(gx.xbow) or 0) end
  local who = {all = melee + xa, melee = melee, xbow = xb, ranged = xb + hunt}
  local res = {n = melee + xa, melee = melee, xbow = xb, hunt = hunt, cats = {}, leather = 0, metal_jobs = 0,
               bars_need = 0, bars_short = 0}
  -- metal pieces the bars at hand could make (any preferred metal), shared by the slots in order
  local bars = 0
  for _, m in ipairs(g.metals or {}) do bars = bars + (st.bars_by['INORGANIC:' .. m] or 0) end
  local bars0 = bars
  local forge = ws_any(r.f, g.forge)
  for _, it in ipairs(g.items or {}) do
    local want, sw                                   -- sw: the soldiers' part (worn % inputs)
    if it.cat == 'bolts' then
      want = math.min(g.bolts_max or 300, xb * (g.bolts_xbow or 100) + hunt * (g.bolts_hunter or 25))
      sw = math.min(want, xb * (g.bolts_xbow or 100))
    else
      want = (who[it.who or 'all'] or 0) * (it.per or 1)
      sw = it.who == 'ranged' and xb * (it.per or 1) or want
    end
    local hv = (it.cat == 'bolts' and r.inv.bolts or r.inv['g_' .. it.cat]) or 0
    local tag = 'dfllm:gear_' .. it.cat
    local opened = (r.s.live[tag] or 0) * (it.out or 1)
    local miss = math.max(0, want - hv - opened)
    local rec = {want = want, sw = sw, have = hv, open = opened, miss = miss, route = miss > 0 and 'none' or 'ok'}
    -- BUG-689: the pieces of the slot that are metal (armor slots with a leather alternative): the metal top-up of plan_gear
    local mh = it.metal and it.leather and r.inv['gm_' .. it.cat] or nil
    rec.mmiss = mh and math.max(0, want - mh) or 0
    res.cats[it.cat] = rec
    if miss > 0 then
      local jobs = (miss + (it.out or 1) - 1) // (it.out or 1)
      local mj = 0
      if it.metal and forge then
        mj = math.min(jobs, bars // it.metal.bars)
        bars = bars - mj * it.metal.bars
        res.metal_jobs = res.metal_jobs + jobs     -- forge jobs this slot wants (charcoal sizing)
      end
      if it.leather and jobs > mj then res.leather = res.leather + (jobs - mj) * (it.leather.n or 1) end
      if it.metal and not it.leather and not it.wood and mj < jobs then res.metal_short = true end
      -- Run 10: iron stuck at 8 bars for years while 20 soldiers wore 38-53 %: the bars every metal slot wants,
      -- forge or not (plan_metal's explore route)
      if it.metal then res.bars_need = res.bars_need + jobs * it.metal.bars end
    end
  end
  res.bars_short = math.max(0, res.bars_need - bars0)
  return res
end

local function hunters_spec(c)
  for _, d in ipairs((c.tools or {}).details or {}) do if d.name == 'Hunters' then return d end end
end

-- hunters wanted: famine or (Run 11) the food_low pre-alarm (PEACE or RECOVERY only), else (PEACE, from
-- mood_from_phase or an open need, not paused for want of game) one while leather, bone or shell is short of its
-- target, `need` while one of them has an open need. Hunters roam outside the walls: in a real siege tools() takes
-- them off the detail at once (reason 'siege'), not after shrink_days (BUG-326 below).
-- BUG-326 (Run 15c Inkintense: a drill at food 42 d took both hunters and all three fishers off, #1717-#1721, every
-- one of seven short ALERTs took them off again, #1769-#1772, and a SIEGE of two lone goblins took the hunters, #1583):
-- the hunters and fishers keep their detail in every mode (DRILL, ALERT, RECOVERY: 'hold', the members stay, none join;
-- the civil alert keeps them in Kern+ anyway). Only a real siege (SIEGE or BREACH, not reflex's lone harmless picture)
-- takes them off at once ('siege'); they go back on the detail as soon as that ends (M.mode_restore).
local HUNT_MODES = {PEACE = true, RECOVERY = true}
M.HUNT_OFF = {SIEGE = true, BREACH = true}
function M.hunt_siege(K)
  if not M.HUNT_OFF[K.mode()] then return false end
  local ok, ids = K.call('reflex', 'lone_ids')
  return not (ok and type(ids) == 'table' and #ids > 0)
end
local function hunt_want(K, c, r)
  local spec = hunters_spec(c)
  if not spec then return 0, 'none' end
  -- BUG-740 (Run 16d i4 Pagedsculpture y386: the militia captain went hunting and died outside, z110): a large or predatory wild
  -- unit in or beside water near a citizen (sense census.w.hold, as for the fishers) keeps the hunters inside, a famine too
  local cw = K.census and K.census.w
  if type(cw) == 'table' and cw.hold == 1 then return 0, 'predator' end
  local mode = K.mode()
  if not HUNT_MODES[mode] then
    if M.hunt_siege(K) then return 0, 'siege' end
    return st.hunters or 0, 'hold'
  end
  if r.p.famine or r.p.food_pre then return spec.famine or 0, r.p.famine and 'famine' or 'food low' end
  if mode ~= 'PEACE' then return st.hunters or 0, 'hold' end
  local short, needed = false, false
  for _, key in ipairs(spec.mood_keys or {}) do
    local tgt = r.targets[key] or target(K, c, r, key)
    if have(r, key) < tgt then short = true end
    if need_n(r.p, key, r.now) > have(r, key) then needed = true end
  end
  -- Run 10 (Handlelock): a fey mood died for two leather; a mood that missed leather while the fort still has none
  -- hunts like an open need (the next mood fails the same way)
  local missed = have(r, 'leather') == 0 and M.mood_missed(c, r.p, 'leather', r.now)
  if not (short or missed) then return 0, 'stock' end
  -- an open mood need still unmet hunts through the "no game" pause (a failed mood ends in a death)
  if needed or missed then return spec.need or spec.mood or 1, needed and 'need' or 'mood leather' end
  if r.now < (r.p.hunt_off or 0) then return 0, 'no game' end
  if not phase_ok(K, c.mood_from_phase or 'P1') then return 0, 'phase' end
  return spec.mood or 0, 'mood stock'
end

-- BUG-697 (Run 16c i3 Wallfree y431-y433: 49 citizens, 23 of 30 adults idle for a year, three fishers, four gatherers, 28 starved):
-- how many helpers a famine puts on a food job: at least `base`, one per `per` citizens, never more than the idle adults (idle_pct of
-- the citizens, but `base` at least) and never over `cap`
function M.famine_scale(base, cap, cit, per, idle_pct)
  cit, per = math.tointeger(cit) or 0, math.max(1, math.tointeger(per) or 1)
  base = math.max(0, math.tointeger(base) or 0)
  local idle = cit * (math.tointeger(idle_pct) or 0) // 100
  local want = math.min((cit + per - 1) // per, math.max(base, idle))
  return clamp(want, base, math.max(base, math.tointeger(cap) or base))
end

-- a fishing zone exists (the zones screen; zones are the runner's or the LLM's, economy only reads them)
local function fishing_zone()
  local zt = df.civzone_type and df.civzone_type.FishingArea
  if zt == nil then return false end
  local ok, yes = pcall(function()
    for _, z in ipairs(df.global.world.buildings.other.ANY_ZONE) do if z.type == zt then return true end end
    return false
  end)
  return ok and yes == true
end

-- fishers wanted (live L5): one per spec.per citizens, at most spec.max, while food is below food.want_days or in
-- a famine, only with a fishing zone, only in PEACE (in RECOVERY only in a famine): fishers stand at the water
-- outside the walls, like hunters: other modes hold the members, a real siege takes them off at once (BUG-326)
local function fish_want(K, c, r)
  local spec
  for _, d in ipairs((c.tools or {}).details or {}) do if d.fish then spec = d end end
  if not spec then return 0, 'none' end
  st.fishzone = fishing_zone()
  -- BUG-494 (Run 16b i2 Brotherarrow: a Hibbertopterus pack at the brook drowned the fisher and the carpenter): sense saw a
  -- large or predatory wild unit in or beside water within reach of a citizen (census.w.hold): nobody fishes until it has
  -- been away for sense's WATER.hold ticks, and the members leave the detail at once
  local cw = K.census and K.census.w
  if type(cw) == 'table' and cw.hold == 1 then return 0, 'water beast' end
  local mode = K.mode()
  if not HUNT_MODES[mode] or (mode ~= 'PEACE' and not r.p.famine) then                -- BUG-326
    if M.hunt_siege(K) then return 0, 'siege' end
    return st.fishers or 0, 'hold'
  end
  if not st.fishzone then return 0, 'no zone' end
  local fc = c.food or {}
  local d = (r.days or {}).food_d or 9999
  -- BUG-057 (Run 13 y512: Fisherdwarves at 0 members beside a fishing zone): raw fish in the fort or open Fish jobs
  -- want `min` fishers (one per `min_per` citizens, at least one) whatever the stock says
  local fl, jc = 0, st.jobc
  if (spec.min or 0) > 0 and (((r.inv or {}).fish_raw or 0) >= ((c.fish or {}).min or 5) or
                              (type(jc) == 'table' and (jc.fish_open or 0) > 0)) then
    fl = clamp((r.cit or 0) // math.max(1, spec.min_per or 6), 1, spec.min)
  end
  if not r.p.famine and d >= (fc.want_days or 90) then return fl, fl > 0 and 'fish' or 'stock' end
  local per = math.max(1, spec.per or 15)
  local n = math.max(fl, clamp(((r.cit or 0) + per - 1) // per, 1, spec.max or 3))
  if r.p.famine then        -- BUG-697: a famine puts the idle adults on the water, not three
    n = math.max(n, M.famine_scale(spec.max or 3, spec.famine_max or 8, r.cit, spec.famine_per or 6, st.idle))
  end
  return n, r.p.famine and 'famine' or 'food'
end

-- Run 10 (Handlelock): no tanner's shop stood and a fey mood died for two leather. Without one, while hides lie or a
-- mood missed leather: PROJECT_REQUEST workshops why=tannery (follow places the missing moodable shops, the Tanners
-- among them) at most every request_days, never while a workshops project is pending
function M.tannery_request(K, c, r, L)
  local missed = M.mood_missed(c, r.p, 'leather', r.now)
  r.route.leather = 'no tannery'
  if not ((r.inv.hides or 0) > 0 or missed) then return end
  if not (missed or phase_ok(K, L.from_phase)) then return end
  local p = r.p
  if p.tan_req and r.now - (math.tointeger(p.tan_req) or 0) < (L.request_days or 14) * DAY then
    r.route.leather = 'no tannery (asked)'
    return
  end
  local okp, pend = K.call('runner', 'pending', 'workshops')
  if okp and type(pend) == 'number' and pend > 0 then r.route.leather = 'no tannery (queued)'; return end
  p.tan_req = r.now
  r.route.leather = 'no tannery (asked)'
  K.emit('PROJECT_REQUEST', 'B', string.format("workshops: no tanner's shop (%d hides, leather %d of %d%s)",
                                               r.inv.hides or 0, have(r, 'leather'), r.targets.leather or 0,
                                               missed and ', a mood missed leather' or ''),
         {tpl = 'workshops', n = 1, why = 'tannery'})
end

-- BUG-309 / FR (Run 15 Drillchamber y376: Possessed moods needing leather, 0-1 leather, hunters 'nothing caught for 10 days',
-- only breeding pairs, so each mood cost a pair through butcher.mark keep_pairs:false): leather short of the mood stock that
-- the hides in the fort do not cover is asked of every caravan (economy.trade_wants `leather`), before a mood needs it.
-- st.lwant = {buy, n, why} or nil (a module field: the main chunk is at 200 locals)
function M.leather_trade(K, c, r)
  st.lwant = nil
  local tg = target(K, c, r, 'leather')
  local short = tg - have(r, 'leather') - (r.inv.hides or 0)
  if tg <= 0 or short <= 0 then return end
  st.lwant = {buy = 'leather', n = math.min(short, 15),
              why = string.format('leather %d + %d hides < mood stock %d', have(r, 'leather'), r.inv.hides or 0, tg)}
end

local function plan_leather(K, c, r)
  local L = c.leather
  local want = target(K, c, r, 'leather') + (phase_ok(K, L.from_phase) and r.gear.leather or 0)
  r.targets.leather = want
  M.leather_trade(K, c, r)
  if have(r, 'leather') >= want or open(r, L.tag) then return end
  if not ws_any(r.f, L.ws) then return M.tannery_request(K, c, r, L) end
  if (r.inv.hides or 0) > 0 and (r.p.hides_days or 0) >= (L.after_days or 2) then
    local n = math.min(left(c, r, 'hides'), want - have(r, 'leather'), L.max_jobs or 10)
    if add(r, {tag = L.tag, spec = L.spec, n = n, uses = {hides = 1}, why = 'leather'}) then r.route.leather = 'tan' end
  end
end

-- BUG-574 (Run 16a i1 Basementflew y429: a Fey mood needed cloth(silk) x1 with 4003 webs in the fort, 116 on the citizens' walk group, thread
-- 2271 of the other kinds and cloth 18 of the others: the kernel's only step was the Loom sheet's CollectWebs task, DF cancelled it seven times
-- 'Needs undisturbed thread', and plan_cloth wove nothing because the cloth stock of plant and yarn was over the target; the player's
-- manual CollectWebs x3 work order came two days before the death). The chain for a silk mood (care.mood_wants `sub` silk): with no silk thread,
-- a CollectWebs work order at the Loom (the manager's job, not the sheet task; webs the citizens reach, `cloth.webs`); with silk thread
-- and a cloth(silk) want, a WeaveCloth silk order, ahead of the kinds in stock. Needs a Loom (care asks for it with the mood's shops).
-- r.silk_woven = the silk weave order is among this run's candidates (plan_cloth leaves it out of its own loop).
function M.silk_chain(K, c, r, Cc)
  r.silk_woven = false
  local want_c, want_t = r.silk_cloth or 0, r.silk_thread or 0
  if want_c + want_t <= 0 then st.silk = nil; return end
  local W = Cc.webs or {}
  local have_t = r.inv.thread_silk or 0
  local g = {cloth = want_c, thread = want_t, have = have_t, webs = r.inv.webs_near or 0}
  st.silk = g
  if not ws_any(r.f, Cc.loom) then g.why = 'no Loom'; return end
  local short_t = math.max(0, want_c + want_t - have_t)
  if short_t > 0 then
    if (r.inv.webs_near or 0) <= 0 then
      g.why = (r.inv.webs or 0) > 0 and 'webs off the citizens walk group' or 'no webs'
    elseif W.tag and not open(r, W.tag) then
      local n = math.min(r.inv.webs_near, short_t + (W.extra or 2), W.max_jobs or 5)
      if add(r, {tag = W.tag, spec = {job = 'CollectWebs'}, n = n, why = 'webs'}) then g.ord = 'CollectWebs' end
    elseif W.tag then g.ord = 'CollectWebs' end
  end
  if want_c > 0 and have_t > 0 then
    for _, w in ipairs(Cc.weave or {}) do
      if w.kind == 'silk' then
        if open(r, w.tag) then r.silk_woven = true
        else
          local n = math.min(want_c, left(c, r, 'thread_silk'), left(c, r, 'thread'), Cc.max_jobs or 10)
          local spec = {job = 'WeaveCloth', material_category = {'silk'}, item_conditions = {cond(1, 'THREAD', {flags = {'collected', 'silk'}})}}
          if add(r, {tag = w.tag, spec = spec, n = n, uses = {thread_silk = 1, thread = 1}, why = 'silk cloth'}) then
            r.silk_woven = true
            g.weave = n
          end
        end
      end
    end
  end
end

local function plan_cloth(K, c, r)
  local Cc = c.cloth
  local naked = 0
  if phase_ok(K, Cc.from_phase) then
    local care = (K.view() or {}).care
    naked = (type(care) == 'table' and math.tointeger(care.naked) or 0) * (Cc.per_naked or 3)
  end
  -- the naked need free cloth (the tailor cannot take care's forbidden mood cloth): want covers both
  local want = math.max(target(K, c, r, 'cloth'), naked + (r.held.cloth or 0))
  r.targets.cloth = want
  local deficit = want - have(r, 'cloth')
  r.fiber_on = deficit > 0
  -- BUG-117: the floor of free cloth (from from_phase on) lifts the weave orders below, not the fiber crops
  local fl = phase_ok(K, Cc.from_phase) and math.tointeger(Cc.floor) or 0
  local orders_deficit = math.max(deficit, math.max(0, (fl or 0) - have(r, 'cloth')))
  -- BUG-024: spider webs are no thread; a CollectWebs hint only for webs on the citizens' walk group
  local thread, webs, near = r.inv.thread or 0, r.inv.webs or 0, r.inv.webs_near or 0
  st.cloth = {deficit = math.max(0, deficit), thread = thread, webs = webs, near = near}
  if r.day and deficit > 0 and thread == 0 and near > 0 and st.web_hint ~= near then
    local wp = st.web_pos
    K.log('info', 'cloth short by %d, no collected thread: %d spider webs on the citizens\' walk group%s: weavers collect ' ..
          'them (WEAVER labor, webs not forbidden)', deficit, near, wp and string.format(' (e.g. %d,%d,%d)', wp[1], wp[2], wp[3]) or '')
  end
  if r.day then st.web_hint = (deficit > 0 and thread == 0 and near > 0) and near or nil end
  M.silk_chain(K, c, r, Cc)                        -- BUG-574: a silk mood: webs -> silk thread -> silk cloth, whatever the cloth stock
  deficit = orders_deficit
  if deficit <= 0 then return end
  if ws_any(r.f, Cc.loom) then
    for _, w in ipairs(Cc.weave or {}) do
      if deficit <= 0 then break end
      if w.kind == 'silk' and r.silk_woven then deficit = deficit - ((st.silk and st.silk.weave) or r.s.live[w.tag] or 0)   -- BUG-574: planned by the chain
      elseif not open(r, w.tag) then
        local key = 'thread_' .. w.kind
        local n = math.min(deficit, left(c, r, key), left(c, r, 'thread'), Cc.max_jobs or 10)
        local spec = {job = 'WeaveCloth', material_category = {w.kind},
                      item_conditions = {cond(1, 'THREAD', {flags = {'collected', w.kind}})}}
        if add(r, {tag = w.tag, spec = spec, n = n, uses = {[key] = 1, thread = 1}, why = 'cloth'}) then
          deficit = deficit - n
          r.route.cloth = 'weave'
        end
      else deficit = deficit - (r.s.live[w.tag] or 0) end
    end
  end
  local th = Cc.thread
  local spare = left(c, r, 'thread')               -- thread no weave order of this run takes
  if deficit > spare and th and not open(r, th.tag) and ws_any(r.f, th.ws) then
    if add(r, {tag = th.tag, spec = th.spec, n = math.min(deficit - spare, Cc.max_jobs or 10), why = 'thread'}) then
      r.route.cloth = (r.route.cloth or '') == '' and 'thread' or r.route.cloth .. '+thread'
    end
  end
end

-- FR-89: the weapons of each wanted training raw in the fort (carried ones too, merchants' goods not): {raw id = n}.
-- One pass over the weapon vector, on the daily run only and only while a squad is on the training policy
function M.training_have(need)
  local out = {}
  pcall(function()
    for _, it in ipairs(df.global.world.items.other.WEAPON) do
      if not it.flags.trader then
        local d = dfhack.items.getSubtypeDef(df.item_type.WEAPON, subtype(it))
        if d and need[d.id] then out[d.id] = (out[d.id] or 0) + 1 end
      end
    end
  end)
  return out
end

function M.plan_training(K, c, r)
  local tc = c.training
  if type(tc) ~= 'table' or tc.on == false or not phase_ok(K, tc.from_phase) then st.train = nil; return end
  local ok, need = K.call('military', 'training_need')
  if not (ok and type(need) == 'table' and next(need) ~= nil) then st.train = nil; return end
  local ids = {}
  for id in pairs(need) do ids[#ids + 1] = id end
  table.sort(ids)
  local key = table.concat(ids, ',')
  if r.day or st.train_have == nil or st.train_key ~= key then st.train_have, st.train_key = M.training_have(need), key end
  local short = 0
  for _, id in ipairs(ids) do
    local n = math.tointeger(need[id]) or 0
    local miss = n + (tc.spare or 0) - (st.train_have[id] or 0)
    local name = id:match('^ITEM_WEAPON_(.-)_TRAINING$')
    if miss > 0 and name then
      short = short + miss
      local tag = (tc.tag or 'dfllm:train') .. '_' .. name:lower()
      if ws_any(r.f, tc.ws) and not open(r, tag) then
        local k = math.min(miss, tc.max_jobs or 5, left(c, r, 'wood'))
        add(r, {tag = tag, spec = wood_spec(c, r, {job = 'MakeWeapon', item_subtype = id, material_category = {'wood'}}),
                n = k, uses = {wood = 1}, why = 'training weapons'})
      end
    end
  end
  st.train = {short = short}
end

local function fuel_cond(r)
  if r.f['workshop:MagmaForge'] or r.f['furnace:MagmaSmelter'] then return nil end
  return cond(1, 'BAR', {material = 'COAL'})
end

-- ores, alloys and charcoal while metal is wanted (bars below target or slots that take metal)
local function plan_metal(K, c, r)
  local Mt = c.metal
  local bars_want = target(K, c, r, 'bars')
  r.targets.bars = bars_want
  local steel = type(st.steel) == 'table' and (st.steel.n or 0) > 0     -- orders wait for steel (plan_steel)
  local wanted = have(r, 'bars') < bars_want or r.gear.metal_jobs > 0 or r.gear.bars_short > 0 or steel
  if not wanted then return end
  if not phase_ok(K, Mt.from_phase) and need_n(r.p, 'bars', r.now) == 0 and r.gear.metal_jobs == 0 and not steel then
    return
  end
  local magma = r.f['furnace:MagmaSmelter'] == true
  local fuel = function() return magma and 99 or left(c, r, 'fuel') end
  local fc = fuel_cond(r)
  local ores = {}
  for tok, o in pairs(st.ores) do ores[#ores + 1] = {tok = tok, n = o.n, metals = o.metals} end
  table.sort(ores, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.tok < b.tok end)
  local function bearing(o, metal)
    for _, m in ipairs(o.metals or {}) do if m == 'INORGANIC:' .. metal then return true end end
    return false
  end
  local smelt_jobs = 0
  if ws_any(r.f, Mt.smelter) then
    -- bronze from ores (1 tin + 1 copper ore -> 8 bars, reaction_smelter.txt), then single ores, then bars
    local B = Mt.bronze
    local tin, cop = 0, 0
    for _, o in ipairs(ores) do
      if bearing(o, 'TIN') then tin = tin + left(c, r, 'ore:' .. o.tok) end
      if bearing(o, 'COPPER') then cop = cop + left(c, r, 'ore:' .. o.tok) end
    end
    if B and tin > 0 and cop > 0 and not open(r, B.tag) then
      local n = math.min(tin, cop, fuel(), B.max_jobs or 5)
      local spec = {job = 'CustomReaction', reaction = B.ore,
                    item_conditions = {cond(1, 'BOULDER', {bearing = 'TIN'}), cond(1, 'BOULDER', {bearing = 'COPPER'}), fc}}
      if add(r, {tag = B.tag, spec = spec, n = n, uses = {fuel = magma and 0 or 1}, why = 'bronze'}) then
        smelt_jobs = smelt_jobs + n
        local t, k = n, n
        for _, o in ipairs(ores) do      -- the ore the reaction takes: planned from the largest kinds
          local key = 'ore:' .. o.tok
          if t > 0 and bearing(o, 'TIN') then local x = math.min(t, left(c, r, key)); r.planned[key] = (r.planned[key] or 0) + x; t = t - x end
          if k > 0 and bearing(o, 'COPPER') then local x = math.min(k, left(c, r, key)); r.planned[key] = (r.planned[key] or 0) + x; k = k - x end
        end
        r.route.bars = 'bronze'
      end
    end
    -- every ore while the mood stock lacks bars; for the soldiers only ores of a gear metal (or tin for bronze)
    local useful = {TIN = true}
    for _, m in ipairs(c.gear.metals or {}) do useful[m] = true end
    local any_bar = have(r, 'bars') < bars_want
    local function wanted_ore(o)
      if any_bar then return true end
      for _, m in ipairs(o.metals or {}) do if useful[m:match('([^:]+)$') or m] then return true end end
      return false
    end
    local kinds = 0
    for _, o in ipairs(ores) do
      if kinds >= (Mt.ores_per_day or 2) then break end
      local tag = 'dfllm:smelt_' .. (o.tok:match('([^:]+)$') or o.tok)
      local key = 'ore:' .. o.tok
      if not open(r, tag) and left(c, r, key) > 0 and wanted_ore(o) then
        local n = math.min(left(c, r, key), fuel(), Mt.max_jobs or 10)
        local spec = {job = 'SmeltOre', material = o.tok, item_conditions = {cond(1, 'BOULDER', {material = o.tok}), fc}}
        if add(r, {tag = tag, spec = spec, n = n, uses = {[key] = 1, fuel = magma and 0 or 1}, why = 'smelt'}) then
          smelt_jobs, kinds = smelt_jobs + n, kinds + 1
          r.route.bars = (r.route.bars and r.route.bars .. '+' or '') .. 'smelt'
        end
      end
    end
    local tinb, copb = left(c, r, 'bars:INORGANIC:TIN'), left(c, r, 'bars:INORGANIC:COPPER')
    if B and r.gear.metal_jobs > 0 and tinb > 0 and copb > 0 and not open(r, B.tag) then
      local n = math.min(tinb, copb, fuel(), B.max_jobs or 5)
      local spec = {job = 'CustomReaction', reaction = B.bars,
                    item_conditions = {cond(1, 'BAR', {material = 'INORGANIC:TIN'}), cond(1, 'BAR', {material = 'INORGANIC:COPPER'}), fc}}
      add(r, {tag = B.tag, spec = spec, n = n, uses = {['bars:INORGANIC:TIN'] = 1, ['bars:INORGANIC:COPPER'] = 1,
                                                        fuel = magma and 0 or 1}, why = 'bronze'})
    end
  end
  -- charcoal for the smelting and forging there is material for
  local ch = Mt.charcoal
  -- Run 11: the metal items marked for melting (census melt: the invaders' gear in the dfllm-melt pile) need a fuel each
  -- at a smelter; with no ore and no bar nothing ordered charcoal, so the melt jobs never ran
  local melt = ws_any(r.f, Mt.smelter) and (r.inv.melt or 0) or 0
  local material = (r.inv.ore or 0) + (r.inv.bars or 0) + melt > 0
  if ch and material and not magma and not open(r, ch.tag) and ws_any(r.f, ch.ws) then
    -- fuel for: the ore still to smelt, the items to melt, the forge jobs the bars (and ore, ~4 bars each) could feed,
    -- the fuel the open orders hold, plus a buffer
    local jobs = math.max(smelt_jobs, math.min(r.inv.ore or 0, Mt.max_jobs or 10)) + math.min(melt, Mt.max_jobs or 10) +
                 math.min(r.gear.metal_jobs, (r.inv.bars or 0) + (r.inv.ore or 0) * 4)
    local want = math.min(ch.cap or 40, jobs + (r.s.used.fuel or 0) + (ch.buffer or 4))
    local n = math.min(want - (r.inv.fuel or 0), left(c, r, 'wood'), Mt.max_jobs or 10)
    add(r, {tag = ch.tag, spec = wood_spec(c, r, {job = 'MakeCharcoal', material_category = {}}), n = n,
            uses = {wood = 1}, why = 'fuel'})
  end
  -- no ore and too few bars: exploration (a dig is not economy's to designate: `plan propose` drafts the `explore`
  -- template from state stock.metal) and the LLM once a year. Run 10 (Handlelock): 8 iron bars stayed for years while
  -- 20 soldiers wanted 60+ (worn 38-53 %), and the old rule waited for 0 spare bars, so this never fired
  local ex = Mt.explore
  local short = r.gear.metal_short or r.gear.bars_short > 0 or have(r, 'bars') < bars_want
  if ex and (r.inv.ore or 0) == 0 and short and phase_ok(K, Mt.from_phase) then
    r.route.bars = 'explore'
    local e = r.p.explore
    if r.now - (math.tointeger(e.req) or -1e12) >= (ex.request_every or 100800) then
      e.req = r.now
      K.emit('PROJECT_REQUEST', 'B', string.format('exploration dig for ore (no ore, %d bars, %d more wanted: soldiers '
                                                   .. 'and moods need metal)', have(r, 'bars'), r.gear.bars_short),
             {tpl = ex.tpl or 'explore', n = 1, why = 'ore', bars = have(r, 'bars'), short = r.gear.bars_short})
    end
    if r.now - (math.tointeger(e.dec) or -1e12) >= (ex.decide_every or 403200) then
      e.dec = r.now
      K.emit('DECISION_NEEDED', 'A', string.format('metal: no ore, %d bars; %d forge jobs, %d bars for the soldiers and '
                                                   .. '%d for moods wanted', have(r, 'bars'), r.gear.metal_jobs,
                                                   r.gear.bars_short, bars_want),
             {id = 'metal', q = 'no ore: plan propose drafts tpl explore (stair shaft + side tunnels below the core) '
                                .. 'each season; trade.want bar:iron first?'})
    end
  end
end

-- steel (Run 10, Handlelock: manager orders 262-268 waited for steel bars, ORDER_STUCK 'no bars:INORGANIC:STEEL', and
-- nothing made any): orders that need steel bars while the fort holds none (T.ocheck: st.steel) get the chain at the
-- smelter: STEEL_MAKING (pig iron + iron bar + flux + fuel -> 2 steel bars) from the pig iron there is, PIG_IRON_MAKING
-- (iron bar + flux + fuel -> pig iron) for the rest, two iron bars per later steel job; iron ore is smelted by
-- plan_metal (iron is a gear metal) and charcoal comes with the bars. A missing input (smelter, flux stone, iron,
-- fuel) -> DECISION_NEEDED steel naming it (util/cadence: again only for a new order or another missing input).
local STEEL_WORDS = {smelter = 'a smelter', flux = 'flux stone (limestone, calcite, dolomite, chalk or marble boulders)',
                     iron = 'iron (bars, or hematite, magnetite or limonite ore)',
                     fuel = 'fuel (a wood furnace for charcoal, or coke)'}
local function plan_steel(K, c, r)
  local Mt = c.metal or {}
  local S, need = Mt.steel, st.steel
  local p = r.p
  if type(S) ~= 'table' or type(need) ~= 'table' or (need.n or 0) == 0 or stock_of(r, 'bars:INORGANIC:STEEL') > 0 then
    if type(p.steel) == 'table' then p.steel = CAD.quiet(p.steel) end
    return
  end
  local magma = r.f['furnace:MagmaSmelter'] == true
  local function fuel() return magma and 99 or left(c, r, 'fuel') end
  local ore = 0
  for tok, o in pairs(st.ores or {}) do
    for _, m in ipairs(o.metals or {}) do if m == 'INORGANIC:IRON' then ore = ore + left(c, r, 'ore:' .. tok); break end end
  end
  local iron, pig = left(c, r, 'bars:INORGANIC:IRON'), left(c, r, 'bars:INORGANIC:PIG_IRON')
  local missing = {}
  if not ws_any(r.f, Mt.smelter) then missing[#missing + 1] = 'smelter' end
  if left(c, r, 'flux') == 0 then missing[#missing + 1] = 'flux' end
  if iron + pig + ore == 0 then missing[#missing + 1] = 'iron' end
  if fuel() == 0 and not ws_any(r.f, (Mt.charcoal or {}).ws) then missing[#missing + 1] = 'fuel' end
  st.steel.missing = missing
  if #missing > 0 then
    local now = K.now()
    local ids = {}
    for i, id in ipairs(need.ids or {}) do ids[i] = tostring(id) end
    if CAD.due(p.steel, now, ids, missing) then
      p.steel = CAD.mark(now, ids, missing)
      local words = {}
      local flux_gone = false
      for i, m in ipairs(missing) do words[i] = STEEL_WORDS[m] or m; if m == 'flux' then flux_gone = true end end
      K.emit('DECISION_NEEDED', 'A', string.format('steel: %d orders (%s) wait for steel bars; missing %s', need.n,
                                                   table.concat(ids, ',', 1, math.min(4, #ids)),
                                                   table.concat(missing, ', ')),
             {id = 'steel', q = ('missing ' .. table.concat(words, '; ') .. ': dig or trade for it (trade.want add ' ..
                                 (flux_gone and '"flux" (BUG-583), ' or '') .. '"bar:steel"), or remove the steel orders?'):sub(1, 240)})
    end
    return
  end
  local want = math.min(S.max_jobs or 5, math.max(1, need.left or need.n))
  local fc = fuel_cond(r)
  local flx = cond(1, 'BOULDER', {reaction_class = 'FLUX'})
  local made = 0
  if not open(r, S.tag) then
    local n = math.min(want, pig, iron, left(c, r, 'flux'), fuel())
    if add(r, {tag = S.tag, n = n, why = 'steel',
               spec = {job = 'CustomReaction', reaction = S.make,
                       item_conditions = {cond(1, 'BAR', {material = 'INORGANIC:PIG_IRON'}),
                                          cond(1, 'BAR', {material = 'INORGANIC:IRON'}), flx, fc}},
               uses = {['bars:INORGANIC:PIG_IRON'] = 1, ['bars:INORGANIC:IRON'] = 1, flux = 1, fuel = magma and 0 or 1}}) then
      made = n
    end
  else made = r.s.live[S.tag] or 0 end
  if not open(r, S.pig_tag) then
    local f = magma and 99 or left(c, r, 'fuel') // 2
    local n = math.min(want - made, left(c, r, 'bars:INORGANIC:IRON') // 2, left(c, r, 'flux') // 2, f)
    add(r, {tag = S.pig_tag, n = n, why = 'steel',
            spec = {job = 'CustomReaction', reaction = S.pig,
                    item_conditions = {cond(1, 'BAR', {material = 'INORGANIC:IRON'}), flx, fc}},
            uses = {['bars:INORGANIC:IRON'] = 1, flux = 1, fuel = magma and 0 or 1}})
  end
  r.route.bars = (r.route.bars and r.route.bars .. '+' or '') .. 'steel'
end

-- BUG-270 (live Earthboat: 'gear: 5 soldiers ... body 0/5 no bars/leatherworks, quiver 3/5 no leatherworks', no shop
-- was ever asked for): a slot that has no route because no Leatherworks stands asks for it (and for the Tanners when none
-- stands), BUG-268: mechanisms the manifest levers miss without a Mechanic's workshop ask for that one; one
-- PROJECT_REQUEST workshops why=gear (M.ws_ask, follow places only those)
-- BUG-525 (Run 16c i3 Sealcertain y395-y397: body 0/5 'ordered' for years, 37 x 'cancels Forge bismuth bronze breastplate: Needs 3
-- bismuth bronze bars' while iron bars lay in the stores): the open order of a gear slot keeps the metal it was entered in. When
-- that metal's bars are gone (fewer in the stores than one piece takes) and another metal of gear.metals has the bars, the order
-- is removed and the slot is planned again (iron first) in the same pass. Returns true when it removed the order.
function M.gear_wrong_metal(K, c, r, it, tag)
  if not it.metal or not (c.gear or {}).metals then return false end
  local oid = r.p.orders[tag]
  local o = oid and order_by_id(oid)
  if not o then return false end
  local okm, tok = pcall(function() return mat_token(o.mat_type, o.mat_index) end)
  if not okm or type(tok) ~= 'string' or tok:sub(1, 10) ~= 'INORGANIC:' then return false end
  local b = it.metal.bars
  if (st.bars_by[tok] or 0) >= b then return false end
  local alt
  for _, m in ipairs(c.gear.metals) do
    local t = 'INORGANIC:' .. m
    if t ~= tok and (st.bars_by[t] or 0) >= b and left(c, r, 'bars:' .. t) >= b and left(c, r, 'bars') >= b then alt = m; break end
  end
  if not alt or not K.act.order_remove(oid) then return false end
  r.p.orders[tag] = nil
  r.s.live[tag] = nil
  K.log('warn', 'gear %s: order %d in %s removed, %d bar(s) of it left and %s has them: planned again', it.cat, oid,
        tok:gsub('^INORGANIC:', ''), st.bars_by[tok] or 0, alt)
  return true
end

-- BUG-556 (Run 16c i3 Sealcertain y395-y401: 'body 0/5+1 ordered', a metal order that never ran; a manual leather order.add raised worn
-- 11 -> 87 %): the planner tried leather only when no metal route existed at all. An open metal order of a slot that made no piece
-- for gear.stale_days (12) game days is removed when leather and a Leatherworks are at hand, and that slot is planned in leather first
-- for gear.leather_days (30) days (kern.log: `gear <cat>: metal order N made nothing in D days: leather`). Progress = the pieces at hand
-- rose. Module fields, not locals (this file sits at Lua's 200-locals limit).
M.GEAR_STALE_DAYS, M.GEAR_LEATHER_DAYS = 12, 30
function M.gear_leather_hold(c, r, it, lw)
  local e = r.p.gstale and r.p.gstale[it.cat]
  local lh = type(e) == 'table' and e.lh
  if not (lh and it.leather and lw and r.now >= lh) then return false end
  if r.now - lh >= ((c.gear or {}).leather_days or M.GEAR_LEATHER_DAYS) * DAY then return false end
  return left(c, r, 'leather') >= (it.leather.n or 1)
end
function M.gear_stale(K, c, r, it, tag, rec, lw)
  if type(r.p.gstale) ~= 'table' then r.p.gstale = {} end
  local gs = r.p.gstale
  local e = gs[it.cat]
  if type(e) ~= 'table' then e = {}; gs[it.cat] = e end
  if not e.t or r.now < e.t or r.now - (e.seen or r.now) > 3 * DAY then e.t, e.h = r.now, rec.have end    -- a gap in the watch: new look
  e.seen = r.now
  if rec.have > (e.h or 0) then e.t = r.now end
  e.h = rec.have
  if not (it.leather and lw) then return false end
  if r.now - e.t < ((c.gear or {}).stale_days or M.GEAR_STALE_DAYS) * DAY then return false end
  local oid = r.p.orders[tag]
  local o = oid and order_by_id(oid)
  if not o then return false end
  local okm, tok = pcall(function() return mat_token(o.mat_type, o.mat_index) end)
  if not okm or type(tok) ~= 'string' or tok:sub(1, 10) ~= 'INORGANIC:' then return false end     -- only a metal order gives way
  if left(c, r, 'leather') < (it.leather.n or 1) or not K.act.order_remove(oid) then return false end
  r.p.orders[tag] = nil
  r.s.live[tag] = nil
  e.lh, e.t = r.now, r.now
  K.log('warn', 'gear %s: metal order %d (%s) made nothing in %d days, %d leather at hand: leather first for %d days', it.cat, oid,
        tok:gsub('^INORGANIC:', ''), ((c.gear or {}).stale_days or M.GEAR_STALE_DAYS), left(c, r, 'leather'),
        ((c.gear or {}).leather_days or M.GEAR_LEATHER_DAYS))
  return true
end

-- BUG-689 (Run 16d i4 Trumpetrealms y455: 'metal 0 %', 32 metal bars, body 28/10 ok in leather and loot, nothing ordered; Run 16a i1 'metal: no ore,
-- 3 bars; 0 forge jobs'): the slot count takes a leather piece for a piece, so a fort whose soldiers wear leather never forged the metal set
-- while the bars lay there. After every slot's own needs were planned (weapons, shields and the missing pieces first), the bars that are left
-- (floors of the mood stock kept) make metal pieces for the armor slots that hold fewer metal pieces than soldiers (gm_<cat> < want): one order a
-- slot, at most gear.max_jobs jobs, never while the slot's order is open, in the first metal of gear.metals that has the bars. Needs a forge.
function M.gear_metal_topup(K, c, r, forge, magma, fc)
  local g = c.gear
  if not forge then return end
  for _, it in ipairs(g.items or {}) do
    local rec = r.gear.cats[it.cat]
    local tag = 'dfllm:gear_' .. it.cat
    if rec and it.metal and it.leather and rec.miss == 0 and (rec.mmiss or 0) > 0 and not open(r, tag) then
      local jobs = (rec.mmiss + (it.out or 1) - 1) // (it.out or 1)
      for _, m in ipairs(g.metals or {}) do
        local tok, b = 'INORGANIC:' .. m, it.metal.bars
        local n = math.min(jobs, left(c, r, 'bars:' .. tok) // b, left(c, r, 'bars') // b, magma and (g.max_jobs or 5) or left(c, r, 'fuel'),
                           g.max_jobs or 5)
        if n > 0 then
          local spec = {job = it.metal.job, item_subtype = it.metal.sub, material = tok}
          spec.item_conditions = {cond(b + floor_of(c, r.p, r, 'bars'), 'BAR', {material = tok}), fc}
          if add(r, {tag = tag, spec = spec, n = n, out = it.out or 1, cat = it.cat, why = 'gear',
                     uses = {['bars:' .. tok] = b, bars = b, fuel = magma and 0 or 1}}) then
            rec.route = 'metal+:' .. m
            if r.day then K.log('info', 'gear: %s: %d of %d slots hold a metal piece, bars lie there: %d %s jobs in %s', it.cat,
                                (rec.want or 0) - rec.mmiss, rec.want or 0, n, it.metal.job, m) end
          end
          break
        end
      end
    end
  end
end

local function plan_gear(K, c, r)
  local g = c.gear
  local forge, lw = ws_any(r.f, g.forge), ws_any(r.f, g.leatherworks)
  local shops = {}
  local okm, mws = pcall(M.plan_mech, K, c, r)
  if not okm then K.log('warn', 'mechanisms: %s', tostring(mws)) elseif mws then shops[#shops + 1] = mws end
  local magma = r.f['workshop:MagmaForge'] == true
  local fc = fuel_cond(r)
  for _, it in ipairs(g.items or {}) do
    local rec = r.gear.cats[it.cat]
    local tag = 'dfllm:gear_' .. it.cat
    if rec and rec.miss == 0 and rec.open > 0 and open(r, tag) and M.gear_stale(K, c, r, it, tag, rec, lw) then
      rec.miss, rec.open, rec.route = rec.open, 0, 'none'      -- BUG-556: the order covered the want and made nothing: leather
    end
    if rec and rec.miss > 0 then
      if open(r, tag) and M.gear_wrong_metal(K, c, r, it, tag) then   -- BUG-525: the wrong-metal order's pieces are missing again
        rec.miss, rec.open, rec.route = rec.miss + rec.open, 0, 'none'
      end
      if M.gear_stale(K, c, r, it, tag, rec, lw) then                  -- BUG-556: a metal order that made nothing for days
        rec.miss, rec.open, rec.route = rec.miss + rec.open, 0, 'none'
      end
      if open(r, tag) then rec.route = 'ordered'
      else
        local jobs = (rec.miss + (it.out or 1) - 1) // (it.out or 1)
        local maxj = g.max_jobs or 5
        local why = {}
        local function base(x)
          return {job = x.job, item_subtype = x.sub}
        end
        if it.metal then
          if not forge then why[#why + 1] = 'forge' end
          local skip_metal = M.gear_leather_hold(c, r, it, lw)                -- BUG-556: leather first after a stale metal order
          for _, m in ipairs((forge and not skip_metal) and g.metals or {}) do
            local tok, b = 'INORGANIC:' .. m, it.metal.bars
            local n = math.min(jobs, left(c, r, 'bars:' .. tok) // b, left(c, r, 'bars') // b,
                               magma and maxj or left(c, r, 'fuel'), maxj)
            if n > 0 then
              local spec = base(it.metal)
              spec.material = tok
              spec.item_conditions = {cond(b + floor_of(c, r.p, r, 'bars'), 'BAR', {material = tok}), fc}
              add(r, {tag = tag, spec = spec, n = n, out = it.out or 1, cat = it.cat, why = 'gear',
                      uses = {['bars:' .. tok] = b, bars = b, fuel = magma and 0 or 1}})
              rec.route = 'metal:' .. m
              break
            end
          end
          if rec.route == 'none' then why[#why + 1] = (left(c, r, 'bars') == 0 and 'bars' or 'fuel') end
        end
        if rec.route == 'none' and it.leather then
          local ln = it.leather.n or 1
          local n = lw and math.min(jobs, left(c, r, 'leather') // ln, maxj) or 0
          if n > 0 then
            local spec = base(it.leather)
            spec.material_category = {'leather'}
            spec.item_conditions = {cond(ln + floor_of(c, r.p, r, 'leather'), 'SKIN_TANNED')}
            add(r, {tag = tag, spec = spec, n = n, out = it.out or 1, cat = it.cat, uses = {leather = ln}, why = 'gear'})
            rec.route = 'leather'
          else
            why[#why + 1] = lw and 'leather' or 'leatherworks'
            if not lw and not shops.lw then
              shops.lw = true
              shops[#shops + 1] = 'Leatherworks'
              if not r.f['workshop:Tanners'] then shops[#shops + 1] = 'Tanners' end
            end
          end
        end
        if rec.route == 'none' and it.wood then
          local n = ws_any(r.f, it.wood.ws) and math.min(jobs, left(c, r, 'wood'), maxj) or 0
          if n > 0 then
            add(r, {tag = tag, spec = wood_spec(c, r, base(it.wood)), n = n, out = it.out or 1, cat = it.cat,
                    uses = {wood = 1}, why = 'gear'})
            rec.route = 'wood'
          else
            why[#why + 1] = 'wood'
            -- BUG-618 (Run 16b i2 Valleyhame: 'hunt: no crossbow, no Bowyer's workshop' through three famines): the crossbows and bolts
            -- of the hunters are made at a Bowyer's; with logs in the fort and no shop that makes them, the shop is asked for
            if (it.cat == 'xbow' or it.cat == 'bolts') and left(c, r, 'wood') > 0 and type(it.wood.ws) == 'table' then
              local sh = tostring(it.wood.ws[#it.wood.ws]):gsub('^workshop:', '')
              if not r.f['workshop:' .. sh] then shops[#shops + 1] = sh end
            end
          end
        end
        if rec.route == 'none' and it.bone then
          local n = ws_any(r.f, it.bone.ws) and math.min(jobs, left(c, r, 'bone'), maxj) or 0
          if n > 0 then
            local spec = base(it.bone)
            spec.material_category = {'bone'}
            spec.item_conditions = {cond(floor_of(c, r.p, r, 'bone') + 1, nil, {flags = {'unrotten', 'bone', 'body_part'}})}
            add(r, {tag = tag, spec = spec, n = n, out = it.out or 1, cat = it.cat, uses = {bone = 1}, why = 'gear'})
            rec.route = 'bone'
          end
        end
        if rec.route == 'none' then rec.route = 'no ' .. table.concat(why, '/') end
      end
    end
  end
  M.gear_metal_topup(K, c, r, forge, magma, fc)
  if #shops > 0 then
    M.ws_ask(K, r.p, 'gear', shops, (c.food or {}).request_days or 14, "workshops: soldiers' gear and levers miss a shop")
  elseif type(r.p.wsask) == 'table' then r.p.wsask.gear = nil end
end

-- the inputs of worn % (DESIGN Ã‚Â§5.3): wanted / at hand / ordered per slot and the route, logged on change
local function gear_report(K, c, r)
  local gr = r.gear
  local parts, want, hv = {}, 0, 0
  local cats = json.object{}
  for _, it in ipairs(c.gear.items or {}) do
    local x = gr.cats[it.cat]
    if x and x.want > 0 then
      parts[#parts + 1] = string.format('%s %d/%d%s %s', it.cat, x.have, x.want, x.open > 0 and ('+' .. x.open) or '', x.route)
      cats[it.cat] = {want = x.want, have = x.have, open = x.open, route = x.route}
      if it.cat ~= 'bolts' then want, hv = want + x.sw, hv + math.min(x.sw, x.have) end
    end
  end
  local ok, kpi = K.call('military', 'kpi')
  local worn = ok and type(kpi) == 'table' and (math.tointeger(kpi.worn) or 0) or -1
  r.p.gear = json.object{soldiers = gr.n, melee = gr.melee, xbow = gr.xbow, hunters = gr.hunt, worn = worn,
                         slots = ok and type(kpi) == 'table' and math.tointeger(kpi.slots) or -1,
                         pieces = hv, wanted = want, metal = r.inv.g_metal or 0, cats = cats}
  local line = string.format('gear: %d soldiers (%d melee, %d xbow) + %d hunters, worn %d%%, pieces %d/%d; %s',
                             gr.n, gr.melee, gr.xbow, gr.hunt, worn, hv, want, table.concat(parts, ', '))
  if #parts > 0 and line ~= st.gear_line then K.log('info', '%s', line) end
  st.gear_line = line
  if want > 0 or r.p.low.gear == 1 then
    local low = hv < want
    if low and r.p.low.gear ~= 1 then
      r.p.low.gear = 1
      K.emit('STOCK_LOW', 'B', string.format('gear %d < %d (worn %d%%)', hv, want, worn),
             {key = 'gear', n = hv, min = want, worn = worn})
    elseif not low then r.p.low.gear = nil end
  end
end

---------------------------------------------------------------- rock furniture in wood (live L3)
-- BUG-733: the boulders of the census a mason may take (reachable, not in a job): rock minus the unusable ones, each counted once
-- (rock_nouse); a census from before the key falls back to the old max(ore + flux, rock_bad)
function M.usable_n(inv)
  local rock = math.max(0, math.tointeger(inv.rock) or 0)
  local no = math.tointeger(inv.rock_nouse)
  if no == nil then no = math.max((math.tointeger(inv.ore) or 0) + (math.tointeger(inv.flux) or 0), math.tointeger(inv.rock_bad) or 0) end
  return math.max(0, rock - no)
end

-- free boulders a mason may take: ores and flux are economic stone (DF's default stone use settings keep them
-- from furniture and blocks; care's reserve counts the same way), minus the rock floor
local function stone_free(c, r)
  local inv = r.inv
  if M.hard_denied(inv, r.now) then return 0 end        -- BUG-545: DF itself says the fort has no non-economic hard stone
  local n = M.usable_n(inv)
  return math.max(0, n - floor_of(c, r.p, r, 'rock'))
end

-- BUG-733 (Run 16b i2 Whirledrampart y431: explore done, CLAYSTONE / CHERT dug, 'stone free 0 need 29-32' for 65 days and nothing said which of
-- the five things took the boulders out): the census boulders step by step, from every boulder of the fort to the ones a mason is given.
-- {boulders, far (another walk group / no walkable tile), busy (a job holds it), rock (the rest), nouse (ore, flux, economic, soft, refused),
-- usable, denied (DF's own refusal memory), floor (reserve of open needs and holders, minus what care holds), free (what stone_free says)}
function M.stone_why(c, r)
  local inv, w = r.inv, {}
  local function g(k) return math.max(0, math.tointeger(inv[k]) or 0) end
  w.boulders, w.far, w.busy, w.rock = g('boulders'), g('rock_far'), g('rock_busy'), g('rock')
  w.nouse, w.usable = w.rock - M.usable_n(inv), M.usable_n(inv)
  w.denied = M.hard_denied(inv, r.now) or nil
  w.floor = floor_of(c, r.p, r, 'rock')
  w.free = stone_free(c, r)
  return w
end

-- the same as one line for kern.log and the decisions
function M.stone_why_text(w)
  local steps = {}
  if w.boulders > 0 then steps[#steps + 1] = string.format('%d boulders', w.boulders) end
  if w.far > 0 then steps[#steps + 1] = string.format('%d out of reach (another walk group or no walkable tile)', w.far) end
  if w.busy > 0 then steps[#steps + 1] = string.format('%d held by a job', w.busy) end
  steps[#steps + 1] = string.format('%d free', w.rock)
  if w.nouse > 0 then steps[#steps + 1] = string.format('%d ore, flux, economic or soft stone', w.nouse) end
  steps[#steps + 1] = string.format('%d usable by the census', w.usable)
  if w.denied then steps[#steps + 1] = 'DF refused them (cancel memory)' end
  if w.floor > 0 then steps[#steps + 1] = string.format('%d kept back for open needs and reserves', w.floor) end
  return string.format('%s -> %d free for the rock orders', table.concat(steps, ', '), w.free)
end

-- BUG-224: true when T.stale switched this order's material (sw) or made it again (redo, its dfllm:redo_ tag)
function M.stale_mark(p, id)
  local rec = type(p) == 'table' and type(p.ostale) == 'table' and p.ostale[tostring(id)] or nil
  return type(rec) == 'table' and (rec.sw == 1 or (math.tointeger(rec.redo) or 0) > 0)
end

local function wood_orders(K, c, r)
  local w = c.wood_orders
  local rock = stone_free(c, r)
  if type(w) ~= 'table' or rock >= (w.boulders_below or 20) then return 0 end
  local jobs = {}
  for _, j in ipairs(w.jobs or {}) do jobs[j] = true end
  local one = df.workquota_frequency_type.OneTime
  local function open_of(o)
    return jobs[df.job_type[o.job_type] or ''] and o.frequency == one and (o.amount_left or 0) > 0
  end
  local keep = math.max(w.wood_min or 30, floor_of(c, r.p, r, 'wood'))
  local budget = (r.inv.wood or 0) - keep - (r.s.used.wood or 0) - (r.planned.wood or 0)
  -- BUG-666 (Run 16d i4 Trumpetrealms y438: the only door order 'Make rock door', 371 days old, beside 99 logs and 0 usable stone): an order
  -- T.stale made again in rock keeps its material only while stone is free (stale_mark); with no stone at all it can never run in rock, so it
  -- goes to the Carpenters like any other rock order
  local n = 0
  for _, o in ipairs(orders_all()) do
    if n >= (w.per_day or 8) or budget <= 0 then break end
    -- BUG-224 (live i3 Earthboat: order 650 ConstructChest went rock -> wood one day after T.stale made it again in
    -- stone): an order T.stale switched or made again (p.ostale sw/redo, M.stale_mark) keeps its material
    if open_of(o) and o.mat_type == 0 and o.amount_left <= budget and (rock <= 0 or not M.stale_mark(r.p, o.id)) then
      local amount = o.amount_left
      if K.act.order_material(o.id, 'wood') then
        n, budget = n + 1, budget - amount
        r.planned.wood = (r.planned.wood or 0) + amount
        K.log('info', 'order %d %s x%d: rock -> wood (%d boulders, %d logs)', o.id, df.job_type[o.job_type], amount,
              r.inv.rock or 0, r.inv.wood or 0)
      end
    end
  end
  return n
end

-- Gordon's rule: plump helmets are never cooked (D-09 'yes' lifts it only during a famine)
-- BUG-345: D-09 'yes' in a famine takes the plant's exclusion off (it only stopped adding it, so a ban set before the
-- famine stood all famine long; the seeds stay banned: the farms' spawn); after the famine the next run puts it back
local function kitchen(K, c, food_d)
  local lift = decision(K, 'D-09') == 'yes' and food_d and food_d < (c.famine_days or 10)
  for _, e in ipairs(c.kitchen or {}) do
    local mi = dfhack.matinfo.find(e.plant, e.mat)            -- as ban-cooking.lua:67
    local it = df.item_type[e.item]
    local has = mi and it and dfhack.kitchen.findExclusion({[e.what] = true}, it, -1, mi.type, mi.index) >= 0
    if lift and has and e.item ~= 'SEEDS' then
      if K.act.kitchen_include(e.item, -1, mi.type, mi.index, e.what) then
        K.log('warn', 'famine (food %d days), D-09 yes: %s %s may be cooked until the famine ends', food_d, e.plant, e.item)
      end
    elseif mi and it and not has and not (lift and e.item ~= 'SEEDS') then
      K.act.kitchen_exclude(e.item, -1, mi.type, mi.index, e.what)    -- Lua API.txt:2648-2662
    end
  end
end

---------------------------------------------------------------- labor
-- labormanager status lines (autolabor.plug.dll 53.16-r2): modern "job board: N postings resolved, avg wait A
-- ticks, longest L ticks; S starving (> 1200 ticks, oldest O ticks)", monitor "labor monitor: S starving
-- postings (> 1200 ticks), oldest <job> at O ticks", dump "starving=S oldest=J (O ticks)"
function M.parse_status(out)
  local s = tostring(out or '')
  local n = s:match('([0-9]+) starving') or s:match('starving=([0-9]+)')
  if not n then return nil end
  local after = s:match('oldest(.*)$') or ''
  local age = after:match('([0-9]+) ticks')
  local job = after:match('^ ([^0-9][^\n]-) at [0-9]+')
  return math.tointeger(tonumber(n)), age and math.tointeger(tonumber(age)) or nil, job
end

function M.parse_starving(out)
  local n = M.parse_status(out)
  return n
end

-- the starving-postings reason (labormanager's oldest posting) when its detail is TOOL_BLOCKED
local function starve_why(job)
  local j = tostring(job or ''):lower()
  for name, b in pairs(st.tblk or {}) do
    if (b.tool == 'axe' and j:find('fell', 1, true)) or (b.tool == 'pick' and (j:find('dig', 1, true) or
       j:find('mine', 1, true) or j:find('stair', 1, true) or j:find('channel', 1, true))) then
      return string.format('no %s in hand (%s %d of %d)', b.tool, name, b.n, b.of)
    end
  end
end

-- the stale floor (live L2/L3: 504 Gather Plants postings from L1, oldest 295,072 ticks, every day)
local function stale_filter(K, c, p, n, age, job)
  local s = c.starving or M.DEFAULTS.starving
  local hist, floor = p.stale, 0
  if age and age >= (s.stale_age or 12000) then
    if #hist >= (s.min_days or 3) then
      floor = hist[1]
      for _, v in ipairs(hist) do floor = math.min(floor, v) end
    end
    hist[#hist + 1] = n
    while #hist > (s.keep or 7) do table.remove(hist, 1) end
  else
    p.stale = {}
  end
  floor = math.min(floor, n)
  -- BUG-023: the oldest posting's detail holds no tool (TOOL_BLOCKED): the reason goes with the line
  local why = starve_why(job)
  if floor ~= st.stale or why ~= st.starve_why then
    K.log('info', 'labor: %d of %d starving postings are stale (oldest %s, %s ticks%s)', floor, n, tostring(job or '?'),
          age and fmt(age) or '?', why and (': ' .. why) or '')
  end
  st.starve_why = why
  st.stale, st.oldest = floor, age
  return n - floor
end

-- FR-77 (Run 13: "N of M adults without a job (0 without reachable work)" with 40-70 % idle): why an adult has no job.
-- flags: mood (a strange mood or insanity), hurt (a wound that needs treatment, BUG-557: not a healed scar; or needs health care while bled), rest (drowsy: sleepiness_timer at DF's
-- "drowsy" mark, or lying down); idle_class names the first that holds (mood, hurt, rest) or nil. Every read is guarded:
-- a field the game does not have is no flag. Module fields, not locals (this file sits at Lua's 200-locals limit).
M.IDLE_SLEEPY = 57600
M.IDLE_CLASSES = {'rest', 'hurt', 'mood', 'held', 'nolabor', 'noreach', 'nowork', 'free'}
M.JOB_LABOR = {GatherPlants = 'HERBALIST', PlantSeeds = 'PLANT', HarvestPlants = 'PLANT', FellTree = 'CUTWOOD',
               Dig = 'MINE', DigChannel = 'MINE', CarveUpwardStaircase = 'MINE', CarveDownwardStaircase = 'MINE',
               CarveUpDownStaircase = 'MINE', CarveRamp = 'MINE', Fish = 'FISH', Hunt = 'HUNT'}
function M.idle_flags(u)
  local f = {}
  pcall(function() f.mood = type(u.mood) == 'number' and u.mood >= 0 end)
  -- BUG-271 (live Earthboat: idle_why hurt 14; units 26374/26371/21852 had 0 wounds, blood 100 %, were hungry and
  -- sleepy): needs_healthcare alone is no hurt; it counts with a wound or blood below its maximum (f.care: the flag alone)
  -- BUG-557 (Run 16d i4 Trumpetrealms y404: idle_why hurt 20 of 25 adults, each with a healed scar, bleed 0, blood 100 %):
  -- a wound counts while it needs treatment (dfllm.util.wound), not because it is on the list
  pcall(function()
    local WD = require('dfllm.util.wound')
    local s = WD.state(u)
    f.hurt = WD.needs_treatment(u)
    f.care = s ~= nil and s.care and not f.hurt or nil
  end)
  pcall(function()
    local t = u.counters2 and u.counters2.sleepiness_timer
    f.rest = type(t) == 'number' and t >= M.IDLE_SLEEPY
    if not f.rest and u.actions then
      for _, a in ipairs(u.actions) do
        local n = df.unit_action_type and df.unit_action_type[a.type]
        if n == 'Sleep' or n == 'LieDown' then f.rest = true; break end
      end
    end
  end)
  return f
end
function M.idle_class(f)
  if f.mood then return 'mood' elseif f.hurt then return 'hurt' elseif f.rest then return 'rest' end
end
-- projects the kernel holds back by a rule of its own (seal first, the rebuild policy, the slot queue): from the published
-- runner state (sched.seal.paused, sched.rb.paused, sched.q.n)
function M.held_projects(K, queued)
  local sc = (K.view() or {}).sched
  if type(sc) ~= 'table' then sc = {} end
  local n = 0
  for _, k in ipairs({'seal', 'rb'}) do
    local e = sc[k]
    if type(e) == 'table' then n = n + (math.tointeger(e.paused) or 0) end
  end
  -- the slot queue: the runner's own answer when the caller has it (inspect), else the published state
  n = n + (math.tointeger(queued) or (type(sc.q) == 'table' and math.tointeger(sc.q.n)) or 0)
  return n
end

-- BUG-486 (Run 16d i4 Trumpetrealms: 'set aside, no runner slot' on many projects, 2 digs at once, 15 of 16 adults idle): the free idle
-- adults (no job and no state that explains it: not resting, hurt or in a mood) and the adults counted, as of the last daily scan
-- (idle_pct); nil before the first scan. The runner raises its parallel slots by them (runner Q.slot_cap).
function M.idle_free(K)
  local iw = st and st.idle_why
  if type(iw) ~= 'table' or type(iw.why) ~= 'table' then return nil end
  return math.tointeger(iw.why.free) or 0, math.tointeger(iw.n) or 0
end

local function idle_pct(K)
  local cu = K.census.u
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' then st.idle_why = nil; return nil end
  local sold = {}
  for _, id in ipairs(cu.soldier_ids or {}) do sold[id] = true end
  local n, idle, why = 0, 0, {rest = 0, hurt = 0, mood = 0, free = 0}
  for _, id in ipairs(cu.ids) do
    local u = not sold[id] and df.unit.find(id)
    if u and not dfhack.units.isChild(u) and not dfhack.units.isBaby(u) then
      n = n + 1
      local j = u.job
      if j == nil or j.current_job == nil then
        idle = idle + 1
        local c = M.idle_class(M.idle_flags(u)) or 'free'
        why[c] = why[c] + 1
      end
    end
  end
  -- the daily scan knows what a unit's own state says; what the job board and the walk groups add (held, no labor
  -- holder, no reachable work) is `inspect workload` (a job scan). soldiers: not counted in n
  st.idle_why = {n = n, sold = #(cu.soldier_ids or {}), held = M.held_projects(K), why = why}
  return n > 0 and idle * 100 // n or 0
end

-- the useful backlog (D-03): never filler digging
local function backlog_pick(K, c, p, inv, rock)
  local ic = c.idle
  for _, b in ipairs(ic.backlog or {}) do
    if b.id == 'blocks' then
      if rock >= ic.boulders_min and (inv.blocks or 0) < ic.blocks_cap and not live(p.orders[b.tag]) then return b end
    elseif b.id == 'crafts' then
      if (inv.crafts or 0) < ic.crafts_cap and rock >= 10 and not live(p.orders[b.tag]) then return b end
    elseif b.id == 'wood_crafts' then
      if (inv.crafts or 0) < ic.crafts_cap and rock < 10 and (inv.wood or 0) >= (ic.wood_min or 60)
         and not live(p.orders[b.tag]) then return b end
    elseif b.id == 'combine' then
      if p.last_combine == nil or K.now().tick - p.last_combine >= ic.combine_every then return b end
    end
  end
end

local function backlog_act(K, b, p)
  if b.id == 'combine' then
    local ok = K.act.run('combine', 'all', '-q')
    if ok then p.last_combine = K.now().tick end
    return ok
  end
  local spec = copy(b.spec)
  spec.tag, spec.amount_total = b.tag, b.amount
  local ok, id = K.act.workorder(spec)
  if ok then p.orders[b.tag] = id end
  return ok
end

-- true when it acted (a command)
-- BUG-037: the runner's queue in one clause ('runner: 6 projects queued behind 3 slot holders ...'), nil when nothing
-- waits; and its data
local function runner_queue(K)
  local ok, msg, data = K.call('runner', 'queue')
  if not ok then return nil, nil end
  return type(msg) == 'string' and msg or nil, type(data) == 'table' and data or nil
end

local function idle_rule(K, c, p, inv, rock)
  local rule = decision(K, 'D-03')
  if st.idle == nil then return false end
  if st.idle > c.idle.pct then p.idle_days = (p.idle_days or 0) + 1 else p.idle_days = 0 end
  local need = rule == 'immediate' and 1 or c.idle.days
  if rule == 'off' or p.idle_days < need or K.mode() ~= 'PEACE' then return false end
  local b = backlog_pick(K, c, p, inv, rock)
  if not b then
    local rq = runner_queue(K)
    K.log('info', 'idle %d%% for %d days, useful backlog empty: no action%s', st.idle, p.idle_days,
          rq and ('; ' .. rq) or '')
    return false
  end
  if backlog_act(K, b, p) then
    K.log('info', 'idle %d%% for %d days: backlog %s', st.idle, p.idle_days, b.id)
    p.idle_days = 0
  end
  return true
end

---------------------------------------------------------------- events
local function stock_low(K, p, key, value, min, as_days)
  local low = value < min
  if low and p.low[key] ~= 1 then
    p.low[key] = 1
    local d = {key = key, min = min}
    if as_days then d.days = value else d.n = value end
    K.emit('STOCK_LOW', 'B', string.format('%s %d < %d', key, value, min), d)
  elseif not low and p.low[key] == 1 and value * 100 >= min * 110 then
    p.low[key] = nil
  end
end

local function find_order_named(key)
  for _, o in ipairs(orders_all()) do
    local ok, name = pcall(function() return dfhack.job.getManagerOrderName(o) end)   -- Lua API.txt:1416
    name = ok and tostring(name or ''):lower() or ''
    if name ~= '' and (name:find(key, 1, true) or key:find(name, 1, true)) then return o.id end
  end
end

-- "<unit> cancels <job>: <reason>." (CANCEL_JOB report text)
function M.cancelled_job(text)
  local j = tostring(text or ''):match('cancels ([^:]+):')
  if not j then return nil end
  j = j:gsub('^[ ]+', ''):gsub('[ ]+$', '')
  return j ~= '' and j or nil
end

-- FR-10: "Needs ..." cancels per order (7-day window); at needs_drop the order is removed (the work orders
-- screen), except the supply orders a famine or a drought would starve without (KEEP_JOBS, brewing)
local KEEP_JOBS = {BrewDrink = true, PrepareMeal = true, MakeBarrel = true, PrepareRawFish = true}
local function keep_order(o)
  local okn, job = pcall(function() return df.job_type[o.job_type] end)
  if okn and KEEP_JOBS[job] then return true end
  local rn = tostring(o.reaction_name or '')
  return rn:sub(1, 5) == 'BREW_'
end

local function needs_cancel(K, c, oid, job, why)
  local oc = c.orders or M.DEFAULTS.orders
  local o = order_by_id(oid)
  if not o or keep_order(o) then return end
  local p = pstate(K)
  local now = K.now().tick
  local key = tostring(oid)
  local rec = p.ocancel[key]
  if type(rec) ~= 'table' or now - (math.tointeger(rec.first) or now) > 7 * DAY then rec = {n = 0, first = now} end
  rec.n, rec.why, rec.job = rec.n + 1, tostring(why):sub(1, 60), tostring(job):sub(1, 40)
  p.ocancel[key] = rec
  K.persist.touch('m.economy')
  if rec.n < (oc.needs_drop or 10) then return end
  -- J2 (BUG-078 x the pruner): a memorial order names its figure; the kernel's own (act.engrave_order) is untagged, so the
  -- backoff below cannot hold it back: slab_engrave remembers the figure (p.slab_drop) and does not order it again at once
  local hf
  pcall(function()
    if o.job_type == df.job_type.EngraveSlab then hf = math.tointeger(o.specdata.hist_figure_id) end
  end)
  local ok = K.act.order_remove(oid)
  if not ok then return end
  if hf and hf >= 0 then
    p.slab_drop = json.object(type(p.slab_drop) == 'table' and p.slab_drop or {})
    p.slab_drop[tostring(hf)] = now
  end
  p.ocancel[key] = nil
  for tag, id in pairs(p.orders) do
    if id == oid then                            -- an own order: not entered again for backoff_days
      p.orders[tag], st.backoff[tag] = nil, now + (oc.backoff_days or 10) * DAY
    end
  end
  K.log('warn', 'order %d %s removed after %d "%s" cancels', oid, job, rec.n, rec.why)
  K.emit('ORDER_STUCK', 'B', string.format('order %d %s removed: %d cancels "%s"', oid, job, rec.n, rec.why),
         {order = oid, job = rec.job, why = 'cancel: ' .. rec.why, n = rec.n, dropped = 1})
end

-- BUG-308 (Run 15 Drillchamber y377: care queued 25 CollectWebs tasks for a silk mood, DF cancelled every one 'Needs undisturbed
-- thread' (gamelog), and care never saw it): the cancels of each job kind since the load (lower-case DF job name, at most
-- 60 kinds) with DF's last words. M.cancels_of(K, key) -> n, why (0 and nil when none)
function M.cancel_note(key, why, tick)
  st.call = st.call or {}
  local r = st.call[key]
  if not r then
    st.call_n = (st.call_n or 0) + 1
    if st.call_n > 60 then                      -- full: the kind cancelled longest ago makes room (a new kind is never lost)
      local old, ot
      for k, v in pairs(st.call) do
        if ot == nil or (v.t or 0) < ot or ((v.t or 0) == ot and k < old) then old, ot = k, v.t or 0 end
      end
      if old then st.call[old] = nil end
      st.call_n = st.call_n - 1
    end
    r = {n = 0}
    st.call[key] = r
  end
  r.n, r.why, r.t = r.n + 1, why, tick
end
function M.cancels_of(K, key)
  local r = (st.call or {})[tostring(key or ''):lower()]
  if not r then return 0, nil end
  return r.n, r.why
end

local function cancel(K, ev)
  local c = M.conf(K)
  local job, why = OL.cancel_parts(ev.text)
  if not job then return end
  local day = (ev.tick or K.now().tick) // DAY
  if st.cday ~= day then
    st.cday, st.cancels, st.looped = day, {}, {}
    st.why_prev, st.why, st.why_n = st.why or {}, {}, 0
  end
  -- FR-40: the day's cancel reasons (inspect workload shows the top ones of today and yesterday), <= 40 kinds
  local wk = tostring(why or '?'):sub(1, 60)
  if st.why[wk] == nil and (st.why_n or 0) < 40 then st.why[wk], st.why_n = 0, (st.why_n or 0) + 1 end
  if st.why[wk] then st.why[wk] = st.why[wk] + 1 end
  -- BUG-005: the cancel reasons of constructions by position (the daily jobs pass names the one of a stuck building)
  local pos = ev.pos
  if type(pos) == 'table' and int(pos.x) and job:lower():sub(1, 9) == 'construct' then
    st.bcancel = st.bcancel or {}
    st.bcancel[#st.bcancel + 1] = {x = int(pos.x), y = int(pos.y), z = int(pos.z), why = wk}
    while #st.bcancel > 40 do table.remove(st.bcancel, 1) end
  end
  local key = job:lower()
  if key == 'collect sand' then                  -- BUG-303: DF does not count the sand zone (the abort series)
    local oks, errs = pcall(M.sand_cancel, K, c, why, ev.tick)
    if not oks then K.log('warn', 'sand cancel: %s', tostring(errs)) end
  end
  M.cancel_note(key, wk, ev.tick)                 -- BUG-308: every cancel of a job kind since the load (care's webs)
  if M.hard_words(why) then                       -- BUG-545: "Needs non-economic hard stone boulders"
    local okh, errh = pcall(M.hard_cancel, K, c, job, ev.tick or K.now().tick)
    if not okh then K.log('warn', 'hard stone cancel: %s', tostring(errh)) end
  end
  if M.logs_words(why) then                      -- BUG-705: "Needs logs" beside census logs
    local okw, errw = pcall(M.wood_cancel, K, job, wk, ev.tick or K.now().tick)
    if not okw then K.log('warn', 'wood cancel: %s', tostring(errw)) end
  end
  st.cancels[key] = (st.cancels[key] or 0) + 1
  local n = st.cancels[key]
  if key == 'dump item' then st.dump = {n = n, why = wk, day = day} end   -- FR-90: the game's own words, for inspect items trash
  local oid
  -- BUG-061: a job cancelled for want of an unengraved slab: the EngraveSlab orders are cut back now, not at the next
  -- daily pass (autoslab queues them again every 1289 ticks)
  if OL.needs(why) and tostring(why):lower():find('unengraved slab', 1, true) then
    local oks, errs = pcall(M.slab_event, K, c)
    if not oks then K.log('warn', 'slab event: %s', tostring(errs)) end
  end
  if OL.needs(why) then
    oid = find_order_named(key)
    -- Run 11: "Needs rock" while no stone is free: re-entered in wood or removed now, not after needs_drop cancels
    if oid and M.rock_why(why) and M.no_rock(K, c, oid, job, why) then oid = nil
    elseif oid then needs_cancel(K, c, oid, job, why) end
  end
  if n < (c.cancel_loop or 5) or st.looped[key] then return end
  st.looped[key] = true
  oid = oid or find_order_named(key)
  -- Run 11: a rock loop while the free stone is below the rock orders' need: a recheck only posts the jobs again
  local rock = M.rock_why(why) and M.rock_short(c, M.view_run(K))
  -- FR-90: a dump job that keeps cancelling names its reason from facts (no zone, not reachable, no free tile)
  local okt, tw, tc = pcall(function() return require('dfllm.trash').reason(K, job) end)
  tw = okt and tw or nil
  K.emit('CANCEL_LOOP', 'B', string.format('%s cancelled %d times today%s%s', job, n,
                                           rock and ' (stone short of the rock orders: no recheck)' or '',
                                           tw and (': ' .. tw) or ''),
         {order = oid or -1, job = job, n = n, why = tw and tostring(tc) or nil})
  if st.rechecked ~= day and not rock then   -- orders.txt: recheck stops cancellation spam of stale conditions
    st.rechecked = day
    K.act.orders('recheck')
  end
end

-- leaving PEACE while hunters (or fishers) are out: the next run (tool details) within rush_ticks takes them off
-- the detail, not up to a day later (drills check "nobody outside" at T+1,200)
M.on.MODE = function(K, ev)
  -- BUG-594: a fight (however short) opens the window in which loose forbidden food is freed after it (T.forbid)
  if type(ev) == 'table' and (ev.to == 'SIEGE' or ev.to == 'BREACH') then
    local okp, pp = pcall(pstate, K)
    if okp and type(pp) == 'table' then pp.fought = K.now().tick end
  end
  -- BUG-295, BUG-326: the hunters and fishers a real siege took off return as soon as the mode is no SIEGE or BREACH
  -- any more (RECOVERY too: the siege is over; p.drill_off)
  if type(ev) == 'table' and ev.from ~= ev.to and not M.HUNT_OFF[ev.to] then
    local okd, nd = pcall(M.drill_restore, K)
    if not okd then K.log('warn', 'drill restore of the tool details: %s', tostring(nd)) end
  end
  -- BUG-326: only a siege takes them off, so only a siege rushes the next tools run
  if type(ev) ~= 'table' or not M.HUNT_OFF[ev.to] or ((st.hunters or 0) == 0 and (st.fishers or 0) == 0) then return end
  st.rush = true
  local rt = M.conf(K).rush_ticks or 100
  if (M.every.ticks or EVERY) > rt then M.every = {ticks = rt} end
end

M.on.REPORT = function(K, ev)
  if ev.type == 'CANCEL_JOB' then return cancel(K, ev) end
  if not st.mig then                    -- remember who was here; the census catches up later
    local known = {}
    for _, id in ipairs(K.census.u and K.census.u.ids or {}) do known[id] = true end
    st.mig = {tick = ev.tick or K.now().tick, known = known}
  end
end

---------------------------------------------------------------- fort positions (nobles screen)
-- Live L0/L1: without a manager no work order is ever validated (0 of 47), so brewing, the orders
-- library and every supply order do nothing. Vacant economy positions are filled like a player does on
-- the nobles screen (act.appoint): the citizen with the best matching skills, no soldier, nobody who
-- already holds a position when someone else can.
-- BUG-055 (Run 14 y577: the CHIEF_MEDICAL_DWARF office stood vacant with flags.ACTIVE and an able candidate for good: this
-- list had three offices only): the hospital's administrator joins, the best healer (never a squad member: a soldier on
-- duty trains and marches; appoint_vacant skips every squad member). The militia commander and captain are NOT in the
-- list: military creates a squad together with its leader on a VACANT assignment (act.squad_create), an appointment
-- made before would take that assignment out of its reach (free_assignment/squad_assignment need histfig -1)
M.POSITIONS = {{code = 'MANAGER', skills = {'ORGANIZATION'}},
               {code = 'BOOKKEEPER', skills = {'RECORD_KEEPING'}},
               {code = 'BROKER', skills = {'APPRAISAL', 'NEGOTIATION', 'JUDGING_INTENT'}},
               {code = 'CHIEF_MEDICAL_DWARF', skills = {'DIAGNOSE', 'SURGERY', 'SET_BONE', 'SUTURE', 'DRESS_WOUNDS'}}}

-- {code -> true} of vacant offered positions, and the histfig ids holding any position
local function positions()
  local vac, held = {}, {}
  local ent = df.global.plotinfo.main.fortress_entity
  if not ent then return vac, held end
  local code_of = {}
  for _, p in ipairs(ent.positions.own) do if p.flags.ACTIVE then code_of[p.id] = p.code end end
  for _, a in ipairs(ent.positions.assignments) do
    local code = code_of[a.position_id]
    if a.histfig >= 0 then held[a.histfig] = true
    elseif code then vac[code] = (vac[code] or 0) + 1 end
  end
  return vac, held
end

local function skill_score(u, skills)
  local s = 0
  for _, name in ipairs(skills) do
    local id = df.job_skill[name]
    if id then s = s + (dfhack.units.getNominalSkill(u, id, true) or 0) end
  end
  return s
end

-- BUG-055: the vacant offices of the last pass, {code -> {n = vacant assignments, since = tick first seen vacant, cand =
-- the best candidate's id, why = why none was appointed}}; M.offices answers readiness/status/inspect from it
function M.appoint_vacant(K)
  local ok, vac, held = pcall(positions)
  if not ok then return 0 end
  local cu = K.census.u
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' then return 0 end
  local p, now, n = pstate(K), K.now().tick, 0
  p.vac = json.object(type(p.vac) == 'table' and p.vac or {})
  st.offices = {}
  for _, pos in ipairs(M.POSITIONS) do
    if vac[pos.code] then
      local since = math.tointeger(p.vac[pos.code]) or now
      p.vac[pos.code] = since
      local o = {n = vac[pos.code], since = since}
      st.offices[pos.code] = o
      local best, bscore
      for _, id in ipairs(cu.ids) do
        local u = df.unit.find(id)
        if u and dfhack.units.isAdult(u) and u.military.squad_id < 0 then
          local score = skill_score(u, pos.skills) * 10 - (held[u.hist_figure_id] and 1000 or 0)
          if not bscore or score > bscore then best, bscore = u, score end
        end
      end
      if best then
        o.cand = best.id
        local aok, res = K.act.appoint(pos.code, best.id)
        if aok then
          held[best.hist_figure_id] = true
          n = n + 1
          st.offices[pos.code], p.vac[pos.code] = nil, nil
          K.log('info', '%s appointed: unit %d (%s)', pos.code, best.id, dfhack.df2utf(dfhack.units.getReadableName(best)))
        else
          o.why = tostring(res):sub(1, 60)
        end
      else
        o.why = 'no adult citizen outside the squads'
      end
    else
      p.vac[pos.code] = nil
    end
  end
  return n
end

-- BUG-055: the offices that stand vacant (flags.ACTIVE, a vacant assignment) after the last daily pass, longest first:
-- {{code, n, days, cand, why}} (cand = the best candidate's unit id, why = why the appointment did not happen);
-- an old kernel state or no pass yet: {}. Read by readiness (R0 blocker `office`), status, inspect offices
function M.offices(K)
  local out, now = {}, K.now().tick
  for code, o in pairs(st.offices or {}) do
    out[#out + 1] = {code = code, n = o.n, days = math.max(0, (now - o.since) // DAY), cand = o.cand, why = o.why}
  end
  table.sort(out, function(a, b)
    if a.days ~= b.days then return a.days > b.days end
    return a.code < b.code
  end)
  return out
end

-- BUG-117 (Run 14 note 92: 151 of 453 citizen deaths were failed strange moods, the Loom was missing for a while): the 12
-- moodable workshop types a strange mood can claim (runner.MOODABLE, dfpilot/bp/rooms.py MOODABLE_TYPES; tests mirror them)
-- and the ones missing on the map now. A built Magma Forge stands for the Metalsmith's Forge and a built Magma Glass
-- Furnace for the Glass Furnace (a mood claims either). nil from `mood_from_phase` on only (before it the plan builds
-- the shops itself) or when the buildings are unreadable. queued[type] = the pending `workshops` project that lists the
-- type ({id, stage, pct, halted}; M.fishery_proj, read-only). Read by readiness (R0 `mood_ws`) and care (MOOD_RISK fix)
M.MOOD_SHOPS = {'Carpenters', 'Masons', 'Craftsdwarfs', 'Jewelers', 'MetalsmithsForge', 'Bowyers', 'Clothiers',
                'Leatherworks', 'Tanners', 'Loom', 'GlassFurnace', 'Mechanics'}
M.MOOD_ALT = {MetalsmithsForge = 'MagmaForge', GlassFurnace = 'MagmaGlassFurnace'}
-- BUG-486 (Run 16d i4 Trumpetrealms y375: 'mood shops missing 45 days', a Secretive mood at phase P0 got no PROJECT_REQUEST: the typed
-- request needs this answer, and the plan's P1 waited for the very shops): `now` (a strange mood is in the fort now, care passes it)
-- answers at any phase; the readiness blocker keeps the phase gate
function M.mood_shops(K, now)
  local c = M.conf(K)
  if now ~= true and not phase_ok(K, c.mood_from_phase or 'P1') then return nil end
  local have = {}
  local ok1 = pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      local n = df.workshop_type[b.type]
      if n and built(b) then have[n] = true end
    end
  end)
  local ok2 = pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.FURNACE_ANY) do
      local n = df.furnace_type[b.type]
      if n and built(b) then have[n] = true end
    end
  end)
  if not (ok1 and ok2) then return nil end
  local out = {missing = {}, queued = {}, gone = {}}
  local mg = type(K.manifest) == 'function' and K.manifest().gone or nil     -- BUG-722: shops the manifest lists as no longer standing
  local gone = {}
  for _, g in ipairs(type(mg) == 'table' and mg or {}) do if type(g) == 'table' and type(g.type) == 'string' then gone[g.type] = true end end
  for _, t in ipairs(M.MOOD_SHOPS) do
    if not have[t] and not (M.MOOD_ALT[t] and have[M.MOOD_ALT[t]]) then
      out.missing[#out.missing + 1] = t
      if gone[t] then out.gone[t] = true end
      local q = M.fishery_proj(K, {'workshop:' .. t})
      if q then out.queued[t] = q end
    end
  end
  return out
end

-- verb appoint {code, unit} (BUG-055, Run 14 note 61: `I.appoint` existed in act.lua but was no verb, the game session
-- replayed seat_figure by hand): the nobles screen's "choose a candidate" for a vacant, offered position. A soldier on
-- duty (squad member) is no candidate for any post but the militia's own (the commander and captain lead squads)
M.SQUAD_POSTS = {MILITIA_CAPTAIN = true, MILITIA_COMMANDER = true}
M.verbs.appoint = function(K, args, cmd)
  if type(args.code) ~= 'string' or not math.tointeger(args.unit) then return false, 'appoint needs {code, unit}' end
  local u = df.unit.find(args.unit)
  if not u then return false, 'no unit ' .. tostring(args.unit) end
  if not M.SQUAD_POSTS[args.code] and (u.military.squad_id or -1) >= 0 then
    return false, string.format('unit %d is a squad member: a soldier on duty is no candidate for %s', args.unit, args.code)
  end
  local p = pstate(K)
  local replace = nil
  if args.replace ~= nil then
    -- BUG-458: the post is taken from a holder who stands outside the fort (days counted by out_watch), not from a reachable one
    local okr = M.replace_ok(K, p, args.code)
    if okr ~= true then return false, 'appoint replace refused: ' .. okr end
    local holder = M.office_holder(K, args.code)
    if holder and holder.id == args.unit then return false, 'appoint replace refused: unit ' .. args.unit .. ' is the holder' end
    replace = true
  end
  local ok, res = K.act.appoint(args.code, args.unit, replace)
  if not ok then
    local why = tostring(res)
    if why:find('no vacant assignment', 1, true) and M.OUT_CODES[args.code] then
      local d, o = M.out_days(K, p, args.code)
      why = why .. string.format('; %s is alive%s', args.code, o and string.format(' and has stood outside the fort for %d days ' ..
                                 '(appoint with replace:true after %d days)', d, M.OUT_DAYS) or ' and among the citizens (no replacement)')
    end
    return false, 'appoint: ' .. why
  end
  if replace then
    p.out = nil
    K.log('warn', '%s taken from the holder outside the fort: unit %d appointed (appoint replace)', args.code, args.unit)
  end
  if type(p.vac) == 'table' then p.vac[args.code] = nil end
  if st.offices then st.offices[args.code] = nil end
  K.log('info', '%s appointed by verb: unit %d (assignment %s)', args.code, args.unit, tostring(res))
  return true, string.format('%s: unit %d appointed', args.code, args.unit), {assignment = res}
end

M.inspect.offices = function(K)
  local list = M.offices(K)
  local txt = {}
  for _, o in ipairs(list) do
    txt[#txt + 1] = string.format('%s vacant %d d%s%s', o.code, o.days, o.cand and (', candidate unit ' .. o.cand) or '',
                                  o.why and (' (' .. o.why .. ')') or '')
  end
  local okm, ls = K.call('military', 'leader_state')          -- the militia posts: military fills them with a squad
  ls = okm and type(ls) == 'table' and ls or nil
  if ls and ls.why then txt[#txt + 1] = 'squad leaders: ' .. ls.why end
  return true, #txt == 0 and 'offices: none vacant' or ('offices: ' .. table.concat(txt, '; ')),
         {offices = list, squads = ls,
          note = 'offices: vacant posts with flags.ACTIVE after the last daily pass (MANAGER, BOOKKEEPER, BROKER, '
                 .. 'CHIEF_MEDICAL_DWARF; fix: dfllm cmd appoint {code, unit}); squads: the militia posts as military sees '
                 .. 'them (active codes, vacant assignments without a squad, why the last squad creation failed; fix: '
                 .. 'dfllm cmd squad.create / squad.leader)'}
end

-- Manager orders that never get validated (live L1: the MANAGER position has required_office 1, so above
-- a population threshold the manager validates only from an office with a chair; DF posts no
-- ManageWorkOrders job otherwise). BUG-042 (Run 11, y471): the office zone stood without a chair and a table, 112 of
-- 446 orders (the brew orders among them) waited for months while the 334 older ones were validated, and the ratio
-- rule (< 10 % validated) never spoke. Now: the office's chair and table are checked daily (M.office_check) and any
-- order unvalidated for orders.unval_days while the manager could validate is DECISION_NEEDED manager_office with the
-- reason (M.unval_watch).
local function validation_watch(K, p, c)
  -- live L6: a new manager (the old one died or left) stood without an office; the office check runs every
  -- day for whoever is manager now, not only when no order was validated
  local now = K.now().tick
  if K.act.manager_office and now - (p.office_t or -DAY) >= DAY then
    p.office_t = now
    -- BUG-204 (live Earthboat: ACT_FAIL 'no free office zone' x39, one every 4-10 game days): a fort without a free
    -- Office zone is a state, not a failed action: said in kern.log once per 7 days and 10 min, the act is not tried
    local why = M.office_none(K)
    if why then
      if CAD.due(p.office_none, K.now(), {}, {why}, {ticks = 7 * DAY, wall_s = CAD.WALL_S})
         or CAD.elapsed(p.office_none, K.now(), 7 * DAY, CAD.WALL_S) then
        p.office_none = CAD.mark(K.now(), {}, {why})
        K.log('info', 'manager office: %s (the office template builds one: dfllm bp sites office; DF asks for it only ' ..
              'above its population line)', why)
      end
    else
      p.office_none = CAD.quiet(p.office_none)
      local okc, res = K.act.manager_office()
      if okc and res == 'assigned' then K.log('warn', 'manager had no office: free Office zone assigned') end
    end
    local oko, err = pcall(M.office_check, K, c, p)
    if not oko then K.log('warn', 'office check: %s', tostring(err)) end
  end
  local ow, owe = pcall(M.out_watch, K, p)             -- BUG-458: the holders of MANAGER / BROKER outside the walk group
  if not ow then K.log('warn', 'office holders out: %s', tostring(owe)) end
  if M.manager_watch(K, p, c) then p.uv, st.unval = nil, nil      -- Run 11: injured, in a mood, gone
  else M.unval_watch(K, p, c) end
  local okb, err = pcall(M.mgr_bypass, K, p, c)        -- BUG-231: the items the validation holds back, as workshop tasks
  if not okb then K.log('warn', 'manager bypass: %s', tostring(err)) end
end

-- BUG-204: why act.manager_office cannot help now ('no manager', 'no free office zone'), or nil (it has one, or a free
-- zone exists, or the zones are unreadable: the act decides). Read-only, the same reads as the act.
function M.office_none(K)
  local ok, why = pcall(function()
    local m = dfhack.units.getUnitByNobleRole('manager')
    if not m or dfhack.units.isDead(m) then return 'no manager' end
    for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
      if z.type == df.civzone_type.Office and (z.assigned_unit_id == m.id or z.assigned_unit_id == -1) then return nil end
    end
    return 'no free office zone'
  end)
  return ok and why or nil
end

-- BUG-042: the Office zone assigned to unit `uid` and the chairs and tables standing in it: {zone, box = {x1, y1, x2,
-- y2, z}, chair, table (built), chair_p, table_p (planned)}, or nil, 'no office zone'. Read-only (zones, buildings).
function M.in_zone(z, x, y, zz)
  if zz ~= z.z or x < z.x1 or x > z.x2 or y < z.y1 or y > z.y2 then return false end
  local fn = dfhack.buildings and dfhack.buildings.containsTile
  if not fn then return true end
  local ok, yes = pcall(fn, z, x, y)
  return not ok or yes == true
end
function M.office_of(K, uid)
  local zone
  for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
    if z.type == df.civzone_type.Office and z.assigned_unit_id == uid then zone = z; break end
  end
  if not zone then return nil, 'no office zone' end
  local rec = {zone = zone.id, box = {zone.x1, zone.y1, zone.x2, zone.y2, zone.z}, chair = 0, table = 0, chair_p = 0,
               table_p = 0, zobj = zone}
  for kind, vec in pairs({chair = 'CHAIR', table = 'TABLE'}) do
    for _, b in ipairs(df.global.world.buildings.other[vec]) do
      if M.in_zone(zone, b.x1 or b.centerx or -1, b.y1 or b.centery or -1, b.z) then
        if built(b) then rec[kind] = rec[kind] + 1 else rec[kind .. '_p'] = rec[kind .. '_p'] + 1 end
      end
    end
  end
  return rec
end

-- BUG-042: free floor tiles of the office zone (revealed floor, no building or planned one, no designation), the first
-- n; the second next to the first when one is (the chair beside its table, as the live fix)
function M.office_spots(K, c, rec, n)
  local x1, y1, x2, y2, z = table.unpack(rec.box)
  local out, reads = {}, 0
  local lim = math.tointeger(((c.office or {}).max_tiles)) or 400
  local find = dfhack.buildings and dfhack.buildings.findAtTile
  for y = y1, y2 do
    for x = x1, x2 do
      reads = reads + 1
      if reads > lim then break end
      if M.in_zone(rec.zobj, x, y, z) then
        local okt, t = K.call('snapshot', 'tile', x, y, z)
        local free = okt and type(t) == 'table' and t.c == '.' and (t.bld or '') == '' and (t.dig or '') == ''
        if free and find then
          local okb, b = pcall(find, x, y, z)
          free = okb and b == nil
        end
        if free then out[#out + 1] = {x, y, z} end
      end
    end
  end
  if #out >= 2 and n >= 2 then
    local a = out[1]
    for k = 2, #out do
      local q = out[k]
      if math.max(math.abs(q[1] - a[1]), math.abs(q[2] - a[2])) == 1 then out[2], out[k] = q, out[2]; break end
    end
  end
  return {table.unpack(out, 1, math.min(n, #out))}
end

-- BUG-396 (Run 16a i1 Bachwald: no office for 294 days, 7 brews and 18 orders unvalidated, drink 0): with no Office zone
-- for the manager and manager orders waiting, the kernel asks for the office itself (PROJECT_REQUEST office why=office, which
-- follow places: the dug template with a core, the surface one without), at most every 7 days; the brews are life.
function M.office_request(K, p)
  local u = st.unval
  if type(u) ~= 'table' or (math.tointeger(u.n) or 0) <= 0 then return end
  local now = K.now().tick
  if now - (math.tointeger(p.office_req) or -7 * DAY) < 7 * DAY then return end
  p.office_req = now
  local b = type(st.brew) == 'table' and st.brew or {}
  local msg = string.format('manager office: none stands and %d manager orders wait%s: an office is requested (surface when ' ..
                            'the fort has no dug core)', math.tointeger(u.n) or 0,
                            (b.unval or 0) > 0 and string.format(' (%d brews)', b.unval) or '')
  K.log('warn', '%s', msg)
  K.emit('PROJECT_REQUEST', 'B', msg:sub(1, 200), {tpl = 'office', n = 1, why = 'office'})
  K.persist.touch('m.economy')
end

-- BUG-042 (daily, from validation_watch): the manager's office must hold a chair (and a table, office.table) to
-- validate work orders. A missing one (destroyed in a siege, never built) is placed on a free floor tile of the zone
-- through runner.repair (quickfort #build: the player's build designation; buildingplan waits for the item, T.jmake
-- orders it), at most every office.retry_days per office; kern.log and MANAGER_OFFICE (B) name it. st.office = what
-- the reasons and texts say (why: 'manager office 18631 has no chair, no table'), nil when the office is complete.
function M.office_check(K, c, p)
  local oc = c.office or M.DEFAULTS.office
  st.office = nil
  local mg = M.manager_state(K)
  if type(mg) ~= 'table' or not mg.unit then return end           -- no manager (appoint) or gone (manager_watch)
  local rec = M.office_of(K, mg.unit)
  if not rec then
    -- BUG-233: the reason the status line shows ('manager: N orders unvalidated for D days: no office ...')
    st.office = {why = 'no office (chair+table needed)', fix = 'an Office zone with a chair and a table for him ' ..
                 '(bp.place office, p.surface=1 without a dug core: dfllm bp sites office surface=1 --fresh; the kernel ' ..
                 'adds chair and table as workshop tasks)', none = true}
    local okz, zerr = pcall(M.office_zone, K, c, p)
    if not okz then K.log('warn', 'office zone: %s', tostring(zerr)) end
    local okr, rerr = pcall(M.office_request, K, p)
    if not okr then K.log('warn', 'office request: %s', tostring(rerr)) end
    return
  end
  local o = type(p.office) == 'table' and p.office or nil
  local nob, miss = {}, {}                          -- kinds not built; not built and not planned either
  for _, kind in ipairs({'chair', 'table'}) do
    if (kind == 'chair' or oc.table ~= false) and rec[kind] == 0 then
      nob[#nob + 1] = kind
      if rec[kind .. '_p'] == 0 then miss[#miss + 1] = kind end
    end
  end
  if #nob == 0 then
    if o then K.log('info', 'manager office %d: chair and table stand', rec.zone); p.office = nil end
    return
  end
  local why = string.format('manager office %d has no %s', rec.zone, table.concat(nob, ', no '))
  st.office = {zone = rec.zone, why = why, at = o and o.zone == rec.zone and o.at ~= '' and o.at or nil}
  if #miss == 0 then                                  -- placed: buildingplan waits for the items and a builder
    local inv, none = K.census.i or {}, {}
    for _, kind in ipairs(nob) do if (math.tointeger(inv[kind .. 's']) or 0) == 0 then none[#none + 1] = kind end end
    -- BUG-233: no 'by hand' (a player without clicks cannot): the kernel adds the task itself (M.mgr_bypass)
    st.office.fix = #none > 0 and string.format('not built: no free %s; the kernel adds it as a workshop task',
                                                table.concat(none, ', no '))
                    or 'not built yet (buildingplan waits for a builder)'
    return
  end
  local now = K.now().tick
  if o and o.zone == rec.zone and now - (math.tointeger(o.t) or 0) < (oc.retry_days or 7) * DAY then return end
  local spots = M.office_spots(K, c, rec, #miss)
  if #spots < #miss then
    st.office.fix = string.format('no free floor tile in office %d (%d,%d-%d,%d z%d): a chair and a table in it by hand',
                                  rec.zone, rec.box[1], rec.box[2], rec.box[3], rec.box[4], rec.box[5])
    if not o or o.zone ~= rec.zone or o.at ~= '' then
      p.office = {zone = rec.zone, t = now, at = ''}
      K.log('warn', '%s: %s', why, st.office.fix)
      K.emit('MANAGER_OFFICE', 'B', (why .. ': ' .. st.office.fix):sub(1, 200),
             {zone = rec.zone, chair = rec.chair, table = rec.table, why = why:sub(1, 80)})
    end
    return
  end
  local cells, at = {}, {}
  for k, kind in ipairs(miss) do
    local q = spots[k]
    cells[#cells + 1] = {q[1], q[2], q[3], kind == 'chair' and 'c' or 't'}
    at[#at + 1] = string.format('%s at %d,%d,%d', kind, q[1], q[2], q[3])
  end
  local okr, r1, r2 = K.call('runner', 'repair', cells, why)
  if not (okr and r1) then
    st.office.fix = 'not placed: ' .. tostring(r2 or r1)
    K.log('warn', '%s: %s', why, st.office.fix)
    return
  end
  local placed = table.concat(at, ', ')
  p.office = {zone = rec.zone, t = now, at = placed, proj = tostring(r2 or '')}
  st.office.at = placed
  K.persist.touch('m.economy')
  K.log('warn', '%s: %s placed (%s)', why, placed, tostring(r2 or ''))
  K.emit('MANAGER_OFFICE', 'B', string.format('%s: %s placed (%s)', why, placed, tostring(r2 or '')):sub(1, 200),
         {zone = rec.zone, chair = rec.chair, table = rec.table, placed = placed:sub(1, 80), proj = tostring(r2 or ''),
          why = why:sub(1, 80)})
end

-- BUG-572 (Run 16b i2 Brotherarrow y406: the manager sat in the refuge for 48 days validating nothing, nine orders open, no meals
-- cooked, `inspect manager`: 'nothing the kernel can read is wrong'; his office zone lay outside Tiefe+): the civ alert sounds, the
-- unit stands in one of its burrows and no tile of his office zone lies in any of them. Returns the alert burrows' names, else nil.
function M.office_gap(zobj, u)
  local ok, res = pcall(function()
    local idx = df.global.plotinfo.alerts.civ_alert_idx
    if not idx or idx == 0 then return nil end
    local ids = {}
    for _, id in ipairs(df.global.plotinfo.alerts.list[idx].burrows) do ids[id] = true end
    local names, bs = {}, {}
    for _, b in ipairs(df.global.plotinfo.burrows.list) do
      if ids[b.id] then names[#names + 1] = tostring(b.name); bs[#bs + 1] = b end
    end
    if #bs == 0 then return nil end
    local held = false
    for _, b in ipairs(bs) do
      if dfhack.burrows.isAssignedTile(b, {x = u.pos.x, y = u.pos.y, z = u.pos.z}) then held = true end
    end
    if not held then return nil end                       -- the alert does not hold him
    for y = zobj.y1, zobj.y2 do
      for x = zobj.x1, zobj.x2 do
        if M.in_zone(zobj, x, y, zobj.z) then
          for _, b in ipairs(bs) do
            if dfhack.burrows.isAssignedTile(b, {x = x, y = y, z = zobj.z}) then return nil end
          end
        end
      end
    end
    table.sort(names)
    return names
  end)
  return ok and type(res) == 'table' and res or nil
end

-- BUG-042: why an available manager validates nothing: the office (st.office) and its fix tail, else the manager by
-- name. BUG-572: first the civ alert that holds him away from his office
function M.unval_why(K)
  local mg0 = M.manager_state(K)
  if type(mg0) == 'table' and mg0.unit then
    local u0, rec0 = df.unit.find(mg0.unit), M.office_of(K, mg0.unit)
    local names = u0 and rec0 and M.office_gap(rec0.zobj, u0)
    if names then
      return string.format('the civ alert holds the manager in %s and his office zone %d lies outside it', table.concat(names, '+'),
                           rec0.zone),
             ': an office inside it (dfllm cmd zone.place type=office there, with chair and table), or the alert widened (siege_starve relief)'
    end
  end
  local o = st.office
  if type(o) == 'table' and o.why then
    local tail = (o.at and (': ' .. o.at .. ' placed') or '') .. (o.fix and ((o.at and '; ' or ': ') .. o.fix) or '')
    return o.why, tail
  end
  local mg = M.manager_state(K)
  local who = type(mg) == 'table' and mg.name and ('manager ' .. mg.name) or 'the manager'
  return who .. ' validates nothing (his office has a chair and a table)', ': inspect the manager (job, path to the office)'
end

-- BUG-458 (Run 16d Orbblock y377: the seal's walls left the manager (and the broker) outside, `appoint code=MANAGER` said 'MANAGER
-- has no vacant assignment', nothing was validated for 145 days): once a day the holders of MANAGER and BROKER are read; one who
-- stands on a walk group that is none of the citizens' home groups (snapshot.far) keeps p.out[code] = {since, unit, x, y, z};
-- standing among the citizens again clears it. appoint {replace = true} takes the post from a holder who has been outside for
-- M.OUT_DAYS days (M.replace_ok) and gives it to a citizen who is not; manager_stuck names the case and the command.
M.OUT_DAYS = 7
M.OUT_CODES = {MANAGER = true, BROKER = true}
function M.office_holder(K, code)
  local ent = df.global.plotinfo.main.fortress_entity
  local pid
  for _, ps in ipairs(ent.positions.own) do if ps.code == code and ps.flags.ACTIVE then pid = ps.id end end
  if not pid then return nil end
  local hf
  for _, a in ipairs(ent.positions.assignments) do
    if a.position_id == pid and (a.histfig or -1) >= 0 then hf = a.histfig end
  end
  if not hf then return nil end
  local cu = K.census.u
  for _, id in ipairs(type(cu) == 'table' and cu.ids or {}) do
    local u = df.unit.find(id)
    if u and u.hist_figure_id == hf then return u, hf end
  end
  local h = df.historical_figure.find(hf)
  local u = h and df.unit.find(h.unit_id) or nil
  if u and not dfhack.units.isDead(u) then return u, hf end
end
function M.out_watch(K, p)
  p.out = type(p.out) == 'table' and p.out or {}
  local now = K.now().tick
  for code in pairs(M.OUT_CODES) do
    local u = M.office_holder(K, code)
    local x, y, z
    if u then x, y, z = dfhack.units.getPosition(u) end
    local okf, far = false, false
    if x then okf, far = K.call('snapshot', 'far', x, y, z) end
    if x and okf and far == true then
      local o = type(p.out[code]) == 'table' and p.out[code] or {since = now}
      o.unit, o.x, o.y, o.z = u.id, x, y, z
      p.out[code] = o
    else
      p.out[code] = nil
    end
  end
  if next(p.out) == nil then p.out = nil end
end
-- the days the holder of `code` has stood outside (0 = not outside, or not known), and the record
function M.out_days(K, p, code)
  local o = type(p.out) == 'table' and p.out[code] or nil
  if type(o) ~= 'table' then return 0, nil end
  return math.max(0, (K.now().tick - (math.tointeger(o.since) or K.now().tick)) // DAY), o
end
-- true when `code`'s holder may be replaced (outside for M.OUT_DAYS days), else the reason it may not
function M.replace_ok(K, p, code)
  if not M.OUT_CODES[code] then return 'only MANAGER and BROKER can be replaced' end
  local d, o = M.out_days(K, p, code)
  if not o then return code .. ' lives and stands among the citizens (or his place is not known): nobody is replaced' end
  if d < M.OUT_DAYS then
    return string.format('%s has stood outside for %d of %d days', code, d, M.OUT_DAYS)
  end
  return true
end
-- a citizen who could take the post: adult, no squad, not outside (snapshot.far), not `skip`; the best ORGANIZATION skill
function M.reachable_candidate(K, skip)
  local best, bscore
  for _, id in ipairs(type(K.census.u) == 'table' and K.census.u.ids or {}) do
    local v = df.unit.find(id)
    if v and id ~= skip and M.citizen(v) and dfhack.units.isAdult(v) and (v.military.squad_id or -1) < 0 then
      local x, y, z = dfhack.units.getPosition(v)
      local okf, far = false, false
      if x then okf, far = K.call('snapshot', 'far', x, y, z) end
      if x and not (okf and far == true) then
        local sc = skill_score(v, {'ORGANIZATION'})
        if not bscore or sc > bscore then best, bscore = id, sc end
      end
    end
  end
  return best
end

-- BUG-499 (Run 16b i2 Roadvises y373 / Run 16a i1 Syrupobeyed y386: 188 open orders, 93 hanging, 30 brews unvalidated, the manager 'validates
-- nothing (his office has a chair and a table)' and the one question left, 'inspect the manager (job, path to the office)', had no command):
-- everything the kernel can read about why a manager validates nothing, in one table: {state (manager_state), unit, job, pos, squad, mood,
-- out (days outside the citizens' walk group), office {zone, box, chair, table, assigned, walk (a walking path from him to the zone),
-- required (DF's room value for the post)}, orders {n, d (days), brews, jobs (ManageWorkOrders jobs in the world and their workers)},
-- causes = {the findings that explain it, most likely first}, next = {the commands}}. Read only.
function M.manager_facts(K, p, c)
  local oc = (c or M.conf(K)).office or M.DEFAULTS.office
  local f = {causes = {}, next = {}, office = json.object{}, orders = json.object{}}
  local mg = M.manager_state(K)
  if type(mg) ~= 'table' then
    f.causes[1] = 'no MANAGER post is open in the fortress (the nobles screen: the mandate/appointment of a manager)'
    return f
  end
  f.state, f.name, f.unit = mg.why, mg.name, mg.unit
  if mg.why then f.causes[#f.causes + 1] = mg.why end
  local un = st.unval or {}
  f.orders.n, f.orders.d = math.tointeger(un.n) or 0, math.tointeger(un.d) or 0
  f.orders.brews = math.tointeger((st.brew or {}).unval) or 0
  if not mg.unit then return f end
  local u = df.unit.find(mg.unit)
  if not u then return f end
  pcall(function()
    local j = u.job and u.job.current_job
    f.job = j and df.job_type[j.job_type] or 'none'
    f.squad = (u.military.squad_id or -1) >= 0 and u.military.squad_id or nil
    f.mood = (u.mood or -1) >= 0 and u.mood or nil
    f.pos = {u.pos.x, u.pos.y, u.pos.z}
  end)
  if f.squad then f.causes[#f.causes + 1] = 'he is in squad ' .. tostring(f.squad) .. ': soldiers on duty do not walk to the office' end
  if f.job == 'HarvestPlants' or f.job == 'PlantSeeds' or f.job == 'GatherPlants' then      -- BUG-547
    f.causes[#f.causes + 1] = 'he works as a farmer (' .. f.job .. '): the kernel switches his Farming labor off while orders wait'
  end
  local outd, outrec = M.out_days(K, p or pstate(K), 'MANAGER')
  if outrec then
    f.out = outd
    f.causes[#f.causes + 1] = string.format('he stands outside the walk group of the citizens (%d days): the walls shut him out', outd)
    f.next[#f.next + 1] = 'dfllm cmd inspect what=reach'
  end
  local rec, nz = M.office_of(K, mg.unit)
  if not rec then
    f.office.zone = nz
    f.causes[#f.causes + 1] = 'no Office zone is assigned to him (bp.place office, p.surface=1 without a dug core)'
    f.next[#f.next + 1] = 'dfllm cmd zone.place type=office'
  else
    f.office.zone, f.office.box, f.office.chair, f.office.table = rec.zone, rec.box, rec.chair, rec.table
    f.office.chair_p, f.office.table_p = rec.chair_p, rec.table_p
    local gap = M.office_gap(rec.zobj, u)                    -- BUG-572
    if gap then
      f.causes[#f.causes + 1] = string.format('the civ alert holds him in %s and his office zone %d lies outside it', table.concat(gap, '+'),
                                              rec.zone)
      f.next[#f.next + 1] = 'dfllm cmd zone.place type=office (inside the alert burrow, with chair and table)'
    end
    if rec.chair == 0 then f.causes[#f.causes + 1] = string.format('office %d has no chair (%d planned)', rec.zone, rec.chair_p) end
    if oc.table ~= false and rec.table == 0 then
      f.causes[#f.causes + 1] = string.format('office %d has no table (%d planned)', rec.zone, rec.table_p)
    end
    local okw, walk = pcall(function()
      local z = rec.zobj
      local ux, uy, uz = u.pos.x, u.pos.y, u.pos.z
      local tried = 0
      for y = z.y1, z.y2 do
        for x = z.x1, z.x2 do
          tried = tried + 1
          if tried <= 60 and M.in_zone(z, x, y, z.z) then
            local ok2, can = K.call('snapshot', 'reach', {x = ux, y = uy, z = uz}, {x = x, y = y, z = z.z})
            if ok2 and can == true then return true end
            if ok2 and can == false then f.office.unreached = (f.office.unreached or 0) + 1 end
          end
        end
      end
      return f.office.unreached ~= nil and false or nil
    end)
    if okw then f.office.walk = walk end
    if f.office.walk == false then
      f.causes[#f.causes + 1] = string.format('no walking path from him (%d,%d,%d) to office %d: a wall, a locked door or a burrow cuts it',
                                              f.pos and f.pos[1] or -1, f.pos and f.pos[2] or -1, f.pos and f.pos[3] or -1, rec.zone)
      f.next[#f.next + 1] = 'dfllm cmd inspect what=reach'
    end
    pcall(function()
      local ok2, txt = pcall(dfhack.buildings.getRoomDescription, rec.zobj, u)
      if ok2 and type(txt) == 'table' then
        local parts = {}
        for _, l in ipairs(txt) do parts[#parts + 1] = tostring(l) end
        f.office.room = table.concat(parts, ' '):sub(1, 120)
      elseif ok2 and type(txt) == 'string' then f.office.room = txt:sub(1, 120) end
    end)
  end
  pcall(function()
    local ent = df.global.plotinfo.main.fortress_entity
    for _, pp in ipairs(ent.positions.own) do
      if pp.code == 'MANAGER' and math.tointeger(pp.required_office) then f.office.required = pp.required_office end
    end
  end)
  -- the jobs of the post (DF posts ManageWorkOrders for a manager in a fit office), with the worker
  pcall(function()
    local jt = df.job_type.ManageWorkOrders
    if not jt then return end
    local n, mine, link, i = 0, 0, df.global.world.jobs.list.next, 0
    while link and i < 20000 do
      local j = link.item
      if j and j.job_type == jt then
        n = n + 1
        if dfhack.job.getWorker(j) == u then mine = mine + 1 end
      end
      link, i = link.next, i + 1
    end
    f.orders.mjobs, f.orders.mjobs_his = n, mine
  end)
  if #f.causes == 0 and f.orders.n > 0 then
    local rq = f.office.required
    f.causes[1] = 'nothing the kernel can read is wrong' .. (rq and rq > 0 and string.format(' (DF asks the office for room value %d: a bigger, '
                  .. 'furnished office zone, dfllm cmd zone.place type=office)', rq) or '')
    f.next[#f.next + 1] = 'dfllm cmd zone.place type=office'
  end
  f.next[#f.next + 1] = 'dfllm cmd inspect what=orders'
  return f
end

M.inspect.manager = function(K)
  local f = M.manager_facts(K, pstate(K), M.conf(K))
  local o = f.orders or {}
  local head = string.format('manager %s%s: %s%s%s; %d orders unvalidated%s%s', f.name or '?', f.unit and (' unit ' .. f.unit) or '',
                             f.job and ('job ' .. f.job) or 'no unit', f.pos and string.format(' at %d,%d,%d', f.pos[1], f.pos[2], f.pos[3]) or '',
                             f.office.zone and (type(f.office.zone) == 'number' and (', office zone ' .. f.office.zone) or (', ' .. f.office.zone)) or '',
                             o.n or 0, (o.d or 0) > 0 and string.format(' for %d d', o.d) or '',
                             (o.brews or 0) > 0 and string.format(' (%d brews)', o.brews) or '')
  return true, (head .. '; ' .. (#f.causes > 0 and ('cause: ' .. table.concat(f.causes, '; ')) or 'no cause found')):sub(1, 1000), f
end

-- BUG-450 (Run 16a i1 Syrupobeyed y386: the manager validated nothing for 149 days, 35 orders, brewing and cooking stopped, drink 291 -> 123 days;
-- `inspect offices` said 'none vacant', his office had a chair and a table, zone.place was locked in SIEGE): orders unvalidated for
-- orders.mgr_stuck_days with a manager who is able (manager_watch said nothing) and a complete office (st.office nil) are
-- DECISION_NEEDED manager_stuck (A, util/cadence: again after mgr_stuck_days): what he is doing and where, his squad, the office zone
-- and what DF asks of it (position.required_office), a candidate for the nobles screen, and the commands that look at him; zone.place
-- type=office is allowed in SIEGE (a second office zone for him). The kernel replaces nobody: the nobles screen's removal is the player's.
function M.mgr_stuck(K, p, c, days, n, why)
  local lim = math.tointeger(((c or {}).orders or M.DEFAULTS.orders).mgr_stuck_days) or 5
  local outd, outrec = M.out_days(K, p, 'MANAGER')                  -- BUG-458: he stands outside the fort
  if lim <= 0 or st.office then return end
  if days < lim and not (outrec and outd >= M.OUT_DAYS) then return end
  local mg = M.manager_state(K)
  if type(mg) ~= 'table' or not mg.unit or mg.why then return end
  local now = K.now()
  if not CAD.due(p.mstuck, now, {mg.hf}, {}, {ticks = lim * DAY, wall_s = CAD.WALL_S}) then return end
  p.mstuck = CAD.mark(now, {mg.hf}, {})
  local u = df.unit.find(mg.unit)
  local facts = {}
  local okj, jn = pcall(function()
    local j = u.job and u.job.current_job
    return j and df.job_type[j.job_type] or nil
  end)
  facts[#facts + 1] = okj and jn and ('job ' .. jn) or 'no job'
  local okp, x, y, z = pcall(function() return u.pos.x, u.pos.y, u.pos.z end)
  if okp then facts[#facts + 1] = string.format('at %d,%d,%d', x, y, z) end
  local rec = M.office_of(K, mg.unit)
  if rec then facts[#facts + 1] = string.format('office zone %d at %d,%d z%d', rec.zone, rec.box[1], rec.box[2], rec.box[5]) end
  local okr, req = pcall(function()
    local ent = df.global.plotinfo.main.fortress_entity
    for _, pp in ipairs(ent.positions.own) do if pp.code == 'MANAGER' then return pp.required_office end end
  end)
  if okr and math.tointeger(req) and req > 0 then facts[#facts + 1] = 'DF asks the office for room value ' .. req end
  local best, bscore
  if outrec then best = M.reachable_candidate(K, mg.unit)             -- BUG-458: one who is not outside himself
  else
    for _, id in ipairs(type(K.census.u) == 'table' and K.census.u.ids or {}) do
      local v = df.unit.find(id)
      if v and id ~= mg.unit and M.citizen(v) and dfhack.units.isAdult(v) and (v.military.squad_id or -1) < 0 then
        local sc = skill_score(v, {'ORGANIZATION'})
        if not bscore or sc > bscore then best, bscore = id, sc end
      end
    end
  end
  local q = string.format('manager %s validates nothing for %d days (%d orders, brews %s) with a complete office: %s%s', mg.name, days, n,
                          (st.brew or {}).unval and tostring(st.brew.unval) or '?', table.concat(facts, ', '),
                          best and ('; acting manager candidate unit ' .. best) or '')
  if outrec then                                    -- BUG-458: the case in one line (d.q is 200 bytes at most)
    q = string.format('manager %s OUTSIDE the fort for %d days (off the main walk group), %d orders unvalidated%s',
                      mg.name, outd, n, best and ('; reachable candidate unit ' .. best) or '')
  end
  -- BUG-499: the first finding of `inspect what=manager` in the question, and that command first
  local okf, fx = pcall(M.manager_facts, K, p, c)
  local cause = okf and type(fx) == 'table' and fx.causes[1] or nil
  K.log('warn', '%s%s', q, cause and not outrec and ('; cause: ' .. cause) or '')
  local cmds = {'dfllm cmd inspect what=manager', 'dfllm cmd inspect what=unit key=' .. mg.unit, 'dfllm cmd inspect what=orders',
                'dfllm cmd inspect what=offices'}
  local replace
  if outrec and outd >= M.OUT_DAYS and best then
    -- BUG-458: outside for days: a reachable citizen takes the post (appoint replace), the first command
    replace = string.format('dfllm cmd appoint \'{"code":"MANAGER","unit":%d,"replace":true}\'', best)
    table.insert(cmds, 1, replace)
  elseif outrec then
    table.insert(cmds, 1, 'dfllm cmd inspect what=reach')
  end
  K.emit('DECISION_NEEDED', 'A', q:sub(1, 200), {id = 'manager_stuck', q = q:sub(1, 200), n = n, days = days,
         units = {mg.unit}, cmds = cmds, out = outrec and outd or nil, replace = replace,
         cause = cause and not outrec and cause:sub(1, 200) or nil})     -- BUG-499: the first finding of inspect what=manager
  K.persist.touch('m.economy')
end

-- BUG-547 (Run 16d i4 Trumpetrealms y397: the manager worked as HarvestPlants, "ConstructDoor unvalidated 14 days", the mechanisms and doors
-- of the refuge waited behind him): the orders are unvalidated past orders.unval_days and the manager (able, not a patient or in a mood) has
-- the Farming labor on: it goes off for him (act.labor_set, the labors screen), at most once a day; the work details give it back to the
-- others only. The first line of `inspect what=manager` names it while it stands.
function M.labor_flag(u, name)                       -- a labor of the labors screen is on (by enum index, else by name)
  local ok, v = pcall(function()
    local l = df.unit_labor and df.unit_labor[name]
    return u.status.labors[l or name]
  end)
  return ok and v == true
end

function M.manager_farm_off(K, p)
  local mg = M.manager_state(K)
  if type(mg) ~= 'table' or not mg.unit or mg.why then return end
  local u = df.unit.find(mg.unit)
  if not (u and M.labor_flag(u, 'PLANT')) then return end
  local now = K.now().tick
  if now - (math.tointeger(p.mgr_farm) or -DAY) < DAY then return end
  p.mgr_farm = now
  local ok, res = K.act.labor_set(mg.unit, 'farm', false)
  if ok and res == 'disabled' then
    K.persist.touch('m.economy')
    K.log('warn', 'manager %s (unit %d): Farming labor off: %d orders unvalidated, a manager at the fields validates none',
          mg.name or '?', mg.unit, (st.unval or {}).n or 0)
  end
end

-- BUG-042: orders waiting for validation by age (the 8 lowest order ids, first seen in p.uv): any unvalidated one for
-- orders.unval_days while a manager is appointed and able (manager_watch said nothing) is DECISION_NEEDED
-- manager_office (A, util/cadence: once per reason, again after 7 days and 10 min); st.unval = {n, d, why}
function M.unval_watch(K, p, c)
  local oc = c.orders or M.DEFAULTS.orders
  local now = K.now()
  local ids = {}
  for _, o in ipairs(orders_all()) do
    local okv, valid = pcall(function() return o.status.validated end)
    if okv and valid == false and (math.tointeger(o.amount_left) or 0) > 0 then ids[#ids + 1] = o.id end
  end
  table.sort(ids)
  local old = type(p.uv) == 'table' and p.uv or {}
  local uv, age = json.object{}, 0
  for k = 1, math.min(8, #ids) do
    local key = tostring(ids[k])
    local t = math.tointeger(old[key]) or now.tick
    uv[key] = t
    age = math.max(age, now.tick - t)
  end
  p.uv = #ids > 0 and uv or nil
  if #ids == 0 then
    if type(p.unval_ann) == 'table' and st.unval and st.unval.why then
      K.log('info', 'manager orders validated again')
    end
    st.unval = nil
    if type(p.unval_ann) == 'table' then p.unval_ann = CAD.quiet(p.unval_ann) end
    return
  end
  local days = age // DAY
  st.unval = {n = #ids, d = days}
  if days < (oc.unval_days or 2) then return end
  local okv, vac = pcall(positions)
  if not okv or type(vac) ~= 'table' or vac.MANAGER then return end   -- no manager yet: appoint first
  local okf, errf = pcall(M.manager_farm_off, K, p)                    -- BUG-547: a manager at the fields validates nothing
  if not okf then K.log('warn', 'manager farm labor: %s', tostring(errf)) end
  local why, fix = M.unval_why(K)
  st.unval.why = why
  local oks, errs = pcall(M.mgr_stuck, K, p, c, days, #ids, why)          -- BUG-450
  if not oks then K.log('warn', 'manager stuck: %s', tostring(errs)) end
  if not CAD.due(p.unval_ann, now, {}, {why}, {ticks = 7 * DAY, wall_s = CAD.WALL_S}) then return end
  p.unval_ann = CAD.mark(now, {}, {why})
  local b = st.brew or M.brew_orders()
  local brew = (b.unval or 0) > 0 and string.format(' (%d brews among them)', b.unval) or ''
  K.log('warn', '%d manager orders not validated for %d days%s: %s%s', #ids, days, brew, why, fix)
  K.emit('DECISION_NEEDED', 'A', string.format('%d manager orders not validated for %d days%s: %s', #ids, days, brew,
                                               why):sub(1, 200),
         {id = 'manager_office', q = (why .. fix):sub(1, 200)})
end

---------------------------------------------------------------- supply alarm, starved labors (live L1)
-- citizens over the thirst / hunger timers (looked up by id from the census, CONTRACTS Ã‚Â§1.4)
local function needs(K, a)
  local cu = K.census.u
  local thirsty, hungry = 0, 0
  for _, id in ipairs(type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}) do
    local u = df.unit.find(id)
    local cn = u and u.counters2
    if cn and M.citizen(u) then                    -- BUG-103: the census also holds residents; the alarm counts citizens
      if (cn.thirst_timer or 0) >= a.thirst then thirsty = thirsty + 1 end
      if (cn.hunger_timer or 0) >= a.hunger then hungry = hungry + 1 end
    end
  end
  return thirsty, hungry
end

-- BUG-344 review: text `s` in at most `max` lines of <= `n` bytes, broken at the last space (a word longer than `n` is
-- cut; the rest past `max` lines is dropped)
function M.lines(s, n, max)
  local out = {}
  s = tostring(s or '')
  while #s > 0 and #out < max do
    if #s <= n then out[#out + 1] = s; break end
    local cut = s:sub(1, n + 1):match('^.*() ')
    if not cut or cut <= 1 then cut = n + 1 end
    out[#out + 1] = s:sub(1, cut - 1)
    s = (s:sub(cut):gsub('^ +', ''))
  end
  return out
end

-- BUG-422 (Run 16d i4 Mazelanterns y386 autumn: citizen 26275 died of thirst 75000/hunger 87384 with 766 days of barrel
-- drink in the fort; the alarm needs alarm.units (2) citizens over the mark or low drink days, so no THIRSTY wake came and
-- the cause read 'unknown' for 4 days): ONE citizen over SOLO_THIRST (or SOLO_HUNGER) is a DECISION_NEEDED thirst_unit
-- (A) every SOLO_EVERY ticks while he stays over it, naming why he cannot drink (caged, unconscious, his job, idle, where
-- he stands) and the drink stock, with the commands that look at him. Dying alone looks like this: stranded, stuck on a
-- job, locked in, unconscious, a lever puller no one relieves
M.SOLO_THIRST, M.SOLO_HUNGER, M.SOLO_EVERY, M.SOLO_MAX = 50000, 70000, 3 * DAY, 5
M.try_squad = function(u) local ok, v = pcall(function() return u.military.squad_id end) return ok and v or nil end
function M.solo_check(K, p, days)
  local cu = K.census.u
  local now = K.now().tick
  local old = type(p.solo) == 'table' and p.solo or {}
  local nxt, rows = json.object{}, {}
  for _, id in ipairs(type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}) do
    local u = df.unit.find(id)
    local cn = u and u.counters2
    if cn and M.citizen(u) then
      local th, hu = cn.thirst_timer or 0, cn.hunger_timer or 0
      if th >= M.SOLO_THIRST or hu >= M.SOLO_HUNGER then
        local key = tostring(id)
        local last = math.tointeger(old[key])
        nxt[key] = last or now
        if (last == nil or now - last >= M.SOLO_EVERY) and #rows < M.SOLO_MAX then
          nxt[key] = now
          local why = {}
          if u.flags1 and u.flags1.caged then why[#why + 1] = 'caged' end
          local okc, unc = pcall(function() return u.counters.unconscious end)
          if okc and (unc or 0) > 0 then why[#why + 1] = 'unconscious' end
          local okj, jn = pcall(function()
            local j = u.job and u.job.current_job
            return j and df.job_type[j.job_type] or nil
          end)
          why[#why + 1] = okj and jn and ('job ' .. jn) or 'no job'
          -- BUG-451: a soldier on a station order does not leave it to eat; military's feed pass releases the squad
          if (M.try_squad(u) or -1) >= 0 then why[#why + 1] = 'squad member' end
          local okp, x, y, z = pcall(function() return u.pos.x, u.pos.y, u.pos.z end)
          rows[#rows + 1] = {id = id, th = th, hu = hu, why = table.concat(why, ', '),
                             pos = okp and {x, y, z} or nil}
        end
      end
    end
  end
  p.solo = next(nxt) ~= nil and nxt or nil
  if #rows == 0 then return 0 end
  -- BUG-509 (Run 16d i4: 24 strange-mood dwarves, children among them, died of thirst under this line with two inspect commands): the
  -- mood of such a unit (care's record: kind, what is short, the commands that can still help) goes into the text and the cmds
  for _, r in ipairs(rows) do
    local okm, mh = K.call('care', 'mood_help', r.id)
    if okm and type(mh) == 'table' then r.mood = mh end
  end
  local parts = {}
  for _, r in ipairs(rows) do
    local mt = ''
    if r.mood then
      mt = string.format(', strange mood %s%s: %s', tostring(r.mood.kind), r.mood.child and ' (child)' or '',
                         #r.mood.lack > 0 and ('short ' .. table.concat(r.mood.lack, ', ')) or 'nothing missing')
    end
    parts[#parts + 1] = string.format('%d (thirst %d, hunger %d, %s%s%s)', r.id, r.th, r.hu, r.why,
                                      r.pos and string.format(' at %d,%d,%d', r.pos[1], r.pos[2], r.pos[3]) or '', mt)
  end
  local q = string.format('%d citizen%s dehydrating or starving with drink %d d: %s', #rows, #rows == 1 and '' or 's',
                          days.drink_d, table.concat(parts, '; '))
  K.log('warn', 'solo thirst: %s', q)
  local cmds, moods = {}, {}
  for i, r in ipairs(rows) do
    if i <= 3 then cmds[#cmds + 1] = 'dfllm cmd inspect what=unit key=' .. r.id end
    if r.mood then
      moods[#moods + 1] = r.id
      for _, cm in ipairs(r.mood.cmds or {}) do
        local dup = false
        for _, x in ipairs(cmds) do if x == cm then dup = true end end
        if not dup and #cmds < 7 then cmds[#cmds + 1] = cm end
      end
    end
  end
  cmds[#cmds + 1] = 'dfllm cmd inspect what=reach'
  K.emit('DECISION_NEEDED', 'A', ('thirst_unit: ' .. q):sub(1, 200), {id = 'thirst_unit', q = q:sub(1, 200),
         units = (function() local l = {} for _, r in ipairs(rows) do l[#l + 1] = r.id end return l end)(), cmds = cmds,
         mood = #moods > 0 and moods or nil})
  return #rows
end

local function alarm_check(K, c, p, days)
  local a = c.alarm or M.DEFAULTS.alarm
  local okn, thirsty, hungry = pcall(needs, K, a)
  if not okn then thirsty, hungry = 0, 0 end
  -- BUG-259 (live Drillchamber: drink 0 days all year, DECISION_NEEDED thirst every 7 days with 0 thirsty, the dwarves
  -- drank at the brook): low drink days alone are no alarm while the thirst timers show the citizens drink water; the
  -- alarm and the thirst wake need one citizen past alarm.thirst (an unreadable census keeps the old rule)
  local dry = days.drink_d < a.days and (thirsty > 0 or not okn)
  -- BUG-391 (Run 16a Bachwald: 'nobody thirsty: they drink water' while 4 citizens on a cut-off walk group stood at thirst
  -- 34,937 and died): citizens siege found over the thirst mark on a group without drink are thirsty, whatever the
  -- others do; no all-clear then
  local okg, sd = K.call('siege', 'dry_group')
  if okg and type(sd) == 'table' and (math.tointeger(sd.n) or 0) > 0 then
    thirsty = math.max(thirsty, math.tointeger(sd.n))
    dry = dry or days.drink_d < a.days
  end
  -- BUG-401: no water the citizens reach and no brewable plant (no_water): low drink days are no 'they drink water'
  if st.nowater and days.drink_d < a.days then dry = true end
  local why
  if thirsty >= a.units then why = string.format('thirst %d', thirsty)
  elseif hungry >= a.units then why = string.format('hunger %d', hungry)
  elseif dry then why = string.format('drink %d d', days.drink_d)
  elseif days.food_d < a.days then why = string.format('food %d d', days.food_d) end
  if why ~= st.alarm then K.log(why and 'warn' or 'info', 'supply alarm %s', why or 'over') end
  if days.drink_d < a.days and not dry and not st.water then
    K.log('info', 'drink %d days but nobody thirsty: the citizens drink water (no supply alarm)', days.drink_d)
  end
  st.alarm, st.thirsty, st.hungry = why, thirsty, hungry
  pcall(M.solo_check, K, p, days)                  -- BUG-422: one dehydrating citizen is no 'units' crowd
  st.water = days.drink_d < a.days and not dry or nil
  local now = K.now().tick
  -- BUG-661 (Run 16c i3 Wallfree: this question every 7 days for 1-2 citizens at a stable thirst ~26,000 who drank at the cavern lake): one
  -- question per episode, again only when MORE citizens are thirsty than the last one announced; the episode is over once nothing was
  -- dry or thirsty for 30 days (p.thirst_seen)
  if thirsty >= a.units or dry then
    if now - (p.thirst_seen or -1e9) > 30 * DAY then p.thirst_ann = nil end
    p.thirst_seen = now
  end
  if (thirsty >= a.units or dry) and now - (p.thirst_woke or -1e9) >= 7 * DAY
     and (p.thirst_ann == nil or thirsty > p.thirst_ann) then
    p.thirst_woke, p.thirst_ann = now, thirsty
    -- BUG-344 (Run 15d Drillchamber y379-y397: this question 271 times, 37 dead of thirst, 13 beside well 18324): water
    -- says what its last run found (a well a thirsty citizen stands at, no accepted water: the recipe) with the commands
    local okw, wtxt, wcmds = K.call('water', 'drink_fix')
    local wq = okw and type(wtxt) == 'string' and wtxt or 'water near the fort (well)'
    local cmds = okw and type(wcmds) == 'table' and wcmds or {}
    -- brewing needs plants (BUG-340); BUG-344 review: a surface farm only in PEACE (BUG-341's rule), else the farm room
    if #cmds < 8 then cmds[#cmds + 1] = K.mode() == 'PEACE' and M.FOOD_CMD.farms or M.FOOD_CMD.farms_room end
    -- BUG-344 review: no coordinate is cut off: q is the whole text when it fits, else the head with the text's first
    -- part; d.water is the whole text in lines of <= 200 bytes broken at spaces (a position x,y,z holds none)
    local head = string.format('%d thirsty, drink %d d (brew: farms, barrels): ', thirsty, days.drink_d)
    local q = head .. wq
    if #q > 200 then
      local first = wq:match('^[^;]*')
      q = #head + #first + 15 <= 200 and (head .. first .. '; see d.water') or (head .. 'see d.water')
    end
    K.emit('DECISION_NEEDED', 'A', string.format('thirst: %d citizens thirsty, drink %d days', thirsty, days.drink_d),
           {id = 'thirst', q = q, water = M.lines(wq, 200, 2), cmds = cmds})
  end
end

-- labormanager list: "BREWER: managed (starved 243 cycles)", "MINE: unmanaged (starved 1384 cycles)"
function M.parse_labor_list(out)
  local r = {}
  for line in tostring(out or ''):gmatch('[^\r\n]+') do
    local labor, mode = line:match('^([A-Z_0-9]+): (u?n?managed)')
    if labor then
      r[labor] = {managed = mode == 'managed', starved = math.tointeger(tonumber(line:match('starved ([0-9]+) cycles') or '0')) or 0}
    end
  end
  return r
end

local function labor_fix(K, c, p, engine)
  local lc = c.labor or M.DEFAULTS.labor
  if engine ~= 'modern' then return 0 end
  local ok, out = K.act.run('labormanager', 'list')
  if not ok then return 0 end
  local list, builtin, n, fallback = M.parse_labor_list(out), {}, 0, nil
  for _, l in ipairs(lc.builtin or {}) do builtin[l] = true end
  for _, l in ipairs(lc.supply or {}) do
    local e = list[l]
    if e and e.starved >= (lc.cycles or 100) then
      local to = builtin[l] and (not e.managed) and 'managed' or (not builtin[l]) and 'monitor' or nil
      if to == 'managed' and K.act.run('labormanager', 'labor', l, to) then
        n = n + 1
        K.log('warn', 'labor %s starved %d cycles: now managed', l, e.starved)
        K.emit('LABOR_STARVED', 'B', string.format('%s starved %d cycles: managed', l, e.starved),
               {labor = l, cycles = e.starved, to = to})
      elseif to == 'monitor' and not fallback then
        fallback = l
        K.emit('LABOR_STARVED', 'B', string.format('%s starved %d cycles: labormanager falls back to monitor', l,
                                                   e.starved), {labor = l, cycles = e.starved, to = to})
        K.call('baseline', 'labor_fallback', string.format('%s starved %d cycles', l, e.starved))
        n = n + 1
      end
    end
  end
  return n
end

local function unit_name(id)
  local u = df.unit.find(id)
  local ok, n = pcall(function() return dfhack.df2utf(dfhack.units.getReadableName(u)) end)
  return ok and type(n) == 'string' and n or ('unit ' .. tostring(id))
end

-- Run 11 (Kilrudrabed y434: the manager, hf 5443, rested with a wound; ConstructCoffin wood x25 and four ConstructDoor
-- wood orders stayed unvalidated while ORDER_STUCK named their material): can the MANAGER validate work orders now?
-- {hf, unit, name, why, since}: why = nil when he can, else 'no manager appointed', 'the manager is gone' (dead, left,
-- not on the map), 'manager <name> resting/injured' (needs health care or rests in bed: water's patient rule),
-- 'manager <name> in a strange mood'; nil when the fort's positions cannot be read or MANAGER is not offered yet
function M.manager_state(K)
  local ok, r = pcall(function()
    local ent = df.global.plotinfo.main.fortress_entity
    if not ent then return nil end
    local pid
    for _, p in ipairs(ent.positions.own) do if p.code == 'MANAGER' and p.flags.ACTIVE then pid = p.id end end
    if not pid then return nil end
    local hf
    for _, a in ipairs(ent.positions.assignments) do
      if a.position_id == pid and (a.histfig or -1) >= 0 then hf = a.histfig end
    end
    if not hf then return {why = 'no manager appointed'} end
    local u
    local cu = K.census.u
    for _, id in ipairs(type(cu) == 'table' and cu.ids or {}) do
      local x = df.unit.find(id)
      if x and x.hist_figure_id == hf then u = x; break end
    end
    if not u then
      pcall(function()
        local h = df.historical_figure.find(hf)
        u = h and df.unit.find(h.unit_id) or nil
      end)
    end
    if not u or dfhack.units.isDead(u) or not dfhack.units.isActive(u) then
      return {hf = hf, why = 'the manager is gone'}
    end
    local name = unit_name(u.id):match('^[^,%s]+') or unit_name(u.id)       -- the first name (the reason fits 80 bytes)
    local r = {hf = hf, unit = u.id, name = name:sub(1, 16)}
    local okp, pat = pcall(function()
      if u.health and u.health.flags.needs_healthcare then return true end
      local j, rest = u.job and u.job.current_job, df.job_type.Rest
      return j ~= nil and rest ~= nil and j.job_type == rest
    end)
    if okp and pat then r.why = 'manager ' .. r.name .. ' resting/injured'
    elseif (u.mood or -1) >= 0 then r.why = 'manager ' .. r.name .. ' in a strange mood'
    elseif (u.military.squad_id or -1) >= 0 then
      -- BUG-450: a squad member on duty (a station, a drill) does not walk to the office to validate
      r.why = 'manager ' .. r.name .. ' is a soldier on duty'
    end
    return r
  end)
  return ok and r or nil
end

-- Run 11: the manager holds the office but cannot validate (M.manager_state why) while work orders wait unvalidated:
-- after orders.manager_days a DECISION_NEEDED manager_absent (A, util/cadence: once per manager and reason) asks the
-- player for an acting manager (the nobles screen: another citizen takes the office; the kernel never replaces a
-- holder). True while that holds (validation_watch's office question waits then).
function M.manager_watch(K, p, c)
  local mg = M.manager_state(K)
  local un, jobs = 0, {}
  if type(mg) == 'table' and mg.hf and mg.why then
    for _, o in ipairs(orders_all()) do
      local okv, valid = pcall(function() return o.status.validated end)
      if okv and valid == false and (math.tointeger(o.amount_left) or 0) > 0 then
        un = un + 1
        if #jobs < 3 then
          local okn, jn = pcall(function() return df.job_type[o.job_type] end)
          jobs[#jobs + 1] = string.format('%s x%d', okn and tostring(jn) or '?', math.tointeger(o.amount_left) or 0)
        end
      end
    end
  end
  if un == 0 then
    if type(p.mabs) == 'table' then
      if p.mabs.ann then K.log('info', 'manager orders validated again (%s)', type(mg) == 'table' and mg.name or '?') end
      p.mabs = p.mabs.ann and {ann = CAD.quiet(p.mabs.ann)} or nil
    end
    return false
  end
  -- BUG-592 (Run 16b i2 Brotherarrow: 'manager Erush is a soldier on duty' for 58 days, the DECISION asked Gordon for the nobles screen): the
  -- manager is taken out of his squad (military.manager_pull); the orders validate at his next walk to the office
  if mg.unit and mg.why:find('soldier on duty', 1, true) then
    local okp, pulled = K.call('military', 'manager_pull', true)
    if okp and pulled == true then
      p.mabs = nil
      return true
    end
  end
  local now = K.now()
  local rec = type(p.mabs) == 'table' and p.mabs or {}
  rec.since = math.tointeger(rec.since) or now.tick
  local days = (now.tick - rec.since) // DAY
  p.mabs = json.object(rec)
  if days < (((c or {}).orders or M.DEFAULTS.orders).manager_days or 3) then return true end
  if CAD.due(rec.ann, now, {mg.hf}, {mg.why}) then
    rec.ann = CAD.mark(now, {mg.hf}, {mg.why})
    p.mabs = json.object(rec)
    local what = table.concat(jobs, ', ') .. (un > #jobs and string.format(' and %d more', un - #jobs) or '')
    K.log('warn', 'no manager available (%s) for %d days: %d work orders not validated (%s)', mg.why, days, un, what)
    K.emit('DECISION_NEEDED', 'A', string.format('no manager available (%s) for %d days: %d orders not validated (%s)',
                                                 mg.why, days, un, what):sub(1, 200),
           {id = 'manager_absent', q = string.format('%s: %d orders wait for validation (%s); appoint an acting manager '
                                                     .. 'on the nobles screen?', mg.why, un, what):sub(1, 200)})
  end
  return true
end

---------------------------------------------------------------- tool work details (live L1b)
-- economy is the sole writer of the builtin Miners / Woodcutters / Hunters memberships (act.work_detail, the
-- work details screen) while labormanager is not in modern mode; modern manages them itself. Members are
-- adult citizens; a soldier, a member of an earlier tool detail or a unit that left the fort is removed at
-- once. New members: no noble (militia posts excepted), no moody or insane dwarf, no sole holder of a key
-- labor, nobody from another tool detail; the best skill joins first. Shrinking waits shrink_days and drops
-- the lowest skill first (among equals those it would not pick).
-- Run 10 (Handlelock): only the members economy added itself (persist m.economy.tools[name].mine) are ever taken
-- off (hunters and fishers leaving PEACE excepted: everybody comes in); a member the player put in stays, counts
-- toward the target and makes no WORK_DETAIL. A member without the detail's labor gets it again through
-- act.work_detail (Lua writes to assigned_units alone set no labor); a miner leaves the everybody-does-this details.
local DIG_JOBS = {Dig = true, CarveUpwardStaircase = true, CarveDownwardStaircase = true,
                  CarveUpDownStaircase = true, CarveRamp = true, DigChannel = true}
local MILITIA = {MILITIA_CAPTAIN = true, MILITIA_COMMANDER = true}
local TOOL_KEY = {MINING = 'w_pick', AXE = 'w_axe', CROSSBOW = 'w_xbow', BOW = 'w_bow'}
local JOB_NAME = {dig = 'dig', fell = 'FellTree'}

-- one pass over the job list: designation dig jobs and FellTree jobs, all and unclaimed (no worker, not suspended)
-- (also digging nobody planned through the runner); BUG-038: GatherPlants too (M.gather_low reads them, no scan of its
-- own)
-- BUG-057: Fish and PlantSeeds + HarvestPlants too (the fishers' and farmers' demand), the first open positions of
-- GatherPlants (400) and of the farm jobs (200) for the walk-group check, and `want` = {job type name = true}: the
-- open count of any other job type M.cover_run covers (r.by / r.by_open)
M.JOB_KIND = {FellTree = 'fell', GatherPlants = 'gather', Fish = 'fish', PlantSeeds = 'plant', HarvestPlants = 'plant'}
M.PTS_CAP = {gather = 400, plant = 200}
local function tool_jobs(want)
  local r = {dig = 0, dig_open = 0, fell = 0, fell_open = 0, gather = 0, gather_open = 0, fish = 0, fish_open = 0,
             plant = 0, plant_open = 0, dig_pts = {}, fell_pts = {}, gather_pts = {}, plant_pts = {}, by = {}, by_open = {}}
  pcall(function()
    local link, i = df.global.world.jobs.list.next, 0
    while link and i < 20000 do
      local j = link.item
      local tn = j and df.job_type[j.job_type]
      local kind = tn and (DIG_JOBS[tn] and 'dig' or M.JOB_KIND[tn]) or nil
      local extra = tn and not kind and type(want) == 'table' and want[tn] and tn or nil
      if kind or extra then
        if kind then r[kind] = r[kind] + 1 else r.by[extra] = (r.by[extra] or 0) + 1 end
        local okw, w = pcall(dfhack.job.getWorker, j)
        if okw and w == nil and not j.flags.suspend then
          if extra then r.by_open[extra] = (r.by_open[extra] or 0) + 1 end
          if kind then
            r[kind .. '_open'] = r[kind .. '_open'] + 1
            -- BUG-023 round 5: where the first open ones lie (the tool diagnosis: can the members take one?)
            local pts = r[kind .. '_pts']
            if pts and #pts < (M.PTS_CAP[kind] or 40) then
              local okp, x, y, z = pcall(function() return j.pos.x, j.pos.y, j.pos.z end)
              if okp and math.tointeger(x) then pts[#pts + 1] = {x, y, z} end
            end
          end
        end
      end
      link, i = link.next, i + 1
    end
  end)
  return r
end

-- BUG-057/FR-72: the job types of cover.labors the job census counts besides its own kinds
function M.cover_types(c)
  local cv, w = c.cover, {}
  for tn in pairs(type(cv) == 'table' and type(cv.labors) == 'table' and cv.labors or {}) do
    if not M.JOB_KIND[tn] then w[tn] = true end
  end
  return w
end

-- weapons usable as the detail's tool (picks, axes, crossbows and bows not carried by soldiers), from the census
local function tool_count(spec, inv)
  local n = 0
  for _, s in ipairs(spec.melee or {}) do n = n + (inv[TOOL_KEY[s] or ''] or 0) end
  for _, s in ipairs(spec.ranged or {}) do n = n + (inv[TOOL_KEY[s] or ''] or 0) end
  return n
end

-- the tool (economy's weapon kind: pick, axe) a unit carries: wielded or worn, not hauled to a pile
local function holds_tool(u, kind)
  local ok, yes = pcall(function()
    local im = df.unit_inventory_item and df.unit_inventory_item.T_mode
    local hauled = im and im.Hauled
    for _, e in ipairs(u.inventory) do
      local it = e.item
      if it and (hauled == nil or e.mode ~= hauled) and it:getType() == df.item_type.WEAPON and weapon_kind(it) == kind then
        return true
      end
    end
    return false
  end)
  return ok and yes == true
end

-- BUG-128 (Run 14 region2-site90: the members rotated every TOOL_BLOCKED, the new ones were patients, the chief medical
-- dwarf and a bone doctor). Module fields, not locals (the main chunk is at Lua's 200-local limit).
-- BUG-186 (live i4 y725: DF 53.16 turns SUTURING and DRESSING_WOUNDS on for nearly every citizen, 33 of 41 adults were
-- skipped as 'doc', 4 of them real doctors): only the doctor labors a player sets by hand count, plus a hospital job and
-- the chief medical dwarf (DOC_JOBS, DOC_POS)
M.DOC_LABORS = {'DIAGNOSE', 'SURGERY', 'BONE_SETTING'}
M.DOC_JOBS = {'DiagnosePatient', 'Surgery', 'SetBone', 'Suture', 'DressWound', 'ApplyCast', 'PlaceInTraction',
              'CleanPatient'}
M.DOC_POS = 'CHIEF_MEDICAL_DWARF'
M.TOOL_PROF = {Miners = 'MINER', Woodcutters = 'WOODCUTTER'}

-- a patient: needs healthcare, or rests (the injured's job Rest)
function M.patient(u)
  local rest = df.job_type and df.job_type.Rest
  local ok, yes = pcall(function()
    local j = u.job and u.job.current_job
    return (u.health and u.health.flags.needs_healthcare) or (j ~= nil and rest ~= nil and j.job_type == rest)
  end)
  return ok and yes and true or false
end

-- why a citizen is no new tool detail member (nil: he may be one): a patient, a doctor (a doctor labor on)
function M.tool_cand_skip(u, spec)
  if not spec.tool then return nil end
  if M.patient(u) then return 'pat' end
  for _, l in ipairs(M.DOC_LABORS) do
    local ok, v = pcall(function() return u.status.labors[l] end)
    if ok and v == true then return 'doc' end
  end
  local okj, jt = pcall(function() local j = u.job and u.job.current_job; return j and df.job_type[j.job_type] end)
  if okj and type(jt) == 'string' then
    for _, n in ipairs(M.DOC_JOBS) do if jt == n then return 'doc' end end
  end
  local okp, ps = pcall(dfhack.units.getNoblePositions, u)
  if okp and type(ps) == 'table' then
    for _, p in ipairs(ps) do
      local okc, code = pcall(function() return p.position.code end)
      if okc and code == M.DOC_POS then return 'doc' end
    end
  end
end

-- BUG-187 (live i4 y725: the patient 42435 lacked the pick for 1313 days, Rest, needs_healthcare; #cur == target, so
-- nobody healthy joined): a member who is a patient (M.patient) and has lacked the tool for tools.block_days (rec.ms of
-- p.tblk: the tick he was first seen without it) is a long-term patient. The kernel takes its own one off the detail, a
-- player's one stays but does not count; either way a healthy candidate may join
function M.tool_long_patient(u, spec, tc, rec, now)
  if not spec.tool or not M.patient(u) or holds_tool(u, spec.tool) then return false end
  local ms = type(rec) == 'table' and type(rec.ms) == 'table' and rec.ms or {}
  local t = math.tointeger(ms[tostring(u.id)])
  return t ~= nil and now - t >= (math.tointeger(tc.block_days) or 3) * DAY
end

-- the profession of the detail (MINER, WOODCUTTER): true when the unit has it
function M.tool_prof(u, spec)
  local pn = M.TOOL_PROF[spec.name]
  local pid = pn and df.profession and df.profession[pn]
  local ok, v = pcall(function() return u.profession end)
  return pid ~= nil and ok and v == pid
end

-- why a kernel-added tool member must stay (nil: he may leave): he holds the tool, DF lists a work tool pair for him
-- (work_units), or he joined less than keep_days ago (ps.at: join ticks by id)
function M.tool_keep(u, spec, tc, ps, now, wu)
  if not spec.tool then return nil end
  if holds_tool(u, spec.tool) then return 'tool' end
  if type(wu) == 'table' and wu[u.id] ~= nil then return 'pair' end
  local at = type(ps.at) == 'table' and math.tointeger(ps.at[tostring(u.id)]) or nil
  if at and now - at < (math.tointeger(tc.keep_days) or 14) * DAY then return 'keep' end
end

-- the jobs of a tool detail that wait (dig, FellTree): the target never falls below 1 while there are any
function M.tool_floor(spec, jc)
  return spec.tool and type(jc) == 'table' and (jc[spec.jobs or ''] or 0) > 0 and 1 or 0
end

local function tool_target(K, spec, cit, inv, r, jc)
  if spec.tiles_per then
    local ok, rb = K.call('runner', 'dig_backlog')
    local tiles = ok and math.tointeger(rb) or 0
    local jobs = jc and jc.dig or 0
    local rp = math.max(1, spec.runner_per or spec.tiles_per)
    local want = math.max((jobs + spec.tiles_per - 1) // spec.tiles_per, (tiles + rp - 1) // rp)
    -- the ore backlog: metal is wanted and the fort has no ore (plan_metal's explore route) while digging is open
    if (spec.ore or 0) > 0 and jobs + tiles > 0 and r and r.route and r.route.bars == 'explore' then
      want = want + spec.ore
    end
    local cap = cit >= (spec.max_pop or 0) and spec.max or spec.min
    return math.max(spec.min, math.min(cap, want)), math.max(jobs, tiles)
  elseif spec.wood then
    local w = inv.wood or 0
    local band = st.chop or spec.wood                -- economy's autochop band (live L4)
    return (w < band[1] and spec.n[1]) or (w < band[2] and spec.n[2]) or spec.n[3], w
  elseif spec.ranged then
    local n = r and r.hunt or 0
    local free = inv.bolts_free or inv.bolts or 0          -- not the soldiers' bolts
    if n > 0 and free < (spec.ammo_min or 1) then
      if st.no_ammo ~= true then K.log('info', 'hunters wanted (%s) but no free bolts: none sent', tostring(r.hunt_why)) end
      st.no_ammo = true
      return 0, 0
    end
    st.no_ammo = false
    return n, free
  elseif spec.fish then
    return r and r.fish or 0, r and r.days and r.days.food_d or 0
  end
  return 0, 0
end

local function noble(u)
  local ok, np = pcall(dfhack.units.getNoblePositions, u)
  if not ok or type(np) ~= 'table' and type(np) ~= 'userdata' then return false end
  for _, e in ipairs(np) do
    local code = e.position and e.position.code
    if code and not MILITIA[code] then return true end
  end
  return false
end

local function labor_on(u, l)
  local ok, v = pcall(function() return u.status.labors[l] end)
  return ok and v == true
end

-- live L3/L4: hunting without a new hide, bone, leather or shell for trial_days pauses for backoff_days
local function hunt_book(K, c, r, hunters)
  local p, h = r.p, c.hunt or M.DEFAULTS.hunt
  if hunters == 0 or r.p.famine or r.p.food_pre then p.hunt = nil; return end
  local inv = r.inv
  local score = (inv.bone or 0) + (inv.hides or 0) + (inv.leather or 0) + (inv.shell or 0)
  if type(p.hunt) ~= 'table' or score > (math.tointeger(p.hunt.score) or 0) then
    p.hunt = {since = r.now, score = score}
    return
  end
  p.hunt.score = score
  if r.now - (math.tointeger(p.hunt.since) or r.now) >= (h.trial_days or 10) * DAY then
    p.hunt_off, p.hunt = r.now + (h.backoff_days or 20) * DAY, nil
    K.log('info', 'hunting: nothing caught for %d days (no game in sight?): hunters off for %d days',
          h.trial_days or 10, h.backoff_days or 20)
  end
end

-- the labors a specialist of `own` gives up (act.work_detail opts.only): those of the everybody-does-this details that
-- are no tool details, without own's labors and the keep labors; {{l = labor index, w = detail}}
local function everybody_labors(li, own, tool_names, keep)
  local out = {}
  local every = df.work_detail_mode and df.work_detail_mode.EverybodyDoesThis
  if not every then return out end
  for _, w in ipairs(li.work_details) do
    if w ~= own and w.flags.mode == every and not tool_names[dfhack.df2utf(w.name)] then
      local al = w.allowed_labors
      out[#out + 1] = {w = w}
      for l = 0, #al - 1 do
        if al[l] and not own.allowed_labors[l] and not keep[l] then out[#out + 1] = {l = l, w = w} end
      end
    end
  end
  return out
end

-- the member sets of the work details, read once per tool run (a 120-citizen fort: 20 details, ~2,400 ids)
local function member_sets(li)
  local sets = {}
  for _, w in ipairs(li.work_details) do
    local m = {}
    for _, x in ipairs(w.assigned_units) do m[x] = true end
    sets[w] = m
  end
  return sets
end

-- true when a member still sits in an everybody-does-this detail or holds one of its labors that no detail the unit
-- is a selected member of grants (the check act.work_detail opts.only makes before it switches labors off)
local function needs_specialist(li, sets, u, evl, own)
  local wm = df.work_detail_mode or {}
  local every, nobody = wm.EverybodyDoesThis, wm.NobodyDoesThis
  for _, e in ipairs(evl) do
    if e.l == nil then
      if sets[e.w] and sets[e.w][u.id] then return true end
    elseif labor_on(u, e.l) then
      local held = false
      for _, x in ipairs(li.work_details) do
        local m = x.flags.mode
        if x ~= own and m ~= every and m ~= nobody and sets[x] and sets[x][u.id] and x.allowed_labors[e.l] then
          held = true
          break
        end
      end
      if not held then return true end
    end
  end
  return false
end

-- BUG-023 / Run 10: a detail's members without its tool in hand while its jobs wait and free tools exist, for
-- block_days -> TOOL_BLOCKED (A, util/cadence: again only for a new member or cause). Woodcutters never fetched the two
-- axes from a bin (19 FellTree jobs, a year without logs); six of eight miners held no pick while 4 lay free.
local function tool_where(kind)               -- where the first free tool of the census lies (a bin: the bin's tile)
  for pass = 1, 4 do                          -- one on the citizens' group first, a far one, a forbidden one (BUG-023, Run 11), a reserved one last
    for _, e in ipairs((st.tool_items or {})[kind] or {}) do
      if pass == M.tool_rank(e) then
        local it = df.item.find(e.id)
        local ok, x, y, z = pcall(function() return dfhack.items.getPosition(it) end)
        if it and ok and x then return {x, y, z} end
      end
    end
  end
end

-- BUG-023 round 5 (Run 11 site98 y434: `Miners: hold no pick for 240 days, 14 dig jobs open; 3 free picks loose`
-- after 240 days of equipment update requests; the picks lay on the floor, not forbidden, not reserved, on the
-- citizens' walk group). What DF needs before it hands a free pick or axe out as a work tool (the pairs
-- plotinfo.equipment.work_weapons / work_units), read once a day for up to TD_PICKS free tools and TD_UNITS members
-- without one, so that TOOL_BLOCKED names the blocker. Read-only. Module fields, not locals (the main chunk is at Lua's
-- 200-local limit).
M.TD_PICKS, M.TD_UNITS = 4, 6
M.TD_FLAGS = {'in_job', 'owned', 'melt', 'forbid', 'artifact', 'hostile', 'encased', 'foreign', 'in_inventory'}
M.TD_BLOCK = {in_job = true, owned = true, melt = true, forbid = true, artifact = true, hostile = true, encased = true}
-- the tool labors one dwarf may hold only one of (act.TOOL_EXCL; DFHack manipulator.cpp: mutually exclusive)
M.TD_EXCL = {Miners = 'MINE', Woodcutters = 'CUTWOOD', Hunters = 'HUNT'}

-- DF's equipment lists for weapons: pool[id] = 'm' (items_unmanifested: not sorted yet), 'a' (items_assigned: reserved
-- by a squad position), 'u' (items_unassigned: free for a squad or as a work tool); ww[item] = unit and wu[unit] = item
-- of the work tool pairs (work_weapons and work_units, parallel vectors), n = pairs
function M.td_pool()
  local eq = df.global.plotinfo.equipment
  local pool, ww, wu, n = {}, {}, {}, 0
  for _, e in ipairs({{'items_unmanifested', 'm'}, {'items_assigned', 'a'}, {'items_unassigned', 'u'}}) do
    local ok = pcall(function() for _, id in ipairs(eq[e[1]].WEAPON) do pool[id] = e[2] end end)
    if not ok and e[2] == 'u' then pool = nil end           -- the free list unreadable: no pool verdict
  end
  pcall(function()
    local wv, uv = eq.work_weapons, eq.work_units
    n = #wv
    for i = 0, #wv - 1 do
      local item, unit = wv[i], uv[i]
      if item ~= nil then ww[item] = unit or -1 end
      if unit ~= nil then wu[unit] = item end
    end
  end)
  return pool, ww, wu, n
end

-- the tile lies in one of the burrows `ids` (plotinfo.burrows.list ids; dfhack.burrows.isAssignedTile)
function M.td_in_burrows(ids, p)
  local want = {}
  for _, id in ipairs(ids) do want[id] = true end
  local ok, yes = pcall(function()
    for _, b in ipairs(df.global.plotinfo.burrows.list) do
      if want[b.id] and dfhack.burrows.isAssignedTile(b, {x = p[1], y = p[2], z = p[3]}) then return true end
    end
    return false
  end)
  return ok and yes == true
end

-- a tool labor of another exclusive tool detail (M.TD_EXCL) the unit holds while no detail grants it (act.work_detail
-- switches it off when the unit joins a tool detail): its name, or nil
function M.stray_tool(li, u, own, name)
  if not M.TD_EXCL[name] then return nil end
  local wm = df.work_detail_mode or {}
  for dn, ln in pairs(M.TD_EXCL) do
    local l = df.unit_labor and df.unit_labor[ln]
    if dn ~= name and type(l) == 'number' and labor_on(u, ln) and not own.allowed_labors[l] then
      local held = false
      for _, x in ipairs(li.work_details) do
        local m = x.flags.mode
        if x ~= own and x.allowed_labors[l] and m ~= wm.NobodyDoesThis then
          if m == wm.EverybodyDoesThis then held = true
          else for _, id in ipairs(x.assigned_units) do if id == u.id then held = true end end end
        end
      end
      if not held then return ln end
    end
  end
end

-- the diagnosis of a blocked tool detail: {picks = {per free tool}, units = {per member without it}, keys (blockers in
-- order), key, why (the first blocker's text), whys (all), civ, ww}
-- BUG-128: fresh = {unit id = true} for the members whose equipment request the kernel made less than a game day ago (not
-- 'pending' yet: DF runs the update on its own schedule)
function M.tool_diag(K, spec, kind, without, cur, jc, pop, fresh)
  local dg = {picks = {}, units = {}, keys = {}, texts = {}, civ = 0, ww = 0, pop = pop, upf = 0}
  pcall(function() dg.upw = df.global.plotinfo.equipment.update.weapon == true or nil end)   -- DF has not run it yet
  if dg.upw and type(fresh) == 'table' and next(fresh) then dg.upw, dg.upwn = nil, true end
  local okp, pool, ww, wu, wn = pcall(M.td_pool)
  if not okp then pool, ww, wu, wn = nil, {}, {}, 0 end
  dg.ww = wn or 0
  local civ
  pcall(function()
    local al = df.global.plotinfo.alerts
    local i = al.civ_alert_idx
    if i and i ~= 0 then
      civ = {}
      for _, id in ipairs(al.list[i].burrows) do civ[#civ + 1] = id end
    end
  end)
  dg.civ = civ and #civ or 0
  local members = {}
  for _, u in ipairs(cur or {}) do members[u.id] = true end
  local items, list = {}, (st.tool_items or {})[kind] or {}
  for pass = 1, 4 do                                        -- the free tools first (BUG-053: those on the citizens' group), then the forbidden ones, the reserved last
    for _, e in ipairs(list) do
      if #items < M.TD_PICKS and pass == M.tool_rank(e) then
        local it = df.item.find(e.id)
        if it and not holder(it) then items[#items + 1] = it end
      end
    end
  end
  local units = {}
  for _, id in ipairs(without) do
    local u = #units < M.TD_UNITS and df.unit.find(id)
    if u then units[#units + 1] = u end
  end
  local pts, ipos, nu = {}, {}, #units
  for i, u in ipairs(units) do
    local ok, x, y, z = pcall(function() return u.pos.x, u.pos.y, u.pos.z end)
    pts[i] = ok and x and {x, y, z} or false
  end
  for i, it in ipairs(items) do
    local ok, x, y, z = pcall(dfhack.items.getPosition, it)
    ipos[i] = ok and x and {x, y, z} or false
    pts[nu + i] = ipos[i]
  end
  local okg, grp = K.call('snapshot', 'groups', pts, false)   -- walk groups (-1 unknown: counts as reachable)
  grp = okg and type(grp) == 'table' and grp or nil
  -- the open jobs of the detail (a tool job is what sends a dwarf for his tool): their walk groups (a wall to dig counts
  -- by its neighbours)
  local jp = type(jc) == 'table' and jc[(spec.jobs or '') .. '_pts'] or {}
  local okjg, jg = false, nil
  if #jp > 0 and grp then okjg, jg = K.call('snapshot', 'groups', jp, true) end
  jg = okjg and type(jg) == 'table' and jg or nil
  for i, it in ipairs(items) do
    local f, fl = it.flags, {}
    for _, k in ipairs(M.TD_FLAGS) do if f[k] then fl[#fl + 1] = k end end
    local r = {id = it.id, at = ipos[i] or nil, flags = fl, pool = pool and (pool[it.id] or '-') or '?'}
    local wid = ww[it.id]
    if wid then
      local wun = df.unit.find(wid)
      r.ww = wid
      r.wws = not wun and 'gone' or (dfhack.units.isDead(wun) and 'dead') or (members[wid] and 'member') or
              ((wun.military.squad_id or -1) >= 0 and 'soldier') or 'other'
    end
    local okw, ow = pcall(dfhack.items.getOwner, it)
    if okw and ow then r.own, r.own_dead = ow.id, dfhack.units.isDead(ow) or nil end
    local okc, cont = pcall(dfhack.items.getContainer, it)
    if okc and cont then r.cont = cont.id end
    local okq, wear = pcall(function() return it.wear end)            -- 1-3: worn (x), well worn (X), tattered (XX)
    if okq and (math.tointeger(wear) or 0) > 0 then r.wear = math.tointeger(wear) end
    if ipos[i] then
      local x, y, z = ipos[i][1], ipos[i][2], ipos[i][3]
      local okf, far = K.call('snapshot', 'far', x, y, z)
      if okf and far == true then r.far = true end
      local okb, b = pcall(dfhack.buildings.findAtTile, x, y, z)
      if okb and b then
        local okt, tn = pcall(function() return df.building_type[b:getType()] end)
        r.bld = okt and tn or 'building'
      end
    end
    r.g = grp and grp[nu + i] or nil
    dg.picks[i] = r
  end
  local rest = df.job_type and df.job_type.Rest
  for i, u in ipairs(units) do
    local r = {id = u.id, lab = spec.labor == nil or labor_on(u, spec.labor), xl = {}, bur = 0}
    for dn, ln in pairs(M.TD_EXCL) do if dn ~= spec.name and labor_on(u, ln) then r.xl[#r.xl + 1] = ln end end
    table.sort(r.xl)
    local wi = wu[u.id]
    if wi then
      local it = df.item.find(wi)
      local h = it and holder(it)
      r.wu = wi
      r.wus = not it and 'gone' or (h and (h.id == u.id and 'held' or ('held by ' .. h.id))) or
              (it.flags.forbid and 'forbidden') or 'loose'
      for _, t in ipairs(items) do if t.id == wi then r.wfree = true end end   -- one of the free tools: not fetched yet
      -- BUG-128 (Run 14: 'upair' for a loose pick outside the 4-pick sample): a loose paired tool is a free tool (no
      -- holder, not forbidden), whether sampled or not: DF paired it, he has not fetched it yet
      if not r.wfree and r.wus == 'loose' then r.wfree, dg.upf = true, dg.upf + 1 end
    end
    pcall(function()
      r.upd = u.uniform.pickup_flags.update == true or nil
      if r.upd and type(fresh) == 'table' and fresh[u.id] then r.upd, r.updn = nil, true end   -- BUG-128
      local pk = u.uniform.uniform_pickup
      r.pk = #pk
      for _, id in ipairs(pk) do
        if id == wi then r.pkt = true end
        for _, t in ipairs(items) do if t.id == id then r.pkt = true end end
      end
    end)
    local j = u.job and u.job.current_job
    r.job = j and tostring(df.job_type[j.job_type] or '?') or 'idle'
    local okh, pat = pcall(function()
      return (u.health and u.health.flags.needs_healthcare) or (j ~= nil and rest ~= nil and j.job_type == rest)
    end)
    r.pat = okh and pat and true or nil
    -- the burrows DF keeps the member to: the civ alert's while it sounds (civilians), else his own (unit.burrows)
    local lim
    if civ and (u.military.squad_id or -1) < 0 then lim = civ
    else
      pcall(function()
        if #u.burrows > 0 then
          lim = {}
          for _, b in ipairs(u.burrows) do lim[#lim + 1] = b end
        end
      end)
    end
    if lim then
      r.bur, r.inb = #lim, 0
      for k = 1, #items do if ipos[k] and M.td_in_burrows(lim, ipos[k]) then r.inb = r.inb + 1 end end
    end
    if grp then
      local g, n = math.tointeger(grp[i]) or -1, 0
      for k = 1, #items do
        local gi = math.tointeger(grp[nu + k]) or -1
        if g < 0 or gi < 0 or g == gi then n = n + 1 end
      end
      r.walk = n
      if jg then                                            -- open jobs he can take: on his group, in his burrows
        local nj = 0
        for k, p in ipairs(jp) do
          local gj = math.tointeger(jg[k]) or -1
          if (g < 0 or gj < 0 or g == gj) and (not lim or M.td_in_burrows(lim, p)) then nj = nj + 1 end
        end
        r.jobs = nj
      end
    end
    dg.units[i] = r
  end
  dg.njobs = #jp
  M.td_blockers(dg, spec, kind, #without)
  return dg
end

-- the blockers of a diagnosis, most basic first (keys and their texts)
function M.td_blockers(dg, spec, kind, nwo)
  local function add(key, text) dg.keys[#dg.keys + 1] = key; dg.texts[#dg.texts + 1] = text end
  local function where(pred)
    local r = {}
    for _, x in ipairs(pred[1]) do if pred[2](x) then r[#r + 1] = x end end
    return r
  end
  local U, P = dg.units, dg.picks
  -- BUG-053 (population level, from the census): every tool of the kind forbidden, the free ones on another walk group
  -- than the citizens (members and haulers cannot reach them), the free ones owned by a dwarf
  local pop = dg.pop
  if pop then
    if pop.free == 0 and pop.forb > 0 then
      add('forbidden', string.format('all %d %ss are forbidden (the daily unforbid could not free them)', pop.forb, kind))
    end
    if pop.free > 0 and pop.use == 0 then
      if pop.far > 0 then
        add('off_group', string.format('%d of %d free %ss lie on another walk group than the citizens%s', pop.far,
                                       pop.free, kind, pop.pos and string.format(' (the first at %d,%d,%d)', pop.pos[1],
                                                                                 pop.pos[2], pop.pos[3]) or ''))
      end
      if pop.own > 0 then
        add('owned', string.format('%d of %d free %ss are owned by a dwarf (flag owned: no work tool for anybody else)',
                                   pop.own, pop.free, kind))
      end
      -- BUG-706: every free tool of the kind is reserved by a squad uniform (the equipment screen): DF hands none out as a work tool
      if (pop.res or 0) > 0 then
        add('reserved', string.format('%d of %d free %ss are reserved by squad uniforms (squads screen, equipment): DF hands none out as ' ..
                                      'a work tool', pop.res, pop.free, kind))
      end
    end
  end
  local nolab = where{U, function(r) return not r.lab end}
  if #nolab > 0 then add('labor', string.format('%d of %d lack the %s labor', #nolab, nwo, tostring(spec.labor))) end
  local two = where{U, function(r) return #r.xl > 0 end}
  if #two > 0 then
    add('tool2', string.format('%d hold a second tool labor (%s %s): one tool labor per dwarf', #two, two[1].id,
                               table.concat(two[1].xl, '+')))
  end
  local fenced = where{U, function(r) return r.inb ~= nil and r.inb == 0 and #P > 0 end}
  if #fenced > 0 then
    add(dg.civ > 0 and 'alert' or 'burrow', dg.civ > 0 and
        string.format('the civ alert holds %d in its burrows, no free %s inside', #fenced, kind) or
        string.format('%d are limited to burrows without a free %s', #fenced, kind))
  end
  local cut = where{U, function(r) return r.walk == 0 and #P > 0 end}
  if #cut > 0 then add('walk', string.format('no free %s on the walk group of %d', kind, #cut)) end
  -- BUG-187 (live i4 #33355: the lacking member was a patient, Rest; bk said 'jobs'): a patient fetches no tool and takes
  -- no job, whatever his walk group or burrows
  local sick = where{U, function(r) return r.pat == true end}
  if #sick > 0 then
    add('patient', string.format('%d of %d are patients (needs healthcare / Rest): they fetch no %s and take no job (%d)',
                                 #sick, nwo, kind, sick[1].id))
  end
  local nojob = where{U, function(r) return r.jobs == 0 and not r.pat end}
  if #nojob > 0 then
    add('jobs', string.format('%d can take none of the first %d open %s jobs (off their walk group or burrows)', #nojob,
                              dg.njobs or 0, JOB_NAME[spec.jobs] or tostring(spec.jobs)))
  end
  local paired = where{P, function(r) return r.ww ~= nil and r.wws ~= 'member' end}
  if #paired > 0 then
    local ids = {}
    for _, r in ipairs(paired) do ids[#ids + 1] = string.format('%d (%s %d)', r.id, r.wws or '?', r.ww) end
    add('pair', string.format('DF lists %s %s as work tool of another unit (work_weapons)', kind,
                              table.concat(ids, ', ')))
  end
  local flagged = where{P, function(r)
    for _, f in ipairs(r.flags) do if M.TD_BLOCK[f] then return true end end
    return false
  end}
  if #flagged > 0 then
    local fl = {}
    for _, r in ipairs(flagged) do
      for _, f in ipairs(r.flags) do if M.TD_BLOCK[f] then fl[#fl + 1] = r.id .. ':' .. f end end
    end
    add('flag', string.format('%d of %d %ss flagged (%s)', #flagged, #P, kind, table.concat(fl, ' ')))
  end
  local off = where{P, function(r) return r.pool ~= 'u' and r.pool ~= '?' end}
  if #off > 0 then
    local pl = {}
    for _, r in ipairs(off) do pl[#pl + 1] = r.id .. ':' .. (r.pool == 'm' and 'unmanifested' or r.pool == 'a' and
                                                               'assigned' or 'none') end
    add('pool', string.format('%d %ss not in DF\'s free equipment list items_unassigned (%s)', #off, kind,
                              table.concat(pl, ' ')))
  end
  local up = where{U, function(r) return r.wu ~= nil and r.wus ~= 'held' and not r.wfree end}
  if #up > 0 then
    add('upair', string.format('DF pairs %d with another %s (%d: %s %s)', #up, kind, up[1].id, tostring(up[1].wu),
                               up[1].wus or '?'))
  end
  local fetch = where{U, function(r) return r.pkt == true or r.wfree == true end}
  if #fetch > 0 then
    add('fetch', string.format('DF assigned %d a free %s (work_units, uniform_pickup), not fetched yet (job %s)', #fetch,
                               kind, fetch[1].job))
  end
  local pend = where{U, function(r) return r.upd == true end}
  if #pend > 0 then add('pending', string.format('DF has not processed the equipment request of %d', #pend)) end
  if #dg.keys == 0 then
    -- BUG-706 (Run 16a i1 Basementflew: 'nothing visible' for 800 days): what the first member does and holds instead
    local m = U[1]
    local ctx = m and string.format(' (member %d: job %s, %d items on his pickup list, %d work tool pairs in the fort)', m.id,
                                    tostring(m.job), m.pk or 0, dg.ww or 0) or ''
    add('none', string.format('nothing visible: the free %ss are in DF\'s list, the members have the labor, reach them '
                              .. 'and are no work tool pair%s', kind, ctx))
  end
  dg.key, dg.why, dg.whys = dg.keys[1], dg.texts[1], table.concat(dg.texts, '; ')
end

-- compact forms of a diagnosis' records (TOOL_BLOCKED picks/units, <= 60 bytes each; kern.log)
function M.td_pick_str(r)
  local s = string.format('%d %s %s', r.id, r.at and string.format('%d,%d,%d', r.at[1], r.at[2], r.at[3]) or '?',
                          r.pool)
  if r.ww then s = s .. ' ww=' .. r.ww .. ':' .. (r.wws or '?') end
  if r.own then s = s .. ' own=' .. r.own .. (r.own_dead and ':dead' or '') end
  if #r.flags > 0 then s = s .. ' ' .. table.concat(r.flags, ',') end
  if r.wear then s = s .. ' wear' .. r.wear end
  if r.far then s = s .. ' far' end
  if r.bld then s = s .. ' ' .. r.bld end
  return s:sub(1, 60)
end
function M.td_unit_str(r)
  local s = string.format('%d %s', r.id, r.lab and 'lab' or 'nolab')
  if #r.xl > 0 then s = s .. ' +' .. table.concat(r.xl, '+') end
  if r.wu then s = s .. ' wu=' .. r.wu .. ':' .. (r.wus or '?') end
  if r.inb then s = s .. string.format(' bur%d/in%d', r.bur, r.inb) end
  if r.walk then s = s .. ' walk' .. r.walk end
  if r.jobs then s = s .. ' jobs' .. r.jobs end
  if r.pk then s = s .. ' pk' .. r.pk .. (r.pkt and '*' or '') end
  if r.upd then s = s .. ' upd' end
  if r.updn then s = s .. ' upd0' end
  if r.pat then s = s .. ' patient' end
  return (s .. ' ' .. tostring(r.job)):sub(1, 60)
end

-- the diagnosis in TOOL_BLOCKED's d: blk (the blockers' texts), bk (their keys), picks / units (compact records, the
-- first 3), civ, ww; the event's d must stay below kern's 1 KB (units, then picks, then the texts give way)
function M.td_event(d, dg)
  d.blk, d.bk, d.civ, d.ww = dg.whys:sub(1, 200), table.concat(dg.keys, ','):sub(1, 60), dg.civ, dg.ww
  d.picks, d.units = {}, {}
  for i = 1, math.min(3, #dg.picks) do d.picks[i] = M.td_pick_str(dg.picks[i]) end
  for i = 1, math.min(3, #dg.units) do d.units[i] = M.td_unit_str(dg.units[i]) end
  local function size() local ok, s = pcall(json.encode, d); return ok and #s or 2000 end
  while size() > 1000 and #d.units > 0 do table.remove(d.units) end
  while size() > 1000 and #d.picks > 0 do table.remove(d.picks) end
  if size() > 1000 then d.blk = dg.why:sub(1, 120) end
  if size() > 1000 and d.hint then d.hint = d.hint:sub(1, 80) end
end

-- BUG-116 (Run 14 note 89: the miners found no pick, 109 picks lay in chests, the hospital's dig stood at 0 %): one sentence
-- for the player in the game's words, from the diagnosis' blocker keys and the counts (TOOL_BLOCKED d.tell, <= 200 bytes).
-- Nothing here is done by the kernel: no verb moves or unforbids a tool for a member (fair play)
function M.tool_tell(spec, kind, c)
  local keys = {}
  for _, k in ipairs(c.keys or {}) do keys[k] = true end
  local t
  if keys.labor then
    t = string.format('turn on the %s labor of the %s detail members (work details screen): they lack it',
                      tostring(spec.labor), spec.name)
  elseif keys.tool2 then
    t = string.format('members of %s hold a second tool labor (one tool labor per dwarf): turn the other off', spec.name)
  elseif keys.patient then                                                                    -- BUG-187
    t = string.format('the %s member without a %s is a patient (hospital, Rest) and fetches none: take him off the detail '
                      .. 'so a healthy dwarf joins', spec.name, kind)
  elseif c.forb > 0 and c.free == 0 then
    t = string.format('the %d %ss are forbidden: unforbid them (the items screen, flag forbid) or put them in a free chest',
                      c.forb, kind)
  elseif c.res > 0 and c.free - c.res <= 0 then
    t = string.format('the %d %ss are reserved by squad uniforms: take the %s off the squad\'s equipment (squads screen) or '
                      .. 'have more made', c.res, kind, kind)
  elseif c.bins > 0 and c.free - c.bins <= 0 then
    t = string.format('the %d %ss lie in chests: dwarves need the %s unforbidden or in a free chest of a tool stockpile '
                      .. 'they can reach (unforbid it, or empty the chest)', c.bins, kind, kind)
  elseif keys.off_group then
    t = string.format('the free %ss lie on another walk group than the dwarves: carry them over or make a tool stockpile '
                      .. 'near the mines', kind)
  elseif keys.jobs then                        -- (review: the diagnosis' key for members cut off by walk group or burrows)
    t = string.format('the alert/burrow keeps the %s members from the %ss: lift the civilian alert or widen the burrow', spec.name,
                      kind)
  else
    t = string.format('free %ss exist but DF hands none out: check the %s detail, the squads screen and forbid flags',
                      kind, spec.name)
  end
  return t:sub(1, 200)
end

-- BUG-128 (Run 14: dfllm-tools stood at 44,92,129 while the picks sat in a binned weapons pile at 87,105,123; DF does not
-- re-haul stored items): the stockpile (not dfllm-tools) the first usable free tool of the census sits in: its building id
function M.tool_src_pile(kind)
  for _, e in ipairs((st.tool_items or {})[kind] or {}) do
    if M.tool_rank(e) == 1 then
      local it = df.item.find(e.id)
      local ok, x, y, z = pcall(function() return dfhack.items.getPosition(it) end)
      if it and ok and x then
        local id
        pcall(function()
          for _, sp in ipairs(df.global.world.buildings.other.STOCKPILE) do
            if dfhack.df2utf(sp.name or '') ~= 'dfllm-tools' and sp.z == z and x >= sp.x1 and x <= sp.x2 and
               y >= sp.y1 and y <= sp.y2 then id = sp.id; return end
          end
        end)
        if id then return id end
      end
    end
  end
end

-- BUG-128: which of the guards applied, for TOOL_BLOCKED d.g (<= 160 bytes): members kept (tool, pair, keep_days),
-- candidates skipped (patients, doctors), a fresh request not called pending, loose pairs counted as fetch, the stale cap,
-- the tool pile's source pile
function M.tool_guards(spec, kind, dg, rec, stale, src, p)
  local g = {}
  local kept = (st.tkept or {})[spec.name]
  if kept then g[#g + 1] = string.format('kept %d (tool/pair/keep_days)', kept) end
  local sk = (st.tskip or {})[spec.name]
  if sk then g[#g + 1] = string.format('skipped pat %d doc %d', sk.pat or 0, sk.doc or 0) end
  local np = (st.tpat or {})[spec.name]
  if np then g[#g + 1] = string.format('patient members not counted %d', np) end          -- BUG-187
  local fresh = dg and dg.upwn or false
  for _, u in ipairs(dg and dg.units or {}) do if u.updn then fresh = true end end
  if fresh then g[#g + 1] = 'request < 1 day: not pending' end
  if dg and (dg.upf or 0) > 0 then g[#g + 1] = string.format('upair->fetch %d', dg.upf) end
  local stn = math.tointeger(rec and rec.stn)
  if stn and stale and stale < stn then g[#g + 1] = string.format('stale %d->%d (stock-(members+2))', stn, stale) end
  if src then
    local tp = type(p) == 'table' and type(p.tpile) == 'table' and p.tpile or {}
    if math.tointeger(tp.take) == src then g[#g + 1] = string.format('pile takes from %d', src)
    elseif #M.tool_piles() > 0 then
      g[#g + 1] = string.format('%ss sit in stockpile %d: set dfllm-tools to take from stockpile %d', kind, src, src)
    end
  end
  return #g > 0 and table.concat(g, '; '):sub(1, 160) or nil
end

local function tool_check(K, tc, r, spec, cur, jc, fixed)
  local p, kind = r.p, spec.tool
  local inv = r.inv or {}
  local rec = p.tblk[spec.name]
  rec = type(rec) == 'table' and rec or {}
  local open = jc[(spec.jobs or '') .. '_open'] or 0
  local without = {}
  for _, u in ipairs(cur) do if not holds_tool(u, kind) then without[#without + 1] = u.id end end
  table.sort(without)
  local free = inv['w_' .. kind .. '_free'] or 0
  local forb = inv['w_' .. kind .. '_forb'] or 0                  -- BUG-023 (Run 11): forbidden ones, unforbidden
  st.tblk, st.tneed, st.tdiag, st.tstale = st.tblk or {}, st.tneed or {}, st.tdiag or {}, st.tstale or {}
  -- the members lack this tool while its jobs wait: T.forbid may unforbid that many forbidden ones
  st.tneed[kind] = #without > 0 and open > 0 and #without or nil
  -- BUG-187: the player's long-term patients (not in cur) keep their first-seen tick, or they would count again
  local pms = {}
  for k in pairs((st.tpat_ids or {})[spec.name] or {}) do
    local t = type(rec.ms) == 'table' and math.tointeger(rec.ms[k]) or nil
    if t then pms[k] = t end
  end
  st.tmiss = st.tmiss or {}
  if #without == 0 or open == 0 or free + forb == 0 then
    st.tmiss[kind] = nil
    st.tblk[spec.name], st.tdiag[spec.name], st.tstale[kind] = nil, nil, nil
    local keep = (rec.ann or next(pms)) and json.object{ann = rec.ann and CAD.quiet(rec.ann) or nil} or nil
    if keep and next(pms) then keep.ms = json.object(pms) end
    p.tblk[spec.name] = keep
    return
  end
  -- BUG-128 (Run 14: "for N days" counted from the detail's first block while the members rotated): the days of the
  -- oldest member still without the tool (rec.ms: unit id -> the tick he was first seen without it)
  local ms, oldest = {}, r.now
  for _, id in ipairs(without) do
    local k = tostring(id)
    local t = type(rec.ms) == 'table' and math.tointeger(rec.ms[k]) or nil
    t = t or (type(rec.ms) ~= 'table' and math.tointeger(rec.since)) or r.now   -- the old detail-wide record, once
    ms[k] = t
    if t < oldest then oldest = t end
  end
  for k, t in pairs(pms) do ms[k] = ms[k] or t end
  rec.ms, rec.since = json.object(ms), nil
  local days = (r.now - oldest) // DAY
  local bins, res = inv['w_' .. kind .. '_bin'] or 0, inv['w_' .. kind .. '_res'] or 0
  -- BUG-023 (Run 11; live L1b: the melt pile's marks kept the spare picks from the miners for a year): a free tool marked
  -- for melting loses the mark (the item sheet's melt toggle), as many a day as members lack the tool
  local unmelt = 0
  for _, e in ipairs((st.tool_items or {})[kind] or {}) do
    if e.melt and not e.forb and unmelt < #without and K.act.item_flag(e.id, 'melt', false) then
      e.melt, unmelt = nil, unmelt + 1
    end
  end
  if unmelt > 0 then
    K.log('info', '%s: %d free %s(s) marked for melting while %d members hold none: melt mark taken off', spec.name,
          unmelt, kind, #without)
    fixed = fixed or {}
    fixed[#fixed + 1] = 'melt'
  end
  local toks = {}
  if bins > 0 then toks[#toks + 1] = 'bin' end
  if free - bins > 0 then toks[#toks + 1] = 'loose' end
  if res > 0 then toks[#toks + 1] = 'reserved' end
  if forb > 0 then toks[#toks + 1] = 'forbidden' end
  local seen = {}
  for _, t in ipairs(fixed or {}) do if not seen[t] then seen[t] = true; toks[#toks + 1] = t end end
  -- what keeps DF from handing the tools out (M.tool_diag); its blockers are cause tokens too, so a new one is news
  local pos = tool_where(kind)
  local pop = {free = free, forb = forb, own = inv['w_' .. kind .. '_own'] or 0, far = inv['w_' .. kind .. '_far'] or 0,
               use = inv['w_' .. kind .. '_use'] or 0, res = res, pos = pos}
  local fresh, tnow = {}, K.now().tick
  for _, id in ipairs(without) do
    local t = (st.fixes or {})[spec.name .. ':' .. id]
    if t and tnow - t < DAY then fresh[id] = true end
  end
  local okd, dg = pcall(M.tool_diag, K, spec, kind, without, cur, jc, pop, fresh)
  if not okd then K.log('warn', '%s: tool diagnosis failed: %s', spec.name, tostring(dg)); dg = nil end
  local ctoks = {table.unpack(toks)}
  for _, k in ipairs(dg and dg.keys or {}) do ctoks[#ctoks + 1] = 'b:' .. k end
  -- BUG-707: the members lack the tool and no free one is usable for them (none usable by the census, or the diagnosis' population / walk
  -- blockers: reserved, forbidden, owned, off the group): plan_axes asks the forge and the caravans for that many
  local cut = pop.use <= 0                     -- (`use` leaves the reserved, owned, melting and far ones out)
  for _, k in ipairs(dg and dg.keys or {}) do
    if k == 'walk' or k == 'off_group' or k == 'reserved' or k == 'forbidden' or k == 'owned' then cut = true end
  end
  st.tmiss[kind] = cut and #without or nil
  -- BUG-053: free tools the members lack for stale_days with no member-side cause stop counting as stock; usable ones
  -- that lie loose get a tool pile (T.toolpile) after pile_days
  local memberside = false
  for _, k in ipairs(dg and dg.keys or {}) do if k == 'labor' or k == 'tool2' then memberside = true end end
  -- the count is fixed when the tools turn stale (rec.stn): picks made or bought afterwards are stock again, or the forge
  -- would go on making picks for members DF hands none to
  -- BUG-128 (Run 14: 97 -> 109 free picks, 222 axes, all reachable): the stale count excludes at most stock - (members + 2)
  -- of the reachable tools; the ones on another walk group (note 19: nobody can fetch them) may all be excluded
  if days >= (tc.stale_days or 14) and free > 0 and not memberside then
    rec.stn = math.min(free, math.tointeger(rec.stn) or free)
    local farn = math.min(rec.stn, inv['w_' .. kind .. '_far'] or 0)
    st.tstale[kind] = math.min(rec.stn, farn + math.max(0, (inv['w_' .. kind] or 0) - farn - (#cur + 2)))
  else
    rec.stn, st.tstale[kind] = nil, nil
  end
  if tc.pile ~= false and days >= (tc.pile_days or 7) and pop.use > 0 and not memberside then
    local take = M.tool_src_pile(kind)
    local ats = M.pile_centres(K, spec, jc, cur, pos, take)                 -- BUG-188
    st.tpile_req = #ats > 0 and {kind = kind, spec = spec.name, at = ats[1].at, ats = ats, take = take} or nil
  end
  local ptok = M.pile_text(r.p, true)
  if ptok then ctoks[#ctoks + 1] = ptok end
  local where = {}
  if bins > 0 then where[#where + 1] = string.format('%d in bins', bins) end
  if free - bins > 0 then where[#where + 1] = string.format('%d loose', free - bins) end
  if res > 0 then where[#where + 1] = string.format('%d reserved by squad uniforms', res) end
  if forb > 0 then where[#where + 1] = string.format('%d forbidden', forb) end
  local at = pos and string.format(' at %d,%d,%d', pos[1], pos[2], pos[3]) or ''
  st.tblk[spec.name] = {n = #without, of = #cur, jobs = open, days = days, free = free, bins = bins, res = res,
                        forb = forb, why = table.concat(toks, ','), tool = kind, blk = dg and dg.key or nil,
                        blk_why = dg and dg.why or nil}
  st.tdiag[spec.name] = dg
  local function diag_line(level)
    if not dg then return end
    local ps, us = {}, {}
    for _, x in ipairs(dg.picks) do ps[#ps + 1] = M.td_pick_str(x) end
    for _, x in ipairs(dg.units) do us[#us + 1] = M.td_unit_str(x) end
    K.log(level, 'tools: %s blocked (%s): %s | civ alert burrows %d, work tool pairs %d%s | %ss: %s | members: %s',
          spec.name, table.concat(dg.keys, ','), dg.whys, dg.civ, dg.ww, dg.upw and ', update.weapon pending' or '',
          kind, table.concat(ps, '; '), table.concat(us, '; '))
  end
  st.tdk = st.tdk or {}
  local logged = false
  if dg and st.tdk[spec.name] ~= dg.whys then             -- the diagnosis changed (or the first one after a load)
    st.tdk[spec.name] = dg.whys
    diag_line('info')
    logged = true
  end
  if days >= (tc.block_days or 3) then
    local now = K.now()
    if CAD.due(rec.ann, now, without, ctoks) then
      rec.ann = CAD.mark(now, without, ctoks)
      local names = {}
      for i = 1, math.min(3, #without) do names[i] = unit_name(without[i]):sub(1, 24) end
      local hint = res > 0 and 'squad uniforms reserve tools (military gives up the pick/axe specs beyond the spare tools); ' or ''
      local eqn, eqt = math.tointeger(rec.eq) or 0, math.tointeger(rec.eqt)
      local eqd = eqt and math.max(0, (r.now - eqt) // DAY) or nil
      hint = hint .. (tc.equip_update == true and (eqn > 0 and
                        string.format('equipment update requested %d times (last %d days ago), no tool picked up yet',
                                      eqn, eqd or 0) or 'equipment update requested with the labor') or
                      'the player may toggle the detail in the work details screen (untested); tools.equip_update ' ..
                      'needs his yes')
      local msg = string.format('%s: %d of %d hold no %s for %d days, %d %s jobs open; %d free %ss (%s)%s',
                                spec.name, #without, #cur, kind, days, open, JOB_NAME[spec.jobs] or spec.jobs, free, kind,
                                table.concat(where, ', '), at)
      if dg and #msg + #dg.why + 2 <= 200 then msg = msg .. ': ' .. dg.why end
      local d = {detail = spec.name, tool = kind, n = #without, members = {table.unpack(without, 1, math.min(10, #without))},
                 jobs = open, days = days, free = free, bins = bins, reserved = res, why = table.concat(toks, ','),
                 who = table.concat(names, ', '), hint = hint:sub(1, 200)}
      if pos then d.pos = pos end
      d.tell = M.tool_tell(spec, kind, {keys = dg and dg.keys, forb = forb, free = free, res = res, bins = bins})
      -- BUG-116: care first leads and the tool is what its dig waits for
      local okc, cf = K.call('runner', 'care_first')
      if okc and type(cf) == 'table' and cf.proj and kind == 'pick' then
        d.care = string.format('the hospital project %s (%s) leads and needs the miners\' %ss',
                               tostring(cf.proj):sub(1, 24), tostring(cf.why or '?'):sub(1, 24), kind):sub(1, 100)
      end
      if eqn > 0 then d.eq, d.eq_days = eqn, eqd or 0 end
      if forb > 0 then d.forb = forb end
      local ptxt = M.pile_text(r.p)
      if ptxt then d.pile = ptxt end
      local src = M.tool_src_pile(kind)
      if src then d.src = src end
      local g = M.tool_guards(spec, kind, dg, rec, st.tstale[kind], src, r.p)
      if g then d.g = g end
      if dg then M.td_event(d, dg) end
      K.log('warn', '%s', msg)
      if not logged then diag_line('warn') end
      K.emit('TOOL_BLOCKED', 'A', msg:sub(1, 200), d)
    end
  end
  p.tblk[spec.name] = json.object(rec)
end

local function tools(K, c, p, inv, engine, r)
  local tc = c.tools
  local cu = K.census.u
  if type(tc) ~= 'table' or engine == nil or engine == 'modern' then return 0 end
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' then return 0 end
  local wds = {}
  local li = df.global.plotinfo.labor_info
  if not li then return 0 end
  for _, w in ipairs(li.work_details) do wds[dfhack.df2utf(w.name)] = w end
  local cit, adults, count, holder_of = {}, {}, {}, {}
  for _, id in ipairs(cu.ids) do
    local u = df.unit.find(id)
    if u and not dfhack.units.isDead(u) then
      cit[id] = u
      if dfhack.units.isAdult(u) then
        adults[#adults + 1] = u
        for _, l in ipairs(tc.key_labors or {}) do
          if labor_on(u, l) then count[l] = (count[l] or 0) + 1; holder_of[l] = id end
        end
      end
    end
  end
  local sole = {}
  for l, n in pairs(count) do if n == 1 then sole[holder_of[l]] = true end end
  local member, tool_names = {}, {}       -- unit id -> name of its first tool detail
  for _, spec in ipairs(tc.details or {}) do
    tool_names[spec.name] = true
    local wd = wds[spec.name]
    if wd then for _, id in ipairs(wd.assigned_units) do member[id] = member[id] or spec.name end end
  end
  local keep = {}
  for _, n in ipairs(tc.keep_labors or {}) do
    local l = df.unit_labor and df.unit_labor[n]
    if type(l) == 'number' then keep[l] = true end
  end
  local function soft_ok(u)                  -- may be picked
    return not noble(u) and not sole[u.id] and not ((u.mood or -1) >= 0)
  end
  p.tools = json.object(type(p.tools) == 'table' and p.tools or {})
  p.tblk = json.object(type(p.tblk) == 'table' and p.tblk or {})
  st.fixes = st.fixes or {}
  local now, changes, taken = K.now().tick, 0, {}
  local jc = tool_jobs(M.cover_types(c))
  st.jobc = jc
  local function opts_of(spec)
    local only = spec.only == true and not p.starve
    -- BUG-057: a fishers' detail on "nobody does this" is set to only selected with its first member
    return {only = only or nil, keep = only and tc.keep_labors or nil, equip = tc.equip_update == true or nil,
            select = spec.fish and true or nil}
  end
  local function set(spec, id, on, why, tgt)
    local ok = K.act.work_detail(spec.name, id, on, opts_of(spec))
    if ok then
      changes = changes + 1
      if not on then M.cv_off(spec.name, id) end                 -- BUG-057: taken off by the kernel itself
      -- a member added now got the equipment update with its labor: its tool repair waits repair_days
      if on then st.fixes[spec.name .. ':' .. id] = now end
      local u = df.unit.find(id)
      local who = u and dfhack.df2utf(dfhack.units.getReadableName(u)) or ('unit ' .. id)
      K.emit('WORK_DETAIL', 'B', string.format('%s %s %s (%s, target %d)', spec.name, on and '+' or '-', who, why,
                                               tgt), {detail = spec.name, unit = id, on = on and 1 or 0, n = tgt,
                                                      why = why})
    end
    return ok
  end
  for _, spec in ipairs(tc.details or {}) do
    local wd = wds[spec.name]
    if wd then
      local tgt, basis = tool_target(K, spec, #cu.ids, inv, r, jc)
      local sid = df.job_skill[spec.skill]
      local function skill(u) return sid and dfhack.units.getNominalSkill(u, sid, true) or 0 end
      local ps = p.tools[spec.name] or {}
      local mine = {}
      for _, id in ipairs(type(ps.mine) == 'table' and ps.mine or {}) do
        if math.tointeger(id) then mine[math.tointeger(id)] = true end
      end
      local keep_ids = {}
      for _, id in ipairs(wd.assigned_units) do keep_ids[#keep_ids + 1] = id end
      local cur = {}
      local trec, npat, pids = p.tblk[spec.name], 0, {}
      for _, id in ipairs(keep_ids) do
        local u = cit[id]
        local ok_u = u and dfhack.units.isAdult(u) and u.military.squad_id < 0 and not taken[id]
        local lpat = ok_u and M.tool_long_patient(u, spec, tc, trec, now)       -- BUG-187
        if lpat then npat = npat + 1; pids[tostring(id)] = true end
        -- BUG-740: a squad member (soldier, captain) never stays on the hunters' detail, the player's entry too
        local sq = spec.ranged ~= nil and u ~= nil and (u.military.squad_id or -1) >= 0
        if ok_u and not lpat then cur[#cur + 1] = u
        elseif mine[id] or sq then
          if set(spec, id, false, lpat and 'patient' or taken[id] and ('in ' .. taken[id]) or 'not eligible', tgt) then
            mine[id] = nil
            if lpat then npat, pids[tostring(id)] = npat - 1, nil end     -- off the detail: no longer a member
          end
        end                                      -- the player's member that is not eligible stays and does not count
      end
      st.tpat, st.tpat_ids = st.tpat or {}, st.tpat_ids or {}
      st.tpat[spec.name], st.tpat_ids[spec.name] = npat > 0 and npat or nil, npat > 0 and pids or nil
      -- the tools the members can use: free (no holder, not reserved by a squad uniform) plus the ones they hold
      local has = {}                             -- members that hold the detail's tool (they stay first)
      if spec.tool then                         -- BUG-023: the demand before the tool cap (military keeps these tools)
        st.want = st.want or {}
        st.want[spec.tool] = math.max(tgt, #cur)
      end
      if tgt > 0 and spec.tool then
        local held = 0
        for _, u in ipairs(cur) do if holds_tool(u, spec.tool) then held, has[u.id] = held + 1, true end end
        local free = math.max(0, (inv['w_' .. spec.tool .. '_free'] or 0) - (inv['w_' .. spec.tool .. '_res'] or 0))
        tgt = math.min(tgt, free + held)
      elseif tgt > 0 and (spec.melee or spec.ranged) then tgt = math.min(tgt, tool_count(spec, inv)) end
      if #cur < tgt then
        ps.low = nil
        local cand = {}
        -- BUG-128: no patient and no doctor joins; the best skill first, then the detail's profession (MINER, WOODCUTTER)
        local skip = {}
        for _, u in ipairs(adults) do
          if not member[u.id] and not taken[u.id] and u.military.squad_id < 0 and soft_ok(u) then
            local why = M.tool_cand_skip(u, spec)
            if why then skip[why] = (skip[why] or 0) + 1 else cand[#cand + 1] = u end
          end
        end
        st.tskip = st.tskip or {}
        st.tskip[spec.name] = next(skip) and skip or nil
        table.sort(cand, function(a, b)
          local sa, sb = skill(a), skill(b)
          if sa ~= sb then return sa > sb end
          local pa, pb = M.tool_prof(a, spec), M.tool_prof(b, spec)
          if pa ~= pb then return pa end
          return a.id < b.id
        end)
        for _, u in ipairs(cand) do
          if #cur >= tgt then break end
          if set(spec, u.id, true, string.format('basis %d', basis), tgt) then
            cur[#cur + 1] = u
            member[u.id] = spec.name
            mine[u.id] = true
          end
        end
      elseif #cur > math.max(tgt, M.tool_floor(spec, jc)) then
        tgt = math.max(tgt, M.tool_floor(spec, jc))   -- BUG-128: never 0 while the detail's jobs exist
        ps.low = ps.low or now
        -- hunters outside the walls while the fort leaves PEACE: off the detail now (siege reflex, drills); every
        -- member then, also the player's
        local at_once = r ~= nil and ((spec.ranged ~= nil and (r.hunt_why == 'siege' or r.hunt_why == 'predator')) or  -- BUG-326: a real siege only
                                      (spec.fish ~= nil and (r.fish_why == 'siege' or r.fish_why == 'water beast')))
        if at_once or now - ps.low >= (tc.shrink_days or 3) * DAY then
          local out, stay = {}, {}
          -- BUG-128: a member who holds the tool, has DF's work tool pair or joined less than keep_days ago stays
          local okw, _, _, wu = pcall(M.td_pool)
          local kept = 0
          for _, u in ipairs(cur) do
            local kw = not at_once and mine[u.id] and M.tool_keep(u, spec, tc, ps, now, okw and wu or nil)
            if kw then kept = kept + 1 end
            if at_once or (mine[u.id] and not kw) then out[#out + 1] = u else stay[#stay + 1] = u end
          end
          st.tkept = st.tkept or {}
          st.tkept[spec.name] = kept > 0 and kept or nil
          table.sort(out, function(a, b)               -- a member with the tool stays, then the best skill
            local ha, hb = has[a.id] == true, has[b.id] == true
            if ha ~= hb then return ha end
            local sa, sb = skill(a), skill(b)          -- (live L1b: shrinking by eligibility first dropped the
            if sa ~= sb then return sa > sb end        -- fort's only trained miner, the bookkeeper)
            local oa, ob = soft_ok(a), soft_ok(b)
            if oa ~= ob then return oa end
            return a.id < b.id
          end)
          local why = at_once and ('mode ' .. tostring(K.mode())) or string.format('basis %d', basis)
          while #stay + #out > tgt and #out > 0 do
            local u = table.remove(out)
            if not set(spec, u.id, false, why, tgt) then out[#out + 1] = u; break end
            if at_once then M.drill_off_add(p, spec.name, u.id) end   -- BUG-295, BUG-326: back when the siege ends
            mine[u.id] = nil
          end
          cur = stay
          for _, u in ipairs(out) do cur[#cur + 1] = u end
          ps.low = nil
        end
      else
        ps.low = nil
      end
      -- labor repair and the specialist rule (one act.work_detail per member, at most every repair_days)
      -- (not in a starvation: T.starve may make anybody a planter then)
      local fixed, evl = {}, spec.only and #cur > 0 and not p.starve and everybody_labors(li, wd, tool_names, keep) or nil
      local sets = evl and #evl > 0 and member_sets(li) or nil
      -- Run 10 (equip_update on after the members were added): a member without its tool in hand while free tools
      -- exist gets the equipment update request again, at the first pass after a load and then every repair_days
      local free_tools = spec.tool and (inv or {})['w_' .. spec.tool .. '_free'] or 0
      local eq = {}
      for _, u in ipairs(cur) do
        local why, xl
        if spec.labor and not labor_on(u, spec.labor) then why = 'labor'
        elseif sets and needs_specialist(li, sets, u, evl, wd) then why = 'everybody'
        else
          -- BUG-023 (Run 11): a second tool labor no detail grants (MINE/CUTWOOD/HUNT: one per dwarf) goes off
          xl = M.stray_tool(li, u, wd, spec.name)
          if xl then why = 'xlabor'
          elseif tc.equip_update == true and free_tools > 0 and not holds_tool(u, spec.tool) then why = 'tool' end
        end
        local key = spec.name .. ':' .. u.id
        if why and now - (st.fixes[key] or -1e12) >= (tc.repair_days or 7) * DAY then
          st.fixes[key] = now
          local o = opts_of(spec)
          local lacks = spec.tool and not holds_tool(u, spec.tool)
          if why == 'tool' or (why == 'xlabor' and lacks and o.equip) then o.equip = 'force' end
          if K.act.work_detail(spec.name, u.id, true, o) then
            changes = changes + 1
            if why == 'tool' then eq[#eq + 1] = u.id else fixed[#fixed + 1] = why end
            if why == 'xlabor' and o.equip == 'force' then eq[#eq + 1] = u.id end
            K.log('info', '%s: %s %s', spec.name, unit_name(u.id),
                  why == 'labor' and ('had no ' .. spec.labor .. ' labor: set through the detail') or
                  why == 'tool' and ('holds no ' .. spec.tool .. ': equipment update requested again') or
                  why == 'xlabor' and ('held a second tool labor (' .. xl .. ', no detail grants it): taken off ' ..
                                       'through the detail') or
                  'left the everybody-does-this details (specialist)')
          end
        end
      end
      local list = {}
      for id in pairs(mine) do list[#list + 1] = id end
      table.sort(list)
      ps.mine = json.array(list)
      -- BUG-128: the ticks the kernel's members joined (keep_days); one seen first now counts from now
      local at = {}
      for _, id in ipairs(list) do
        local k = tostring(id)
        at[k] = type(ps.at) == 'table' and math.tointeger(ps.at[k]) or now
      end
      ps.at = json.object(at)
      p.tools[spec.name] = json.object(ps)
      for _, u in ipairs(cur) do taken[u.id] = spec.name end
      if spec.tool and #eq > 0 then
        local rec = type(p.tblk[spec.name]) == 'table' and p.tblk[spec.name] or {}
        rec.eq, rec.eqt = (math.tointeger(rec.eq) or 0) + #eq, now
        p.tblk[spec.name] = json.object(rec)
      end
      if spec.tool and r and r.day then tool_check(K, tc, r, spec, cur, jc, fixed) end
      local serial = spec.tiles_per and #cur >= 3 and jc.dig > 0 and jc.dig_open == 0 and basis > 2 * jc.dig
      if serial and r and r.day and st.dig_hint ~= jc.dig then
        -- a single tunnel is dug serially (one job per front): more miners help only with several fronts
        K.log('info', 'Miners: %d dig tiles planned but %d dig jobs (fronts): open several fronts for %d miners',
              basis, jc.dig, #cur)
      end
      if spec.tiles_per then st.dig_hint = serial and jc.dig or nil end
      if spec.ranged then
        st.hunters = #cur                          -- on.MODE: leaving PEACE with hunters out rushes a run
        if r and r.day then hunt_book(K, c, r, #cur) end
      elseif spec.fish then
        st.fishers = #cur                          -- the same for fishers at the water (live L5)
      end
    end
  end
  changes = changes + M.soldier_hunt_off(K, cu.soldier_ids, now, adults, wds.Hunters, p)
  return changes
end

-- BUG-740 (Run 16d i4 Pagedsculpture y386: the militia captain Rovod, a Bone Carver, 'cancels Hunt for small creature: Could not find
-- path' for days, missing a week, dead of thirst on the surface at z110; the fort held 16 citizens): a squad member (soldier or captain)
-- with the Hunting labor on walks out of the walls on a vermin or game hunt, also in an alert, on no detail the kernel runs. The labor
-- goes off for each squad member (act.labor_set 'hunt', the labors screen), at most once a day per unit and 3 a pass; WORK_DETAIL
-- (B) why 'soldier'. Returns the number switched off.
-- BUG-741 (Run 16c i3 Doorwings y385: the Gem Cutter 28225, in no detail the kernel runs, on a HuntVermin job 70 tiles from the fort,
-- STRANDED on a walk group with no way back to drink, dead of thirst; the Hunters detail never held him): the same for a civilian who has
-- the Hunting labor on and is no member of the Hunters detail (`adults`, `wd`; why 'stray'), except in a famine (the kernel wants
-- hunters then) and with the detail on 'everybody does this' (the labor is meant for all).
M.SOLDIER_HUNT_MAX = 3
function M.soldier_hunt_off(K, ids, now, adults, wd, p)
  st.fixes = st.fixes or {}
  local n = 0
  local function off(u, why, txt)
    local id = u.id
    local key = 'soldier_hunt:' .. tostring(id)
    if n >= M.SOLDIER_HUNT_MAX or now - (st.fixes[key] or -1e12) < DAY then return end
    if not M.labor_flag(u, 'HUNT') then return end
    st.fixes[key] = now
    local ok, res = K.act.labor_set(id, 'hunt', false)
    if ok and res == 'disabled' then
      n = n + 1
      K.emit('WORK_DETAIL', 'B', string.format('Hunting labor - %s (%s)', unit_name(id), txt),
             {detail = 'Hunters', unit = id, on = 0, n = 0, why = why})
    end
  end
  local sold = {}
  for _, id in ipairs(type(ids) == 'table' and ids or {}) do
    local u = math.tointeger(id) and df.unit.find(id)
    if u and not dfhack.units.isDead(u) and (u.military.squad_id or -1) >= 0 then
      sold[id] = true
      off(u, 'soldier', 'squad member: no hunting outside the walls')
    end
  end
  local every = df.work_detail_mode and df.work_detail_mode.EverybodyDoesThis
  if not wd or (every ~= nil and wd.flags.mode == every) or (type(p) == 'table' and p.famine) then return n end
  local mem = {}
  for _, id in ipairs(wd.assigned_units) do mem[id] = true end
  for _, u in ipairs(type(adults) == 'table' and adults or {}) do
    if not mem[u.id] and not sold[u.id] and (u.military.squad_id or -1) < 0 then
      off(u, 'stray', 'in no hunters detail: no hunting outside the walls')
    end
  end
  return n
end

-- BUG-295 (Run 15c Inkintense y376: every automatic drill took both hunters off their detail, 'mode DRILL', #1408/#1409,
-- #1492/#1493, and they came back only with the next full economy run 30,000-50,000 ticks later, in a famine): the members
-- a DRILL took off (p.drill_off = {detail = {ids}}) go back on that detail as soon as the mode is PEACE or RECOVERY again
-- (on.MODE), through the work details screen like any other add (act.work_detail), WORK_DETAIL why 'drill over'. A unit
-- that died, joined a squad or is no adult any more stays off; the next tools pass decides about it as usual.
function M.drill_off_add(p, name, id)
  p.drill_off = json.object(type(p.drill_off) == 'table' and p.drill_off or {})
  local l = type(p.drill_off[name]) == 'table' and p.drill_off[name] or {}
  for _, x in ipairs(l) do if x == id then return end end
  l[#l + 1] = id
  p.drill_off[name] = json.array(l)
end

function M.drill_restore(K)
  local p = pstate(K)
  local off = type(p.drill_off) == 'table' and p.drill_off or nil
  if not off or next(off) == nil then return 0 end
  p.drill_off = nil
  K.persist.touch('m.economy')
  local c = M.conf(K)
  local tc = type(c.tools) == 'table' and c.tools or {}
  local n = 0
  for _, spec in ipairs(tc.details or {}) do
    local ids = off[spec.name]
    for _, id in ipairs(type(ids) == 'table' and ids or {}) do
      local u = math.tointeger(id) and df.unit.find(id)
      if u and not dfhack.units.isDead(u) and dfhack.units.isAdult(u) and u.military.squad_id < 0 then
        local only = spec.only == true and not p.starve
        local o = {only = only or nil, keep = only and tc.keep_labors or nil, equip = tc.equip_update == true or nil,
                   select = spec.fish and true or nil}
        if K.act.work_detail(spec.name, id, true, o) then
          n = n + 1
          if spec.ranged then st.hunters = (st.hunters or 0) + 1 elseif spec.fish then st.fishers = (st.fishers or 0) + 1 end
          p.tools = json.object(type(p.tools) == 'table' and p.tools or {})
          local ps = type(p.tools[spec.name]) == 'table' and p.tools[spec.name] or {}
          local mine = type(ps.mine) == 'table' and ps.mine or {}
          local has = false
          for _, x in ipairs(mine) do if x == id then has = true end end
          if not has then mine[#mine + 1] = id end
          ps.mine = json.array(mine)
          p.tools[spec.name] = json.object(ps)
          K.emit('WORK_DETAIL', 'B', string.format('%s + %s (drill over, back from the drill)', spec.name, unit_name(id)),
                 {detail = spec.name, unit = id, on = 1, n = #mine, why = 'drill over'})
        end
      end
    end
  end
  if n > 0 then K.log('info', 'drill over: %d member%s back on the hunting/fishing details', n, n == 1 and '' or 's') end
  return n
end

-- CONTRACTS Ã‚Â§7: the supply alarm, or nil (arbiter brakes tempo while it is set)
function M.alarm(K) return st.alarm end
-- BUG-023: the tool details' demand before the tool cap, {pick = n, axe = n} (nil before the first tools pass);
-- military keeps that many picks and axes out of the soldiers' weapon specs
function M.tool_want(K) return st.want end

---------------------------------------------------------------- famine (live L1: a dwarf starved unnoticed)
-- Below famine_days of eatable food: let labormanager staff hunters and fishers (modern mode forbids both
-- by default) and wake the LLM once per famine week (gathering zones, farms, trade are its tools).
local function famine(K, c, p, days, inv, r)
  local fd, dd = days.food_d, days.drink_d
  local lim = c.famine_days or 10
  if fd >= lim then
    if p.famine then p.famine = nil; K.log('info', 'famine over: %d food days', fd) end
    return
  end
  local now = K.now().tick
  if not p.famine then
    p.famine = {since = now, woke = 0}
    r.cmdq[#r.cmdq + 1] = {'labormanager', 'allow-hunting'}
    r.cmdq[#r.cmdq + 1] = {'labormanager', 'allow-fishing'}
    K.log('warn', 'famine: %d food days (%d eatable, %d cookable), hunting and fishing allowed', fd, inv.food or 0,
          inv.cookable or 0)
  end
  if now - (p.famine.woke or 0) >= 7 * DAY then
    p.famine.woke = now
    -- Run 11: the blockers (no fishery for the raw fish, why the kitchens cook nothing, no safe fishing water, ...)
    local bl, auto = M.food_block(K, c, r, inv)
    local q, opts, cmds = M.food_q(fd, r, inv, bl, auto, M.food_more(K, r))
    local ids, aids, head = M.food_head(bl, auto)
    K.emit('DECISION_NEEDED', 'A', string.format('famine: %d food days, %d drink days%s', fd, dd, head),
           {id = 'famine', q = q, food = fd, block = ids, opts = opts, auto = aids,
            cmds = #cmds > 0 and cmds or nil})     -- BUG-340
  end
end

---------------------------------------------------------------- food follows the population (live L5)
-- Castlerisen y294-y295: migrants took the fort from 41 to 53 citizens on the same 80 farm tiles, autofarm's
-- threshold 50 stopped the helmets at 40, nothing fished; food fell from 105 to 15 days and the fort was paused.
-- built farm plot tiles (buildings.other.FARM_PLOT, surface and underground alike)
local function farm_tiles()
  local n = 0
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.FARM_PLOT) do
      if built(b) then n = n + math.max(0, ((b.x2 or 0) - (b.x1 or 0) + 1) * ((b.y2 or 0) - (b.y1 or 0) + 1)) end
    end
  end)
  return n
end

-- the farm tiles cit citizens want: cit * per_dwarf plants a season at `yield` crops per tile and season
function M.farm_need(cit, fc)
  fc = type(fc) == 'table' and fc or M.DEFAULTS.food
  local y = math.max(1, math.tointeger(fc.yield) or 1)
  return ((math.tointeger(cit) or 0) * (math.tointeger(fc.per_dwarf) or 3) + y - 1) // y
end

-- daily: the food trend over trend_days, the farm tiles wanted, a farms request (follow places it) while food is
-- below want_days or falling, the fort has fewer tiles than it wants and no farms project is pending
local function food_plan(K, c, r)
  local fc = c.food
  if type(fc) ~= 'table' then return end
  local p, inv = r.p, r.inv
  if type(p.fhist) ~= 'table' then p.fhist = {} end
  local h = p.fhist
  h[#h + 1] = math.tointeger(inv.food or 0) or 0
  local span = math.max(1, math.tointeger(fc.trend_days) or 14)
  while #h > span + 1 do table.remove(h, 1) end
  local falling = #h > span and h[#h] < h[1]
  local tiles, need = farm_tiles(), M.farm_need(r.cit, fc)
  local fd = (r.days or {}).food_d or 9999
  local pt = math.max(1, math.tointeger(fc.plot_tiles) or 35)
  -- BUG-256 (live Inkintense y373/y374: famine on 1 plot; the player placed the second farm by hand): during a famine
  -- (below famine_days) one more plot is wanted on top of the tiles built, up to twice the citizens' need
  local hungry = p.famine and tiles < 2 * math.max(need, pt)
  if hungry then need = math.max(need, tiles + pt) end
  st.food = {tiles = tiles, need = need, falling = falling, fd = fd}
  if tiles >= need or not (fd < (fc.want_days or 90) or falling) then return end
  local okp, pend = K.call('runner', 'pending', 'farms')
  if okp and (math.tointeger(pend) or 0) > 0 then return end
  -- BUG-058 (DECISIONS 9; Run 11: five farms projects build_lost and parked, no soil): one lost for good stops the
  -- requests until it is cancelled or the farms are placed elsewhere. BUG-257 (live Inkintense/Drillchamber: the same
  -- stone site re-dug for 8 seasons): each lost project is placed elsewhere once (follow ranks farms sites by soil now,
  -- bp/sites.py), then the requests stop as before
  local okl, nl, lid = K.call('runner', 'lost', 'farms')
  local resite
  if type(p.farm_resite) ~= 'table' then p.farm_resite = {} end
  if okl and (math.tointeger(nl) or 0) > 0 then
    if p.farm_resite[tostring(lid)] == nil then resite = tostring(lid)
    else
      if st.farm_lost ~= lid then
        K.log('warn', 'farms: project %s lost to build_lost (no soil there?): no further farms request until it is ' ..
              'cancelled (bp.cancel) or the farms are placed elsewhere', tostring(lid))
      end
      st.farm_lost = lid
      return
    end
  end
  st.farm_lost = nil
  -- BUG-697: in a famine the farms are asked for every famine_request_days (7), not every request_days (14): the placement may find a
  -- smaller plot or another spot a week later (BUG-696), and 35 days of food are 35 days
  local every = p.famine and math.min(fc.request_days or 14, fc.famine_request_days or 7) or (fc.request_days or 14)
  if p.farm_req and r.now - (math.tointeger(p.farm_req) or 0) < every * DAY then return end
  local plots = clamp((need - tiles + pt - 1) // pt, 1, fc.plots_max or 4)
  p.farm_req = r.now
  if resite then
    p.farm_resite[resite] = r.now
    K.log('warn', 'farms: project %s lost to build_lost (no soil there): farms requested once at another site', resite)
  end
  K.log('info', 'farms: %d of %d tiles for %d citizens, food %d days%s: request %d plots', tiles, need, r.cit, fd,
        falling and ' and falling' or '', plots)
  K.emit('PROJECT_REQUEST', 'B', string.format('farms x%d: %d of %d farm tiles for %d citizens, food %d days%s',
                                               plots, tiles, need, r.cit, fd, falling and ' (falling)' or ''),
         {tpl = 'farms', n = plots, why = 'food'})
end

-- the famine pre-alarm: below pre_days (and not yet a famine) a class-A DECISION_NEEDED food_low with the numbers, what
-- keeps the food from coming (M.food_block) and the options. Run 11 (BUG-008 cadence, util/cadence): the first at
-- once, again only with news (a new blocker, or food below 20 days) after max(7 days, 10 min)
local function food_pre(K, c, p, days, inv, r)
  local fc = c.food
  local fd = days.food_d
  local pre, lim = type(fc) == 'table' and (fc.pre_days or 0) or 0, c.famine_days or 10
  if fd >= pre then
    if p.food_pre then p.food_pre = nil; K.log('info', 'food pre-alarm over: %d food days', fd) end
    if type(p.food_rep) == 'table' then p.food_rep = CAD.quiet(p.food_rep) end
    return
  end
  if fd < lim then return end                       -- the famine wake (famine_days) speaks now
  local now = K.now()
  if type(p.food_pre) ~= 'table' then
    p.food_pre = {since = now.tick, woke = 0}
    K.log('warn', 'food pre-alarm: %d food days (< %d)', fd, pre)
  end
  local bl, auto = M.food_block(K, c, r, inv)
  local ids, aids, head = M.food_head(bl, auto)
  local toks = {fd < 20 and 'below20' or 'below30'}
  for _, id in ipairs(ids) do toks[#toks + 1] = id end
  if not CAD.due(p.food_rep, now, {}, toks, {ticks = 7 * DAY, wall_s = CAD.WALL_S}) then return end
  p.food_rep, p.food_pre.woke = CAD.mark(now, {}, toks), now.tick
  local q, opts, cmds = M.food_q(fd, r, inv, bl, auto, M.food_more(K, r))
  K.emit('DECISION_NEEDED', 'A', string.format('food low: %d food days (famine below %d)%s', fd, lim, head),
         {id = 'food_low', q = q, food = fd, block = ids, opts = opts, auto = aids,
          cmds = #cmds > 0 and cmds or nil})       -- BUG-340
end

-- BUG-042 (Run 11, y471: drink 93 -> 32 days beside 15 stills, 275 plants and 3079 growths; every brew order waited
-- for the manager, whose office had no chair): why the stills do not brew the drink deficit, {{id, text}} by weight:
-- no still, no brew order (or none validated: the manager's reason), no brewable plants, no empty barrel, nobody
-- brews; and what the kernel does itself {{id, text}} (brew orders out, barrels ordered, the office's chair placed)
function M.drink_block(K, c, r, inv)
  local f, out, auto = M.facts_now(K, r), {}, {}
  local function put(id, txt) out[#out + 1] = {id, txt} end
  local b = st.brew or M.brew_orders()
  local plants = (inv.brew_p or 0) + (inv.brew_g or 0)
  if not ws_any(f, {'workshop:Still'}) then put('still', 'no still') end
  if b.n == 0 then put('brew', 'no brew order')
  elseif (b.unval or 0) > 0 and st.unval and st.unval.why then        -- past orders.unval_days (M.unval_watch)
    put('unvalidated', string.format('%d brews wait for validation: %s', b.unval, st.unval.why))
  end
  if plants == 0 then
    -- BUG-397: what the fort does about it, so nobody asks: seeds of a brewable crop in stock, the gather zone, the caravans
    local bs, bf = st.bseeds, st.bfit
    local w = bs ~= nil and string.format('no brewable plants (%d seeds; gathering, trade)', bs) or 'no brewable plants'
    -- BUG-406: seeds in stock that fit no plot say so (a plot of their kind is requested)
    if bs and bs > 0 and type(bf) == 'table' and ((bf.surf > 0 and bf.pl_surf == 0) or (bf.under > 0 and bf.pl_under == 0)) then
      w = string.format('no brewable plants (%d seeds fit no farm plot: %s; a plot is requested, gathering)', bs,
                        bf.surf > 0 and bf.pl_surf == 0 and 'surface seeds' or 'underground seeds')
    end
    put('plants', w)
  end
  if (inv.barrels_empty or 0) == 0 then put('barrels', 'no empty barrel') end
  if not M.labor_holder(K, 'BREWER') then put('brewer', 'nobody brews (Brewing on no citizen)') end
  if b.n > 0 then auto[#auto + 1] = {'brew', string.format('%d brews ordered', b.left)} end
  local o = st.office
  if type(o) == 'table' and o.at and o.at ~= '' then auto[#auto + 1] = {'office', o.at .. ' placed'} end
  if r.s and r.s.live['dfllm:barrel'] then auto[#auto + 1] = {'barrels', 'barrels ordered'} end
  local sg = st.gather
  if type(sg) == 'table' and (sg.n or 0) > 0 then auto[#auto + 1] = {'gather', string.format('%d gatherers', sg.n)} end
  return out, auto
end

-- BUG-042: the drink cause in one line (state stock.dwhy, <= 80 bytes) while drink is below the plan's target, or nil
function M.drink_why(K, c, r)
  local d = (r.days or {}).drink_d or 9999
  if d >= (math.tointeger((K.plan.supply or {}).drink_d) or 170) and not st.nowater then return nil end     -- BUG-401
  local bl = M.drink_block(K, c, r, r.inv or {})
  local w = bl[1] and bl[1][2] or nil
  if st.nowater then w = 'no reachable water' .. (w and ('; ' .. w) or '') end            -- BUG-401
  -- BUG-259: below the thirst line with nobody thirsty the status names it (the citizens drink water)
  if st.water then w = (w and (w .. '; ') or '') .. 'nobody thirsty: they drink water' end
  local okg, sd = K.call('siege', 'dry_group')                 -- BUG-391: a cut-off group without drink is no all-clear
  if okg and type(sd) == 'table' and (math.tointeger(sd.n) or 0) > 0 then
    w = string.format('%d stranded without drink (group %s)', math.tointeger(sd.n), tostring(sd.grp)) .. (w and ('; ' .. w) or '')
  end
  return w and w:sub(1, 80) or nil
end

-- BUG-255 (live Inkintense y372: drink 161 -> 55 days in year 1, 'no still', DECISION_NEEDED drink_low only; the player
-- placed workshops only=Still by hand): no Still and no project building one -> PROJECT_REQUEST workshops why=mandatory
-- types=[Still] (+ Kitchen while food is below 60 days and none stands; follow places them), at most every
-- food.request_days and twice an episode; the request is what the kernel did (auto 'still'), not the player's blocker.
-- BUG-259: no brewable plant -> the caravans are asked for plants and drink (M.trade_wants, st.fdwants)
function M.drink_fix(K, c, r, bl, auto)
  local p, now = r.p, r.now or K.now().tick
  local i
  for k, x in ipairs(bl) do if x[1] == 'still' then i = k end end
  if i then
    local q = type(p.still_req) == 'table' and p.still_req or {t = -1e12, n = 0}
    local every = (((c.food or {}).request_days) or 14) * DAY
    if (q.n or 0) < 2 and now - (math.tointeger(q.t) or 0) >= every then
      local types = {'Still'}
      local f = M.facts_now(K, r)
      if ((r.days or {}).food_d or 9999) < 60 and not ws_any(f, {'workshop:Kitchen'}) then types[2] = 'Kitchen' end
      q = {t = now, n = (q.n or 0) + 1}
      p.still_req = q
      K.log('warn', 'drink %d days, no still and no project builds one: request workshops %s (%d/2)',
            (r.days or {}).drink_d or 0, table.concat(types, '+'), q.n)
      K.emit('PROJECT_REQUEST', 'B', string.format('workshops %s: drink %d days and no still', table.concat(types, '+'),
                                                   (r.days or {}).drink_d or 0),
             {tpl = 'workshops', why = 'mandatory', types = types})
    end
    if now - (math.tointeger(q.t) or -1e12) < every then
      table.remove(bl, i)
      auto[#auto + 1] = {'still', 'Still requested'}
    end
  end
  return bl, auto
end

-- BUG-259/BUG-256: what the caravans should bring for food and drink (st.fdwants, read by M.trade_wants): plants and
-- drink while drink is below drink.low_d and no brewable plant is in stock; seeds while farm plots stand (or food is
-- low) and not one usable seed is left
function M.fd_wants(K, c, r)
  local inv, out = r.inv or {}, {}
  local dd = (r.days or {}).drink_d or 9999
  if (dd < (math.tointeger((c.drink or {}).low_d) or 0) or st.nowater) and (inv.brew_p or 0) + (inv.brew_g or 0) == 0 then
    out[#out + 1] = {buy = 'plant', n = 20, why = string.format('drink %d d, no brewable plants', dd)}
    out[#out + 1] = {buy = 'drink', n = 40, why = string.format('drink %d d, no brewable plants', dd)}
  end
  local seeds = 0
  for _, n in pairs(type(st.seeds) == 'table' and st.seeds or {}) do seeds = seeds + (math.tointeger(n) or 0) end
  if st.seeds_known and seeds == 0 and ((st.farm and (st.farm.plots or 0) > 0) or M.food_low(c, r)) then
    out[#out + 1] = {buy = 'seeds', n = 20, why = 'no usable seeds for the farm plots'}
  end
  -- BUG-397: the stills' plants are short and no seed of a brewable crop is in stock: the caravans bring seeds (and the
  -- plants and drink above) -- the gather zone (BUG-382) brings wild plants meanwhile
  if st.bshort and st.bseeds == 0 and (st.farm and (st.farm.plots or 0) > 0) then
    local have = false
    for _, w in ipairs(out) do if w.buy == 'seeds' then have = true end end
    if not have then out[#out + 1] = {buy = 'seeds', n = 15, why = 'no seeds of a brewable crop'} end
    local hp = false
    for _, w in ipairs(out) do if w.buy == 'plant' then hp = true end end
    if not hp then out[#out + 1] = {buy = 'plant', n = 20, why = 'drink short: no brewable seeds'} end
  end
  -- BUG-381: the kitchen has nothing to cook and no seeds of a crop it may cook (M.cook_plan): seeds of one come by trade
  if st.cook_sig == 'none' and (st.farm and (st.farm.plots or 0) > 0) then
    local have = false
    for _, w in ipairs(out) do if w.buy == 'seeds' then have = true end end
    if not have then out[#out + 1] = {buy = 'seeds', n = 10, why = 'no seeds of a crop the kitchen may cook'} end
  end
  -- BUG-340 (Run 15c/15d: the famine decisions asked the player for `trade.want food`, which the verb refused as written
  -- and which replaces the plan's whole want list): below food.pre_days (or in a famine) the caravans bring food and seeds
  if M.food_low(c, r) then
    local fd = (r.days or {}).food_d or 0
    out[#out + 1] = {buy = 'food', n = 30, why = string.format('food %d d', fd)}
    local have = false
    for _, w in ipairs(out) do if w.buy == 'seeds' then have = true end end
    if not have then out[#out + 1] = {buy = 'seeds', n = 10, why = string.format('food %d d: more farm crops', fd)} end
    -- BUG-618: hunters wanted, a crossbow in the fort, no free bolts and nothing to make them of (no logs, no bone): the caravans bring bolts
    if st.no_ammo == true and (inv.w_xbow or 0) + (inv.w_bow or 0) > 0 and (inv.wood or 0) == 0 and (inv.bone or 0) == 0 then
      out[#out + 1] = {buy = 'bolts', n = 25, why = string.format('food %d d: hunters have no bolts, no logs or bone to make them', fd)}
    end
  elseif M.food_early(c, r) then
    -- BUG-618: food falling below twice the pre-alarm line: the caravans are asked now, not at 29 days (a caravan comes once a season)
    out[#out + 1] = {buy = 'food', n = 20, why = string.format('food %d d and falling', (r.days or {}).food_d or 0)}
  end
  st.fdwants = #out > 0 and out or nil
  return out
end

-- BUG-401 (Run 16a Mansionlauded: 13 of 16 dead of thirst in y372-373, the first fort Bachwald the same; the stock of 48 drink
-- days ran out beside a frozen river, no accepted water, no brewable plant, and the only questions came with the thirst):
-- the early check. The water run knows no source the citizens drink at (no Water Source zone, no wet well, no body with a
-- bank they reach: water.drink_access) and not one brewable plant is in stock: the stock is all the fort has, whatever its
-- days say. At once, once a week while it holds: DECISION_NEEDED no_water (A, urgent) with the commands (the water scan, a zone
-- or well at the nearest reachable water, a cistern, the caravans for plants and drink); the kernel sends the gatherers for
-- wild plants (st.bshort) and the caravans (fd_wants) itself. st.nowater switches off 'nobody thirsty: they drink water'.
function M.no_water(K, c, r)
  local p = r.p
  local plants = ((r.inv or {}).brew_p or 0) + ((r.inv or {}).brew_g or 0)
  local oka, acc = K.call('water', 'drink_access')
  local dry = oka and type(acc) == 'table' and acc.known == true and acc.ok == false and plants == 0 and (r.cit or 0) > 0
  -- BUG-446 (Run 16b i2 Roadvises: water 72 tiles off counted as 'reachable', drink 0 days and no brewable plant, nobody asked): water the
  -- citizens reach only farther than water.drink_far tiles, no accepted source, drink under drink_far_d days: dry as well
  local far = false
  if not dry and oka and type(acc) == 'table' and acc.known == true and acc.far == true and plants == 0 and (r.cit or 0) > 0 then
    local fd = math.tointeger(acc.far_d) or 0
    far = fd > 0 and ((r.days or {}).drink_d or 0) < fd
    dry = far
  end
  if not dry then
    if st.nowater then K.log('info', 'no-water check over: %s', oka and type(acc) == 'table' and acc.ok and 'water reachable'
                             or 'brewable plants or no scan') end
    st.nowater = nil
    if type(p.nw_rep) == 'table' then p.nw_rep = CAD.quiet(p.nw_rep) end
    return
  end
  local now, dd = K.now(), (r.days or {}).drink_d or 0
  if not st.nowater then
    K.log('warn', 'no reachable water and no brewable plant: %d bodies, %d with a bank, %d accepted sources, drink %d d', acc.bodies,
          acc.bank, acc.acc, dd)
  end
  st.nowater = {tick = st.nowater and st.nowater.tick or now.tick, d = dd}
  local toks = {dd < 30 and 'below30' or 'stock', 'w' .. (now.tick // (7 * DAY))}               -- a new token each week: the question repeats while it holds
  if not CAD.due(p.nw_rep, now, {}, toks, {ticks = 7 * DAY, wall_s = CAD.WALL_S}) then return end
  p.nw_rep = CAD.mark(now, {}, toks)
  local okf, wtxt, wcmds = K.call('water', 'drink_fix')
  local fix = okf and type(wtxt) == 'string' and wtxt or 'a well over water or a Water Source zone (inspect water_sources)'
  local cmds = {}
  for _, x in ipairs(okf and type(wcmds) == 'table' and wcmds or {}) do cmds[#cmds + 1] = x end
  cmds[#cmds + 1] = 'dfllm cmd inspect what=reach'
  cmds[#cmds + 1] = [[dfllm cmd trade.want '{"add":["plant","drink","seeds"]}']]
  local head = string.format('%d bodies of water, %d with a bank the citizens reach%s, no brewable plant, drink %d d', acc.bodies,
                             acc.bank, acc.partial > 0 and ' (scan partial)' or '', dd)
  if far and acc.bd then head = string.format('the nearest water they reach is %d tiles off, no accepted source, no brewable plant, drink %d d', acc.bd, dd) end
  local q = string.format('no water the citizens reach: %s; what to do: d.water, d.cmds', head)
  if far then q = string.format('water only %d tiles off: %s; what to do: d.water, d.cmds', acc.bd or -1, head) end
  -- BUG-423/424: the water NEAREST to the fort (acc.near, not a fixed representative tile) with the cistern commands that name it
  local nat = type(acc.near) == 'table' and acc.near or (far and type(acc.bat) == 'table' and acc.bat or nil)   -- BUG-446: far water has a bank
  if nat then
    local at = string.format('%d,%d,%d', nat[1], nat[2], nat[3])
    cmds[#cmds + 1] = 'python -m dfpilot.bp.sites cistern --near ' .. at .. ' --radius 20'
  end
  local auto = {'gatherers for wild plants', 'caravans asked for plants and drink'}
  if (acc.emerg or 0) > 0 then auto[#auto + 1] = 'EMERGENCY well accepted as a slow drink source (water.well_emerg)' end
  K.emit('DECISION_NEEDED', 'A', far and string.format('water is %d tiles away, no brewable plant: drink %d days is all the fort has',
                                                       acc.bd or -1, dd)
         or string.format('no reachable water, no brewable plant: drink %d days is all the fort has', dd),
         {id = 'no_water', q = q:sub(1, 200), drink = dd, auto = auto, cmds = cmds, water = M.lines(fix, 200, 2),
          near = nat and json.array{nat[1], nat[2], nat[3]} or nil, nd = far and acc.bd or acc.nd})
  local ad = math.tointeger(((c.drink or {}).access_d)) or 0
  if ad > 0 and dd < ad and nat then
    K.emit('PROJECT_REQUEST', 'B', string.format('cistern: no water the citizens reach, the nearest %d tiles off at %d,%d,%d, drink %d days',
                                                 (far and acc.bd or acc.nd) or -1, nat[1], nat[2], nat[3], dd),
           {tpl = 'cistern', why = 'no_water', n = far and acc.bd or acc.nd, at = json.array{nat[1], nat[2], nat[3]}})
  end
end

-- BUG-042: the drink pre-alarm: below drink.low_d (and from alarm.days on, where DECISION_NEEDED thirst speaks), a
-- class-A DECISION_NEEDED drink_low with the days, why the stills do not brew and what the kernel did; once per
-- episode, again with news (a new cause, below 30 days) after max(7 days, 10 min) (util/cadence)
function M.drink_low(K, c, r)
  local p, dd = r.p, (r.days or {}).drink_d or 9999
  local low = math.tointeger(((c.drink or {}).low_d)) or 0
  st.dwhy = M.drink_why(K, c, r)
  -- BUG-382: the runner draws the gather zone for the stills' plants too: drink below gather.drink_d and the brewable plants
  -- (census brew_p + brew_g) short of the drink deficit (M.brew_need, as M.gather_low's dshort)
  local gd = type(c.gather) == 'table' and math.tointeger(c.gather.drink_d) or 0
  local bneed, bhave = M.brew_need(K, r)
  -- BUG-408 (Run 16a i1: 'no brewable plants' beside 50 seeds, the zone drawn at 60 drink days only): with no brewable plant at all
  -- the zone is drawn from gather.drink_early drink days on
  local ge = type(c.gather) == 'table' and math.tointeger(c.gather.drink_early) or 0
  st.bshort = (dd < gd or st.nowater ~= nil or (bhave == 0 and dd < ge)) and bhave < bneed or nil   -- BUG-401/408
  -- BUG-397: the Cook ban's plants (brewed by rule) and the seeds of brewable crops, for the farm slots, the caravans' wants
  -- and the words of the block
  st.nocook = st.bshort and M.cook_ban_set(c) or nil
  st.bseeds = st.bshort and M.brew_seeds(c) or nil
  local okf, ferr = pcall(M.brew_farm_request, K, c, r)                    -- BUG-406/408: seeds that fit no plot -> a plot
  if not okf then K.log('warn', 'brew farm request: %s', tostring(ferr)) end
  if dd >= low then
    if p.drink_pre then p.drink_pre = nil; K.log('info', 'drink pre-alarm over: %d drink days', dd) end
    if type(p.drink_rep) == 'table' then p.drink_rep = CAD.quiet(p.drink_rep) end
    if type(p.drink_note) == 'table' then p.drink_note = CAD.quiet(p.drink_note) end
    p.still_req = nil
    return
  end
  local now = K.now()
  local bl, auto = M.drink_block(K, c, r, r.inv or {})
  -- BUG-206 (live Earthboat spr d43: DECISION_NEEDED drink_low 'no still' while the applied fortcore stage 1 built the
  -- Still): no still but a pending project builds one, above the thirst alarm: a kern.log note (own cadence p.drink_note),
  -- no wake; the episode's question is not used up, so it comes once the Still stands and drink is still low
  local sq = bl[1] and bl[1][1] == 'still' and M.fishery_proj(K, {'workshop:Still'})
  if not sq then M.drink_fix(K, c, r, bl, auto) end                        -- BUG-255
  -- the thirst wake speaks now (BUG-259: only with a thirsty citizen; drinking water, drink_low goes on asking)
  if dd < ((c.alarm or M.DEFAULTS.alarm).days or 10) and not st.water then return end
  if not p.drink_pre then
    p.drink_pre = now.tick
    K.log('warn', 'drink pre-alarm: %d drink days (< %d)%s', dd, low, st.dwhy and (': ' .. st.dwhy) or '')
  end
  local ids, aids, head = M.food_head(bl, auto)
  local toks = {dd < 30 and 'below30' or 'below60'}
  for _, id in ipairs(ids) do toks[#toks + 1] = id end
  if sq then
    if CAD.due(p.drink_note, now, {}, toks, {ticks = 7 * DAY, wall_s = CAD.WALL_S}) then
      p.drink_note = CAD.mark(now, {}, toks)
      K.log('warn', 'drink low: %d drink days, no still yet: project %s builds one (%s %s%%)%s', dd, sq.id,
            tostring(sq.stage), tostring(sq.pct), sq.halted and (', halted: ' .. sq.halted) or '')
    end
    return
  end
  if not CAD.due(p.drink_rep, now, {}, toks, {ticks = 7 * DAY, wall_s = CAD.WALL_S}) then return end
  p.drink_rep = CAD.mark(now, {}, toks)
  local parts, au = {}, {}
  for _, x in ipairs(bl) do parts[#parts + 1] = x[2]:sub(1, 90) end
  for _, x in ipairs(auto) do au[#au + 1] = x[2]:sub(1, 50) end
  local ap = #au > 0 and ('; auto: ' .. table.concat(au, ', ')) or ''
  local q = string.format('drink %d d (%d cit, %d brewable plants, %d empty barrels)', dd, r.cit or 0,
                          (r.inv.brew_p or 0) + (r.inv.brew_g or 0), r.inv.barrels_empty or 0) ..
            (#parts > 0 and (': ' .. table.concat(parts, '; ')) or '')
  if #q + #ap > 200 then q = q:sub(1, math.max(40, 197 - #ap)) .. '...' end
  K.emit('DECISION_NEEDED', 'A', string.format('drink low: %d drink days (thirst alarm below %d)%s', dd,
                                               (c.alarm or M.DEFAULTS.alarm).days or 10, head):sub(1, 200),
         {id = 'drink_low', q = (q .. ap):sub(1, 200), drink = dd, block = ids, auto = aids})
end

-- autofarm status: one "SPELT limit 50 current 32" line per crop autofarm knows, and "Default: 50"
function M.parse_autofarm(out)
  local crops, default = {}, nil
  for line in tostring(out or ''):gmatch('[^\r\n]+') do
    local id, lim = line:match('^%s*([A-Z][A-Z0-9_]*) limit (%d+)')
    if id then crops[#crops + 1] = {id = id, limit = math.tointeger(tonumber(lim))} end
    local d = line:match('[Dd]efault[^0-9\n]*([0-9]+)')
    if d then default = math.tointeger(tonumber(d)) end
  end
  return crops, default
end

---------------------------------------------------------------- orders: crash guard and sanity (FR-39, FR-01)
local function job_name(o) return df.job_type[o.job_type] end

-- FR-39: open make-item orders without an item subtype (DF 53.16 crashes when a dwarf takes their job)
local function unsafe_orders()
  local r = {}
  for _, o in ipairs(orders_all()) do
    local okn, job = pcall(job_name, o)
    if okn and (o.amount_left or 0) > 0 and OL.unsafe(job, o.item_subtype) then
      r[#r + 1] = {id = o.id, job = tostring(job), left = o.amount_left}
    end
  end
  return r
end

-- reaction raws: workshop keys and labor of a CustomReaction order (cached per boot; a custom workshop: nil)
local function reaction_needs(name)
  if type(name) ~= 'string' or name == '' then return nil end
  local c = rcache[name]
  if c == nil then
    c = false
    pcall(function()
      for _, rx in ipairs(df.global.world.raws.reactions.reactions) do
        if rx.code == name then
          local ws, bt = {}, df.building_type
          for i, t in ipairs(rx.building.type) do
            local sub = rx.building.subtype[i]
            local wn = t == bt.Workshop and df.workshop_type[sub] or t == bt.Furnace and df.furnace_type[sub] or nil
            if not wn or wn == 'Custom' then ws = nil; break end
            ws[#ws + 1] = (t == bt.Workshop and 'workshop:' or 'furnace:') .. wn
          end
          local okl, l = pcall(function() return df.job_skill.attrs[rx.skill].labor end)
          local ln = okl and type(l) == 'number' and l >= 0 and df.unit_labor[l] or nil
          c = {ws = ws and #ws > 0 and ws or nil, labors = ln and {ln} or nil}
          break
        end
      end
    end)
    rcache[name] = c
  end
  if not c then return nil end
  return c.ws, c.labors
end

-- the input checks of one run: reachable stock per census key, labor holders among the free adults
local function order_ctx(K, c, r)
  local inv = r.inv or {}
  local reach = st.reach
  local ctx = {f = r.f or {}, holders = {}, mgr = M.manager_state(K), uwhy = st.unval and st.unval.why}
  function ctx.is_metal(mi)
    local f = mat_flags({mat_type = 0, mat_index = mi})
    return f ~= nil and f.IS_METAL == true
  end
  function ctx.has(key)
    if key == 'cook' then return M.cook_n(inv) > 0
    elseif key == 'fish_raw' then return (inv.fish_raw or 0) > 0
    -- B2: M.slab_pass counts them; J2: a blank slab a running job holds is the job's (the trim keeps blank + busy orders),
    -- the order is not blocked for want of one: three engravings at work were a "jam" of three cancelling jobs
    elseif key == 'slab_blank' then return st.slab == nil or (st.slab.blank or 0) + (st.slab.busy or 0) > 0 end
    local n = key == 'rock' and stone_free(c, r) or stock_of(r, key)
    if n <= 0 then return false end
    return type(reach) ~= 'table' or reach[key] == true
  end
  -- BUG-024: a loom waits for collected thread; loose spider webs are none (a weaver must collect them first)
  function ctx.label(key)
    if key == 'cook' then return M.cook_why(inv, ctx.f) end     -- Run 11: 'no cook' read like a missing cook
    if key == 'slab_blank' then return 'unengraved slab' end
    if key ~= 'thread' then return key end
    local w, near = inv.webs or 0, inv.webs_near or 0
    if w == 0 then return 'collected thread' end
    if near > 0 then return string.format('collected thread (%d webs, %d near: weavers collect them)', w, near) end
    return string.format('collected thread (%d webs, none on the walk group)', w)
  end
  function ctx.labor_ok(list)
    for _, ln in ipairs(list) do
      local h = ctx.holders[ln]
      if h == nil then
        h = false
        local lid = df.unit_labor and df.unit_labor[ln]
        if type(lid) ~= 'number' then h = true                  -- unknown labor name: not checked
        else
          local cu = K.census.u
          local sold = {}
          for _, id in ipairs(type(cu) == 'table' and cu.soldier_ids or {}) do sold[id] = true end
          for _, id in ipairs(type(cu) == 'table' and cu.ids or {}) do
            local u = not sold[id] and df.unit.find(id)
            if u and dfhack.units.isAdult(u) and labor_on(u, lid) then h = true; break end
          end
        end
        ctx.holders[ln] = h
      end
      if h then return true end
    end
    return false
  end
  return ctx
end

-- what keeps one order from running now (FR-01), or nil; only positively known needs count
function M.order_reasons(o, ctx)
  local okn, job = pcall(job_name, o)
  if not okn or type(job) ~= 'string' then return nil end
  -- Run 11 (the manager rested with a wound; 25 coffins and four doors stayed unvalidated while ORDER_STUCK named their
  -- material): an order the manager has not validated runs only once he can validate it, so that is its reason
  local mg = ctx.mgr
  if type(mg) == 'table' and mg.why then
    local okv, valid = pcall(function() return o.status.validated end)
    if okv and valid == false then return 'unvalidated: no manager available (' .. mg.why .. ')', job end
  elseif ctx.uwhy then                       -- BUG-042: the manager's office has no chair, ...
    local okv, valid = pcall(function() return o.status.validated end)
    if okv and valid == false then return 'unvalidated: ' .. ctx.uwhy, job end
  end
  local mc = OL.mat_class(o, ctx.is_metal)
  local ws, labors
  if job == 'CustomReaction' then ws, labors = reaction_needs(o.reaction_name)
  else
    ws = OL.workshops(job, mc)
    labors = OL.labors(job, mc, ws)
  end
  local why, kind = {}, {}
  if ws and not ws_any(ctx.f, ws) then
    -- BUG-059 (Run 14 y577: 'no Farmers' for ProcessPlants sent the game session to the work details; it meant that no
    -- Farmer's Workshop stood): the workshop is named as one, not as a person
    local label = M.ws_label(ws[1])
    why[#why + 1] = 'no ' .. label
    kind.ws, kind.wsk = label, ws[1]                -- BUG-267: the key ('workshop:Loom') names the shop to ask for
  end
  if job ~= 'CustomReaction' then
    local tok = (mc == 'metal' or job == 'SmeltOre') and (o.mat_index or -1) >= 0 and mat_token(0, o.mat_index) or nil
    local key = OL.input(job, mc, tok)
    if key and not ctx.has(key) then why[#why + 1] = 'no ' .. (ctx.label and ctx.label(key) or key); kind.input = true end
  end
  if labors and not ctx.labor_ok(labors) then
    why[#why + 1] = 'no worker ' .. table.concat(labors, '/')
    kind.worker = table.concat(labors, '/')
  end
  -- BUG-061: nothing of its own keeps the order from running, but the slots of its workshop type are full of jobs that
  -- cancel at once (the pre-pass of T.ocheck found the jam): that is the reason, and T.stale may help it
  if #why == 0 and ctx.jam and ws then
    for _, w in ipairs(ws) do
      if ctx.jam[w] then
        ctx.jam_ids = ctx.jam_ids or {}
        ctx.jam_ids[o.id] = true
        why[1] = ctx.jam[w]
        kind.jam = true
        break
      end
    end
  end
  if #why == 0 then return nil, job end
  return table.concat(why, ', '), job, kind
end

-- BUG-059: a workshop key as words: 'workshop:Farmers' -> "Farmer's Workshop", 'workshop:Masons' -> 'Masons workshop',
-- 'furnace:Smelter' -> 'Smelter furnace'
M.WS_NAMES = {Farmers = "Farmer's Workshop", MetalsmithsForge = "Metalsmith's Forge", Craftsdwarfs = "Craftsdwarf's workshop",
              Jewelers = "Jeweler's workshop", Bowyers = "Bowyer's workshop", Leatherworks = 'Leatherworks',
              Clothiers = "Clothier's shop", Tanners = "Tanner's shop", Butchers = "Butcher's shop", Siege = 'Siege workshop'}
function M.ws_label(key)
  local kind, name = tostring(key):match('^(%a+):(.+)$')
  if not name then return tostring(key) end
  if M.WS_NAMES[name] then return M.WS_NAMES[name] end
  return name .. (kind == 'furnace' and ' furnace' or ' workshop')
end

local function order_name(o)
  local ok, n = pcall(function() return dfhack.job.getManagerOrderName(o) end)
  return ok and type(n) == 'string' and dfhack.df2utf(n) or ''
end

---------------------------------------------------------------- suspended construction jobs (FR-16)
local function plugin(name)              -- a DFHack plugin's Lua module (read API only), nil when absent
  if plugins[name] == nil then
    local ok, m = pcall(require, 'plugins.' .. name)
    plugins[name] = ok and type(m) == 'table' and m or false
  end
  return plugins[name] or nil
end
local function first_fn(m, names)
  for _, n in ipairs(names) do
    local f = m and m[n]
    if type(f) == 'function' then return f end
  end
end

-- the footprint, building type and attached items of a construction job's building (plain values)
local function building_info(rec, j, b)
  local ok, id = pcall(function() return b.id end)
  rec.bld = ok and int(id) or nil
  local okr, x1, y1, x2, y2, z = pcall(function() return b.x1, b.y1, b.x2, b.y2, b.z end)
  if okr and int(x1) and int(y1) and int(z) then
    rec.rect = {x1 = int(x1), y1 = int(y1), x2 = int(x2) or int(x1), y2 = int(y2) or int(y1), z = int(z)}
  end
  local okt, tn = pcall(function() return df.building_type[b:getType()] end)
  rec.kind = okt and type(tn) == 'string' and tn or 'building'
  local oks, sg = pcall(function() return b:getBuildStage() end)
  rec.stage = oks and int(sg) or nil
  -- BUG-466: the subtype tells a furnace / forge (fire-safe building material: logs burn) from a shop any material builds
  if rec.kind == 'Workshop' or rec.kind == 'Furnace' then
    local okw, sub = pcall(function() return (rec.kind == 'Workshop' and df.workshop_type or df.furnace_type)[b.type] end)
    if okw and type(sub) == 'string' then rec.sub = sub end
  end
  rec.fire = M.fire_safe(rec.kind, rec.sub) or nil
end

-- BUG-004: what a planned building still waits for: its job_items without an attached item (the building sheet's
-- "waiting for"): {{t = item type, mt, mi, n = items missing, bm = any building material}}. Quantities in dimension
-- units (bars x150, cloth x10000) count as one item.
local function job_missing(j)
  local out = {}
  pcall(function()
    local elems = j.job_items.elements
    local att = {}
    for _, ref in ipairs(j.items) do
      local idx = int(ref.job_item_idx)
      if idx then att[idx] = (att[idx] or 0) + 1 end
    end
    for i, ji in ipairs(elems) do                -- DF vectors iterate from 0, as job_item_idx counts
      local q = int(ji.quantity) or 1
      if q > 100 then q = 1 end
      local miss = q - (att[i] or 0)
      if miss > 0 and #out < 8 then
        local okb, bm = pcall(function() return ji.flags2.building_material == true end)
        local oku, tu = pcall(function() return int(ji.has_tool_use) end)     -- BUG-476: which tool (an offering place waits for an altar)
        out[#out + 1] = {t = int(ji.item_type) or -1, mt = int(ji.mat_type) or -1, mi = int(ji.mat_index) or -1,
                         n = math.min(miss, 50), bm = okb and bm or false, tu = oku and tu or nil}
      end
    end
  end)
  return out
end

-- suspended ConstructBuilding jobs: {id, why, kept = suspendmanager keeps it suspended (preventblocking, water,
-- a designation in the way), planned = buildingplan waits for its materials, bld, kind = building type, rect =
-- footprint {x1, y1, x2, y2, z}, items = attached items, need = job_missing (planned ones)}, and the set of every
-- ConstructBuilding job id. The plugins' own read API answers (feature-detected); without it a job counts as neither
-- [live-untested: 53.16 function names].
function M.suspended_jobs(max)
  local list, all = {}, {}
  local sm, bp = plugin('suspendmanager'), plugin('buildingplan')
  local kept_f = first_fn(sm, {'isKeptSuspended', 'suspendmanager_isKeptSuspended'})
  local desc_f = first_fn(sm, {'suspensionDescription', 'suspendmanager_suspensionDescription', 'getSuspendReason'})
  local plan_f = first_fn(bp, {'isPlannedBuilding'})
  pcall(function()
    local cb = df.job_type.ConstructBuilding
    local link, i = df.global.world.jobs.list.next, 0
    while link and i < 50000 do
      local j = link.item
      if j and j.job_type == cb then
        all[j.id] = true
        if j.flags.suspend and #list < (max or 400) then
          local rec = {id = j.id, why = 'suspended'}
          local okb, b = pcall(dfhack.job.getHolder, j)
          if okb and b then building_info(rec, j, b) end
          if plan_f and okb and b then
            local okp, v = pcall(plan_f, b)
            if okp and v then rec.planned, rec.why = true, 'buildingplan: waiting for materials' end
          end
          if not rec.planned and kept_f then
            local okk, v = pcall(kept_f, j)
            if okk and v then
              rec.kept = true
              local okd, d = false, nil
              if desc_f then okd, d = pcall(desc_f, j) end
              d = okd and type(d) == 'string' and d ~= '' and dfhack.df2utf(d) or 'kept suspended'
              rec.why = ('suspendmanager: ' .. d):sub(1, 60)
            end
          end
          local oki, n = pcall(function() return #j.items end)
          rec.items = oki and int(n) or 0
          if rec.planned then rec.need = job_missing(j) end
          list[#list + 1] = rec
        end
      end
      link, i = link.next, i + 1
    end
  end)
  return list, all
end

-- the preventblocking decision: the verb's persisted choice, else the config default ('keep' = none)
local function pb_choice(c, p)
  local v = p.pb or (c.jobs or {}).preventblocking
  return (v == 'on' or v == 'off') and v or nil
end

local function why_line(cnt, n)
  local list = {}
  for k, v in pairs(cnt) do list[#list + 1] = {k, v} end
  table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
  local parts = {}
  for i = 1, math.min(n or 3, #list) do parts[#parts + 1] = string.format('%s x%d', list[i][1], list[i][2]) end
  return table.concat(parts, '; ')
end

---------------------------------------------------------------- farm season slots (FR-17)
-- a plant raw's farm facts: id, under (a subterranean crop), seasons[1..4], crop (has seeds, no tree)
local function plant_info(i)
  local v = pinfo[i]
  if v ~= nil then return v or nil end
  v = false
  pcall(function()
    local raw = df.global.world.raws.plants.all[i]
    if not raw then return end
    local fl = raw.flags
    local function on(n)
      local ok, b = pcall(function() return fl[n] end)
      return ok and b == true
    end
    local okd, d = pcall(function() return raw.underground_depth_min end)
    v = {id = raw.id, under = on('BIOME_SUBTERRANEAN_WATER') or (okd and (math.tointeger(d) or 0) > 0),
         seasons = {on('SPRING'), on('SUMMER'), on('AUTUMN'), on('WINTER')}, crop = on('SEED') and not on('TREE')}
  end)
  pinfo[i] = v
  return v or nil
end

local function plant_index(id)
  if not pidx then
    pidx = {}
    pcall(function() for i, raw in ipairs(df.global.world.raws.plants.all) do pidx[raw.id] = i end end)
  end
  return pidx[id]
end

-- BUG-397 (Run 16c i3 Yawninggilt: an embark without plump helmet seeds and no depot, 'no brewable plants', drink 150 -> 0):
-- a crop whose plant a still brews: DRINK_MAT in the structural material or a growth, or a plant on the Cook ban (plump helmets,
-- brewed by rule D-09; nocook = {plant id = true}). Cached per plant.
M.brew_cache = {}
function M.brew_crop(pid, nocook)
  local raw = df.global.world.raws.plants.all[pid]
  if not raw then return false end
  if nocook and nocook[raw.id] then return true end
  local v = M.brew_cache[pid]
  if v ~= nil then return v end
  v = false
  pcall(function()
    local mi = dfhack.matinfo.find(raw.id, 'STRUCTURAL')
    if mi and M.drink_mat(mi.type, mi.index) then v = true; return end
    for _, g in ipairs(raw.growths) do
      if M.drink_mat(g.mat_type, g.mat_index) then v = true; return end
    end
  end)
  M.brew_cache[pid] = v
  return v
end

-- the plants on the config's Cook ban (the kitchen entries what = Cook, item = PLANT): {plant id = true}
function M.cook_ban_set(c)
  local nocook = {}
  for _, e in ipairs(type(c) == 'table' and c.kitchen or {}) do
    if e.what == 'Cook' and e.item == 'PLANT' and type(e.plant) == 'string' then nocook[e.plant] = true end
  end
  return nocook
end

-- seeds in stock of crops a still brews (the census' st.seeds), or nil before the seed census
function M.brew_seeds(c)
  if not st.seeds_known or type(st.seeds) ~= 'table' then return nil end
  local nocook, n = M.cook_ban_set(c), 0
  for id, cnt in pairs(st.seeds) do
    local pid = (math.tointeger(cnt) or 0) > 0 and plant_index(id) or nil
    local inf = pid and plant_info(pid)
    if pid and inf and inf.crop and M.brew_crop(pid, nocook) then n = n + math.tointeger(cnt) end
  end
  return n
end

-- BUG-406 (Run 16c i3 Yawninggilt y388: one underground farm plot, 'no seeds for MUSHROOM_HELMET_PLUMP and no other crop with seeds
-- grows there now' in every season while 476 seeds of brewable surface crops lay unused, drink 23 days): the stock seeds of brewable
-- crops by kind (under = grows underground only, surf = on the surface) and the built farm plots by kind. A plot whose kind is
-- unknown (no tile reading, no crop yet) counts for both. nil before the seed census.
function M.brew_fit(K, c)
  if not st.seeds_known or type(st.seeds) ~= 'table' then return nil end
  local nocook = st.nocook or M.cook_ban_set(c)
  local f = {under = 0, surf = 0, pl_under = 0, pl_surf = 0, plots = 0}
  for id, cnt in pairs(st.seeds) do
    local n = math.tointeger(cnt) or 0
    local pid = n > 0 and plant_index(id) or nil
    local inf = pid and plant_info(pid)
    if inf and inf.crop and M.brew_crop(pid, nocook) then
      local k = inf.under and 'under' or 'surf'
      f[k] = f[k] + n
    end
  end
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.FARM_PLOT) do
      if built(b) then
        f.plots = f.plots + 1
        local u = M.plot_under(K, b)
        if u == nil then
          for s = 0, 3 do
            local pid = b.plant_id[s]
            local inf = pid and pid >= 0 and plant_info(pid) or nil
            if inf then u = inf.under; break end
          end
        end
        if u ~= false then f.pl_under = f.pl_under + 1 end
        if u ~= true then f.pl_surf = f.pl_surf + 1 end
      end
    end
  end)
  return f
end

-- BUG-406/BUG-408 (Run 16a i1 Bachwald: 'no brewable plants' beside 50 seeds and no farm plot; Run 16c i3: 476 seeds, one plot of the
-- other kind): the stills' plants are short and the brewable seeds in stock fit no farm plot (no plot of their kind, or no plot at
-- all): PROJECT_REQUEST farms why=drink (an underground plot) or why=drink_surface (a surface plot, in PEACE only: planters walk
-- outside), one plot, at most every food.request_days; never while a farms project is pending or lost. follow places it (wake.py)
function M.brew_farm_request(K, c, r)
  local p = r.p
  if not st.bshort or (st.bseeds or 0) <= 0 then st.bfit = nil; return end
  local f = M.brew_fit(K, c)
  st.bfit = f
  if not f then return end
  local sgap, ugap = f.surf > 0 and f.pl_surf == 0, f.under > 0 and f.pl_under == 0
  if not (sgap or ugap) then return end
  local surface = sgap and (not ugap or f.surf >= f.under)
  if surface and K.mode() ~= 'PEACE' then return end
  local now = r.now or K.now().tick
  if p.bfarm_req and now - (math.tointeger(p.bfarm_req) or 0) < (((c.food or {}).request_days) or 14) * DAY then return end
  local okp, pend = K.call('runner', 'pending', 'farms')
  if okp and (math.tointeger(pend) or 0) > 0 then return end
  local okl, nl = K.call('runner', 'lost', 'farms')
  if okl and (math.tointeger(nl) or 0) > 0 then return end
  p.bfarm_req = now
  local msg = string.format('drink %d days: %d brewable %s seeds fit no farm plot (%d plots): a %s farm plot is requested',
                            (r.days or {}).drink_d or 0, surface and f.surf or f.under, surface and 'surface' or 'underground',
                            f.plots, surface and 'surface' or 'room')
  K.log('warn', '%s', msg)
  K.emit('PROJECT_REQUEST', 'B', msg:sub(1, 200), {tpl = 'farms', n = 1, why = surface and 'drink_surface' or 'drink'})
  K.persist.touch('m.economy')
end

-- BUG-381/BUG-398: the cook crop (most seeds) that grows in season s (0-based) under/over ground while the plan has slots
-- left for that season; takes the slot from the plan. nil when none is due or none fits.
function M.cook_pick(cook, under, s, seeds)
  if not (cook and cook.left and (cook.left[s] or 0) > 0) then return nil end
  local best, bn
  for id, n in pairs(seeds) do
    local pid = plant_index(id)
    local inf = pid and cook.set[pid] and plant_info(pid)
    if inf and inf.under == under and inf.seasons[s + 1] == true and inf.crop and n > 0
       and (not bn or n > bn or (n == bn and pid < best)) then best, bn = pid, n end
  end
  if best then cook.left[s] = cook.left[s] - 1 end
  return best
end

-- the crop for empty slot s (0-based) of a plot whose crops are `crops` (raw indices): a crop of the plot that
-- grows then with usable seeds, else the crop with the most usable seeds that grows then and there, else nil
-- (BUG-256: never a crop without a seed; underground crops grow all year)
function M.slot_crop(crops, under, s, seeds, food, fiber, cook)
  local function fits(inf) return inf and inf.under == under and inf.seasons[s + 1] == true end
  -- BUG-397: the stills' plants are short (st.bshort, M.drink_low): an empty slot takes the brewable crop with the most seeds
  if st.bshort then
    local best, bn
    for id, n in pairs(seeds) do
      local pid = plant_index(id)
      local inf = pid and plant_info(pid)
      if fits(inf) and inf.crop and n > 0 and M.brew_crop(pid, st.nocook) and (not bn or n > bn or (n == bn and pid < best)) then
        best, bn = pid, n
      end
    end
    if best then return best end
  end
  -- BUG-381: a crop the kitchen may cook first while it has nothing to cook (cook = M.cook_plan, left[s] = slots allowed)
  local ck = M.cook_pick(cook, under, s, seeds)
  if ck then return ck end
  -- I3: a fiber crop first while the kernel is the only farmer (fiber = M.fiber_plan, left[s] = slots still allowed)
  if fiber and not food and (fiber.left[s] or 0) > 0 then
    local best, bn
    for id, n in pairs(seeds) do
      local pid = plant_index(id)
      local inf = pid and fiber.set[pid] and plant_info(pid)
      if fits(inf) and inf.crop and n > 0 and (not bn or n > bn or (n == bn and pid < best)) then best, bn = pid, n end
    end
    if best then fiber.left[s] = fiber.left[s] - 1; return best end
  end
  -- BUG-058: with `food` (food low) the edible crops go first (a dye or fiber crop with the most seeds feeds nobody)
  for pass = 1, food and 2 or 1 do
    local function ok(pid) return not (food and pass == 1) or M.food_plant(pid) end
    for _, pid in ipairs(crops) do
      local inf = plant_info(pid)
      if fits(inf) and (seeds[inf.id] or 0) > 0 and ok(pid) then return pid end
    end
    local best, bn
    for id, n in pairs(seeds) do
      local pid = plant_index(id)
      local inf = pid and plant_info(pid)
      if fits(inf) and inf.crop and n > 0 and ok(pid) and (not bn or n > bn or (n == bn and pid < best)) then
        best, bn = pid, n
      end
    end
    if best then return best end
    -- BUG-256: no seedless fallback (the plot's own crop without a seed made 'Needs <crop> spawn' cancels and an
    -- empty plot through a famine); the slot stays empty, M.fd_wants asks the caravans for seeds
  end
end

-- BUG-058 (Run 13 y513: the new plots on z149 held surface crops, TURNIP, PARSNIP, QUINOA, and made no PlantSeeds job):
-- does the plot lie underground (true), on the surface (false) or is that unknown (nil)? The tile of the plot's corner
-- (snapshot.plot_under: a revealed tile under the open sky is the surface, a `subterranean` one underground; the plot
-- sheet's crop list follows the same flag)
function M.plot_under(K, b)
  local okp, x, y, z = pcall(function() return b.x1, b.y1, b.z end)
  if not okp then return nil end
  local ok, v = K.call('snapshot', 'plot_under', x, y, z)
  if ok and (v == true or v == false) then return v end
  return nil
end

-- {plot id, season, crop} for every empty slot of the built farm plots (and every slot holding a crop of the wrong kind
-- for the plot: a surface crop underground or the reverse); st.farm counts plots and empty slots.
-- `only` = one season (0..3, T.slotnow: the running season), else all; `food` = the edible crops first
local function farm_fills(K, max, only, food, fiber, cook)
  local fills, plots, empty = {}, 0, 0
  -- BUG-256 (live Inkintense y373: a plot held MUSHROOM_CUP_DIMPLE with 0 seeds for autumn and winter beside 130 other
  -- seeds; famine): a slot of the running season set to a crop without a usable seed is chosen again (only by a crop
  -- with seeds); the seed census must be known (st.seeds)
  local okc, cur = pcall(function() return K.now().season end)
  cur = okc and math.tointeger(cur) or nil
  local seeds = st.seeds_known and type(st.seeds) == 'table' and st.seeds or nil
  pcall(function()
    if fiber then                                   -- I3: the fiber slots a season already holds count against the cap
      fiber.left = {}
      for sn = 0, 3 do fiber.left[sn] = fiber.max end
      for _, b in ipairs(df.global.world.buildings.other.FARM_PLOT) do
        if built(b) then
          for sn = 0, 3 do
            local pid = b.plant_id[sn]
            if pid and fiber.set[pid] then fiber.left[sn] = math.max(0, fiber.left[sn] - 1) end
          end
        end
      end
    end
    if cook then                                    -- BUG-381: the slots a season already holds of a cook crop count too
      cook.left = {}
      for sn = 0, 3 do cook.left[sn] = cook.max end
      for _, b in ipairs(df.global.world.buildings.other.FARM_PLOT) do
        if built(b) then
          for sn = 0, 3 do
            local pid = b.plant_id[sn]
            if pid and cook.set[pid] then cook.left[sn] = math.max(0, cook.left[sn] - 1) end
          end
        end
      end
    end
    for _, b in ipairs(df.global.world.buildings.other.FARM_PLOT) do
      if built(b) then
        plots = plots + 1
        local tile = M.plot_under(K, b)
        local crops, under = {}, tile
        for s = 0, 3 do
          local pid = b.plant_id[s]
          if pid and pid >= 0 then
            crops[#crops + 1] = pid
            local inf = plant_info(pid)
            if inf and under == nil then under = inf.under end
          end
        end
        for s = 0, 3 do
          if only == nil or s == only then
            local pid = b.plant_id[s]
            local inf = pid and pid >= 0 and plant_info(pid) or nil
            local wrong = tile ~= nil and inf ~= nil and inf.under ~= tile
            local seedless = not wrong and inf ~= nil and seeds ~= nil and s == cur and (seeds[inf.id] or 0) <= 0
            -- BUG-398 (Run 16b i2 Ostgate: 79 citizens, 0 meals for months, every slot planted with plump helmets, so the
            -- R20 cook plan found no empty slot): a planted slot of a crop the kitchen will not cook gives way to a cook
            -- crop while the plan has slots left for that season (never more than the plan's, planted cook slots count)
            local swap = cook and cook.left and (cook.left[s] or 0) > 0 and pid and pid >= 0 and not wrong and not seedless
                         and inf ~= nil and not cook.set[pid] and not M.cook_plant(pid, cook.nocook)
            if swap then
              local ck = under ~= nil and #fills < max and M.cook_pick(cook, under, s, st.seeds or {}) or nil
              if ck and ck ~= pid then
                fills[#fills + 1] = {id = b.id, s = s, crop = ck, swap = true}
              end
            elseif not pid or pid < 0 or wrong or seedless then
              if not (wrong or seedless) then empty = empty + 1 end
              local crop = under ~= nil and #fills < max and M.slot_crop(crops, under, s, st.seeds or {}, food, fiber, cook) or nil
              -- a crop of the wrong kind is replaced only by one with usable seeds (a wrong reading of the tile must not
              -- cost a planted slot)
              if crop and (wrong or seedless) then
                local ci = plant_info(crop)
                if not (ci and ((st.seeds or {})[ci.id] or 0) > 0) then crop = nil end
              end
              local key = seedless and (tostring(b.id) .. ':' .. s .. ':' .. tostring(inf.id) .. ':' .. tostring(crop))
              if type(st.noseed) ~= 'table' then st.noseed = {} end
              if key and not st.noseed[key] and (crop or #fills < max) then
                st.noseed[key] = true
                if crop then
                  K.log('warn', 'farm plot %s season %d: no usable seeds for %s: %s instead', tostring(b.id), s,
                        tostring(inf.id), tostring((plant_info(crop) or {}).id))
                else
                  K.log('warn', 'farm plot %s season %d: no seeds for %s and no other crop with seeds grows there now',
                        tostring(b.id), s, tostring(inf.id))
                end
              end
              if crop and crop ~= pid then
                fills[#fills + 1] = {id = b.id, s = s, crop = crop, wrong = wrong or nil, seedless = seedless or nil}
              end
            end
          end
        end
      end
    end
  end)
  if only == nil then st.farm = {plots = plots, empty = empty} end
  return fills
end

-- BUG-381 (Run 16 i1/i2/i4: 'raw food is not cooked', 0 meals for months beside 2,000 plump helmets and a built kitchen with
-- COOK held): the kitchen cooks what is EDIBLE_COOKED and not on its Cook ban, and the one crop the farms planted was the
-- plump helmet (Gordon's rule D-09: brewed, never cooked; M.slot_crop took the crop with the most seeds). A plant raw the
-- kitchen may cook: not on the config's Cook ban, edible cooked in its structural material or in a growth
M.cook_cache = {}                                    -- (a field: the main chunk is at its 200 locals)
function M.cook_plant(pid, nocook)
  local raw = df.global.world.raws.plants.all[pid]
  if not raw then return false end
  if nocook and nocook[raw.id] then return false end
  local v = M.cook_cache[pid]
  if v ~= nil then return v end
  v = false
  pcall(function()
    local function cooked(mi)
      local mat = mi and (mi.material or (dfhack.matinfo.decode(mi.type, mi.index) or {}).material)
      local fl = mat and mat.flags
      return fl and fl.EDIBLE_COOKED == true
    end
    if cooked(dfhack.matinfo.find(raw.id, 'STRUCTURAL')) then v = true; return end
    for _, g in ipairs(raw.growths) do
      if cooked(dfhack.matinfo.decode(g.mat_type, g.mat_index)) then v = true; return end
    end
  end)
  M.cook_cache[pid] = v
  return v
end

-- the farms' cook plan: while the kitchen has fewer cook ingredients than citizens (M.cook_n) and fewer meals than
-- citizens, up to farms.cook_slots empty slots a season take a crop with usable seeds the kitchen may cook ({set = plant
-- raw indices, max}); nil when none is due. Never replaces a planted slot. One kern.log line when the crops change.
function M.cook_plan(K, c, r)
  local fc = c.farms or M.DEFAULTS.farms
  local n = math.tointeger(fc.cook_slots)
  if n == nil then n = M.DEFAULTS.farms.cook_slots end
  local inv = r.inv or K.census.i or {}
  local cit = math.max(math.tointeger(r.cit) or 0, 1)
  if n <= 0 or not st.seeds_known or type(st.seeds) ~= 'table' then return nil end
  if M.cook_n(inv) >= cit or (inv.meals or 0) >= cit then st.cook_sig = nil; return nil end
  local nocook = {}
  for _, e in ipairs(c.kitchen or {}) do
    if e.what == 'Cook' and e.item == 'PLANT' and type(e.plant) == 'string' then nocook[e.plant] = true end
  end
  local set, names = {}, {}
  for id, cnt in pairs(st.seeds) do
    local pid = (math.tointeger(cnt) or 0) > 0 and plant_index(id) or nil
    local inf = pid and plant_info(pid)
    if pid and inf and inf.crop and M.cook_plant(pid, nocook) then set[pid], names[#names + 1] = true, id end
  end
  if next(set) == nil then
    if st.cook_sig ~= 'none' then
      st.cook_sig = 'none'
      K.log('warn', 'kitchen has %d cook ingredients and %d meals for %d citizens, and no seeds of a crop it may cook: the ' ..
            'caravans are asked for seeds (M.fd_wants), plump helmets stay brewed (D-09)', M.cook_n(inv), inv.meals or 0, cit)
    end
    return nil
  end
  table.sort(names)
  local sig = table.concat(names, ',')
  if st.cook_sig ~= sig then
    st.cook_sig = sig
    K.log('warn', 'kitchen has %d cook ingredients and %d meals for %d citizens: the farms plant a cook crop (%s; at most %d ' ..
          'slots a season)', M.cook_n(inv), inv.meals or 0, cit, sig:sub(1, 120), n)
  end
  -- BUG-398: a big fort needs more than two slots a season for its meals (cook_slots + 1 per 30 citizens, at most 8)
  return {set = set, max = math.min(8, n + math.floor(cit / 30)), nocook = nocook}
end

-- I3: autofarm off for good ('off', two wipes) is the kernel as the only farmer; the thread and cloth chain (standing
-- SpinThread / WeaveCloth / ProcessPlants, plan_cloth) lives on fiber crops autofarm used to plant (Run 14: silk, yarn
-- and plant cloth missing in three moods). While cloth is short and food is not, up to farms.fiber_slots empty slots a
-- season take a fiber crop with usable seeds; nil when none is due. Never replaces a planted slot.
function M.fiber_plan(K, c, r)
  local fc = c.farms or M.DEFAULTS.farms
  local n = math.tointeger(fc.fiber_slots)
  if n == nil then n = M.DEFAULTS.farms.fiber_slots end
  local cl = st.cloth
  if n <= 0 or not st.af_off or type(cl) ~= 'table' or (cl.deficit or 0) <= 0 or M.food_low(c, r) then return nil end
  local set = {}
  for _, id in ipairs((c.cloth or {}).fiber or {}) do
    local pid = plant_index(id)
    if pid then set[pid] = true end
  end
  if next(set) == nil then return nil end
  return {set = set, max = n}
end

-- I3 (daily, once a week): the cloth the farms do not plant, in words (kern.log); what autofarm's silence costs
function M.fiber_note(K, c, r, fp)
  local p = r.p
  if type(p.af) ~= 'table' then p.af = {} end
  local af = p.af
  local cl = st.cloth
  if not st.af_off or type(cl) ~= 'table' or (cl.deficit or 0) <= 0 then af.fnote = CAD.quiet(af.fnote); return end
  -- J2: util/cadence -- a game week is 19 s at timestream speed, so the week alone repeated the line three times a minute
  -- while the condition stood; the repeat waits max(7 game days, 10 min); an old state held a tick number (no record)
  local T0 = K.now()
  if type(af.fnote) == 'table' and not CAD.elapsed(af.fnote, T0, 7 * DAY, CAD.WALL_S) then return end
  af.fnote = CAD.mark(T0, {}, {})
  local seeds = 0
  for _, id in ipairs((c.cloth or {}).fiber or {}) do if (st.seeds or {})[id] then seeds = seeds + 1 end end
  K.log('warn', 'cloth short by %d (thread %d) and autofarm is off (%s): the kernel plants fiber crops itself (%s; %d fiber ' ..
        'seed kinds in stock)', cl.deficit or 0, cl.thread or 0, tostring(af.why or (c.farms or {}).autofarm or '?'),
        fp and string.format('at most %d slots a season', fp.max) or 'none now: food low, farms.fiber_slots 0 or no fiber crop',
        seeds)
end

---------------------------------------------------------------- unforbid (FR-23, FR-25, FR-50)
-- a tile the fort knows (snapshot.tile; no tile reader loaded -> true, as care) and on the citizens' walk group
local function known_tile(K, x, y, z)
  local ok, t = K.call('snapshot', 'tile', x, y, z)
  if not ok then return true end
  return type(t) == 'table'
end
local function far(K, x, y, z)
  local ok, v = K.call('snapshot', 'far', x, y, z)
  return ok == true and v == true
end

---------------------------------------------------------------- starvation (FR-25)
-- a plant raw a gatherer brings food from: the configured list, or an edible structural / growth material
local function edible(i, list)
  local v = ecache[i]
  if v ~= nil then return v end
  v = false
  pcall(function()
    local raw = df.global.world.raws.plants.all[i]
    if not raw then return end
    for _, id in ipairs(list or {}) do if raw.id == id then v = true; return end end
    local function food(mi) local fl = mi and mi.material and mi.material.flags; return fl and (fl.EDIBLE_RAW or fl.EDIBLE_COOKED) end
    if food(dfhack.matinfo.find(raw.id, 'STRUCTURAL')) then v = true; return end
    for _, g in ipairs(raw.growths) do
      if food(dfhack.matinfo.decode(g.mat_type, g.mat_index)) then v = true; return end
    end
  end)
  ecache[i] = v
  return v
end

-- BUG-058: a plant raw that feeds (an edible structural or growth material); M.slot_crop's `food` pass
function M.food_plant(pid) return edible(pid, nil) == true end

local function hungry_ids(K, lim)
  local r = {}
  local cu = K.census.u
  for _, id in ipairs(type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}) do
    local u = df.unit.find(id)
    local cn = u and u.counters2
    if cn and M.citizen(u) and (cn.hunger_timer or 0) >= lim then r[#r + 1] = id end     -- BUG-103: citizens only
  end
  return r
end

-- the work detail of a starvation helper: by name first, else the detail that grants the labor
local function find_detail(names, labor)
  local by_name, by_labor
  pcall(function()
    local lid = df.unit_labor and df.unit_labor[labor]
    for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do
      local n = dfhack.df2utf(w.name)
      for _, want in ipairs(names or {}) do if n == want and not by_name then by_name = w end end
      if not by_labor and type(lid) == 'number' then
        local ok, on = pcall(function() return w.allowed_labors[lid] end)
        if ok and on == true then by_labor = w end
      end
    end
  end)
  local w = by_name or by_labor
  return w and dfhack.df2utf(w.name), w
end

-- who of the hungry cannot reach any food: unit ids (snapshot.reach to the census's food samples)
-- BUG-299 (Run 15c Inkintense y376: '28 cannot reach food' at food 0 days while `inspect reach` put all 50 citizens and
-- all 176 food items on one walk group): with no edible food lying free there is nothing to reach, so nobody is cut off;
-- the starvation line says the stock is empty instead (T.starve)
local function cut_off(K, ids)
  local samples, r = st.food_pos or {}, {}
  if #samples == 0 then return r end
  for _, id in ipairs(ids) do
    local u = df.unit.find(id)
    local p = u and u.pos
    local reach = false
    if p then
      if #samples == 0 then reach = false
      else
        for _, fp in ipairs(samples) do
          local ok, yes = K.call('snapshot', 'reach', {x = p.x, y = p.y, z = p.z}, fp)
          if not ok or yes ~= false then reach = true; break end
        end
      end
    else reach = true end
    if not reach then r[#r + 1] = id end
  end
  return r
end


---------------------------------------------------------------- the daily run: a task list over frames
-- Each task does at most one DF command per call (r.cmds counts them; the planner and the tool details count as
-- one too) and returns false to be called again; a frame runs tasks until slice_cmds of them ran. A rush run
-- (a new need) skips the day bookkeeping (stock-day samples, idle days, labor KPI).
local T = {}

function T.days(K, c, r)
  local p, inv, now = r.p, r.inv, K.now()
  local cu = K.census.u
  st.rate = {}
  local days = {}
  for key, stock in pairs({drink = inv.drink, food = inv.food}) do
    local base = (c.seed_milli[key] or 0) * r.cit
    push(p.hist[key], M.sample(p.prev[key], stock, base, c.spike_x or 3))
    p.prev[key] = stock
    local sum = 0
    for _, v in ipairs(p.hist[key]) do sum = sum + v end
    st.rate[key .. '_d'] = sum // #p.hist[key]
    days[key .. '_d'] = M.days(stock, p.hist[key])
  end
  r.days, st.days = days, days
  -- BUG-059 (Run 12 y503: 12 starved under 'food 41 d' with meals 0): the citizens past DF's "hungry" line, daily
  st.hungry_n = #hungry_ids(K, (c.starve or M.DEFAULTS.starve).hunger or 50000)
  -- BUG-177 (live i1: after a reload `stock` was bare for ~15 game days: demoted x8 and paced, economy's first daily run
  -- took ~40 game days and st.out came only in T.finish, after the kernel's 28-day carry ran out): the stock days are
  -- published as soon as they are known; T.finish completes the rest (labor, mood_miss)
  -- BUG-199: the boot's early stock (from the save's last run) is replaced by this live one; p.days_t dates it
  if not st.out or st.out.boot then
    st.out = {drink_d = days.drink_d, food_d = days.food_d, meals = (r.inv or {}).meal_kinds, hungry = st.hungry_n or 0,
              mood_miss = {}, early = true}
  end
  p.days_t, p.meals = now.tick, math.tointeger((r.inv or {}).meal_kinds)
  -- BUG-607: since when the fort has had no log (M.treeless); no tree on the map at all counts as of the first day
  if (math.tointeger((r.inv or {}).wood) or 0) > 0 then p.nowood = nil
  elseif math.tointeger(p.nowood) == nil then
    p.nowood = now.tick
    if M.count_trees() == 0 then p.nowood = now.tick - (math.tointeger((c.pieces or {}).treeless_days) or 20) * DAY end
  end
  if st.first then st.first = false; M.first_boost(K) end
  M.hungry_warn(K, c, r)
  local sup = K.plan.supply or {}
  stock_low(K, p, 'drink_d', days.drink_d, math.tointeger(sup.drink_d) or 170, true)
  stock_low(K, p, 'food_d', days.food_d, math.tointeger(sup.food_d) or 60, true)
  -- the mood keys' STOCK_LOW waits for T.plan: care's forbidden reserve (r.held) is known after T.scan
  p.hides_days = (inv.hides or 0) > 0 and (p.hides_days or 0) + 1 or 0
  -- migrants (report seen; count the new citizens once the census caught up)
  if st.mig and now.tick - st.mig.tick >= 100 then
    local n = 0
    for _, id in ipairs(cu and cu.ids or {}) do if not st.mig.known[id] then n = n + 1 end end
    K.emit('MIGRANTS', 'B', string.format('%d migrants', n), {n = n})
    p.migrants, st.mig = 1, nil
  end
end

function T.kitchen(K, c, r) pcall(kitchen, K, c, r.days.food_d) end
function T.appoint(K, c, r) M.appoint_vacant(K) end
function T.food(K, c, r) if r.day then food_plan(K, c, r) end end
function T.watch(K, c, r)
  local okc, errc = pcall(M.cut_scan, K, c, r)     -- BUG-654: first, the shop facts below read p.cutws
  if not okc then K.log('warn', 'cut-off shop scan failed: %s', tostring(errc)) end
  M.no_water(K, c, r)                              -- BUG-401: first, alarm_check and drink_low read st.nowater
  validation_watch(K, r.p, c)
  alarm_check(K, c, r.p, r.days)
  M.food_shops(K, c, r)                            -- BUG-618: before the decisions, so they list it under auto
  famine(K, c, r.p, r.days, r.inv, r)
  food_pre(K, c, r.p, r.days, r.inv, r)
  M.food_unban(K, c, r, r.inv)
  M.cook_repair(K, c, r, r.inv)                    -- BUG-345
  M.cook_watch(K, c, r)                            -- BUG-629
  M.fish_watch(K, c, r)                            -- BUG-716
  M.drink_low(K, c, r)                             -- BUG-042
  M.fd_wants(K, c, r)                              -- BUG-256, BUG-259
end

function T.cmdq(K, c, r)
  local q = table.remove(r.cmdq, 1)
  if not q then return true end
  K.act.run(table.unpack(q))
  r.cmds = r.cmds + 1
  return #r.cmdq == 0
end

-- the engine decides who owns the builtin tool details: modern labormanager, otherwise economy (L1b)
function T.engine(K, c, r)
  local okm, out = K.act.run('labormanager', 'mode')
  r.cmds = r.cmds + 1
  st.engine = okm and (tostring(out):lower():find('modern', 1, true) and 'modern' or 'other') or nil
  -- BUG-010: the daily read names the legacy engine (the Run 9 crash engine): baseline's guard switches it off
  local okp, eng = K.call('baseline', 'engine_of', okm and out or '')
  if okp and eng == 'legacy' then K.call('baseline', 'legacy_guard', 'economy daily') end
end

function T.labor_fix(K, c, r)
  if st.engine ~= 'modern' then return true end
  r.cmds = r.cmds + 1
  local ok, err = pcall(labor_fix, K, c, r.p, st.engine)
  if not ok then K.log('warn', 'labor fix: %s', tostring(err)) end
end

function T.scan(K, c, r)
  r.s = scan_orders(r.p)
  r.f = facts(K, r.p)
  care_hooks(K, r)
end

-- live L6 (Laborkings: a famine beside idle grazers): while the famine or the food_low pre-alarm runs, surplus tame
-- animals are marked for slaughter (act.animal_slaughter, the animal sheet's toggle) once per `every_days`: per
-- race `keep_f` adult females and `keep_m` adult males stay for breeding; pets, war and hunting animals and
-- animals already marked are left alone; at most `max` a time, only with a butcher's shop, in PEACE/RECOVERY.
-- One mark per call (one DF command per slice).
function M.slaughter_pick(list, sc)
  local keep = {}
  local cand = {}
  local sorted = {}
  for _, a in ipairs(type(list) == 'table' and list or {}) do
    if type(a) == 'table' and math.tointeger(a.id) then sorted[#sorted + 1] = a end
  end
  table.sort(sorted, function(x, y) return x.id < y.id end)
  local marked = 0
  for _, a in ipairs(sorted) do
    if not a.pet and not a.war then
      if a.slaughter then marked = marked + 1
      else
        local race = tostring(a.race)
        local k = keep[race] or {f = 0, m = 0}
        keep[race] = k
        if a.adult and a.female and k.f < (sc.keep_f or 1) then k.f = k.f + 1
        elseif a.adult and not a.female and k.m < (sc.keep_m or 1) then k.m = k.m + 1
        else cand[#cand + 1] = a.id end
      end
    end
  end
  -- BUG-498: a mood wants bones, not the youngest animal: adults first, then the race with most animals (the breeding stock stays)
  if sc.adult_first then
    local byid, count = {}, {}
    for _, a in ipairs(sorted) do
      if not a.pet and not a.war and not a.slaughter then
        byid[a.id] = a
        count[tostring(a.race)] = (count[tostring(a.race)] or 0) + 1
      end
    end
    table.sort(cand, function(x, y)
      local ax, ay = byid[x].adult == true, byid[y].adult == true
      if ax ~= ay then return ax end
      local cx, cy = count[tostring(byid[x].race)], count[tostring(byid[y].race)]
      if cx ~= cy then return cx > cy end
      return x < y
    end)
  end
  local r = {}
  for i = 1, math.min(#cand, math.max(0, (sc.max or 10) - marked)) do r[i] = cand[i] end
  return r
end

-- live L6 (Paddletribes): two strange moods waited for a bone with tame surplus animals at hand and failed or
-- needed a manual slaughter. An open mood need for bone or leather with none of it in stock marks ONE surplus
-- animal (same keep rules), at most every `mood_days`.
local function mood_animal_need(r)
  local needs = r.p.needs or {}
  for _, key in ipairs({'bone', 'shell', 'leather'}) do      -- BUG-498: shell too (a tortoise)
    local m = needs[key]
    if type(m) == 'table' and type(m.care) == 'table' and (m.care.n or 0) > 0 and have(r, key) <= 0 then return key end
  end
end

function T.slaughter(K, c, r)
  local sc, p = c.slaughter, r.p
  if type(sc) ~= 'table' or not HUNT_MODES[K.mode()] then return true end
  local mood = not (p.famine or p.food_pre) and mood_animal_need(r)
  if not (p.famine or p.food_pre or mood) then return true end
  if not r.sl then
    local t_key, every = mood and 'slaughter_mood_t' or 'slaughter_t', mood and (sc.mood_days or 3) or (sc.every_days or 7)
    if p[t_key] and r.now - (math.tointeger(p[t_key]) or 0) < every * DAY then return true end
    if not ws_any(r.f, sc.ws) then return true end
    local ca = K.census.a
    local pick_sc = sc
    if mood then pick_sc = {keep_f = sc.keep_f, keep_m = sc.keep_m, max = 1, adult_first = true} end
    local alist = type(ca) == 'table' and ca.list
    r.sl, r.sl_n = M.slaughter_pick(alist, pick_sc), 0
    local last = false
    if mood and #r.sl == 0 then
      -- BUG-498 (Run 16d i4 Trumpetrealms y383: a Fey mood 'bone x1 none in the fort', butcher.mark took one young cavy, 12 animals
      -- stayed because each race kept its breeding pair; three mood deaths): the dwarf's life is worth more than the last pair; an adult
      -- (pets and war / hunting animals never) is marked, the most numerous race first
      r.sl = M.slaughter_pick(alist, {keep_f = 0, keep_m = 0, max = 1, adult_first = true})
      last = #r.sl > 0
    end
    p[t_key] = r.now
    if mood and #r.sl > 0 then
      local a
      for _, x in ipairs(type(alist) == 'table' and alist or {}) do if type(x) == 'table' and x.id == r.sl[1] then a = x end end
      a = a or {}
      K.log('warn', 'mood needs %s: animal %d marked for slaughter', mood, r.sl[1])
      K.emit('ANIMAL_MARKED', 'B', string.format('mood needs %s (none in the fort): %s %s %d marked for slaughter%s', mood,
                                                 a.adult and 'adult' or 'young', M.race_name(a.race), r.sl[1],
                                                 last and ' (the last of its breeding pair: pets and war animals stay)' or
                                                 ' (a surplus animal)'):sub(1, 200),
             {need = mood, animal = r.sl[1], race = M.race_name(a.race), adult = a.adult and 1 or 0, last = last and 1 or 0})
    end
    if #r.sl == 0 then return true end
  end
  local id = table.remove(r.sl, 1)
  if not id then return true end
  r.cmds = r.cmds + 1
  if K.act.animal_slaughter(id, true) then r.sl_n = r.sl_n + 1 end
  if #r.sl > 0 then return false end
  K.log('warn', 'food %d days (%s): %d surplus animals marked for slaughter', (r.days or {}).food_d or 0,
        p.famine and 'famine' or 'food low', r.sl_n)
  return true
end

-- BUG-260 (live Inkintense y373: famine, 4 tame animals of 2 races, each a breeding pair the famine slaughter keeps;
-- the game session marked turkey 26285 and duck 26450 by hand): butcher.mark {n?, race?, sex?, keep_pairs?} marks n (1..20,
-- default 1) tame animals for slaughter with the animal sheet's toggle (act.animal_slaughter): pets, war and hunting
-- animals never; one adult female and one adult male per race stay unless keep_pairs is false (the player's word);
-- race = the creature id (TURKEY) or the census' race number. The reply names the ids and whether a Butcher's shop stands.
function M.race_name(race)
  local ok, n = pcall(function() return df.global.world.raws.creatures.all[race].creature_id end)
  return ok and type(n) == 'string' and n or tostring(race)
end
M.verbs['butcher.mark'] = function(K, args, cmd)
  local n = args.n == nil and 1 or math.tointeger(args.n)
  if not n or n < 1 or n > 20 then return false, 'n must be 1..20' end
  if args.keep_pairs ~= nil and type(args.keep_pairs) ~= 'boolean' then return false, 'keep_pairs must be true or false' end
  local race = args.race
  if race ~= nil and not (math.tointeger(race) or (type(race) == 'string' and race:match('^[A-Z0-9_]+$'))) then
    return false, 'race must be a creature id (TURKEY) or a race number'
  end
  -- BUG-309 (Run 15 Drillchamber y376: 'marked for slaughter: 26280' was a stray dog, the reply said nothing of it): sex filter
  if args.sex ~= nil and args.sex ~= 'male' and args.sex ~= 'female' then return false, 'sex must be male or female' end
  local ca = K.census.a
  local list, by = {}, {}
  for _, a in ipairs(type(ca) == 'table' and type(ca.list) == 'table' and ca.list or {}) do
    if type(a) == 'table' and (race == nil or a.race == math.tointeger(race) or M.race_name(a.race) == race)
       and (args.sex == nil or (args.sex == 'female') == (a.female == true)) then
      list[#list + 1] = a
      if math.tointeger(a.id) then by[a.id] = a end
    end
  end
  local keep = args.keep_pairs == false and 0 or 1
  local pick = M.slaughter_pick(list, {keep_f = keep, keep_m = keep, max = n + 1000, adult_first = true})   -- BUG-498: adults before young
  if #pick == 0 then
    return false, string.format('no animal to mark (%d tame%s: pets, war/hunting animals, marked ones and %s stay)', #list,
                                race and (' ' .. tostring(race)) or '', keep == 1 and 'one breeding pair per race' or 'none')
  end
  local done, names, info = {}, {}, {}
  for i = 1, math.min(n, #pick) do
    local ok = K.act.animal_slaughter(pick[i], true)
    if ok then
      done[#done + 1] = pick[i]
      local a = by[pick[i]] or {}
      local e = {id = pick[i], race = M.race_name(a.race), sex = a.female and 'female' or 'male', adult = a.adult and 1 or 0}
      info[#info + 1] = e
      names[#names + 1] = string.format('%d %s %s%s', e.id, e.race, e.sex, a.adult and '' or ' (young)')
    end
  end
  local ws = ws_any(M.facts_now(K, {p = pstate(K)}), (M.DEFAULTS.slaughter or {}).ws or {'workshop:Butchers'})
  K.log('warn', 'butcher.mark by %s: %d animals marked for slaughter (%s)%s', tostring(cmd and cmd.by), #done,
        table.concat(names, ', '), ws and '' or "; no Butcher's shop stands")
  return #done > 0, string.format('%d marked for slaughter: %s%s', #done, table.concat(names, ', '),
                                  ws and '' or "; no Butcher's shop: nobody slaughters them yet"):sub(1, 200),
         {ids = done, butcher = ws and 1 or 0, animals = info}
end

---------------------------------------------------------------- glass for strange moods (Run 11)
-- Kilrudrabed (site98, y427-429): no gem vein on the site (`explore` digs since y427), and every year the first mood that
-- wanted gems died. What glass does (reserve.glass_ok, DF's own mood filters): raw glass serves a glassmaker's base
-- material and the extra raw glass; cut glass (CutGlass at a jeweler's) the extra "cut gems" (SMALLGEM of any
-- material); nothing of glass serves rough gems (ROUGH of an inorganic: a gem cutter's or setter's base, the extra rough
-- gem), metal bars, blocks, leather or cloth. The chain runs while a mood wants raw glass or cut gems (care.mood_wants
-- glass), or, with no natural gem in the fort (census gems - gems_glass = 0), while a mood missed gems or glass within
-- leather.memory_days, or from glass.from_phase while the gems (care's held ones included) stay below the mood
-- reserve's gems target (config reserve.targets.gems): cut glass up to that target, glass.raw raw glass on top.
--   shops  no glass furnace (or no jeweler's while cut glass is wanted): PROJECT_REQUEST workshops why=glass (follow
--          places the missing moodable shops), every request_days at most, never while a workshops project is pending;
--   sand   no sand collection zone: one 1x1 zone `dfllm-sand` (act.sand_zone, the zones screen) on a revealed sand
--          floor on the citizens' walk group (snapshot.sand: the exports' sand marks; snapshot.tile and far), again
--          only after request_days; before any export of this boot one is asked for (purpose debug);
--   bags   no empty bag: ConstructBag from spare cloth (clothier's) or leather (leatherworks), up to glass.bags;
--   fuel   without a magma glass furnace: charcoal (MakeCharcoal at a wood furnace, from spare wood) for the glass jobs;
--   orders CollectSand (one per empty bag), MakeRawGlass GLASS_GREEN (a bag of sand + fuel), CutGlass GLASS_GREEN.
-- What the kernel cannot fix itself (no sand revealed, no bags, no fuel) is GLASS_BLOCKED (B), again only when a new
-- blocker appears after report_days (util/cadence); economy.route('gems'|'glass') names the chain for MOOD_RISK.
-- Module fields, not locals: the main chunk is at Lua's 200-local limit.
M.GLASS_WHY = {no_sand = 'no sand revealed (a sand zone needs a revealed sand floor)',
               no_bags = 'no bags (spare cloth/leather + its shop)', no_fuel = 'no fuel (wood furnace + wood, or magma)',
               sand_invalid = 'sand zone invalid ("Need valid, active sand collection zone"): needs a bare sand floor, no grass'}
M.GLASS_SHORT = {no_sand = 'no sand revealed', no_bags = 'no bags', no_fuel = 'no fuel', sand_invalid = 'sand zone invalid'}

-- BUG-303 (Run 15d Drillchamber y375-y378: economy's 1x1 zone 18035 at 70,83,144 and the player's 3x3 zone 18173 lay on
-- floors of a sand layer that DF does not count; the gamelog gathered 1,233 "Collect sand: Need valid, active sand collection
-- zone" cancels, about one a day, so no CANCEL_LOOP (5 a day) came, the order stayed ("Need" is no "Needs ..." reason) and
-- glass_plan saw a zone (M.sand_zones() > 0) and went on ordering CollectSand: no GLASS_BLOCKED, the mood route was dead).
-- The cancels with DF's words are counted as one abort series in p.sand_bad {n, first, last} (a gap of more than
-- glass.sand_abort_days, default 7, starts a new series). From glass.sand_abort cancels (default 3) the zones count as
-- invalid: blocker sand_invalid (GLASS_BLOCKED once per series, at once: p.sand_rep = the series reported) and glass_sand paints a
-- new zone on a bare sand floor outside every sand zone; a painted zone ends the series.
M.SAND_BAD = 'sand collection zone'
function M.sand_cancel(K, c, why, tick)
  if not tostring(why or ''):lower():find(M.SAND_BAD, 1, true) then return end
  local G = type(c.glass) == 'table' and c.glass or {}
  local p = pstate(K)
  local now = math.tointeger(tick) or K.now().tick
  local s = p.sand_bad
  if type(s) ~= 'table' or now - (math.tointeger(s.last) or now) > (G.sand_abort_days or 7) * DAY then
    s = {n = 0, first = now}
  end
  s.n, s.last = (math.tointeger(s.n) or 0) + 1, now
  p.sand_bad = s
  K.persist.touch('m.economy')
end

-- the abort series when it counts (>= sand_abort cancels, the last within sand_abort_days), else nil (an old one is dropped)
function M.sand_series(c, p, now)
  local G, s = c.glass, p.sand_bad
  if type(s) ~= 'table' then return nil end
  if now - (math.tointeger(s.last) or 0) > (G.sand_abort_days or 7) * DAY then p.sand_bad = nil; return nil end
  return (math.tointeger(s.n) or 0) >= (G.sand_abort or 3) and s or nil
end

-- is x, y, z inside a sand collection zone (its rectangle)? A tile of a zone DF refuses is no new site.
function M.in_sand_zone(x, y, z)
  local hit = false
  pcall(function()
    for _, zn in ipairs(df.global.world.buildings.other.ZONE_SAND_COLLECTION) do
      if zn.z == z and x >= zn.x1 and x <= (zn.x2 or zn.x1) and y >= zn.y1 and y <= (zn.y2 or zn.y1) then hit = true; break end
    end
  end)
  return hit
end

-- the mood reserve's gems target (config/baseline.json reserve.targets.gems, care holds that many)
function M.gem_reserve(K)
  local rs = type(K.cfg.baseline) == 'table' and K.cfg.baseline.reserve
  return type(rs) == 'table' and type(rs.targets) == 'table' and math.tointeger(rs.targets.gems) or 5
end

function M.sand_zones()                          -- sand collection zones of the fort (the player's count too)
  local ok, n = pcall(function() return #df.global.world.buildings.other.ZONE_SAND_COLLECTION end)
  return ok and math.tointeger(n) or 0
end

function M.glass_shop(K, c, r, g, what)
  local G, p = c.glass, r.p
  if p.glass_req and r.now - (math.tointeger(p.glass_req) or 0) < (G.request_days or 14) * DAY then
    g.shop = what .. ' (asked)'
    return
  end
  local okp, pend = K.call('runner', 'pending', 'workshops')
  if okp and type(pend) == 'number' and pend > 0 then g.shop = what .. ' (queued)'; return end
  p.glass_req, g.shop = r.now, what .. ' (asked)'
  K.emit('PROJECT_REQUEST', 'B', string.format('workshops: %s for glass (strange moods: %d raw glass, %d cut gems wanted)',
                                               what, g.raw, g.cut), {tpl = 'workshops', n = 1, why = 'glass'})
end

-- one sand collection zone on a revealed sand floor the citizens reach (fair play: only what the exports saw)
function M.glass_sand(K, c, r, g)
  local G, p = c.glass, r.p
  if p.sand_t and r.now - (math.tointeger(p.sand_t) or 0) < (G.request_days or 14) * DAY then g.zone = 'painted'; return end
  local ok, s = K.call('snapshot', 'sand')
  if ok and type(s) == 'table' and (math.tointeger(s.tick) or -1) < 0 then
    if not st.sand_snap then                     -- no export this boot yet: one is asked for, the next run looks
      st.sand_snap = true                        -- (BUG-033: any export queued or running will do)
      K.call('snapshot', 'export', {purpose = 'debug', by = 'economy', any = true})
    end
    g.zone = 'looking'
    return
  end
  -- candidates: revealed floors on the citizens' walk group (<= 8); roofed ones first (no hauler out in the open)
  local cand = {}
  for _, t in ipairs(ok and type(s) == 'table' and type(s.tiles) == 'table' and s.tiles or {}) do
    local x, y, z = int(t[1]), int(t[2]), int(t[3])
    local okt, v = K.call('snapshot', 'tile', x, y, z)
    -- BUG-303: the tile reader still calls it a bare sand floor (grass may have grown since the export), outside the zones
    if x and y and z and okt and type(v) == 'table' and v.c == '.' and v.sand ~= false and not M.in_sand_zone(x, y, z)
       and not far(K, x, y, z) and #cand < 8 then
      cand[#cand + 1] = {x, y, z}
    end
  end
  local oko, sky = K.call('snapshot', 'outside_near', cand, 0)
  local tries = 0
  for pass = 0, 1 do
    for i, pos in ipairs(cand) do
      local open_sky = oko and type(sky) == 'table' and sky[i] == 1
      if (pass == 0) ~= (open_sky == true) and tries < 4 then
        tries, r.cmds = tries + 1, r.cmds + 1
        if K.act.sand_zone(pos) then
          p.sand_t, p.sand_at, g.zone = r.now, pos, 'painted'
          p.sand_bad = nil                       -- BUG-303: a new zone ends the abort series
          K.log('info', 'glass: sand collection zone dfllm-sand at %d,%d,%d', pos[1], pos[2], pos[3])
          return
        end
      end
    end
  end
  g.block[#g.block + 1] = 'no_sand'
end

-- empty bags for CollectSand from spare cloth or leather (their floors and the moods' needs stay)
function M.glass_bags(K, c, r, g, short)
  local G = c.glass
  local B = G.bag or {}
  if open(r, B.tag) then g.ord[#g.ord + 1] = 'ConstructBag'; return end
  for _, kind in ipairs({'cloth', 'leather'}) do
    local ws = (B.ws or {})[kind]
    local n = math.min(G.bags or 2, short, left(c, r, kind))
    if ws and r.f[ws] and add(r, {tag = B.tag, spec = {job = 'ConstructBag', material_category = {kind}}, n = n,
                                  uses = {[kind] = 1}, why = 'bags'}) then
      g.ord[#g.ord + 1] = 'ConstructBag'
      return
    end
  end
  g.block[#g.block + 1] = 'no_bags'
end

-- fuel for `jobs` raw glass jobs: the spare fuel now (charcoal is ordered for the rest; none and no way: no_fuel)
function M.glass_fuel(K, c, r, g, jobs)
  local G = c.glass
  local fuel = left(c, r, 'fuel')
  if fuel >= jobs or open(r, G.fuel_tag) then return fuel end
  local ch = (c.metal or {}).charcoal
  local n = math.min(jobs - fuel, left(c, r, 'wood'), G.max_jobs or 5)
  if ch and ws_any(r.f, ch.ws) and add(r, {tag = G.fuel_tag, spec = wood_spec(c, r, {job = 'MakeCharcoal', material_category = {}}),
                                          n = n, uses = {wood = 1}, why = 'glass fuel'}) then
    g.ord[#g.ord + 1] = 'MakeCharcoal'
  elseif fuel <= 0 then
    g.block[#g.block + 1] = 'no_fuel'
  end
  return fuel
end

function M.glass_report(K, c, r, g)
  local G, p = c.glass, r.p
  if #g.block == 0 then p.glass_rep = CAD.quiet(p.glass_rep); return end
  local T = K.now()
  local series = g.series and p.sand_rep ~= g.series   -- BUG-303: each sand abort series is reported once, at once
  if not series and not CAD.due(p.glass_rep, T, {}, g.block, {ticks = (G.report_days or 28) * DAY, wall_s = CAD.WALL_S}) then
    return
  end
  if g.series then p.sand_rep = g.series end
  p.glass_rep = CAD.mark(T, {}, g.block)
  local parts = {}
  for _, b in ipairs(g.block) do parts[#parts + 1] = M.GLASS_WHY[b] or b end
  K.emit('GLASS_BLOCKED', 'B', string.format('glass for moods (%d raw, %d cut) blocked: %s', g.raw, g.cut,
                                             table.concat(parts, '; ')):sub(1, 200),
         {why = {table.unpack(g.block)}, raw = g.raw, cut = g.cut, aborts = g.aborts})
end

function M.glass_plan(K, c, r)
  local G, p, inv, now = c.glass, r.p, r.inv, r.now
  st.glass = nil
  if type(G) ~= 'table' or not phase_ok(K, c.mood_from_phase or 'P1') then return end
  -- BUG-573 (Run 16c i3 Sealcertain y416: a Fey mood wanted 'gems(cut) x1', the reserve said 'gems 5/5' (rough gems), 93 rough gems lay
  -- in the fort and a jeweler stood: nobody cut one, and the glass chain started 26 days before the deadline): the stock is the CUT
  -- form (census gems_cut: cut glass counts, care's held cut gems too). A cut-gem want (a mood's, or the reserve's gems target) is
  -- covered first by CutGems on the rough gems beyond glass.rough_keep (the rough-gem filters keep those); only where the fort has no
  -- rough gem to cut does the glass chain (sand -> raw glass -> cut glass) make them, as before for a fort without a gem vein.
  local raw_need, cut_need, res = need_n(p, 'glass', now), r.glass_cut or 0, M.gem_reserve(K)
  local missed = M.mood_missed(c, p, 'gems', now) or M.mood_missed(c, p, 'glass', now)
  local cutn = (inv.gems_cut or 0) + (r.held.gems or 0)
  -- the census count, not left(): an open CutGems order of ours uses these gems up, and the stock it is about to make must not
  -- count as missing (it would start the glass chain on the next run for the same standing stock)
  local spare = math.max(0, (inv.gems_rough or 0) - (G.rough_keep or 2))
  local standing = missed or phase_ok(K, G.from_phase)
  local stand_short = standing and math.max(0, res - cutn) or 0
  local by_gems = math.min(cut_need + stand_short, spare)
  local cut_stand = spare == 0 and stand_short or 0           -- a standing stock is made of glass only where no rough gem is spare
  local cut = math.max(0, cut_need - by_gems) + cut_stand
  local glass_stand = cut_stand > 0
  if raw_need + cut + by_gems <= 0 then
    p.glass_rep = CAD.quiet(p.glass_rep)         -- the chain is off: a blocker that comes back is news
    return
  end
  local raw = raw_need + (glass_stand and (G.raw or 3) or 0) + cut
  r.targets.glass = raw
  local g = {raw = raw, cut = cut, have = inv.glass or 0, block = {}, ord = {}, gems = by_gems}
  st.glass = g
  local f, mx = r.f, G.max_jobs or 5
  local fur, magma, jew = ws_any(f, G.furnace), f[G.magma] == true, ws_any(f, G.jeweler)
  if (raw_need + cut > 0) and not fur then M.glass_shop(K, c, r, g, 'no glass furnace')
  elseif cut + by_gems > 0 and not jew then M.glass_shop(K, c, r, g, "no jeweler's") end
  if jew and by_gems > 0 and not open(r, G.gems.tag) then       -- BUG-573: CutGems on the spare rough gems
    local spec = copy(G.gems.spec)
    spec.item_conditions = {cond(1, 'ROUGH')}
    if add(r, {tag = G.gems.tag, spec = spec, n = math.min(by_gems, mx), uses = {gems_rough = 1}, why = 'cut gems'}) then
      g.ord[#g.ord + 1] = 'CutGems'
    end
  elseif open(r, G.gems.tag) then g.ord[#g.ord + 1] = 'CutGems' end
  local raw_short = math.max(0, raw - (inv.glass or 0) - (r.s.live[G.make.tag] or 0))
  local sand_short = math.max(0, raw_short - (inv.sand or 0) - (r.s.live[G.sand.tag] or 0))
  if sand_short > 0 then
    local bad = M.sand_series(c, p, now)           -- BUG-303: DF refuses the sand zones: a new one, and the blocker
    if M.sand_zones() > 0 and not bad then g.zone = 'zone'
    else
      if bad then
        g.block[#g.block + 1], g.series, g.aborts = 'sand_invalid', bad.first, math.tointeger(bad.n)
      end
      M.glass_sand(K, c, r, g)
    end
    if (inv.bags or 0) == 0 then M.glass_bags(K, c, r, g, sand_short) end
  end
  local fuel = mx
  if raw_short > 0 and not magma then fuel = M.glass_fuel(K, c, r, g, math.min(raw_short, mx)) end
  if fur and g.zone == 'zone' and sand_short > 0 and not open(r, G.sand.tag) then
    local spec = copy(G.sand.spec)
    spec.item_conditions = {cond(1, 'BAG', {flags = {'empty'}})}
    if add(r, {tag = G.sand.tag, spec = spec, n = math.min(sand_short, left(c, r, 'bags'), mx), uses = {bags = 1},
               why = 'sand'}) then g.ord[#g.ord + 1] = 'CollectSand' end
  elseif open(r, G.sand.tag) then g.ord[#g.ord + 1] = 'CollectSand' end
  if fur and raw_short > 0 and not open(r, G.make.tag) then
    local spec = copy(G.make.spec)
    spec.item_conditions = {cond(1, nil, {flags = {'sand_bearing'}}), (not magma) and cond(1, 'BAR', {material = 'COAL'}) or nil}
    if add(r, {tag = G.make.tag, spec = spec, n = math.min(raw_short, left(c, r, 'sand'), fuel, mx),
               uses = {sand = 1, fuel = magma and 0 or 1}, why = 'glass'}) then g.ord[#g.ord + 1] = 'MakeRawGlass' end
  elseif open(r, G.make.tag) then g.ord[#g.ord + 1] = 'MakeRawGlass' end
  if jew and cut > 0 and not open(r, G.cut.tag) then
    local spec = copy(G.cut.spec)
    spec.item_conditions = {cond(1, 'ROUGH', {material = 'GLASS_GREEN'})}
    if add(r, {tag = G.cut.tag, spec = spec, n = math.min(cut, left(c, r, 'glass'), mx), uses = {glass = 1},
               why = 'cut glass'}) then g.ord[#g.ord + 1] = 'CutGlass' end
  elseif open(r, G.cut.tag) then g.ord[#g.ord + 1] = 'CutGlass' end
  r.route.glass = g.block[1] or g.ord[#g.ord] or 'stock'
  M.glass_report(K, c, r, g)
end

-- BUG-520 (Run 16a y375/y376, 16d i4 y383: a Fey mood 'bone x1 none in the fort' with butcher.mark 'no animal to mark', a Secretive mood
-- 'glass x1' in a soil fort without a furnace or sand, a Secretive mood 'bars(metal) x1' without ore, three or more mood deaths): what
-- supplies a mood class here and what is impossible, said when the mood begins (MOOD_RISK route) and at the deadline (mood_deadline `imp`).
-- Returns text, impossible: the text names the exact blocker and the way left (trade.want, a furnace, melting), impossible = true when
-- the fort's own means cannot make it at all (only a caravan can). nil for a class this does not judge or when the facts are unknown.
-- Never judges a pet or a war / hunting animal slaughterable (M.slaughter_pick keeps them).
function M.mood_hint(K, cls)
  cls = key_of(cls)
  local inv, f, c = K.census.i or {}, st.f or {}, M.conf(K)
  if cls == 'bone' or cls == 'shell' or cls == 'leather' then
    local ca = K.census.a
    if type(ca) ~= 'table' or type(ca.list) ~= 'table' then return nil end
    local tame = math.tointeger(ca.n) or #ca.list
    local pick = M.slaughter_pick(ca.list, {keep_f = 0, keep_m = 0, max = 50, adult_first = true})
    local butcher = ws_any(f, (c.slaughter or {}).ws)
    if #pick > 0 then
      return string.format('%d tame animal%s can be slaughtered (butcher.mark)%s', #pick, #pick == 1 and '' or 's',
                           butcher and '' or "; no Butcher's shop stands"), false
    end
    local shoot = (inv.w_xbow or 0) + (inv.w_bow or 0) > 0 and not st.no_ammo
    local why = string.format('no animal can be slaughtered (%d tame: pets, war and hunting animals stay)', tame)
    if cls == 'leather' then return why .. (shoot and '; hunting is the way' or '; no hunter can shoot'), not shoot end
    return why .. (shoot and '; hunting is the way' or '; no hunter can shoot (crossbow, bolts)'), not shoot
  elseif cls == 'glass' then
    local fur = ws_any(f, ((c.glass or {}).furnace) or {})
    if fur then return nil end
    if M.stone_zero() then
      return 'no glass furnace and no stone to build one (a boulder is needed): trade.want glass, or quarry stone first', true
    end
    return 'no glass furnace: place one (bp.place workshops only=GlassFurnace), then sand and fuel (economy starts the chain)', false
  elseif cls == 'bars' or cls == 'bar' then
    if (inv.ore or 0) > 0 or (inv.melt or 0) > 0 then return nil end
    local smelter = ws_any(f, (c.metal or {}).smelter)
    return string.format('no ore and no metal marked for melting%s: trade.want bar:iron, an explore dig for ore, or mark metal items ' ..
                         '(weapons, tools, armour) for melting', smelter and '' or ', and no smelter'), not smelter and M.stone_zero()
  end
end

-- BUG-727 (Run 16b i2 Whirledrampart y425: a Fey mood 'glass_green x1 none in the fort', 'Make raw glass: no sand', `trade.want glass` ignored,
-- the dwarf died of thirst in the mood): true, text when the fort's own glass chain cannot make raw glass in time: no furnace and no stone to
-- build one (mood_hint), or no sand revealed / an invalid sand zone (glass_plan's blockers). care's early mood decision names it.
function M.glass_stuck(K)
  local okh, hint, imp = pcall(M.mood_hint, K, 'glass')
  if okh and type(hint) == 'string' and imp == true then return true, hint end
  local g = st.glass
  for _, b in ipairs(type(g) == 'table' and type(g.block) == 'table' and g.block or {}) do
    if b == 'no_sand' or b == 'sand_invalid' then
      return true, (M.GLASS_SHORT[b] or b) .. ': raw glass cannot be made here (trade.want glass, or reveal / zone sand)'
    end
  end
  return false
end

-- economy.route for gems and raw glass (care's MOOD_RISK): via 'glass' = the missing gems filter takes cut glass; any
-- other gems need is a rough gem, which no glass replaces
function M.glass_route(K, key, via)
  if key == 'gems' and via ~= 'glass' then
    return 'rough gems: mine a gem vein or trade.want rough (glass is no rough gem)'
  end
  local g, parts = st.glass, {}
  if type(g) ~= 'table' then
    parts[1] = 'glass furnace, sand zone, bags, fuel (economy starts the chain)'
  else
    if g.shop then parts[#parts + 1] = g.shop end
    for _, b in ipairs(g.block) do parts[#parts + 1] = M.GLASS_SHORT[b] or b end
    if #g.ord > 0 then parts[#parts + 1] = table.concat(g.ord, '+') end
    parts[#parts + 1] = string.format('raw %d/%d', g.have, g.raw) .. (g.cut > 0 and string.format(', cut %d', g.cut) or '')
  end
  local by_rough = type(g) == 'table' and (g.gems or 0) > 0 and (g.cut or 0) == 0     -- BUG-573: CutGems on rough gems, no glass
  local s = (key == 'gems' and (by_rough and 'cut gems: ' or 'cut glass: ') or 'raw glass: ') .. table.concat(parts, ', ')
  return key == 'gems' and (s .. '; trade.want gem') or s
end

---------------------------------------------------------------- pieces in the material the fort has (Run 11)
-- Run 11 (Kilrudrabed y432, BREACH, pop 54): REFUGE_FAIL `open to 1 entrance 128,121,143 floor beside door
-- 127,121,143`; `seal at=last` ended build_lost (missing d): quickfort `orders` makes every door and hatch a rock order
-- (live L3), ConstructDoor was cancelled for rock with 1 boulder in the fort and ~110 orders said 'no rock'. Doors hold
-- no building destroyer anyway: any material does. What a planned building waits for gets an order the fort can run
-- (T.jmake, after T.jmat): rock while the free stone covers the open rock orders, else wood, else rock behind them;
-- the walls' building material is whatever buildingplan allows. Live y432 (34 boulders, the refuge door 128,121,143
-- still open): the door item comes first, so a planned door without a runnable door order gets one. Fields, not
-- locals: the main chunk is at Lua's 200-local limit.
-- item class (T.jmat's label) -> {kind (seal piece / MATERIAL_SHORT name), job, inv (census key of free items), def
-- (a defense piece: logs down to the moods' floor), wood (no rock variant)}
M.PIECES = {door = {kind = 'door', job = 'ConstructDoor', inv = 'doors', def = true},
            hatch_cover = {kind = 'hatch', job = 'ConstructHatchCover', inv = 'hatches', def = true},
            grate = {kind = 'grate', job = 'ConstructGrate', inv = 'grates', def = true},
            floodgate = {kind = 'floodgate', job = 'ConstructFloodgate', def = true},
            cabinet = {kind = 'cabinet', job = 'ConstructCabinet'}, box = {kind = 'chest', job = 'ConstructChest'},
            table = {kind = 'table', job = 'ConstructTable', inv = 'tables'},
            chair = {kind = 'chair', job = 'ConstructThrone', inv = 'chairs'},
            armorstand = {kind = 'armor stand', job = 'ConstructArmorStand'},
            weaponrack = {kind = 'weapon rack', job = 'ConstructWeaponRack'},
            bed = {kind = 'bed', job = 'ConstructBed', wood = true}}
M.PIECE_KIND = (function()
  local t = {}
  for _, e in pairs(M.PIECES) do t[e.kind] = e end
  return t
end)()
M.PIECE_INV = {DOOR = 'doors', HATCH_COVER = 'hatches', GRATE = 'grates', BLOCKS = 'blocks_free', CHAIR = 'chairs',
               TABLE = 'tables'}     -- BUG-042: the manager office's chair and table
-- buildingplan's material settings for building material (walls): the census key of each; logs first when only
-- one has to be switched on (bars are never switched on: metal is the soldiers')
M.BM = {{'blocks', 'blocks_free'}, {'boulders', 'rock'}, {'logs', 'wood'}, {'bars', 'bars'}}
M.BM_ON = {'logs', 'boulders', 'blocks'}
M.ROCK_WORDS = {'rock', 'stone', 'boulder'}

function M.is_metal(mi)
  local f = mat_flags({mat_type = 0, mat_index = mi})
  return f ~= nil and f.IS_METAL == true
end

-- the boulders the open rock orders still want (the amount left of every order whose input is plain rock: stone
-- furniture, blocks, crafts, mechanisms; one boulder an item)
function M.rock_open()
  local n = 0
  for _, o in ipairs(orders_all()) do
    local left_n = math.tointeger(o.amount_left) or 0
    if left_n > 0 then
      local okn, jn = pcall(job_name, o)
      if okn and OL.input(jn, OL.mat_class(o, M.is_metal)) == 'rock' then n = n + left_n end
    end
  end
  return n
end

-- free stone left once the open rock orders and this run's rock orders have theirs (negative: rock below the need)
function M.rock_left(c, r)
  if r.rk == nil then r.rk = M.rock_open() end
  return stone_free(c, r) - r.rk - (r.planned.rock or 0)
end

-- no free stone at all, or less than the open rock orders want
function M.rock_short(c, r) return stone_free(c, r) <= 0 or M.rock_left(c, r) < 0 end

-- logs economy may spend; a defense piece (door, hatch, grate, floodgate) keeps only the moods' and needs' floor, not
-- the config reserve (Run 11: a seal door before a barrel)
function M.wood_left(c, r, def)
  if not def then return left(c, r, 'wood') end
  local p = r.p
  local fl = math.max(0, math.max(holder_floor(p, 'wood'), need_n(p, 'wood', r.now)) - (r.held.wood or 0))
  -- BUG-497 (Run 16d i4 Trumpetrealms y384: a seal door 'queued behind the other rock orders, no logs' with 229 logs in stock; the
  -- barrels, beds and tables of other owners had claimed them): a defense piece goes before the orders of others, their wood is
  -- not taken off its stock (only the floor and our own open orders are)
  return math.max(0, (r.inv.wood or 0) - fl - math.max(0, (r.s.used.wood or 0) - (r.s.xwood or 0)) - (r.planned.wood or 0))
end

-- a run-shaped view outside a run (the hooks): census, floors, open orders, the workshops of the last run
function M.view_run(K)
  local p = pstate(K)
  return {p = p, inv = K.census.i or {}, now = K.now().tick, held = (st.sup or {}).held or {}, f = st.f or {},
          s = scan_orders(p), planned = {}}
end

-- how the fort makes n of a piece now: 'item' (free ones stand), 'rock' (Masons; the free stone covers the open rock
-- orders too), 'wood' (Carpenters), 'rock' again when stone is free but the rock orders want more (the order queues
-- behind them; live y432: 34 boulders and the refuge door still open), or nil, why ('no material for door: no rock,
-- no logs'). A door item comes first: buildingplan waits for the item, never for raw rock or logs.
-- BUG-607: a fort without logs for `pieces.treeless_days` days (p.nowood, kept by T.days) or without a tree on the map (st.trees) is treeless
function M.count_trees()
  local n
  pcall(function()
    local pl = df.global.world.plants
    n = #pl.tree_dry + #pl.tree_wet
  end)
  return n
end
function M.treeless(c, r)
  local days = math.tointeger((c.pieces or {}).treeless_days) or 20
  if days <= 0 or (math.tointeger(r.inv.wood) or 0) > 0 then return false end
  local since = math.tointeger(r.p.nowood)
  return since ~= nil and r.now - since >= days * DAY
end

function M.piece_route(c, r, e, n)
  local inv, f = r.inv, r.f or {}
  if e.inv and (inv[e.inv] or 0) >= n then return 'item' end
  local masons, carp = f['workshop:Masons'] == true, f['workshop:Carpenters'] == true
  local rock = not e.wood and M.rock_left(c, r) or 0
  local free = not e.wood and stone_free(c, r) - (r.planned.rock or 0) or 0
  local wood = M.wood_left(c, r, e.def)
  if not e.wood and rock >= n and masons then return 'rock' end
  if wood >= n and carp then return 'wood' end
  if not e.wood and free >= n and masons then return 'rock', nil, true end
  -- BUG-607: a treeless fort has no wood to wait for: the piece goes to the Masons even while DF's hard stone denial holds the stone at 0
  -- (the cancel is counted: the second episode turns the probe off, M.HARD.sticky); only boulders the census calls usable
  if not e.wood and masons and free <= 0 and M.treeless(c, r) and M.hard_denied(inv, r.now)
     and (math.tointeger(type(st.hard) == 'table' and st.hard.eps) or 1) < M.HARD.sticky then
    local d = M.hard_diag(inv)
    if d.usable >= n then return 'rock', nil, true end
  end
  local why = {}
  if not e.wood then why[#why + 1] = free >= n and 'no Masons' or 'no rock' end
  why[#why + 1] = wood >= n and 'no Carpenters' or (M.treeless(c, r) and 'no logs, the fort has no trees' or 'no logs')
  if e.wood and M.treeless(c, r) then why[#why + 1] = 'a bed is wood only: trade.want wood' end
  return nil, string.format('no material for %s: %s', e.kind, table.concat(why, ', '))
end

---------------------------------------------------------------- the manager's orders as workshop tasks (BUG-231)
-- Live Guildcleans (y373, pop 20): the manager had no office zone, so DF's manager validated none of the 22 work orders
-- (doors, blocks, food) for ~330 days; the office project waited for a chair and a table that only those orders made.
-- No door: the seal stuck, the perimeter stood open 427 days, workshops, tombs and farms hung, a strange mood failed.
-- A player breaks this cycle at the workshop: "add task" needs no manager. M.mgr_bypass (daily, from validation_watch):
-- orders unvalidated, or the manager's office short of its chair/table, for orders.bypass_days -> the office's chair and
-- table and the doors, beds and blocks the planned buildings wait for (T.jmat's classes, st.jneed) are added as tasks
-- at a built Carpenter's workshop (wood) or else a Mason's (rock) through act.ws_task: the jobs of that type already
-- queued at the shops count (deduped), at most bypass_max a day and bypass_open queued at once, each kern.log'd and
-- MANAGER_BYPASS (B); no such shop stands: PROJECT_REQUEST workshops why=manager (a workshop is built without an order).
-- item class (T.jmat's label, M.PIECE_INV) -> {job, wood, rock (the variants), inv (census key of free items)}
M.BYPASS = {chair = {job = 'ConstructThrone', wood = true, rock = true, inv = 'chairs'},
            table = {job = 'ConstructTable', wood = true, rock = true, inv = 'tables'},
            door = {job = 'ConstructDoor', wood = true, rock = true, inv = 'doors'},
            bed = {job = 'ConstructBed', wood = true},
            blocks = {job = 'ConstructBlocks', rock = true, inv = 'blocks_free'}}
M.BYPASS_ORDER = {'chair', 'table', 'door', 'bed', 'blocks'}

-- the item classes the planned buildings wait for with none free or forbidden in the fort ({label = n}), from T.jmat
function M.jneed(jb)
  if type(jb) ~= 'table' or type(jb.mq) ~= 'table' then return nil end
  local out = {}
  for _, q in ipairs(jb.mq) do
    if (M.BYPASS[q.label] or q.label == 'trapparts') and (q.free or 0) == 0 and (q.forb or 0) == 0 then   -- BUG-435: trapparts
      out[q.label] = (out[q.label] or 0) + (q.n or 0)
    end
  end
  return out
end

-- the built Carpenter's and Mason's workshops ({Carpenters = {b...}, Masons = {...}}) and the jobs queued at them by type
function M.bypass_shops()
  local shops, jobs = {Carpenters = {}, Masons = {}}, {}
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      local n = df.workshop_type[b.type]
      if shops[n] and built(b) then
        local list = shops[n]
        list[#list + 1] = b
        for _, j in ipairs(b.jobs or {}) do jobs[j.job_type] = (jobs[j.job_type] or 0) + 1 end
      end
    end
  end)
  return shops, jobs
end

-- what the bypass adds now: {{kind, n}} in M.BYPASS_ORDER, free items subtracted
function M.bypass_want(K, c)
  local inv, want = K.census.i or {}, {}
  local o = st.office
  if type(o) == 'table' and o.why then                 -- the office: a chair and (office.table) a table
    local rec
    local mg = M.manager_state(K)
    if type(mg) == 'table' and mg.unit then rec = M.office_of(K, mg.unit) end
    want.chair = (not rec or rec.chair == 0) and 1 or 0
    want.table = ((c.office or {}).table ~= false and (not rec or rec.table == 0)) and 1 or 0
  end
  local cap = ((c.pieces or {}).max_n) or 6
  for kind, n in pairs(type(st.jneed) == 'table' and st.jneed or {}) do
    want[kind] = math.max(want[kind] or 0, math.min(n, cap))
  end
  local out = {}
  for _, kind in ipairs(M.BYPASS_ORDER) do
    local e = M.BYPASS[kind]
    local n = (want[kind] or 0) - (e.inv and (math.tointeger(inv[e.inv]) or 0) or 0)
    if n > 0 then out[#out + 1] = {kind = kind, n = n} end
  end
  return out
end

-- the days the validation holds the fort: the oldest unvalidated order (st.unval) or the absent manager (p.mabs), and the
-- office short of its chair/table (p.boff, since first seen)
function M.bypass_days(K, p)
  local now = K.now().tick
  if type(st.office) == 'table' and st.office.why then p.boff = math.tointeger(p.boff) or now else p.boff = nil end
  local d = type(st.unval) == 'table' and (math.tointeger(st.unval.d) or 0) or 0
  if type(p.mabs) == 'table' and math.tointeger(p.mabs.since) then d = math.max(d, (now - p.mabs.since) // DAY) end
  if p.boff then d = math.max(d, (now - p.boff) // DAY) end
  return d
end

-- the logs the unvalidated live orders still hold (scan_orders' count of s.used.wood, for those orders only)
function M.held_wood(p)
  local own, n = {}, 0
  for tag, id in pairs(type(p) == 'table' and type(p.orders) == 'table' and p.orders or {}) do own[id] = tag end
  for _, o in ipairs(orders_all()) do
    local left = math.tointeger(o.amount_left) or 0
    local okv, valid = pcall(function() return o.status.validated end)
    if left > 0 and okv and valid == false then
      local tag = own[o.id]
      if tag then
        local meta = type(p.meta) == 'table' and p.meta[tag] or nil
        local uses = type(meta) == 'table' and type(meta.uses) == 'table' and meta.uses or {}
        n = n + left * (math.tointeger(uses.wood) or 0)
      else
        local mc = o.material_category
        if (mc and mc.wood) or df.job_type[o.job_type] == 'MakeCharcoal' then n = n + left end
      end
    end
  end
  return n
end

function M.mgr_bypass(K, p, c)
  local oc = c.orders or M.DEFAULTS.orders
  local lim = math.tointeger(oc.bypass_days) or 5
  local days = M.bypass_days(K, p)
  if lim <= 0 or days < lim then
    if st.byp then K.log('info', 'manager bypass over: the manager validates again or the office stands') end
    st.byp = nil
    return
  end
  local want = M.bypass_want(K, c)
  if #want == 0 then st.byp = nil; return end
  local shops, queued = M.bypass_shops()
  local r = M.view_run(K)
  -- the logs the unvalidated orders hold are free for the tasks: those orders wait for the very manager (live
  -- Guildcleans: deep soil, no stone, the held wood orders took every log, so no task could be made in wood)
  r.s.used.wood = math.max(0, (r.s.used.wood or 0) - M.held_wood(r.p))
  local wood = M.wood_left(c, r, true)
  local rock = stone_free(c, r)
  local budget, open_n = math.tointeger(oc.bypass_max) or 4, 0
  for _, e in pairs(M.BYPASS) do
    local jt = df.job_type[e.job]
    if jt ~= nil then open_n = open_n + (queued[jt] or 0) end
  end
  local room = math.max(0, (math.tointeger(oc.bypass_open) or 8) - open_n)
  local added, names, noshop, nomat = {}, {}, nil, false
  for _, w in ipairs(want) do
    local e = M.BYPASS[w.kind]
    local jt = df.job_type[e.job]
    local k = math.min(w.n - (jt ~= nil and (queued[jt] or 0) or 0), budget, room)
    names[#names + 1] = w.n > 1 and string.format('%s x%d', w.kind, w.n) or w.kind
    for _ = 1, math.max(0, k) do
      local mat = (e.wood and #shops.Carpenters > 0 and wood > 0) and 'wood'
                  or (e.rock and #shops.Masons > 0 and rock > 0) and 'rock' or nil
      if not mat then                                  -- no shop for the material the fort has (no logs: the masons)
        if e.wood and #shops.Carpenters == 0 and (wood > 0 or not e.rock or rock <= 0) then noshop = noshop or 'Carpenters'
        elseif e.rock and #shops.Masons == 0 and rock > 0 then noshop = noshop or 'Masons'
        else nomat = true end
        break
      end
      local list = mat == 'wood' and shops.Carpenters or shops.Masons
      table.sort(list, function(a, b) return #(a.jobs or {}) < #(b.jobs or {}) end)
      local ok = K.act.ws_task(list[1].id, e.job, mat)
      if not ok then break end
      if mat == 'wood' then wood = wood - 1 else rock = rock - 1 end
      budget, room = budget - 1, room - 1
      added[#added + 1] = string.format('%s (%s) at %d', w.kind, mat, list[1].id)
    end
  end
  local what = table.concat(names, ', ')
  st.byp = ((nomat and #added == 0 and 'workshop tasks wait for logs or stone: ' or 'kernel adds workshop tasks: ')
            .. what):sub(1, 80)
  local why = type(st.office) == 'table' and st.office.why or (type(st.unval) == 'table' and st.unval.why) or 'unvalidated'
  if #added > 0 then
    local msg = string.format('manager orders held %d d (%s): workshop tasks %s', days, why, table.concat(added, ', '))
    K.log('warn', '%s', msg)
    K.emit('MANAGER_BYPASS', 'B', msg:sub(1, 200), {days = days, n = #added, tasks = table.concat(added, ', '):sub(1, 120),
                                                    why = tostring(why):sub(1, 80)})
    K.persist.touch('m.economy')
  end
  if noshop then M.bypass_shop(K, p, noshop, what) end
end

-- BUG-458 (Run 16d Orbblock y375-y376: the seal's doors 'wait for door x1 (0 free, 5 ordered)', the orders 'no job for 12 days', and
-- the fallback walled the door spots): the runner holds a wall that would cut citizens off (seal.wall_cuts) and asks for the
-- door itself. n doors as workshop tasks at a built Carpenter's (wood) or Mason's (rock), whatever the manager does (a task
-- needs no validation), when no door item stands free and fewer than n door tasks are queued; no shop: the workshop request of
-- the bypass. Returns the tasks added (0 = none needed or none possible)
function M.seal_doors(K, n)
  n = math.tointeger(n) or 1
  local e = M.BYPASS.door
  local inv = K.census.i or {}
  if (math.tointeger(inv[e.inv]) or 0) >= n then return 0 end
  local c, r = M.conf(K), M.view_run(K)
  local shops, queued = M.bypass_shops()
  local jt = df.job_type[e.job]
  local k = n - (jt ~= nil and (queued[jt] or 0) or 0)
  if k <= 0 then return 0 end
  local wood, rock = M.wood_left(c, r, true), stone_free(c, r)
  local added, noshop = 0, nil
  for _ = 1, k do
    local mat = (#shops.Carpenters > 0 and wood > 0) and 'wood' or (#shops.Masons > 0 and rock > 0) and 'rock' or nil
    if not mat then
      if #shops.Carpenters == 0 and (wood > 0 or rock <= 0) then noshop = 'Carpenters'
      elseif #shops.Masons == 0 and rock > 0 then noshop = 'Masons' end
      break
    end
    local list = mat == 'wood' and shops.Carpenters or shops.Masons
    table.sort(list, function(a, b) return #(a.jobs or {}) < #(b.jobs or {}) end)
    if not K.act.ws_task(list[1].id, e.job, mat) then break end
    if mat == 'wood' then wood = wood - 1 else rock = rock - 1 end
    added = added + 1
    K.log('warn', 'seal door: workshop task ConstructDoor (%s) at %d (the seal holds a wall back: it would cut citizens off)', mat,
          list[1].id)
  end
  if noshop then M.bypass_shop(K, pstate(K), noshop, 'door') end
  return added
end

-- no Carpenter's (or Mason's) workshop for the bypass: PROJECT_REQUEST workshops why=manager types {t}, at most every
-- 7 days, never while a workshops project builds one (M.ws_queued) or runner's mandatory request asks for it
function M.bypass_shop(K, p, t, what)
  st.byp = ('no ' .. t .. ': workshop requested for ' .. what):sub(1, 80)
  local now = K.now().tick
  if now - (math.tointeger(p.byp_req) or -7 * DAY) < 7 * DAY then return end
  if M.ws_queued(K, t) then return end
  local okm, mand = K.call('runner', 'req_types', 'wsm')
  if okm and type(mand) == 'table' then for _, x in ipairs(mand) do if x == t then return end end end
  p.byp_req = now
  K.log('warn', 'manager bypass: no %s workshop for %s: requested', t, what)
  K.emit('PROJECT_REQUEST', 'B', string.format('workshops: no %s workshop for the tasks the manager holds back (%s)', t,
                                               what):sub(1, 200), {tpl = 'workshops', n = 1, why = 'manager', types = {t}})
end

-- BUG-232: with no Office zone at all (none of his, none free), an Office zone over a built chair (and the built table
-- beside it) that stands outside every room zone: zones > Office over those tiles (act.zone_place, zonelib's checks);
-- act.manager_office then gives it to him. At most every office.retry_days; outside a fight.
function M.office_zone(K, c, p)
  local oc = c.office or M.DEFAULTS.office
  if oc.zone == false or M.office_none(K) ~= 'no free office zone' then return end
  local mode = K.mode()
  if mode ~= 'PEACE' and mode ~= 'ALERT' and mode ~= 'RECOVERY' then return end
  local now = K.now().tick
  if now - (math.tointeger(p.ozone) or -1e9) < (oc.retry_days or 7) * DAY then return end
  local Z = require('dfllm.zonelib')
  local function tile(x, y, z)
    local okt, t = K.call('snapshot', 'tile', x, y, z)
    return okt and t or nil
  end
  local function at(b) return b.x1 or b.centerx, b.y1 or b.centery, b.z end
  for _, ch in ipairs(df.global.world.buildings.other.CHAIR) do
    local x, y, z = at(ch)
    if built(ch) and x then
      local box = {x0 = x, y0 = y, x1 = x, y1 = y, z = z}
      for _, tb in ipairs(df.global.world.buildings.other.TABLE) do
        local tx, ty, tz = at(tb)
        if built(tb) and tz == z and tx and math.max(math.abs(tx - x), math.abs(ty - y)) == 1 then
          box = {x0 = math.min(x, tx), y0 = math.min(y, ty), x1 = math.max(x, tx), y1 = math.max(y, ty), z = z}
          break
        end
      end
      local zones, inroom = Z.zones(z), false
      for _, zn in ipairs(zones) do
        if Z.ROOMS[zn.tname or ''] and zn.x0 <= box.x1 and zn.x1 >= box.x0 and zn.y0 <= box.y1 and zn.y1 >= box.y0 then
          inroom = true
          break
        end
      end
      if not inroom and not Z.tiles_ok('office', box, tile) and not Z.conflict('office', box, zones) then
        p.ozone = now
        local cell, pos = Z.cell('office', box, 'Office')
        local okz, res = K.act.zone_place({cell = cell, pos = pos, box = box, ztype = 'Office'})
        local zid = okz and type(res) == 'table' and type(res.ids) == 'table' and res.ids[1] or nil
        local where = string.format('%d,%d-%d,%d z%d', box.x0, box.y0, box.x1, box.y1, z)
        if not zid then
          K.log('warn', 'manager office: no Office zone could be drawn at %s: %s', where, tostring(res))
          return
        end
        K.log('warn', 'manager has no office: Office zone %s drawn over the chair at %s', tostring(zid), where)
        K.emit('MANAGER_OFFICE', 'B', string.format('no office zone: Office zone %s drawn over the chair at %s',
                                                    tostring(zid), where),
               {zone = math.tointeger(zid) or 0, why = 'no office zone', placed = ('office zone at ' .. where):sub(1, 80)})
        return
      end
    end
  end
end

-- buildingplan's global material settings (its planner overlay; plugin function getGlobalSettings), the plugin's
-- defaults when it does not answer: blocks, boulders and logs on, bars off
function M.bp_settings()
  local s = {blocks = true, boulders = true, logs = true, bars = false}
  local fn = first_fn(plugin('buildingplan'), {'getGlobalSettings'})
  if fn then
    local ok, v = pcall(fn)
    if ok and type(v) == 'table' then
      for k in pairs(s) do if v[k] ~= nil then s[k] = v[k] == true end end
    end
  end
  return s
end

-- BUG-466 (Run 16a i1 Basementflew: GlassFurnace and MetalsmithsForge 'waits for building material' 300-395 days with 203 logs in
-- stock; economy answered 'logs' for them and ordered nothing, said nothing): a furnace and a forge need FIRE-SAFE building material
-- (stone or blocks; logs burn, bars are the soldiers'). Every other shop (carpenter, kitchen, still, butcher, farmer, craftsdwarf, mechanic,
-- masons ...) takes any building material, logs too. Fields, not locals: the main chunk is at Lua's 200-local limit.
M.FIRE_SHOPS = {MetalsmithsForge = true, MagmaForge = true}
function M.fire_safe(kind, sub)
  return kind == 'Furnace' or (kind == 'Workshop' and M.FIRE_SHOPS[sub] == true)
end

-- what buildingplan builds a wall of now: via (the setting: blocks, boulders, logs, bars), nil + the setting to
-- switch on (only that material is there), or nil, why. BUG-466: fire = a furnace or forge: no logs
function M.bm_route(r, s, kind, fire)
  local inv = r.inv
  -- BUG-667 (Run 16d i4 Trumpetrealms y439: pop 12, stone 0 usable, 99 logs; the trade depot 'building material: blocks' and a seal wall 'no item' for
  -- 90 days, so no caravan could trade for stone: a vicious circle): once DF has refused the fort's stone (M.hard_denied), a building takes
  -- its logs, not the boulders the game will not hand out; the boulders are not the building's material while logs are there
  -- BUG-736: r.nostone = the free stone is 0 after the moods' floors (stone_free), not only refused: logs are the wall's material then too
  local deny = not fire and (inv.wood or 0) > 0 and (M.stone_none(inv, r.now) or r.nostone == true)
  for _, e in ipairs(M.BM) do
    if s[e[1]] and (inv[e[2]] or 0) > 0 and not (fire and e[1] == 'logs') and not (deny and e[1] == 'boulders') then return e[1] end
  end
  for _, k in ipairs(M.BM_ON) do
    for _, e in ipairs(M.BM) do
      if e[1] == k and (inv[e[2]] or 0) > 0 and not (fire and k == 'logs') and not (deny and k == 'boulders') then return nil, nil, k end
    end
  end
  -- BUG-544: the census counts what the citizens can reach; stone on another walk group is named, not counted
  local far = (inv.rock_far or 0) + (inv.blocks_far or 0)
  local tail = far > 0 and string.format(' (%d boulders and blocks lie on another walk group)', far) or ''
  if fire then
    return nil, 'no material for ' .. (kind or 'furnace') .. ': no rock, no blocks (logs burn: a furnace or forge needs stone)' .. tail
  end
  return nil, 'no material for ' .. (kind or 'wall') .. ': no rock, no blocks, no logs' .. tail
end

-- what a building waiting for building material is called in MATERIAL_SHORT: a wall (construction), the trade depot
-- (Run 11: destroyed in siege 3), a workshop, else a building
M.BM_KIND = {Construction = 'wall', TradeDepot = 'depot', Workshop = 'workshop', Furnace = 'workshop'}
function M.bm_kind(q)
  local j = (q.jobs or {})[1]
  if q.fire then return 'furnace' end                    -- BUG-466: a furnace or forge (fire-safe material)
  return j and M.BM_KIND[j.kind or ''] or (j and 'building') or 'wall'
end

-- economy.mat_for(kind, n) (CONTRACTS §7): can the fort make n of a seal piece now? kind = door, hatch, grate, wall
-- (or a furniture kind of M.PIECES). Returns via ('item', 'rock', 'wood'; walls: 'blocks', 'boulders', 'logs', 'bars',
-- 'setting' when economy switches a buildingplan material on; 'unknown' before the first census) or nil, why
function M.mat_for(K, kind, n)
  n = math.max(1, math.tointeger(n) or 1)
  if not K.census.i then return 'unknown' end
  local c, r = M.conf(K), M.view_run(K)
  if kind == 'wall' or kind == 'depot' or kind == 'workshop' or kind == 'furnace' then
    r.nostone = stone_free(c, r) <= 0 and (r.inv.blocks_free or 0) <= 0          -- BUG-736
    local via, why, set = M.bm_route(r, M.bp_settings(), kind, kind == 'furnace')   -- BUG-466: furnace = fire-safe only
    if set then return 'setting', 'buildingplan ' .. set .. ' goes on' end
    return via, why
  end
  local e = M.PIECE_KIND[kind]
  if not e then return nil, 'unknown piece ' .. tostring(kind) end
  return M.piece_route(c, r, e, n)
end

-- BUG-655 (Run 16a i1 Basementflew y442-y466: the hospital stage lost its four beds ('missing b x4') in six projects, 283 logs in the
-- fort, mat_for said 'wood', and no ConstructBed order ever stood: the pieces are not planned buildings, so nothing waited for a bed
-- item and T.jmake made no order): what the supply of n pieces of `kind` lacks, from the orders and the shops the kernel sees now.
-- Returns text, command line, code: no_shop (no workshop of the kind stands), cut (it stands, no citizen can walk to it), no_logs, no_order
-- (nothing makes the pieces: order.add), ordered (an order stands: the shop has not made them), item (free ones stand). nil, unknown kind.
function M.piece_supply(K, kind, n)
  local e = M.PIECE_KIND[kind]
  n = math.max(1, math.tointeger(n) or 1)
  if not e or not K.census.i then return nil end
  local c, r = M.conf(K), M.view_run(K)
  local inv, f, p = r.inv or {}, r.f or {}, r.p or {}
  local jt, open = df.job_type[e.job], 0
  for _, o in ipairs(orders_all()) do
    if jt ~= nil and o.job_type == jt then open = open + (math.tointeger(o.amount_left) or 0) end
  end
  local logs = math.tointeger(inv.wood) or 0
  local shops = e.wood and {'Carpenters'} or {'Carpenters', 'Masons'}
  local stands, cutl = false, nil
  for _, t in ipairs(shops) do
    if f['workshop:' .. t] then stands = true end
    if f['cut:' .. t] then cutl = cutl or M.cut_text(p, t) end
  end
  local head = string.format('%s x%d: %s x%d open', e.kind, n, e.job, open)
  local free = e.inv and (math.tointeger(inv[e.inv]) or 0) or 0
  if free >= n then return head .. string.format(', %d free in stock: the planned pieces take them', free), nil, 'item' end
  local function order_cmd(k) return string.format([[dfllm cmd order.add '{"job":"%s","amount":%d}']], e.job, k) end
  local ws_cmd = string.format([[dfllm cmd bp.place '{"tpl":"workshops","site":"S1","p":{"only":"%s"}}']], shops[1])
  if not stands then
    if cutl then return head .. ', ' .. shops[1] .. ' cut off (' .. cutl .. '): a new one is asked for', ws_cmd, 'cut' end
    return head .. ', no ' .. shops[1] .. (e.wood and '' or ' or Masons') .. ' workshop stands', ws_cmd, 'no_shop'
  end
  if e.wood and logs < n then
    return head .. string.format(', %s stands, logs %d < %d: no wood to make them', shops[1], logs, n),
           [[dfllm cmd trade.want '{"add":["wood"]}']], 'no_logs'
  end
  if open < n then
    return head .. string.format(', %s stands, logs %d: nothing makes the missing %d', shops[1], logs, n - open), order_cmd(n - open), 'no_order'
  end
  return head .. ', ' .. shops[1] .. ' stands: not made yet (dfllm cmd inspect orders)', nil, 'ordered'
end

-- BUG-443 (Run 16c i3 Castletongs: an aqshaft ring on a heavy level hung 60 % for a year in very deep soil, 74 of 181 orders stuck,
-- the mood reserve held the 5 boulders): mat_for answers yes for ONE log or boulder; the ring needs a count. wall_stock(K) =
-- {have, blocks, rock (free boulders: the moods' floor and ore/flux not counted), logs (above the wood floor), soil (the
-- stone digs found only soil: the caravans are asked for stone)} or nil before the first census
function M.wall_stock(K)
  if not K.census.i then return nil end
  local c, r = M.conf(K), M.view_run(K)
  local inv = r.inv
  local blocks = math.max(0, math.tointeger(inv.blocks_free) or 0)
  local rock = stone_free(c, r)
  local logs = math.max(0, (math.tointeger(inv.wood) or 0) - floor_of(c, r.p, r, 'wood'))
  local rk = st.rock
  -- BUG-677 (Run 16c i3 Wallfree: 37-53 claystone boulders 'free', every wall order 'Needs non-economic hard stone'): boulders no job may take
  -- (M.stone_none: DF refused them, or ore / flux / soft only) are no wall material; `none` says so in the stall text
  local okn, none = pcall(M.stone_none, K.census.i or {}, K.now().tick)
  none = okn and none == true
  if none then rock = 0 end
  -- BUG-736: ore / flux boulders (no usable stone, no blocks, no logs): the last-resort wall material `alt` (buildingplan's boulders take them);
  -- blocks the jobs hold (`busy`) and blocks on another walk group (`far`) are named in the stall text, not counted
  local alt = math.max(0, (math.tointeger(inv.ore) or 0) + (math.tointeger(inv.flux) or 0))
  return {have = blocks + rock + logs, blocks = blocks, rock = rock, logs = logs, none = none, alt = alt,
          busy = math.max(0, math.tointeger(inv.blocks_busy) or 0), far = math.max(0, math.tointeger(inv.blocks_far) or 0),
          soil = type(rk) == 'table' and rk.soil == true}
end

-- BUG-736 (Run 16c i3 Doorwings y381/y382: the aqshaft ring wall at z140 'unbuilt for 31-32 d' twice, census wood 385-440, blocks 132 with blocks_free 0,
-- boulders only ore / flux or reserved: the walls waited for a boulder nobody could hand over while buildingplan kept boulders ON, because
-- the switch to logs needed a stone DF had refused (stone_none) and a planned building in the job scan): a wall (ring, plug, seal, depot) that
-- has waited for its material ring_wait is told where its material is. Returns the sentence for the stall / stop text (nil: stone or blocks are
-- free, the builders have material). No free stone and no free block, logs above the wood floor: buildingplan's boulders go off (p.bpoff 'wall',
-- on again when 8 stones are free or the logs are gone) and logs is on; no logs: ore / flux boulders are the material (boulders go on).
-- A constructed wall of any material stops water: the ring logic reads only the tile's construction state, never its material.
function M.wall_alt(K)
  if not K.census.i then return nil end
  local s = M.wall_stock(K)
  if type(s) ~= 'table' or (s.rock or 0) > 0 or (s.blocks or 0) > 0 then return nil end
  local r = M.view_run(K)
  local c = M.conf(K)
  local bp = M.bp_settings()
  local why = string.format('no free stone and no free block (%d blocks held by jobs, %d on another walk group, %d ore and flux boulders)',
                            s.busy or 0, s.far or 0, s.alt or 0)
  if (s.logs or 0) > 0 then
    if bp.boulders and not r.p.bpoff then
      r.cmds = (r.cmds or 0) + 1
      if K.act.run('buildingplan', 'set', 'boulders', 'false') then
        r.p.bpoff = 'wall'
        K.persist.touch('m.economy')
        K.log('warn', 'buildingplan boulders off: %s, %d logs are the wall material', why, s.logs)
      end
    end
    if not bp.logs and K.act.run('buildingplan', 'set', 'logs', 'true') then
      K.log('info', 'buildingplan logs on: the walls take logs')
    end
    return string.format('%s: the walls are built of logs (%d reachable), buildingplan boulders are off', why, s.logs)
  end
  if (s.alt or 0) > 0 then
    if not bp.boulders and K.act.run('buildingplan', 'set', 'boulders', 'true') then
      r.p.bpoff = nil
      K.persist.touch('m.economy')
      K.log('warn', 'buildingplan boulders on: %s, no logs: the walls take the ore / flux boulders', why)
    end
    return string.format('%s, no logs: the walls are built of the ore / flux boulders (stone the smelters lose)', why)
  end
  return nil
end

-- the open orders of a piece's job: what they make (n). A rock order the free stone cannot cover with the other rock
-- orders is re-entered in wood where logs allow (act.order_material; the carpenter is not behind them); without logs
-- it still counts while stone is free (it queues), else it makes nothing (its "Needs rock" cancel removes it: M.no_rock)
function M.piece_orders(K, c, r, e)
  local jt, made, queued = df.job_type[e.job], 0, 0
  local one = df.workquota_frequency_type.OneTime
  local wj = {}
  for _, j in ipairs((c.wood_orders or {}).jobs or {}) do wj[j] = true end
  for _, o in ipairs(orders_all()) do
    local n = math.tointeger(o.amount_left) or 0
    if jt ~= nil and o.job_type == jt and n > 0 then
      if OL.mat_class(o, M.is_metal) ~= 'rock' or M.rock_left(c, r) >= 0 then made = made + n
      elseif wj[e.job] and o.frequency == one and M.wood_left(c, r, e.def) >= n and (r.f or {})['workshop:Carpenters']
             and K.act.order_material(o.id, 'wood') then
        r.cmds = r.cmds + 1
        r.rk, r.planned.wood, made = (r.rk or 0) - n, (r.planned.wood or 0) + n, made + n
        K.log('info', 'order %d %s x%d: %d free stone for %d rock orders: re-entered in wood (%d logs)', o.id, e.job, n,
              stone_free(c, r), r.rk + n, r.inv.wood or 0)
      elseif stone_free(c, r) >= n then made, queued = made + n, queued + n
      end
    end
  end
  return made, queued
end

-- MATERIAL_SHORT (B): the pieces nothing in the fort can make, per reason ('no material for door, cabinet: no rock,
-- no logs'); once per set of kinds and reasons (util/cadence, pieces.report_days)
function M.short_report(K, c, r, short)
  local p = r.p
  st.short = short
  if #short == 0 then
    p.mshort = CAD.quiet(p.mshort)
    return
  end
  local by, reasons, kinds, pieces, total, pre, queued = {}, {}, {}, {}, 0, {}, false
  for _, s in ipairs(short) do
    local why = s.pre and s.why or (s.why:match(': (.+)$') or s.why)
    if not by[why] then by[why] = {}; reasons[#reasons + 1] = why; pre[why] = s.pre or 'no material for' end
    table.insert(by[why], s.kind)
    kinds[#kinds + 1] = s.kind
    pieces[#pieces + 1] = string.format('%s x%d', s.kind, s.n)
    total = total + s.n
    queued = queued or s.queued == true
  end
  table.sort(kinds)
  local T0 = K.now()
  local o = {ticks = ((c.pieces or {}).report_days or 28) * DAY, wall_s = CAD.WALL_S}
  if not CAD.due(p.mshort, T0, kinds, reasons, o) then return end
  p.mshort = CAD.mark(T0, kinds, reasons)
  local parts = {}
  for _, why in ipairs(reasons) do parts[#parts + 1] = pre[why] .. ' ' .. table.concat(by[why], ', ') .. ': ' .. why end
  -- the boulders the census holds that masons may not take (ore, flux, DF's economic stone, soft stone, the floor)
  local free, all = stone_free(c, r), math.tointeger(r.inv.rock) or 0
  local tail = (queued and string.format('; %d free boulders, %d in rock orders', free, r.rk or 0) or '') ..
               (all > free and string.format('; %d boulders are ore, flux, economic or soft stone', all - free) or '')
  local msg = table.concat(parts, '; ')
  K.log('warn', '%s (%s wait)%s', msg, table.concat(pieces, ', '), tail)
  K.emit('MATERIAL_SHORT', 'B', (msg .. ' (' .. table.concat(pieces, ', ') .. ' wait)' .. tail):sub(1, 200),
         {pieces = table.concat(pieces, ', '):sub(1, 200), why = reasons, n = total, rock = free,
          logs = math.tointeger(r.inv.wood) or 0, boulders = all})
end

-- rock below the need (the open rock orders, walls without material, care's needs) while the miners have nothing to
-- dig: PROJECT_REQUEST bedrooms why=rock (a stone dig the fort needs anyway; follow places it), PEACE, with a pick
-- BUG-268: the mechanisms the manifest levers miss (st.mech.stone) count as rock need too. BUG-269 (Guildcleans, deep soil:
-- moods missed rock, 'stone free 0'): a stone dig asked rock_soil times while not one free boulder came marks the fort
-- soil (p.rocksoil, st.rock.soil): M.supply_wants then asks the caravans for stone and gems
M.ROCK_SOIL = 2
function M.rock_dig(K, c, r, walls)
  local rc = c.rock
  local free = stone_free(c, r)
  local need = (r.rk or M.rock_open()) + (walls or 0) + need_n(r.p, 'rock', r.now) + ((st.mech or {}).stone or 0)
  if free > 0 then r.p.rocksoil = nil end
  -- BUG-467 (Run 16b i2 Roadvises: six strange moods and three deaths in a stone-0 fort, 16a i1 two more for glass and gems): the fort that
  -- has had no free boulder for SUPPLY.zero_days is stone-poor whether or not the stone digs found soil (rocksoil): the moods' stone, gems,
  -- bars and cloth are bought before a mood asks (st.rock.zero)
  if free > 0 then r.p.rock0 = nil
  elseif int(r.p.rock0) == nil then r.p.rock0 = r.now end
  local zero = int(r.p.rock0) ~= nil and (r.now - int(r.p.rock0)) >= M.SUPPLY.zero_days * DAY or nil
  -- BUG-545: boulders but none usable (ore, flux, economic or soft stone, out of reach) while stone is wanted: a decision, not a queue
  if free == 0 and need > 0 and (math.tointeger(r.inv.boulders) or 0) >= M.HARD.min_boulders and K.mode() ~= 'SIEGE' then
    local okh, errh = pcall(M.hard_report, K, c, r, 0)
    if not okh then K.log('warn', 'hard stone report: %s', tostring(errh)) end
  end
  st.rock = {free = free, need = need, open = r.rk or 0, gems = math.tointeger(r.inv.gems) or 0,
             soil = (int(r.p.rocksoil) or 0) >= M.ROCK_SOIL or nil, zero = zero,
             bars = math.tointeger(r.inv.bars) or 0, cloth = math.tointeger(r.inv.cloth) or 0}
  -- BUG-733: where the boulders went when stone is wanted and none is free (workload `stone.why`; kern.log every 3 game days)
  if free == 0 and need > 0 then
    local okw, w = pcall(M.stone_why, c, r)
    if okw and type(w) == 'table' then
      st.rock.why = w
      if w.boulders > 0 and (not st.rock_why_t or r.now - st.rock_why_t >= 3 * DAY) then
        st.rock_why_t = r.now
        K.log('warn', 'economy: stone free 0 (need %d): %s', need, M.stone_why_text(w))
      end
    end
  end
  if type(rc) ~= 'table' or need <= free or K.mode() ~= 'PEACE' or (r.inv.w_pick or 0) == 0 then return end
  if ((st.jobc or tool_jobs()).dig or 0) > 0 then return end                -- the miners have digging
  local okb, bl = K.call('runner', 'dig_backlog')
  if okb and (int(bl) or 0) > 0 then return end
  local okp, pend = K.call('runner', 'pending', 'bedrooms')
  if okp and (int(pend) or 0) > 0 then return end
  local last = int(r.p.rockreq)
  if last and r.now - last < (rc.request_days or 7) * DAY then return end
  r.p.rockreq = r.now
  if free == 0 then r.p.rocksoil = (int(r.p.rocksoil) or 0) + 1 end
  local n = rc.rooms or 4
  K.emit('PROJECT_REQUEST', 'B', string.format('bedrooms x%d: a stone dig, %d free boulders < %d wanted (rock orders, ' ..
                                               'walls), the miners have nothing to dig', n, free, need),
         {tpl = 'bedrooms', n = n, why = 'rock', short = need - free})
end

-- BUG-497 (Run 16d i4 Trumpetrealms y384: no boulder in the fort, the explore that digs to hard stone at 40 % behind 'no runner slot'):
-- true while the last stone census found no free boulder (st.rock.free, rock_dig); the runner queues the stone-reaching dig first
function M.stone_zero()
  local rk = st.rock
  return type(rk) == 'table' and math.type(rk.free) == 'integer' and rk.free <= 0
end

-- BUG-268 (live Earthboat #1051 ACT_FAIL 'needs 2 free reachable mechanisms, 1 found', levers B2/O1 never linked;
-- Guildcleans the same with stone free 0, so the STRANDED rescue through O1 could not run): nobody counted or ordered
-- mechanisms. need = MECH.per_lever per manifest lever gate.linked does not count as linked; free = the mechanisms the
-- lever sheet may take (not forbidden, in a job or building, owned, ...); short = need - free -> ConstructMechanisms
-- (stone, at a Mechanic's workshop, at most MECH.max_jobs) under the tag dfllm:mech. No Mechanic's workshop: returns
-- 'Mechanics' (plan_gear asks for it); no free stone: st.mech.stone = the short (M.rock_dig counts it) and
-- M.supply_wants asks the caravans for mechanisms. State st.mech {need, levers, free, short, route, stone}.
M.MECH = {tag = 'dfllm:mech', per_lever = 2, max_jobs = 4, max_traps = 12}      -- BUG-435: max_traps = the waiting trap parts counted
M.MECH_SKIP = {'forbid', 'in_job', 'in_building', 'trader', 'garbage_collect', 'removed', 'dump', 'melt', 'hostile',
               'owned', 'construction', 'encased', 'spider_web', 'on_fire', 'rotten'}   -- act.lua MECH_FLAGS
function M.mech_free()
  local n = 0
  local ok = pcall(function()
    for _, it in ipairs(df.global.world.items.other.TRAPPARTS) do
      local bad = false
      for _, k in ipairs(M.MECH_SKIP) do if it.flags[k] then bad = true; break end end
      if not bad then n = n + 1 end
    end
  end)
  return ok and n or 0
end
-- BUG-681 (Run 16a i1 Basementflew y470-y486: 19 mechanisms 'free' by this count, the traps project 'waits for trapparts x1' 300 days, the
-- ConstructMechanisms orders 'no job for 64 days' (the Mechanics' shops lie in the flooded level), `plan propose` drew traps@S1 every year
-- because stock.mfree said 19): the free parts a citizen can walk to. A part on a tile with no walkable group (flooded, walled in) or on a group
-- the citizens do not stand on is counted apart. n_reach, n_far. mech_free itself stays the raw count the lever flows (gate, seal, readiness) use
function M.mech_reach(K)
  local n, far_n = 0, 0
  pcall(function()
    for _, it in ipairs(df.global.world.items.other.TRAPPARTS) do
      local bad = false
      for _, k in ipairs(M.MECH_SKIP) do if it.flags[k] then bad = true; break end end
      if not bad then
        local x, y, z = dfhack.items.getPosition(it)
        local okf, fr = false, false
        if x then okf, fr = K.call('snapshot', 'far', x, y, z, true) end
        if okf and fr == true then far_n = far_n + 1 else n = n + 1 end
      end
    end
  end)
  return n, far_n
end
function M.mech_need(K)
  local man = K.manifest()
  local lv = 0
  for name, spec in pairs(type(man) == 'table' and type(man.bridges) == 'table' and man.bridges or {}) do
    local nl = type(spec) == 'table' and type(spec.levers) == 'table' and #spec.levers or 0
    if nl > 0 then
      local ok, n = K.call('gate', 'linked', name)
      lv = lv + math.max(0, nl - (ok and int(n) or 0))
    end
  end
  -- BUG-712: a lever that is placed and not built waits for a mechanism of its own (the building takes 1) before its link takes 2
  local sites = 0
  local okl, ls = K.call('gate', 'lever_states')
  for _, e in pairs(okl and type(ls) == 'table' and ls or {}) do sites = sites + (type(e) == 'table' and int(e.site) or 0) end
  return lv * M.MECH.per_lever + sites, lv
end
-- BUG-627 (trade): the stock days the sell list's automatic surplus kinds follow {food_d, drink_d}; nil before the first stock pass
function M.surplus_days(K)
  local o = st and st.out
  if type(o) ~= 'table' then return nil end
  return {food_d = math.tointeger(o.food_d), drink_d = math.tointeger(o.drink_d)}
end
-- BUG-491 (seal): what the last plan_mech pass found {need, free, short, route ('ordered' | 'stone' | 'no stone' | 'no Mechanics' |
-- nil: none short)}; nil before the first pass
function M.mech_state(K)
  local m = st.mech
  if type(m) ~= 'table' then return nil end
  -- BUG-583: hard = DF itself refused the rock jobs ('Needs non-economic hard stone', BUG-545): no mechanism can be made from the stone at hand
  return {need = m.need or 0, free = m.free or 0, short = m.short or 0, route = m.route,
          hard = type(st.hard) == 'table' and st.hard.denied == true or nil}
end
function M.plan_mech(K, c, r)
  local need, lv = M.mech_need(K)
  -- BUG-435 (Run 16d i4 Mazelanterns y401: the traps project 'waits for trapparts' 912 days, nobody ordered the mechanisms: only the
  -- levers' need was counted): the mechanisms the planned buildings wait for (T.jmat's class `trapparts`, none free or forbidden)
  local tp = math.min(math.tointeger((st.jneed or {}).trapparts) or 0, M.MECH.max_traps)
  need = need + tp
  local free = M.mech_free()
  local rfree, ffar = M.mech_reach(K)
  local m = {need = need, levers = lv, traps = tp, free = free, short = math.max(0, need - free), route = 'none', rfree = rfree, ffar = ffar}
  st.mech = m
  if m.short == 0 then m.route = nil; return nil end
  if open(r, M.MECH.tag) then m.route = 'ordered'; return nil end
  local stone = stone_free(c, r) - (r.s.used.rock or 0) - (r.planned.rock or 0)
  if stone <= 0 then m.route, m.stone = 'no stone', m.short end
  if not ws_any(r.f, {'workshop:Mechanics'}) then m.route = 'no Mechanics'; return 'Mechanics' end
  if stone <= 0 then return nil end
  local n = math.min(m.short, stone, M.MECH.max_jobs)
  add(r, {tag = M.MECH.tag, spec = {job = 'ConstructMechanisms', material = 'INORGANIC'}, n = n, uses = {rock = 1},
          why = string.format('levers: %d unlinked, traps waiting: %d; need %d mechanisms, %d free', lv, tp, need, free)})
  m.route = 'stone'
  return nil
end

-- BUG-546 (Run 16d i4 Trumpetrealms: refuge-lever link jobs waited 1000 days, the question said "needs a dwarf with the Mechanics labor" and
-- named nobody): gate asks for a Mechanic while a link job waits. Returns 'have', unit id (an adult citizen off duty holds the labor),
-- 'set', unit id (act.labor_set switched it on for the best candidate: idle first, then Mechanics skill; no soldier, patient, moody
-- or noble), 'none' (no candidate) or 'wait' (switched on less than a day ago)
function M.mechanic_labor(K)
  local cu = K.census.u
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' then return 'none' end
  local sid = df.job_skill and df.job_skill.MECHANICS
  local cands = {}
  for _, id in ipairs(cu.ids) do
    local u = df.unit.find(id)
    if u and not dfhack.units.isDead(u) and dfhack.units.isAdult(u) and M.citizen(u) and (u.military.squad_id or -1) < 0
       and (u.mood or -1) < 0 then
      if M.labor_flag(u, 'MECHANIC') then return 'have', id end
      if not M.patient(u) and not noble(u) then
        cands[#cands + 1] = {id = id, idle = (u.job == nil or u.job.current_job == nil) and 1 or 0,
                             sk = sid and dfhack.units.getNominalSkill(u, sid, true) or 0}
      end
    end
  end
  if #cands == 0 then return 'none' end
  local p, now = pstate(K), K.now().tick
  if now - (math.tointeger(p.mechl) or -DAY) < DAY then return 'wait' end
  table.sort(cands, function(a, b)
    if a.idle ~= b.idle then return a.idle > b.idle end
    if a.sk ~= b.sk then return a.sk > b.sk end
    return a.id < b.id
  end)
  p.mechl = now
  K.persist.touch('m.economy')
  local ok = K.act.labor_set(cands[1].id, 'mechanic', true)
  if not ok then return 'none' end
  K.log('warn', 'Mechanics labor on for unit %d: a lever link job waits and nobody had it', cands[1].id)
  return 'set', cands[1].id
end

-- BUG-268/269: what the caravans are asked for besides economy.trade_wants (trade.lua puts these after them, before
-- plan.trade.want): `mechanism` while levers miss mechanisms and no stone or no Mechanic's workshop makes them; in a soil
-- fort (st.rock.soil) `stone` for the rock need and `gem` up to SUPPLY.gems (strange moods, Guildcleans #665-#672)
M.SUPPLY = {gems = 3, stone_cap = 30, zero_days = 14, mood_stone = 5, mood_bars = 2, mood_cloth = 2, fire_cap = 6, flux_cap = 10}
function M.supply_wants(K)
  local w = {}
  local m = st.mech
  if type(m) == 'table' and (m.short or 0) > 0 and (m.route == 'no stone' or m.route == 'no Mechanics') then
    w[#w + 1] = {buy = 'mechanism', n = m.short, why = string.format('levers: %d mechanisms short (%s)', m.short, m.route)}
  end
  -- BUG-466: coffins that cannot be made (no hard stone, no spare logs): the caravans bring logs, stone or the coffins
  local okc, cw = K.call('care', 'coffin_wants')
  for _, e in ipairs(okc and type(cw) == 'table' and cw or {}) do
    if type(e) == 'table' and type(e.buy) == 'string' then w[#w + 1] = {buy = e.buy, n = e.n, why = e.why} end
  end
  -- BUG-607: a treeless fort whose beds (wood only) or wood pieces wait for logs: the caravans bring logs
  local ws = math.tointeger(st.wood_short) or 0
  if ws > 0 then
    w[#w + 1] = {buy = 'wood', n = math.min(60, ws * 4), why = string.format('treeless fort: %d wood-only pieces (beds) wait for logs', ws)}
  end
  -- BUG-624 (Run 16d i4 Trumpetrealms y426-y428: the steel DECISION named flux but the want list never held it, `trade.want flux` was
  -- accepted by hand only): orders wait for steel bars and the chain (plan_steel) lacks flux stone, the smelting of pig iron and steel
  -- needs one boulder per job: the caravans bring flux (a mudstone fort has none), two per steel order up to SUPPLY.flux_cap
  local sm = type(st.steel) == 'table' and st.steel.missing
  for _, m in ipairs(type(sm) == 'table' and sm or {}) do
    if m == 'flux' then
      local left_n = math.tointeger(st.steel.left) or math.tointeger(st.steel.n) or 1
      w[#w + 1] = {buy = 'flux', n = math.min(M.SUPPLY.flux_cap, math.max(2, left_n * 2)),
                   why = string.format('steel: %d order(s) wait for steel bars, no flux stone in the fort', math.tointeger(st.steel.n) or 0)}
      break
    end
  end
  local rk = st.rock
  -- BUG-466: a furnace or forge waits for fire-safe building material and the fort has no stone or block: the caravans bring stone
  local fn = math.tointeger(st.fire_n) or 0
  local askstone = false
  if fn > 0 then
    w[#w + 1] = {buy = 'stone', n = math.min(M.SUPPLY.fire_cap, math.max(1, fn)),
                 why = string.format('%d furnace/forge waits for fire-safe material (logs burn), no stone or block in the fort', fn)}
    askstone = true
  end
  if type(rk) == 'table' and (rk.soil or rk.zero) then
    local why = rk.soil and 'soil fort' or 'stone-0 fort'
    if (rk.need or 0) > (rk.free or 0) then
      if not askstone then
        w[#w + 1] = {buy = 'stone', n = math.min(M.SUPPLY.stone_cap, rk.need - rk.free),
                     why = string.format('%s: %d free boulders < %d wanted', why, rk.free or 0, rk.need)}
        askstone = true
      end
    elseif rk.zero and not askstone then
      -- BUG-467: nothing is wanted by the orders yet, but a strange mood needs a boulder at once (stone / mason's mood)
      w[#w + 1] = {buy = 'stone', n = M.SUPPLY.mood_stone, why = 'stone-0 fort: boulders for strange moods'}
    end
    if (rk.gems or 0) < M.SUPPLY.gems then
      w[#w + 1] = {buy = 'gem', n = M.SUPPLY.gems - (rk.gems or 0), why = why .. ': gems for strange moods'}
    end
    if rk.zero then   -- the moods that need a bar (smith) or cloth (weaver, clothier) cannot be made from stone the fort lacks
      if (rk.bars or 0) < M.SUPPLY.mood_bars then
        w[#w + 1] = {buy = 'bar:iron', n = M.SUPPLY.mood_bars - (rk.bars or 0), why = 'stone-0 fort: bars for strange moods'}
      end
      if (rk.cloth or 0) < M.SUPPLY.mood_cloth then
        w[#w + 1] = {buy = 'cloth', n = M.SUPPLY.mood_cloth - (rk.cloth or 0), why = 'stone-0 fort: cloth for strange moods'}
      end
    end
  end
  return w
end

-- Run 11: the missing items of planned buildings (T.jmat's classes without a free or forbidden item) get an order in
-- the material the fort has; walls switch buildingplan's material on when that is all there is; the rest is short
function T.jmake(K, c, r)
  local jb, pc = r.jb, c.pieces
  st.jneed = M.jneed(jb)                              -- BUG-231: what the planned buildings wait for (M.mgr_bypass)
  -- BUG-667: the boulders go back on in buildingplan once the stone is usable again (more boulders came, or DF took them)
  -- BUG-736: boulders switched off for a ring wall / seal wall (no free stone, logs there: p.bpoff == 'wall') stay off until stone is free again
  if r.p.bpoff and not M.stone_none(r.inv, r.now) and (r.p.bpoff ~= 'wall' or stone_free(c, r) >= 8 or (r.inv.wood or 0) <= 0) then
    r.cmds = r.cmds + 1
    if K.act.run('buildingplan', 'set', 'boulders', 'true') then
      r.p.bpoff = nil
      K.persist.touch('m.economy')
      K.log('info', 'buildingplan boulders on again: the stone is usable')
    end
  end
  st.fire_n = nil                                     -- BUG-466: furnaces / forges waiting for fire-safe material, none in the fort
  if not jb or type(pc) ~= 'table' then return true end
  local short, walls, s = {}, 0, nil
  st.wood_short = nil                                 -- BUG-607: wood-only pieces (beds) waiting in a treeless fort (supply_wants)
  for _, q in ipairs(jb.mq or {}) do
    if q.label == 'building material' then
      s = s or M.bp_settings()
      local kind = M.bm_kind(q)
      r.nostone = stone_free(c, r) <= 0 and (r.inv.blocks_free or 0) <= 0       -- BUG-736
      local via, why, set = M.bm_route(r, s, kind, q.fire)
      -- BUG-667: logs are the material (stone is refused): buildingplan's boulders go off so no wall or depot reserves a boulder nobody may take
      if via == 'logs' and s.boulders and not q.fire and (M.stone_none(r.inv, r.now) or r.nostone) and not r.p.bpoff then
        r.cmds = r.cmds + 1
        if K.act.run('buildingplan', 'set', 'boulders', 'false') then
          r.p.bpoff = M.stone_none(r.inv, r.now) and r.now or 'wall'
          K.persist.touch('m.economy')
          K.log('warn', 'buildingplan boulders off: DF refuses the stone of the fort, %d walls/buildings wait for building material, %d logs', q.n,
                r.inv.wood or 0)
        end
      end
      st.bp_on = st.bp_on or {}
      if set and not st.bp_on[set] then
        st.bp_on[set] = true
        r.cmds = r.cmds + 1
        if K.act.run('buildingplan', 'set', set, 'true') then
          K.log('info', 'buildingplan %s on: %d walls/buildings wait for building material, only %s in the fort', set,
                q.n, set)
        end
      elseif not via and not set then
        short[#short + 1] = {kind = kind, n = q.n, why = why}
        walls = walls + q.n
        if q.fire then st.fire_n = (st.fire_n or 0) + q.n end      -- BUG-466: supply_wants asks the caravans for stone
      end
    else
      local e = M.PIECES[q.label]
      if e and q.mt < 0 and q.free == 0 and q.forb == 0 then
        local need = math.min(q.n, pc.max_n or 6)
        local made, queued = M.piece_orders(K, c, r, e)
        local via, why, wait = nil, nil, queued > 0
        if made < need then
          local k = need - made
          via, why, wait = M.piece_route(c, r, e, k)
          wait = wait or queued > 0
          local tag = (pc.tag or 'dfllm:piece_') .. e.kind:gsub(' ', '_')
          if (via == 'rock' or via == 'wood') and not open(r, tag) then
            local spec = {job = e.job}
            if via == 'rock' then spec.material = 'INORGANIC'
            else
              local fl = e.def and math.max(holder_floor(r.p, 'wood'), need_n(r.p, 'wood', r.now)) or floor_of(c, r.p, r, 'wood')
              spec.material_category, spec.item_conditions = {'wood'}, {cond(fl + 1, 'WOOD')}
            end
            add(r, {tag = tag, spec = spec, n = k, uses = {[via] = 1}, why = e.kind .. ' for a planned building'})
          elseif not via then
            short[#short + 1] = {kind = e.kind, n = k, why = why}
            if e.wood and M.treeless(c, r) then st.wood_short = (st.wood_short or 0) + k end       -- BUG-607
          end
        end
        -- a seal piece whose stone order queues behind the other rock orders (no logs for wood): the player hears it
        if e.def and wait then
          short[#short + 1] = {kind = e.kind, n = need, pre = 'stone queued for', why = 'behind the other rock orders, ' ..
                               ((r.f or {})['workshop:Carpenters'] and 'no logs' or 'no Carpenters'), queued = true}
        end
      end
      -- BUG-476: a tool the planned building waits for by use (an altar for the temple's offering place) is ordered at the Masons'
      -- while the stone covers it, else the reason is MATERIAL_SHORT's (the temple waits and says why, not for a year unseen)
      local tp = M.TOOL_BY_LABEL[q.label]
      if tp and q.free == 0 and q.forb == 0 then
        local need = math.min(q.n, pc.max_n or 6)
        local made = M.tool_orders(tp)
        if made < need then
          local k = need - made
          local masons = (r.f or {})['workshop:Masons'] == true
          local tag = (pc.tag or 'dfllm:piece_') .. tp.kind
          if masons and (M.rock_left(c, r) >= k or stone_free(c, r) - (r.planned.rock or 0) >= k) then
            if not open(r, tag) then
              add(r, {tag = tag, spec = {job = tp.job, item_subtype = tp.sub, material = 'INORGANIC'}, n = k,
                      uses = {rock = 1}, why = tp.kind .. ' for a planned building'})
            end
          else
            short[#short + 1] = {kind = tp.kind, n = k, why = string.format('no material for %s: %s', tp.kind,
                                                                           masons and 'no rock' or 'no Masons')}
          end
        end
      end
    end
  end
  M.short_report(K, c, r, short)
  M.rock_dig(K, c, r, walls)
  r.cmds = r.cmds + 1
  return true
end

-- Run 11: a "Needs rock" cancel (DF's words name rock, stone or a boulder: "Needs non-economic hard stone") of a
-- one-time stone order while the free stone is below what the open rock orders want (1 boulder for ~110 of them):
-- re-entered in wood when logs cover it (a wood variant: wood_orders.jobs); with no free stone at all removed (it would
-- only cancel again; T.jmake orders what planned buildings still wait for once rock or logs are in). At most
-- rock.drop_per_day.
function M.rock_why(why)
  local s = tostring(why or ''):lower()
  for _, w in ipairs(M.ROCK_WORDS) do if s:find(w, 1, true) then return true end end
  return false
end

function M.no_rock(K, c, oid, job, why)
  local rc, o = c.rock, order_by_id(oid)
  if type(rc) ~= 'table' or not o or keep_order(o) then return false end
  local n = math.tointeger(o.amount_left) or 0
  if o.frequency ~= df.workquota_frequency_type.OneTime or n <= 0 then return false end
  local okn, jn = pcall(job_name, o)
  if not okn or OL.input(jn, OL.mat_class(o, M.is_metal)) ~= 'rock' then return false end
  local r = M.view_run(K)
  if M.rock_left(c, r) >= 0 then return false end
  local free = stone_free(c, r)
  local day = K.now().tick // DAY
  if st.rd_day ~= day then st.rd_day, st.rd_n = day, 0 end
  if st.rd_n >= (rc.drop_per_day or 20) then return false end
  st.rd_n = st.rd_n + 1
  local wj = {}
  for _, j in ipairs((c.wood_orders or {}).jobs or {}) do wj[j] = true end
  local def = false
  for _, e in pairs(M.PIECES) do if e.job == jn then def = e.def == true end end
  -- BUG-736 (Run 16c i3 Doorwings y385-y388: twenty ConstructBlocks orders 'removed: no logs for it (426 logs)'; the carpenters make blocks of logs):
  -- a rock block order is re-entered in wood like the furniture jobs
  if (wj[jn] or jn == 'ConstructBlocks') and r.f['workshop:Carpenters'] and M.wood_left(c, r, def) >= n
     and K.act.order_material(oid, 'wood') then
    K.log('info', 'order %d %s x%d: "%s", %d free stone for %d in rock orders: re-entered in wood (%d logs)', oid, jn,
          n, why, free, r.rk, r.inv.wood or 0)
    return true
  end
  if free > 0 then return false end              -- stone is there: the order queues (needs_cancel counts as before)
  if not K.act.order_remove(oid) then return false end
  local p, now = r.p, K.now().tick
  p.ocancel[tostring(oid)] = nil
  for tag, id in pairs(p.orders) do
    if id == oid then p.orders[tag], st.backoff[tag] = nil, now + ((c.orders or {}).backoff_days or 10) * DAY end
  end
  K.persist.touch('m.economy')
  local why_w = (r.inv.wood or 0) > 0 and (r.f['workshop:Carpenters'] and 'logs ' .. M.wood_left(c, r, def) .. ' free above the floors < ' .. n
                  or 'no Carpenters workshop') or 'no logs'                       -- BUG-736: the message named the true cause
  K.log('warn', 'order %d %s x%d removed: "%s", %d free stone for %d in rock orders, no wood for it (%s; %d logs)', oid,
        jn, n, why, stone_free(c, r), r.rk, why_w, r.inv.wood or 0)
  K.emit('ORDER_STUCK', 'B', string.format('order %d %s removed: "%s", stone short of the rock orders, no wood for it',
                                           oid, jn, tostring(why):sub(1, 60)),
         {order = oid, job = tostring(jn):sub(1, 40), why = ('no rock: ' .. tostring(why)):sub(1, 60), n = n,
          dropped = 1})
  return true
end

-- BUG-545 (Run 16d i4 Trumpetrealms y404: 101 boulders in a mudstone fort, gamelog "cancels Make rock mechanisms / Load stone trap: Needs
-- non-economic hard stone boulders" from several dwarves for years, the refuge levers' link jobs waiting on mechanisms nobody could make;
-- Run 16a i1 Basementflew the same with every boulder out of reach): economy queued the rock orders on `free boulders > 0` and said nothing.
-- DF's own cancel is the proof: M.HARD.n of them within M.HARD.window_days days make the fort stone-less for M.HARD.hold_days days
-- (stone_free 0 until the census shows more than M.HARD.new boulders beyond the count at the last cancel): no rock order is queued
-- for it, the caravans are asked for stone and mechanisms (supply_wants, plan_mech 'no stone'), and DECISION_NEEDED no_hard_stone names
-- the counts (usable, economic or soft, ore and flux, out of reach) and the way out. A census with boulders but none usable says the same.
-- BUG-610 (Run 16a i1 Basementflew y426-y429: the 14-day hold ran out, the rock orders were queued again, DF cancelled them 3 times, 14 more
-- days; boulders all out of reach): a second denial with no new boulders in between (`sticky` episodes) is held until more than
-- `new` boulders come, with no time limit, and the question is asked once
M.HARD = {n = 3, window_days = 7, hold_days = 14, new = 5, min_boulders = 10, repeat_days = 28, sticky = 2}
function M.hard_words(why)
  local s = tostring(why or ''):lower()
  return s:find('non-economic', 1, true) ~= nil or s:find('hard stone', 1, true) ~= nil
end
-- BUG-705 (Run 16b i2 Whirledrampart: every wooden job 'Needs logs' with census wood 210 and no word why): DF's "Needs logs" cancel
function M.logs_words(why)
  local s = tostring(why or ''):lower()
  return s:find('needs', 1, true) ~= nil and (s:find(' logs', 1, true) ~= nil or s:find(' log', 1, true) ~= nil)
end
-- where the logs of the fort lie and what holds them (read only, at most PROBE_MAX logs): 'in job x, forbidden x, owned x, carried x, levels zN x'
M.PROBE_MAX = M.PROBE_MAX or 400
function M.wood_probe(K)
  local zs, fl, n = {}, {}, 0
  pcall(function()
    local v = df.global.world.items.other.WOOD
    for i = 0, #v - 1 do
      if n >= M.PROBE_MAX then break end
      local it = v[i]
      local f = it and it.flags
      if f and not (f.removed or f.garbage_collect or f.trader or f.dump or f.in_building or f.construction or f.hostile) then
        n = n + 1
        if f.in_job then M.tally(fl, 'in a job', 1) end
        if f.forbid then M.tally(fl, 'forbidden', 1) end
        if f.owned then M.tally(fl, 'owned', 1) end
        if f.in_inventory then M.tally(fl, 'carried', 1) end
        local x, y, z = dfhack.items.getPosition(it)
        if x then M.tally(zs, 'z' .. tostring(z), 1) end
      end
    end
  end)
  local function list(t)
    local out = {}
    for _, e in ipairs(M.top(t, 4)) do out[#out + 1] = string.format('%s x%d', e[1], e[2]) end
    return table.concat(out, ', ')
  end
  return string.format('%d logs sampled: %s; levels %s', n, list(fl) ~= '' and list(fl) or 'none held', list(zs))
end
-- a "Needs logs" cancel: the census' split of the logs (free / on another walk group / forbidden) and the probe, once per 3 game days
function M.wood_cancel(K, job, why, tick)
  local last = math.tointeger(st.wood_note)
  if last and tick - last < 3 * DAY then return end
  st.wood_note = tick
  local inv = K.census.i or {}
  local free, far, forb = math.tointeger(inv.wood) or 0, math.tointeger(inv.wood_far) or 0, math.tointeger(inv.wood_forb) or 0
  local cause
  if free > 0 then cause = 'DF refuses logs the census counts usable (reachable, not forbidden)'
  elseif far > 0 then cause = 'every log lies on another walk group than the citizens (open the way, bring them in, or cut trees)'
  elseif forb > 0 then cause = 'every log is forbidden (the mood reserve forbids some; unforbid the rest on the items screen)'
  else cause = 'the fort holds no log (cut trees: the Woodcutters need an axe, or ask the caravans: trade.want wood)' end
  local okp, probe = pcall(M.wood_probe, K)
  K.log('warn', 'economy: DF cancels %s "%s": census logs free %d, on another walk group %d, forbidden %d: %s; %s', tostring(job),
        tostring(why), free, far, forb, cause, okp and probe or '?')
end
function M.hard_denied(inv, now)
  local h = st.hard
  if type(h) ~= 'table' or not h.denied then return false end
  if now and h.last and now - h.last >= M.HARD.hold_days * DAY and (math.tointeger(h.eps) or 1) < M.HARD.sticky then return false end
  return (math.tointeger(type(inv) == 'table' and inv.rock) or 0) <= (h.rock or 0) + M.HARD.new
end

-- BUG-667: the fort has no stone a job may take (M.stone_none): DF refused it (hard_denied) or the census holds boulders and none usable (ore, flux,
-- economic, soft or refused stone; out of reach is not counted at all)
function M.stone_none(inv, now)
  if M.hard_denied(inv, now) then return true end
  local d = M.hard_diag(inv)
  return d.rock > 0 and d.usable == 0
end

-- the stone census in one table: usable = the free boulders a mason may take by the census (ore, flux, economic and soft stone
-- out; out of reach is not in `rock` at all), cause 'none' (no usable boulder) or 'denied' (usable by the census, DF cancels anyway)
function M.hard_diag(inv)
  local function g(k) return math.max(0, math.tointeger(inv[k]) or 0) end
  local rock, bad, orf = g('rock'), g('rock_bad'), g('ore') + g('flux')
  local usable = M.usable_n(inv)
  return {boulders = g('boulders'), rock = rock, usable = usable, bad = bad, orf = orf, far = g('rock_far'), busy = g('rock_busy'),
          cause = usable == 0 and 'none' or 'denied'}
end

-- BUG-648 (Run 16c i3 Wallfree y384-y386: Masons 8-11 shops, 0 jobs, doors / tables / chests / thrones waiting 24-44 days beside 350
-- blocks and 37-53 boulders, DF cancelling "Needs non-economic hard stone boulders"; the rock there was CLAYSTONE, 16d i4 MUDSTONE):
-- the stone-use screen (plotinfo.economic_stone[mat_index]) keeps a plain building stone out of furniture while it is marked economic.
-- A free boulder material that is hard (ITEMS_HARD), no ore and no flux and marked economic is cleared to 0 (gui/advfort.lua does the
-- same write: the player's own stone-use setting, no memory trick); soft stone (no ITEMS_HARD) is DF's own refusal and stays out. The
-- material cache is dropped so the census counts the stone usable at its next read, and the denial memory goes with it.
-- Returns the list of {tok, n} cleared and the list of every free boulder material {tok, n, hard, econ, ore, flux} (for the log).
function M.stone_unmark(K)
  local mats, order = {}, {}
  pcall(function()
    local v = df.global.world.items.other.BOULDER
    for i = 0, #v - 1 do
      local it = v[i]
      local f = it and it.flags
      if f and not f.removed and not f.garbage_collect and not f.trader and not f.in_job and it.mat_type == 0 then
        local m = mats[it.mat_index]
        if not m then m = {idx = it.mat_index, n = 0}; mats[it.mat_index] = m; order[#order + 1] = m end
        m.n = m.n + 1
      end
    end
  end)
  local cleared, seen = {}, {}
  for _, m in ipairs(order) do
    orec[m.idx] = nil                                        -- read the raws and the stone-use flag afresh
    local o = ore_of(m.idx)
    m.tok, m.econ, m.hard = o.token or ('mat ' .. tostring(m.idx)), o.econ == true, o.soft ~= true
    m.ore, m.flux = o.metals ~= nil, o.flux == true
    seen[#seen + 1] = {tok = m.tok, n = m.n, hard = m.hard, econ = m.econ, ore = m.ore, flux = m.flux, refused = o.refused == true}
    if m.econ and m.hard and not m.ore and not m.flux then
      local ok, done = pcall(K.act.stone_economic, m.idx, false)
      if ok and done then
        orec[m.idx] = nil
        cleared[#cleared + 1] = {tok = m.tok, n = m.n}
      end
    end
  end
  return cleared, seen
end

-- BUG-665: where the boulders the census counts usable lie, for the question and kern.log when DF refuses them anyway ('denied'): per level, per
-- walkable group, and the flags a job picker looks at; the first MAX probe items of the vector. Returns the text ('' when nothing is readable)
-- and the number of boulders read.
M.PROBE_MAX = 400
function M.boulder_probe(K)
  local zs, gs, fl, n = {}, {}, {}, 0
  pcall(function()
    local v = df.global.world.items.other.BOULDER
    for i = 0, #v - 1 do
      if n >= M.PROBE_MAX then break end
      local it = v[i]
      local f = it and it.flags
      if f and it.mat_type == 0 and not (f.removed or f.garbage_collect or f.trader or f.dump or f.forbid or f.in_building or f.construction
                                       or f.hostile or f.in_job) then
        local o = ore_of(it.mat_index)
        if not (o.metals or o.flux or o.econ or o.soft or o.refused) then
          local x, y, z = dfhack.items.getPosition(it)
          if x then
            n = n + 1
            M.tally(zs, 'z' .. tostring(z), 1)
            local oks, spot = K.call('snapshot', 'spot', x, y, z)             -- {g = walkable group, hidden}
            spot = oks and type(spot) == 'table' and spot or {}
            M.tally(gs, 'g' .. tostring(spot.g or '?'), 1)
            if spot.hidden then M.tally(fl, 'hidden', 1) end
            if f.owned then M.tally(fl, 'owned', 1) end
            if f.in_inventory then M.tally(fl, 'carried', 1) end
          end
        end
      end
    end
  end)
  if n == 0 then return '', 0 end
  local function list(t)
    local out = {}
    for _, e in ipairs(M.top(t, 3)) do out[#out + 1] = string.format('%s x%d', e[1], e[2]) end
    return table.concat(out, ', ')
  end
  local fs = list(fl)
  return string.format('%d usable boulders lie at %s; walk groups %s%s', n, list(zs), list(gs), fs ~= '' and ('; ' .. fs) or ''), n
end

function M.hard_report(K, c, r, cancels)
  local p = r.p
  local d = M.hard_diag(r.inv)
  if (cancels or 0) == 0 and d.usable > 0 then return end        -- the census alone: usable boulders may be the moods' floor
  local now = K.now()
  -- BUG-648: building stone marked economic is cleared (the player's stone-use setting), soft stone and ore stay; the masons take it
  -- at the next census; what the free boulders are is in kern.log
  local okc, cleared, seen = pcall(M.stone_unmark, K)
  local mats
  if okc and type(seen) == 'table' and #seen > 0 then
    local parts = {}
    for i, m in ipairs(seen) do
      if i <= 6 then
        parts[#parts + 1] = string.format('%s x%d (%s%s%s%s%s)', m.tok, m.n, m.hard and 'hard' or 'soft', m.econ and ', economic' or '',
                                          m.ore and ', ore' or '', m.flux and ', flux' or '', m.refused and ', refused by the game' or '')
      end
    end
    K.log('warn', 'economy: free boulders by material: %s', table.concat(parts, '; '))
    mats = {}
    for _, m in ipairs(seen) do
      if m.refused or m.econ or not m.hard then mats[#mats + 1] = (m.tok:gsub('^INORGANIC:', '')):lower() end
    end
  end
  if okc and type(cleared) == 'table' and #cleared > 0 then
    local names, n = {}, 0
    for _, m in ipairs(cleared) do names[#names + 1] = m.tok; n = n + m.n end
    st.hard = nil
    K.log('warn', 'economy: %s marked economic (stone-use screen) kept %d boulders from doors, tables and chests ("Needs ' ..
          'non-economic hard stone"): the mark is cleared, the Masons take it again', table.concat(names, ', '), n)
    K.persist.touch('m.economy')
    return
  end
  local sticky = type(st.hard) == 'table' and (math.tointeger(st.hard.eps) or 1) >= M.HARD.sticky
  if sticky and p.hard_ann_eps == M.HARD.sticky then return end        -- BUG-610: reported once, then quiet until boulders come
  if not (CAD.due(p.hard_ann, now, {}, {d.cause}, {ticks = M.HARD.repeat_days * DAY, wall_s = CAD.WALL_S}) or CAD.elapsed(p.hard_ann, now, M.HARD.repeat_days * DAY, CAD.WALL_S)) then return end
  p.hard_ann = CAD.mark(now, {}, {d.cause})
  p.hard_ann_eps = sticky and M.HARD.sticky or nil
  local q
  -- BUG-665: the way out names the cause: which rock the fort sits on (the materials the game or the stone-use screen refuses) and where the
  -- boulders it counts usable lie (level, walk group, flags) when DF cancels anyway
  local probe = ''
  if d.cause == 'denied' then
    local okp, pt = pcall(M.boulder_probe, K)
    probe = okp and pt or ''
    if probe ~= '' then K.log('warn', 'economy: DF refuses boulders the census counts usable: %s', probe) end
  end
  -- BUG-734 (Run 16c i3 Doorwings: CHALK 36, MAGNETITE 25 held, no plain hard stone, the caravans' `stone` bought more economic boulders):
  -- hard stones the fort holds that only the stone-use screen / the flux and ore rules keep from the masons: the player may free one (stone.use)
  local alts = {}
  if okc and type(seen) == 'table' then
    for _, m in ipairs(seen) do
      if m.hard and not m.refused and (m.econ or m.flux or m.ore) and m.tok then alts[#alts + 1] = m end
    end
    table.sort(alts, function(a, b)
      if (a.ore == true) ~= (b.ore == true) then return not a.ore end                  -- plain economic or flux stone before an ore
      return a.n > b.n
    end)
  end
  local altcmd, altmat
  if #alts > 0 and d.cause == 'none' then
    altmat = (alts[1].tok:gsub('^INORGANIC:', '')):lower()
    altcmd = string.format([[dfllm cmd stone.use '{"mat":"%s"}']], altmat)      -- last in cmds (wake.no_hard_stone_hint names it)
  end
  if d.cause == 'none' then
    local rock = mats and #mats > 0 and (' (' .. table.concat(mats, ', ', 1, math.min(#mats, 4)) .. ' refused)') or ''
    q = string.format('no non-economic hard stone: %d boulders, 0 usable (%d economic/soft, %d ore/flux, %d out of reach)%s; dig ' ..
                      'another rock layer (bp sites explore) or trade for stone; wood serves doors, chests, beds', d.boulders, d.bad,
                      d.orf, d.far, rock)
  else
    q = string.format('DF cancels rock jobs x%d "Needs non-economic hard stone" beside %d boulders counted usable: stone counts 0 ' ..
                      'for %d d; levers, mechanisms, stone traps need it; wood serves doors, beds', cancels, d.usable, M.HARD.hold_days)
    if sticky then      -- BUG-610: the second denial in a row (the boulders may be out of DF's reach): no more rock orders until new boulders come
      q = string.format('DF cancels rock jobs again "Needs non-economic hard stone" beside %d boulders counted usable (%d out of reach ' ..
                        'by the census): no rock order is queued until more than %d new boulders come; mechanisms, stone traps, levers need it; ' ..
                        'wood serves doors, beds', d.usable, d.far, M.HARD.new)
    end
  end
  local cmds = {[[dfllm cmd trade.want '{"add":["stone","mechanism"]}']], 'dfllm plan propose',
                [[dfllm cmd inspect '{"what":"workload"}']]}
  if (math.tointeger(r.inv.wood) or 0) > 0 then          -- BUG-666: the wooden door has a verb now
    cmds[#cmds + 1] = [[dfllm cmd order.add '{"job":"ConstructDoor","amount":4,"mat":"wood"}']]
  end
  if altcmd then cmds[#cmds + 1] = altcmd end
  if probe ~= '' then q = q .. '; ' .. probe end
  K.log('warn', '%s', q)
  K.emit('DECISION_NEEDED', 'A', q:sub(1, 200),
         {id = 'no_hard_stone', q = q:sub(1, 200), cause = d.cause, n = d.usable, cmds = cmds, mat = altmat})
  K.persist.touch('m.economy')
end

function M.hard_cancel(K, c, job, tick)
  local h = type(st.hard) == 'table' and st.hard or {t = {}}
  st.hard = h
  local keep, lim = {}, tick - M.HARD.window_days * DAY
  for _, t in ipairs(h.t) do if t >= lim then keep[#keep + 1] = t end end
  keep[#keep + 1] = tick
  while #keep > 20 do table.remove(keep, 1) end
  -- BUG-610: a first cancel after the hold ran out (the rock orders were queued again) starts another episode of the same denial
  if h.denied and h.last and tick - h.last >= M.HARD.hold_days * DAY then h.lapsed = true end
  h.t, h.last = keep, tick
  if #keep < M.HARD.n then return end
  local r = M.view_run(K)
  if not h.denied or (math.tointeger(r.inv.rock) or 0) > (h.rock or 0) + M.HARD.new then h.eps = 1       -- new boulders: a fresh denial
  elseif h.lapsed then h.eps = (math.tointeger(h.eps) or 1) + 1 end
  h.lapsed = nil
  h.denied, h.rock = true, math.tointeger(r.inv.rock) or 0
  M.hard_report(K, c, r, #keep)
end

-- Run 11: picks for the Miners (their demand before the tool cap, BUG-023, against every pick in the fort): a pick
-- from the first metal with a spare bar at a forge, else economy.trade_wants asks the caravans for them
-- BUG-053: the tools of a kind the fort can hand out: every tool of the census less the free ones the members lacked for
-- tools.stale_days without a member-side cause (tool_check's st.tstale; 16 and 100 loose picks counted as stock for 1081
-- and 144 days while the miners held none, so no pick was made or asked for)
function M.tools_have(inv, kind)
  return math.max(0, (inv['w_' .. kind] or 0) - ((st.tstale or {})[kind] or 0))
end

-- BUG-707 (Run 16b i2 Whirledrampart y421: 'axe 1, free 1, forbidden 1, reserved 1', the Woodcutters without an axe, every wooden job 'Needs logs', trade.want held
-- pick and not axe; Run 16a i1: 17-20 free axes, none handed out for 1229 days): the forge makes axes the way it makes picks (c.axes, a battle axe)
-- and the caravans are asked for them (trade_wants). The demand is the Woodcutters' target less the axes the fort can hand out, and the members
-- that lack an axe while no free one is usable for them (all reserved, forbidden, owned, on another walk group, or none: tool_check's st.tmiss)
function M.plan_picks(K, c, r) return M.plan_tool(K, c, r, 'pick', c.picks, 'ITEM_WEAPON_PICK', 'picks') end
function M.plan_axes(K, c, r) return M.plan_tool(K, c, r, 'axe', c.axes, 'ITEM_WEAPON_AXE_BATTLE', 'axes') end
function M.plan_tool(K, c, r, kind, pc, sub, slot)
  local want, have = (st.want or {})[kind] or 0, M.tools_have(r.inv, kind)
  local pk = {have = have, want = want, short = math.max(0, want - have), route = ''}
  if kind == 'axe' then pk.short = math.max(pk.short, (st.tmiss or {}).axe or 0) end
  st[slot] = pk
  if type(pc) ~= 'table' or pk.short == 0 then return end
  if open(r, pc.tag) then pk.route = 'forge'; return end
  local g = c.gear or {}
  local forge, magma = ws_any(r.f, g.forge), r.f['workshop:MagmaForge'] == true
  for _, m in ipairs(forge and pc.metals or {}) do
    local tok = 'INORGANIC:' .. m
    local n = math.min(pk.short, left(c, r, 'bars:' .. tok), left(c, r, 'bars'), magma and pk.short or left(c, r, 'fuel'),
                       pc.max_jobs or 2)
    if n > 0 then
      add(r, {tag = pc.tag, spec = {job = 'MakeWeapon', item_subtype = sub, material = tok,
                                    item_conditions = {cond(1 + floor_of(c, r.p, r, 'bars'), 'BAR', {material = tok}),
                                                       fuel_cond(r)}},
              n = n, uses = {['bars:' .. tok] = 1, bars = 1, fuel = magma and 0 or 1},
              why = kind == 'axe' and 'axes for the woodcutters' or 'picks for the miners'})
      pk.route = 'forge'
      return
    end
  end
  pk.route = 'trade' .. (forge and '' or ' (no forge)')
end

-- Run 11 (Kilrudrabed y431-y441, site98: no metal ore on the site, bars 0 for ten years, the explore found none and the
-- caravans were never asked for iron; 10 soldiers at worn 58 % lost siege 8): metal is short while soldiers are wanted
-- (gear.n), they wear < metal_short.worn %, no ore boulder of a gear metal lies in the fort and the gear-metal bars are
-- below what the soldiers' metal slots want (gear.bars_short). Then economy.trade_wants asks every caravan for metal
-- (picks and axes up to `tools`, the bars, the missing metal pieces per slot, the alloy metals) and the fort keeps
-- `crafts` crafts to sell for it. st.metal: economy.metal() (military.targets: the melee squads follow the gear),
-- state stock.mshort/melt.
function M.metal_plan(K, c, r)
  local ms, g, inv = c.metal_short, r.gear, r.inv
  if type(ms) ~= 'table' then st.metal = nil; return end
  local gm = {}
  for _, m in ipairs((c.gear or {}).metals or {}) do gm['INORGANIC:' .. m] = true end
  local ore, bars = 0, 0
  for _, o in pairs(st.ores or {}) do
    for _, m in ipairs(o.metals or {}) do if gm[m] then ore = ore + (o.n or 0); break end end
  end
  for tok in pairs(gm) do bars = bars + (st.bars_by[tok] or 0) end
  local okk, kpi = K.call('military', 'kpi')
  local worn = okk and type(kpi) == 'table' and math.tointeger(kpi.worn) or 0
  local short = g.n > 0 and worn < (ms.worn or 80) and ore == 0 and g.bars_short > 0
  local mt = {short = short, worn = worn, bars = bars, ore = ore, need = g.bars_short, melt = inv.melt or 0, wants = {}}
  st.metal = mt
  if not short then return end
  local why = string.format('metal short: worn %d%%, %d bars, no ore, %d bars wanted', worn, bars, g.bars_short)
  for _, k in ipairs({'pick', 'axe'}) do              -- military's tools-first rule: no melee squad below `tools` each
    local have = M.tools_have(inv, k)
    local n = math.max((ms.tools or 3) - have, ((st.want or {})[k] or 0) - have)
    if n > 0 then mt.wants[#mt.wants + 1] = {buy = k, n = n, why = string.format('%d %ss; %s', have, k, why), metal = 1} end
  end
  for _, w in ipairs(ms.wants or {}) do
    local rec = g.cats[w.n]
    local n = w.n == 'bars' and g.bars_short or (rec and rec.miss or 0)
    if type(w.buy) == 'string' and n > 0 then mt.wants[#mt.wants + 1] = {buy = w.buy, n = n, why = why, metal = 1} end
  end
  -- goods to pay with: crafts in free stone (not while stone is short of the rock orders), else in wood
  local tag = ms.craft_tag or 'dfllm:trade_crafts'
  local want = (ms.crafts or 40) - (inv.crafts or 0)
  if want <= 0 or open(r, tag) or not ws_any(r.f, ms.craft_ws or {'workshop:Craftsdwarfs'}) then return end
  local n = math.min(want, ms.craft_jobs or 10)
  local rk = st.rock
  local rock = math.min(stone_free(c, r), left(c, r, 'rock'))
  if rock >= 10 and not (type(rk) == 'table' and (rk.need or 0) > (rk.free or 0)) then
    add(r, {tag = tag, spec = {job = 'MakeCrafts', material = 'INORGANIC'}, n = math.min(n, rock // 2),
            uses = {rock = 1}, why = 'crafts to trade for metal'})
  else
    local wood = left(c, r, 'wood') - ((c.idle or {}).wood_min or 60)
    if wood > 0 then
      add(r, {tag = tag, spec = wood_spec(c, r, {job = 'MakeCrafts'}), n = math.min(n, wood), uses = {wood = 1},
              why = 'crafts to trade for metal'})
    end
  end
end

-- BUG-582: a built trade depot stands (a caravan has a place to unload and trade)
function M.depot_built()
  local ok, res = pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.TRADE_DEPOT) do
      if b:getBuildStage() >= b:getMaxBuildStage() then return true end
    end
    return false
  end)
  return ok and res == true
end

-- BUG-582: trade goods for the caravans. Crafts are on the trade module's sell list and a depot stands, but the fort holds fewer than
-- c.trade_goods.min crafts (the census counts the finished craft items): MakeCrafts in bone, else wood, else stone, at most `jobs` an order
-- (tag c.trade_goods.tag, one open at a time). st.tgoods = {crafts, min, route} for the log and the state.
function M.trade_goods(K, c, r)
  local tg = c.trade_goods
  if type(tg) ~= 'table' then st.tgoods = nil; return end
  local okt, sells = K.call('trade', 'sells')
  local sell = false
  for _, t in ipairs(okt and type(sells) == 'table' and sells or {}) do
    if tostring(t):match('^crafts') then sell = true end
  end
  -- BUG-630: an empty sell list sells whatever lies at the depot, crafts too
  if okt and type(sells) == 'table' and #sells == 0 then sell = true end
  if not (sell and M.depot_built()) then st.tgoods = nil; return end
  local have = r.inv.crafts or 0
  local tgs = {crafts = have, min = tg.min or 30, route = '', logged = type(st.tgoods) == 'table' and st.tgoods.logged or nil}
  st.tgoods = tgs
  local want = tgs.min - have
  if want <= 0 or open(r, tg.tag) then return end
  -- BUG-630 (Run 16b i2 Valleyhame y376-y383: a depot, a caravan, 'nothing_to_sell' and no Craftsdwarf's workshop, so no craft was ever made):
  -- the depot stands, the fort holds fewer crafts than it would sell and no Craftsdwarf's workshop stands: the shop is asked for (workshops
  -- why=trade; M.ws_ask paces the repeats), the crafts come with it
  if not ws_any(r.f, tg.ws or {'workshop:Craftsdwarfs'}) then
    local t = tostring((tg.ws or {'workshop:Craftsdwarfs'})[1]):gsub('^workshop:', '')
    tgs.route = 'no shop'
    M.ws_ask(K, r.p, 'trade', {t}, (c.food or {}).request_days or 14,
             string.format('trade: %d crafts < %d to sell and no Craftsdwarf workshop', have, tgs.min))
    return
  end
  local n = math.min(want, tg.jobs or 10)
  local bone = left(c, r, 'bone') - (tg.bone_keep or 10)
  local rk = st.rock
  local rock = math.min(stone_free(c, r), left(c, r, 'rock'))
  local wood = left(c, r, 'wood') - ((c.idle or {}).wood_min or 60)
  if bone > 0 then
    local spec = {job = 'MakeCrafts', material_category = {'bone'},
                  item_conditions = {cond(floor_of(c, r.p, r, 'bone') + 1, nil, {flags = {'unrotten', 'bone', 'body_part'}})}}
    if add(r, {tag = tg.tag, spec = spec, n = math.min(n, bone), uses = {bone = 1}, why = 'crafts for the caravans'}) then tgs.route = 'bone' end
  elseif wood > 0 then
    if add(r, {tag = tg.tag, spec = wood_spec(c, r, {job = 'MakeCrafts'}), n = math.min(n, wood), uses = {wood = 1},
               why = 'crafts for the caravans'}) then tgs.route = 'wood' end
  elseif rock >= 10 and not (type(rk) == 'table' and (rk.need or 0) > (rk.free or 0)) then
    if add(r, {tag = tg.tag, spec = {job = 'MakeCrafts', material = 'INORGANIC'}, n = math.min(n, rock // 2), uses = {rock = 1},
               why = 'crafts for the caravans'}) then tgs.route = 'stone' end
  end
  if tgs.route ~= '' and tgs.logged ~= tgs.route then
    tgs.logged = tgs.route
    K.log('info', 'trade goods: %d crafts < %d, a depot stands and crafts are on the sell list: MakeCrafts in %s queued (BUG-582)',
          have, tgs.min, tgs.route)
  end
end

-- economy.metal() (CONTRACTS §7): {short, worn, bars, ore, need, melt} of the last plan (M.metal_plan), nil before it
function M.metal(K)
  local mt = st.metal
  if type(mt) ~= 'table' then return nil end
  return {short = mt.short, worn = mt.worn, bars = mt.bars, ore = mt.ore, need = mt.need, melt = mt.melt}
end

-- economy.trade_wants() (CONTRACTS §7): what economy asks the caravans for, [{buy, n, why, metal?}] (trade puts these
-- after the moods' tokens, before plan.trade.want); Run 11: picks the Miners miss while no bar at a forge makes one;
-- while metal is short (M.metal_plan) picks and axes, bars and metal gear (metal = 1: trade sells more for them)
function M.trade_wants(K)
  local r, by = {}, {}
  local pk = st.picks
  if type(pk) == 'table' and (pk.short or 0) > 0 and pk.route ~= 'forge' then
    r[1] = {buy = 'pick', n = pk.short, why = string.format('miners: %d picks < %d', pk.have, pk.want)}
    by.pick = r[1]
  end
  local ak = st.axes                                         -- BUG-707: the woodcutters' axes
  if type(ak) == 'table' and (ak.short or 0) > 0 and ak.route ~= 'forge' then
    r[#r + 1] = {buy = 'axe', n = ak.short, why = string.format('woodcutters: %d axes usable < %d wanted', ak.have, ak.short + ak.have)}
    by.axe = r[#r]
  end
  local mt = st.metal
  for _, w in ipairs(type(mt) == 'table' and mt.short and mt.wants or {}) do
    local e = by[w.buy]
    if e then e.n, e.metal = math.max(e.n, w.n), 1
    else e = {buy = w.buy, n = w.n, why = w.why, metal = 1}; r[#r + 1] = e; by[w.buy] = e end
  end
  for _, w in ipairs(st.fdwants or {}) do                    -- BUG-256, BUG-259: plants, drink, seeds
    if not by[w.buy] then r[#r + 1] = {buy = w.buy, n = w.n, why = w.why}; by[w.buy] = r[#r] end
  end
  local lw = st.lwant                                        -- BUG-309: the mood stock's leather
  if type(lw) == 'table' and not by[lw.buy] then r[#r + 1] = {buy = lw.buy, n = lw.n, why = lw.why}; by[lw.buy] = r[#r] end
  return r
end


---------------------------------------------------------------- fishing and the food blockers (Run 11)
-- Kilrudrabed (site98, y432 winter, pop 54, food 24 days and falling): no meat or fish, no farm soil, both kitchens
-- without a job (ORDER_STUCK PrepareMeal 'no cook'), nobody fished: the Fisherdwarves detail waits for a fishing zone
-- and the kernel only read zones; in y433 883-4532 raw fish lay uncleaned because no fishery stood (food fell to 5
-- days). Module fields, not locals: the main chunk is at Lua's 200-local limit.
--   fishery  raw fish (>= fish.min) or fishers at work and no fishery built: PROJECT_REQUEST workshops why=fishery
--            (follow places a workshops project with only the fishery) at most every food.request_days;
--   zone     while fishers are wanted (food below food.want_days, the food_low pre-alarm or a famine), no fishing zone
--            stands and the fort is in PEACE/RECOVERY, at most every fishing.scan_days: revealed water around the
--            citizens' median (fishing.r tiles; the fortcore surface and the level below it, the citizens' levels and
--            the level below each, at most fishing.levels) through snapshot.liquids (ice listed apart), of depth >=
--            min_flow, never cavern water (caverns stay sealed) or ice (winter), with a standable bank on the citizens'
--            walk group (same level, or the level above over open space or a brook top), never on the attack path
--            (manifest Z1/Z2, killboxes); a roofed bank (inside the walls) first, else the nearest. A side x side zone
--            `dfllm-fish` (act.fish_zone, the zones screen) over the water, and over the bank's level when it stands
--            above. None: 'no safe fishing water (n frozen, n cavern, ...)' in the food decisions and kern.log;
--   decisions food_low (< food.pre_days) and famine name these blockers (M.food_block) with the options.
M.FISH_STAND = {['.'] = true, r = true, ['<'] = true, ['>'] = true, X = true, ['^'] = true}
M.N8 = {{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}

-- the facts (built workshops) of this run: T.watch runs before T.scan, so they are read here first (T.scan again)
function M.facts_now(K, r)
  if type(r.f) ~= 'table' or next(r.f) == nil then r.f = facts(K, r.p) end
  return r.f
end

-- a free adult citizen (no soldier) holds labor `ln` (unit labors, the work details' result)
function M.labor_holder(K, ln)
  local lid = df.unit_labor and df.unit_labor[ln]
  if type(lid) ~= 'number' then return true end           -- unknown labor name: not checked
  local cu = K.census.u
  local sold = {}
  for _, id in ipairs(type(cu) == 'table' and cu.soldier_ids or {}) do sold[id] = true end
  for _, id in ipairs(type(cu) == 'table' and cu.ids or {}) do
    local u = not sold[id] and df.unit.find(id)
    if u and dfhack.units.isAdult(u) and labor_on(u, lid) then return true end
  end
  return false
end

-- BUG-038: the pending workshops project that builds a fishery (its doc's manifest lists one; the runner's project
-- list and doc, read-only): {id, stage, pct, halted = P.blocked unless '' or 'stalled'} or nil. Only `workshops`
-- projects and, BUG-206 (live Earthboat: the fishery request went out while fortcore stage 1, which builds one, was
-- queued), a pending fortcore stage 1: every fortcore stage's doc lists stage 1's workshops, built long ago in a fort
-- whose later stages still run
function M.fishery_proj(K, ws)
  local pd = K.persist.get('projects')
  for _, P in ipairs(type(pd) == 'table' and type(pd.list) == 'table' and pd.list or {}) do
    local id = type(P) == 'table' and (P.tpl == 'workshops' or P.tpl == 'fortcore') and P.done ~= 1 and tostring(P.id or '')
    local d = id and id:match('^[%w_.%-]+$') and K.persist.get('bp.' .. id)
    if id and P.tpl == 'fortcore' and type(d) == 'table' then
      local pp = type(d.params) == 'table' and d.params or {}
      if (math.tointeger(pp.stage) or 1) ~= 1 or (math.tointeger(pp.retrofit) or 0) ~= 0 then d = nil end
    end
    local m = type(d) == 'table' and type(d.manifest) == 'table' and d.manifest.workshops
    for _, w in ipairs(type(m) == 'table' and m or {}) do
      if type(w) == 'table' and ('workshop:' .. tostring(w.type)) == (ws or M.FISHERY)[1] then
        local b = tostring(P.blocked or '')
        return {id = id, stage = P.stage, pct = P.pct, halted = (b ~= '' and b ~= 'stalled') and b or nil}
      end
    end
  end
end

-- BUG-181: the id of the pending workshops project that builds workshop type t (its doc's manifest lists it, as
-- M.fishery_proj), 'unknown' when a pending workshops project's doc lists no workshop at all (it may build anything:
-- held back as before), else nil. Only live projects count (runner.pending_types, else runner.pending > 0): a parked one
-- (build_lost, breach) builds nothing and held no request back before BUG-181 either
function M.ws_queued(K, t)
  local okt, set, all = K.call('runner', 'pending_types', 'workshops')
  if okt and type(set) == 'table' then
    if not (set[t] or all) then return nil end
  else
    local okp, pend = K.call('runner', 'pending', 'workshops')
    if not (okp and type(pend) == 'number' and pend > 0) then return nil end
  end
  local q = M.fishery_proj(K, {'workshop:' .. t})
  if q then return q.id end
  if okt and type(set) == 'table' then return set[t] and 'pending' or 'unknown' end
  local pd = K.persist.get('projects')
  for _, P in ipairs(type(pd) == 'table' and type(pd.list) == 'table' and pd.list or {}) do
    local id = type(P) == 'table' and P.tpl == 'workshops' and P.done ~= 1 and tostring(P.id or '')
    local d = id and id:match('^[%w_.%-]+$') and K.persist.get('bp.' .. id)
    local m = type(d) == 'table' and type(d.manifest) == 'table' and d.manifest.workshops
    if id and not (type(m) == 'table' and #m > 0) then return 'unknown' end
  end
end

-- raw fish (>= fish.min) or fishers at work and no fishery built: PROJECT_REQUEST workshops why=fishery at most every
-- food.request_days (p.fishery_req, the last request). BUG-038 (Run 11, y451: the fishery was destroyed in the sieges,
-- food fell from 51 to 22 days and no fishery came): a fishery seen standing leaves the clock alone (a fishery built
-- from the request and destroyed again waits for the period, one destroyed long after its request is asked at once);
-- 'queued' (no request) only while a pending workshops project builds a fishery, is not halted and moved (stage or
-- pct, p.fishery_q) within the period, and for at most 4 periods; else asked again. kern.log names why it asks.
function M.fishery_request(K, c, r)
  local f, p = c.fish, r.p
  if type(f) ~= 'table' then return end
  local last = math.tointeger(p.fishery_req)
  if ws_any(M.facts_now(K, r), f.ws) then st.fishery, p.fishery_q = nil, nil; return end
  local raw = r.inv.fish_raw or 0
  local fishing = (st.fishers or 0) > 0
  if raw < (f.min or 5) and not fishing then st.fishery = nil; return end
  local every = ((c.food or {}).request_days or 14) * DAY
  local q, pq = M.fishery_proj(K, f.ws), type(p.fishery_q) == 'table' and p.fishery_q or nil
  if not q then pq = nil
  elseif not pq or pq.id ~= q.id or pq.s ~= q.stage or pq.pct ~= q.pct then      -- new, or it moved
    pq = {id = q.id, s = q.stage, pct = q.pct, t = r.now, t0 = pq and pq.id == q.id and pq.t0 or r.now}
  end
  p.fishery_q = pq
  st.fishery_proj = q and q.id or nil
  if last and r.now - last < every then st.fishery = q and 'queued' or 'asked'; return end
  local why
  if q then
    local still = r.now - (math.tointeger(pq.t) or r.now)
    local open = r.now - (last or math.tointeger(pq.t0) or r.now)
    if not q.halted and still < every and open < 4 * every then st.fishery = 'queued'; return end
    why = q.halted and string.format('project %s %s', q.id, q.halted:sub(1, 30))
          or still >= every and string.format('project %s has not moved for %d days', q.id, still // DAY)
          or string.format('project %s open for %d days', q.id, open // DAY)
  else
    why = last and string.format('%d days since the last request', (r.now - last) // DAY) or 'first request'
  end
  p.fishery_req, st.fishery = r.now, 'asked'
  local fd = (r.days or {}).food_d or 0
  K.log('warn', 'fishery: none built, %d raw fish%s, food %d days: request (%s)', raw,
        fishing and ', fishers at work' or '', fd, why)
  K.emit('PROJECT_REQUEST', 'B', string.format('workshops: a fishery for %d raw fish (food %d days)', raw, fd),
         {tpl = 'workshops', n = 1, why = 'fishery'})
end

-- BUG-698: the fishing zones that stand, {{x, y, z}, ...} (the middle of each)
function M.fish_zones()
  local out = {}
  local zt = df.civzone_type and df.civzone_type.FishingArea
  if zt == nil then return out end
  pcall(function()
    for _, z in ipairs(df.global.world.buildings.other.ANY_ZONE) do
      if z.type == zt then
        out[#out + 1] = {(math.tointeger(z.x1) + math.tointeger(z.x2)) // 2, (math.tointeger(z.y1) + math.tointeger(z.y2)) // 2,
                         math.tointeger(z.z)}
      end
    end
  end)
  return out
end

-- BUG-698 (daily, with a fishing zone standing): fishers are wanted and some stand on the detail, yet no Fish job exists and no raw fish
-- lies in the fort: counted in p.fishdry per day, reset by the first Fish job or raw fish. Returns true once it has lasted dry_days days
function M.fish_dry(c, r, zone, fishers, fish_jobs)
  local p, F = r.p, c.fishing or {}
  local inv = r.inv or {}
  local fd = (r.days or {}).food_d or 9999
  local low = p.famine or p.food_pre or fd < ((c.food or {}).want_days or 90)
  if not (zone and low and (fishers or 0) > 0 and fish_jobs == 0 and (inv.fish_raw or 0) < ((c.fish or {}).min or 5)) then
    p.fishdry = nil
    return false
  end
  local day = r.now // DAY
  local fdry = type(p.fishdry) == 'table' and p.fishdry or {since = r.now, days = 0, day = day}
  if fdry.day ~= day then fdry.days, fdry.day = (fdry.days or 0) + 1, day end
  p.fishdry = fdry
  return (fdry.days or 0) >= (F.dry_days or 20)
end

-- the search of this run: levels and box around the citizens, or nil (a zone stands, nothing wanted, mode, cadence)
function M.fish_start(K, c, r)
  local F, p = c.fishing, r.p
  if type(F) ~= 'table' or not rawget(K.act, 'fish_zone') then return nil end
  local spec
  for _, d in ipairs((c.tools or {}).details or {}) do if d.fish then spec = d end end
  if not spec then return nil end
  st.fishzone = fishing_zone()                      -- fish_want reads it again in T.plan
  local dry = false
  if st.fishzone then
    dry = M.fish_dry(c, r, st.fishzone, st.fishers, type(st.jobc) == 'table' and (st.jobc.fish or 0) or nil)      -- BUG-698: fished out: a second zone on another water body
    if not dry then st.fishz = {zone = true}; return nil end
    st.fishdry = true
    local lastd = type(p.fishz) == 'table' and p.fishz or nil
    if not HUNT_MODES[K.mode()] or (lastd and r.now - (math.tointeger(lastd.t) or 0) < (F.scan_days or 7) * DAY) then
      st.fishz = {zone = true}
      return nil
    end
  else
    st.fishdry = nil
  end
  local fd = (r.days or {}).food_d or 9999
  if not (p.famine or p.food_pre or fd < ((c.food or {}).want_days or 90)) then st.fishz = nil; return nil end
  local last = (not dry) and type(p.fishz) == 'table' and p.fishz or nil
  if last then st.fishz = last end
  if not HUNT_MODES[K.mode()] then return nil end
  local cw = K.census and K.census.w
  if type(cw) == 'table' and cw.hold == 1 then return nil end       -- BUG-494: no new fishing zone beside a water beast
  if last and r.now - (math.tointeger(last.t) or 0) < (F.scan_days or 7) * DAY then return nil end
  local xs, ys, zn = {}, {}, {}
  for _, id in ipairs(type(K.census.u) == 'table' and K.census.u.ids or {}) do
    local u = df.unit.find(id)
    local pos = u and u.pos
    local x, y, z = pos and math.tointeger(pos.x), pos and math.tointeger(pos.y), pos and math.tointeger(pos.z)
    if x and y and z and x >= 0 then xs[#xs + 1], ys[#ys + 1], zn[z] = x, y, (zn[z] or 0) + 1 end
  end
  if #xs == 0 then return nil end
  table.sort(xs)
  table.sort(ys)
  local fz = {stage = 'read', lv = {}, li = 1, mx = xs[(#xs + 1) // 2], my = ys[(#ys + 1) // 2], water = {}, nw = 0,
              ice = 0, cav = 0, shallow = 0, nobank = 0, path = 0, checked = 0, wi = 1, found = {},
              old = dry and M.fish_zones() or nil, olds = 0}
  local seen = {}
  local function lv(z)
    if z and z >= 0 and not seen[z] and #fz.lv < (F.levels or 6) then seen[z] = true; fz.lv[#fz.lv + 1] = z end
  end
  local o1 = (K.manifest().bridges or {}).O1
  local fp = type(o1) == 'table' and type(o1.fp) == 'table' and math.tointeger(o1.fp[3])
  if fp then lv(fp + 2); lv(fp + 1) end                  -- fortcore: the surface is two levels above O1
  local zl = {}
  for z, n in pairs(zn) do zl[#zl + 1] = {z, n} end
  table.sort(zl, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] > b[1] end)
  fz.mz = zl[1][1]
  for _, e in ipairs(zl) do lv(e[1]); lv(e[1] - 1) end
  local R = math.max(4, math.tointeger(F.r) or 48)
  local okm, X, Y = pcall(dfhack.maps.getTileSize)
  X, Y = okm and math.tointeger(X) or nil, okm and math.tointeger(Y) or nil
  fz.box = {math.max(0, fz.mx - R), math.max(0, fz.my - R), X and math.min(X - 1, fz.mx + R) or fz.mx + R,
            Y and math.min(Y - 1, fz.my + R) or fz.my + R}
  fz.y = fz.box[2]
  return fz
end

-- a bank for the water tile w = {x, y, z}: {water, bank, up} or nil, and the tile reads it took
function M.fish_bank(K, w)
  local x, y, z = w[1], w[2], w[3]
  local n = 1
  local okt, t = K.call('snapshot', 'tile', x, y, z)
  if not (okt and type(t) == 'table' and (t.c == 'w' or t.c == '~')) or t.ice or t.cav or t.magma then return nil, n end
  local function stand(xx, yy, zz)
    n = n + 1
    local ok, v = K.call('snapshot', 'tile', xx, yy, zz)
    return ok and type(v) == 'table' and M.FISH_STAND[v.c] == true and not v.cav and not far(K, xx, yy, zz)
  end
  for _, o in ipairs(M.N8) do
    if stand(x + o[1], y + o[2], z) then return {water = {x, y, z}, bank = {x + o[1], y + o[2], z}}, n end
  end
  n = n + 1
  local oku, up = K.call('snapshot', 'tile', x, y, z + 1)
  if oku and type(up) == 'table' and not up.cav then
    -- BUG-296 (Run 15c Inkintense: 164 water tiles on z132, 117 under a ramp top 'v' on z133, '160 no bank on the walk
    -- group'): water that fills a ramp lies under the ramp's top, which is open like '_': a fisher stands on the floor
    -- beside that top, one level up (DF lets a dwarf fish from a bank above the water)
    if up.c == '_' or up.c == 'v' then
      for _, o in ipairs(M.N8) do
        if stand(x + o[1], y + o[2], z + 1) then
          return {water = {x, y, z}, bank = {x + o[1], y + o[2], z + 1}, up = true}, n
        end
      end
    elseif M.FISH_STAND[up.c] and not far(K, x, y, z + 1) then           -- a brook top over its water
      return {water = {x, y, z}, bank = {x, y, z + 1}, up = true}, n
    end
  end
  return nil, n
end

-- a tile on the attack path: manifest zones Z1 (bailey), Z2 (trap hall) and the killboxes
function M.attack_path(K, q)
  local man = K.manifest()
  local function inb(b)
    return type(b) == 'table' and #b >= 6 and q[1] >= b[1] and q[1] <= b[4] and q[2] >= b[2] and q[2] <= b[5]
           and q[3] >= b[3] and q[3] <= b[6]
  end
  for _, k in ipairs({'Z1', 'Z2'}) do
    for _, b in ipairs(type(man.zones) == 'table' and type(man.zones[k]) == 'table' and man.zones[k] or {}) do
      if inb(b) then return true end
    end
  end
  for _, kb in ipairs(type(man.killboxes) == 'table' and man.killboxes or {}) do
    if type(kb) == 'table' and inb(kb.bbox) then return true end
  end
  return false
end

function M.fish_none(fz)
  if fz.nw == 0 and fz.ice == 0 and fz.cav == 0 and fz.shallow == 0 then
    return fz.err and 'no fishing water read' or 'no fishing water revealed'
  end
  local parts = {}
  for _, e in ipairs({{fz.ice, 'frozen'}, {fz.cav, 'cavern'}, {fz.shallow, 'shallow'},
                      {fz.nobank, 'no bank on the walk group'}, {fz.path, 'on the attack path'}}) do
    if e[1] > 0 then parts[#parts + 1] = string.format('%d %s', e[1], e[2]) end
  end
  return 'no safe fishing water (' .. table.concat(parts, ', ') .. ')'
end

-- one frame of the search: true when done (the zone painted or the reason kept)
function M.fish_step(K, c, r)
  local F, fz, p = c.fishing, r.fz, r.p
  if fz.stage == 'read' then
    local b, z = fz.box, fz.lv[fz.li]
    if not z then fz.stage = 'sort'; return false end
    local w = b[3] - b[1] + 1
    local rows = math.max(1, math.min(b[4] - fz.y + 1, (F.tiles or 1500) // w, 4096 // w))
    local ok, list, err = K.call('snapshot', 'liquids', b[1], fz.y, b[3], fz.y + rows - 1, z, 1, true)
    if not ok or type(list) ~= 'table' then
      fz.err, fz.stage = 'snapshot.liquids: ' .. tostring(ok and err or list), 'sort'
      return false
    end
    for _, t in ipairs(list) do
      if t[5] == 1 then fz.ice = fz.ice + 1
      elseif t[4] == 1 then fz.cav = fz.cav + 1
      elseif (math.tointeger(t[3]) or 0) < (F.min_flow or 2) then fz.shallow = fz.shallow + 1
      elseif fz.nw < (F.max_water or 3000) then
        fz.nw = fz.nw + 1
        local d = math.max(math.abs(t[1] - fz.mx), math.abs(t[2] - fz.my)) + 3 * math.abs(z - fz.mz)
        fz.water[fz.nw] = {t[1], t[2], z, d}
      end
    end
    fz.y = fz.y + rows
    if fz.y > b[4] then fz.y, fz.li = b[2], fz.li + 1 end
    return false
  end
  if fz.stage == 'sort' then
    table.sort(fz.water, function(a, b)
      if a[4] ~= b[4] then return a[4] < b[4] end
      if a[3] ~= b[3] then return a[3] > b[3] end
      if a[2] ~= b[2] then return a[2] < b[2] end
      return a[1] < b[1]
    end)
    fz.stage = 'check'
    return false
  end
  if fz.stage == 'check' then
    local reads, lim = 0, F.checks or 160
    while fz.wi <= #fz.water and fz.checked < lim and reads < (F.reads or 200) do
      local w = fz.water[fz.wi]
      fz.wi = fz.wi + 1
      local dup = false                      -- the same water body as a bank already found outside
      for _, s in ipairs(fz.found) do
        local sw = s.water
        if sw[3] == w[3] and math.max(math.abs(sw[1] - w[1]), math.abs(sw[2] - w[2])) <= 8 then dup = true end
      end
      for _, o in ipairs(fz.old or {}) do      -- BUG-698: the fished-out water (a zone that stands) is no second zone
        if math.abs(o[3] - w[3]) <= 1 and math.max(math.abs(o[1] - w[1]), math.abs(o[2] - w[2])) <= 8 then
          dup = true
          fz.olds = fz.olds + 1
        end
      end
      if not dup then
        fz.checked = fz.checked + 1
        local site, n = M.fish_bank(K, w)
        reads = reads + n
        if not site then fz.nobank = fz.nobank + 1
        elseif M.attack_path(K, site.bank) then fz.path = fz.path + 1
        else
          local oko, sky = K.call('snapshot', 'outside_near', {site.bank}, 0)
          site.inside = not (oko and type(sky) == 'table' and sky[1] == 1)
          if site.inside then fz.best = site; break end
          fz.found[#fz.found + 1] = site
        end
      end
    end
    if not fz.best and fz.wi <= #fz.water and fz.checked < lim then return false end
    fz.stage = 'paint'
    return false
  end
  local site = fz.best or fz.found[1]
  -- BUG-258: seen = every water tile the scan met (fishable, frozen, cavern, shallow): 0 is a fort without water
  -- (a scan that failed to read the map records none: the fishing zone stays an option then)
  local rec = {t = r.now, ice = fz.ice, cav = fz.cav,
               seen = not fz.err and (fz.nw + fz.ice + fz.cav + fz.shallow) or nil}
  if site then
    r.cmds = r.cmds + 1
    local ok, n = K.act.fish_zone(site.water, F.side or 3, site.up == true)
    local w, bk = site.water, site.bank
    if ok then
      rec.at, rec.bank, rec.inside, rec.why = w, bk, site.inside and 1 or 0, 'painted'
      K.log('info', 'fishing: %s dfllm-fish at %d,%d,%d (%s; bank %d,%d,%d), food %d days', fz.old and 'SECOND zone (the first is fished out)'
            or 'zone', w[1], w[2], w[3], site.inside and 'roofed, inside' or 'open sky', bk[1], bk[2], bk[3], (r.days or {}).food_d or 0)
      if fz.old then p.fishdry = nil end                 -- BUG-698: the fishers have new water
    else
      rec.why = ('fishing zone at %d,%d,%d refused: %s'):format(w[1], w[2], w[3], tostring(n)):sub(1, 80)
      K.log('warn', 'fishing: %s', rec.why)
    end
  else
    rec.why = M.fish_none(fz)
    if fz.old then rec.why = ('fished out, no second water: ' .. rec.why):sub(1, 80) end      -- BUG-698
    K.log('warn', 'fishing: %s around %d,%d on z %s%s', rec.why, fz.mx, fz.my, table.concat(fz.lv, ','),
          fz.err and (' (' .. fz.err .. ')') or '')
  end
  p.fishz, st.fishz = rec, rec
  return true
end

-- daily (before T.watch, so the food decisions name what it found): the fishery request, then the fishing zone search
-- over frames
function T.fishz(K, c, r)
  if not r.day then return true end
  if not r.fz then
    M.fishery_request(K, c, r)
    r.fz = M.fish_start(K, c, r) or false
    if not r.fz then return true end
    r.cmds = r.cmds + 1
    return false
  end
  r.cmds = r.cmds + 1
  return M.fish_step(K, c, r)
end

---------------------------------------------------------------- plant gatherers at food_low (BUG-038)
-- Run 11 (Kilrudrabed y451, pop 26): food_low at 26 days, `inspect workload` 'unclaimed: GatherPlants 450' (the
-- runner's dfllm-gather zone below 30 food days; FR-25 marks shrubs only in a starvation) with 4 of 26 idle: nobody
-- gathered. Below food.pre_days (the food_low line, famine included), in PEACE/RECOVERY, not in labormanager's modern
-- mode, with >= gather.min_jobs unclaimed GatherPlants jobs in the tool details' daily job census (st.jobc of the last
-- tools pass, no scan of its own): the plant gathering detail (starve.details.gatherers by name, else the detail that
-- grants HERBALIST) gets members up to gather.n through act.work_detail (opts.select: a detail on "nobody does this"
-- is set to "only selected", the work details screen's toggle); idle citizens first, then HERBALISM, then id; never a
-- soldier, a noble, a mood, a doctor (DIAGNOSE, SURGERY, BONE_SETTING), the only holder of a key labor or a member of
-- a tool detail. The members it added (p.gather) leave once food is back at gather.off_days (between the lines nothing
-- changes). One kern.log line per change, WORK_DETAIL (B) why=food_low per member; st.gather feeds the food decisions
-- (d.auto gather, or the blocker 'gather: <why>').
M.MEDIC = {'DIAGNOSE', 'SURGERY', 'BONE_SETTING'}
M.TOOL_DETAILS = {Miners = true, Woodcutters = true, Hunters = true, Fisherdwarves = true}

-- the citizens who may join the gatherers, best first: {id, ...}
-- BUG-057: `o` = {skill = job_skill name (default HERBALISM), excl = {unit id = true} (the other farm detail's members),
-- prefer = labor name (holders of it first, among the idle), noprefer = labor name (its holders are left to their own
-- detail), labor = the detail's own labor (a sole holder of it may join)}
function M.gather_cand(K, c, member, o)
  o = o or {}
  local cu = K.census.u or {}
  local sold, cnt, holder, tool_m = {}, {}, {}, {}
  for _, id in ipairs(cu.soldier_ids or {}) do sold[id] = true end
  pcall(function()
    for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do
      if M.TOOL_DETAILS[dfhack.df2utf(w.name)] then for _, id in ipairs(w.assigned_units) do tool_m[id] = true end end
    end
  end)
  local adults = {}
  for _, id in ipairs(cu.ids or {}) do
    local u = df.unit.find(id)
    if u and not dfhack.units.isDead(u) and dfhack.units.isAdult(u) then
      adults[#adults + 1] = u
      for _, l in ipairs((c.tools or {}).key_labors or {}) do
        if labor_on(u, l) then cnt[l], holder[l] = (cnt[l] or 0) + 1, id end
      end
    end
  end
  local sole = {}
  for l, n in pairs(cnt) do if n == 1 and l ~= o.labor then sole[holder[l]] = true end end
  local sid = o.skill ~= false and df.job_skill and df.job_skill[o.skill or 'HERBALISM'] or nil   -- false: no skill ranking
  local excl = o.excl or {}
  local cand = {}
  for _, u in ipairs(adults) do
    local id, doc = u.id, false
    for _, l in ipairs(M.MEDIC) do if labor_on(u, l) then doc = true end end
    local squad = u.military and math.tointeger(u.military.squad_id) or -1
    if not (member[id] or sold[id] or tool_m[id] or sole[id] or excl[id] or doc or squad >= 0 or noble(u) or
            (u.mood or -1) >= 0 or (o.noprefer and labor_on(u, o.noprefer))) then
      cand[#cand + 1] = {id = id, idle = (u.job == nil or u.job.current_job == nil) and 1 or 0,
                         sk = sid and dfhack.units.getNominalSkill(u, sid, true) or 0,
                         pf = o.prefer and labor_on(u, o.prefer) and 1 or 0}
    end
  end
  table.sort(cand, function(a, b)
    if a.idle ~= b.idle then return a.idle > b.idle end
    if a.pf ~= b.pf then return a.pf > b.pf end
    if a.sk ~= b.sk then return a.sk > b.sk end
    return a.id < b.id
  end)
  local r = {}
  for i, e in ipairs(cand) do r[i] = e.id end
  return r
end

-- BUG-042: the brewable plants the drink deficit to the plan's target wants (5 drinks a plant) and the ones in the
-- census (brew_p + brew_g): need, have
function M.brew_need(K, r)
  local dd = (r.days or {}).drink_d or 9999
  local tgt = math.tointeger((K.plan.supply or {}).drink_d) or 170
  local inv = r.inv or {}
  local have = (math.tointeger(inv.brew_p) or 0) + (math.tointeger(inv.brew_g) or 0)
  if dd >= tgt then return 0, have end
  return ((tgt - dd) * (st.rate.drink_d or 0) // 1000 + 4) // 5, have
end

-- BUG-057 (note 35: the four PLANT holders became the gatherers while 122 PlantSeeds waited): while farm jobs wait above
-- cover.min_jobs, the food_low gatherers are not taken from the farm detail's members nor from the PLANT holders
-- (gather_cand options), as M.cover_plan keeps them apart. nil = no farm backlog
function M.gather_apart(K, c)
  local cv, jc = c.cover, st.jobc
  if type(cv) ~= 'table' or type(jc) ~= 'table' then return nil end
  if (math.tointeger(jc.plant_open) or 0) <= (math.tointeger(cv.min_jobs) or 20) then return nil end
  local sc = c.starve or M.DEFAULTS.starve
  local name, wd = find_detail((sc.details or {}).planters, 'PLANT')
  local excl = {}
  if name and not M.TOOL_DETAILS[name] then
    for _, id in ipairs(wd.assigned_units) do excl[id] = true end
  end
  return {excl = excl, noprefer = 'PLANT'}
end

function M.gather_low(K, c, r)
  local g, p = c.gather, r.p
  if type(g) ~= 'table' or (math.tointeger(g.n) or 0) <= 0 then st.gather = nil; return end
  local fd = (r.days or {}).food_d or 9999
  local dd = (r.days or {}).drink_d or 9999
  -- BUG-042: drink low while the brewable plants cannot brew the deficit (the stills' input is gathered too)
  local bneed, bhave = M.brew_need(K, r)
  local dshort = bhave < bneed
  local pg = type(p.gather) == 'table' and type(p.gather.ids) == 'table' and p.gather or nil
  local jc = st.jobc
  local open = type(jc) == 'table' and math.tointeger(jc.gather_open) or 0
  if pg and fd >= (g.off_days or 60) and not (dshort and (dd < (g.drink_off or 0) or st.bshort)) then   -- food (and drink) back
    local out = {}
    for _, id in ipairs(pg.ids) do
      local uid = math.tointeger(id)
      if uid and K.act.work_detail(pg.d, uid, false) then
        M.cv_off(pg.d, uid)
        out[#out + 1] = unit_name(uid)
        K.emit('WORK_DETAIL', 'B', string.format('%s - %s (food back at %d days, drink %d days)', pg.d, unit_name(uid),
                                                 fd, dd),
               {detail = pg.d, unit = uid, on = 0, n = 0, why = (pg.why or 'food_low') .. ' over'})
      end
    end
    r.cmds = r.cmds + 1
    K.log('info', 'gather: food %d days (>= %d), drink %d days: %d plant gatherers off %s (%s)', fd, g.off_days or 60,
          dd, #out, tostring(pg.d), table.concat(out, ', '))
    p.gather, st.gather = nil, nil
    return
  end
  st.gather = pg and {n = #pg.ids, open = open, d = pg.d} or nil
  local flow = fd < ((c.food or {}).pre_days or 30)
  local dlow = (dd < (g.drink_d or 0) or st.bshort) and dshort           -- BUG-408: bshort = the early zone too
  if not (flow or dlow) then return end                                  -- no food_low, no drink_low: nothing new
  local why = flow and 'food_low' or 'drink_low'
  local lead = flow and string.format('food %d days', fd)
               or string.format('drink %d days, %d brewable plants < %d', dd, bhave, bneed)
  if st.engine == 'modern' or type(jc) ~= 'table' or not HUNT_MODES[K.mode()] then return end
  if open < (g.min_jobs or 10) then return end
  st.gather = st.gather or {n = 0, open = open}
  local sc = c.starve or M.DEFAULTS.starve
  local name, wd = find_detail((sc.details or {}).gatherers, 'HERBALIST')
  if not name then st.gather.why = 'no plant gathering detail'; return end
  local wm = df.work_detail_mode or {}
  local mode = wd.flags and wd.flags.mode
  if wm.EverybodyDoesThis ~= nil and mode == wm.EverybodyDoesThis then
    st.gather.why = name .. ' is everybody-does-this (the jobs wait for another reason)'
    return
  end
  local member, have = {}, 0
  for _, id in ipairs(wd.assigned_units) do member[id], have = true, have + 1 end
  local want = math.tointeger(g.n) or 4
  local nobody = wm.NobodyDoesThis ~= nil and mode == wm.NobodyDoesThis
  if have >= want and not nobody then return end
  local ids, mine, names = {}, {}, {}
  for _, id in ipairs(pg and pg.ids or {}) do
    local uid = math.tointeger(id)
    if uid and not mine[uid] then mine[uid], ids[#ids + 1] = true, uid end
  end
  -- enough members on a "nobody does this" detail (the player's): the first of them sets it to only selected
  local list = have >= want and {wd.assigned_units[0]} or M.gather_cand(K, c, member, M.gather_apart(K, c))
  local flipped = false
  for _, id in ipairs(list) do
    if have >= want and not nobody then break end
    if K.act.work_detail(name, id, true, {select = true}) then
      if not member[id] then
        have, names[#names + 1] = have + 1, unit_name(id)
        if not mine[id] then mine[id], ids[#ids + 1] = true, id end
        K.emit('WORK_DETAIL', 'B', string.format('%s + %s (%s: %s, %d gather jobs, target %d)', name,
                                                 unit_name(id), why, lead, open, want),
               {detail = name, unit = id, on = 1, n = want, why = why})
      end
      flipped, nobody = flipped or nobody, false
    end
  end
  r.cmds = r.cmds + 1
  local fl = flipped and '; it was nobody does this: now only selected' or ''
  if #names == 0 then
    if flipped then K.log('warn', 'gather: %s, %d unclaimed GatherPlants jobs: %s%s', lead, open, name, fl)
    elseif not pg then st.gather.why = string.format('no free citizen for %s (%d of %d)', name, have, want) end
    return
  end
  table.sort(ids)
  p.gather = {d = name, ids = json.array(ids), t = pg and pg.t or r.now, why = pg and pg.why or why}
  st.gather = {n = #ids, open = open, d = name}
  K.log('warn', 'gather: %s, %d unclaimed GatherPlants jobs: %s +%d (%s), %d of %d%s', lead, open, name,
        #names, table.concat(names, ', '), have, want, fl)
end

function T.gather(K, c, r) if r.day then M.gather_low(K, c, r) end end

---------------------------------------------------------------- work details follow the demand (BUG-057, FR-72)
-- Run 12-14 (Wheelsblows, Kilrudrabed): PlantSeeds 122-421 and GatherPlants 250-565 stayed unclaimed for years with 30-70 %
-- of the adults idle, the details Planters / Fisherdwarves / Plant gatherers stood at 0 members, and the only code that
-- staffed Planters was FR-25's starvation (food_d <= 0 with hungry citizens). Daily (M.cover_run), in PEACE/RECOVERY and
-- not in labormanager's modern mode: the farmers (PLANT, detail Planters) and the gatherers (HERBALIST, detail Plant
-- gatherers) follow the unclaimed reachable jobs of their kind (config economy.cover), kept apart (a gatherer is not taken
-- from the farmers, a farmer not from the gatherers, the PLANT holders are not made gatherers while farm jobs wait); any
-- other job type of cover.labors with more than min_jobs unclaimed jobs and no holder of its labor gets idle citizens through
-- a detail that grants the labor. A detail never shrinks while unclaimed jobs of its kind exist; the members the kernel
-- added (persist m.economy.cover.mine) leave after idle_days passes without any; the player's members stay. A member
-- without the detail's labor gets it again (every tools.repair_days). Every pass audits Planters, Plant gatherers and
-- Fisherdwarves: members that vanished without the kernel taking them off, and a mode change, go to kern.log and
-- `inspect workload key=details` (the live answer to "who resets the details", note 54).
-- GatherPlants designations nobody worked on for cover.stale_days days and the ones off the citizens' walk group (two passes
-- in a row) are withdrawn (act.plant_ungather, the designation screen's cancel), at most cover.unmark_max a day.
M.COVER = {
  {key = 'farm', det = 'planters', labor = 'PLANT', skill = 'PLANT', kind = 'plant', per = 'farm_per', min = 'farm_min',
   max = 'farm_max', jobs = 'min_jobs', types = {'PlantSeeds', 'HarvestPlants'}},
  {key = 'gather', det = 'gatherers', labor = 'HERBALIST', skill = 'HERBALISM', kind = 'gather', per = 'gather_per',
   min = 'gather_min', max = 'gather_max', jobs = 'gather_jobs', types = {'GatherPlants'}},
}

-- the kernel took a member off a detail (tools, gather_low, cover): a member that vanishes without it was taken off by
-- somebody else (the game, a plugin, the player)
function M.cv_off(name, id)
  st.wd_off = st.wd_off or {}
  st.wd_off[name .. ':' .. tostring(id)] = true
end

-- the cover specs: the farm and gather ones, then one per further labor of cover.labors (sorted; tool labors have
-- their own details and are left to M.tools)
function M.cover_specs(cv)
  local out = {}
  for _, s in ipairs(M.COVER) do out[#out + 1] = s end
  local seen, names, by = {}, {}, {}
  for _, s in ipairs(M.COVER) do seen[s.labor] = true end
  for tn, lab in pairs(type(cv.labors) == 'table' and cv.labors or {}) do
    if type(lab) == 'string' and not seen[lab] and not M.JOB_KIND[tn] then
      by[lab] = by[lab] or {}
      by[lab][#by[lab] + 1] = tn
    end
  end
  for lab in pairs(by) do names[#names + 1] = lab end
  table.sort(names)
  for _, lab in ipairs(names) do
    table.sort(by[lab])
    out[#out + 1] = {key = lab:lower(), labor = lab, kind = 'by', types = by[lab], jobs = 'min_jobs', per = 'other_per',
                     max = 'other_max', other = true}
  end
  return out
end

-- BUG-390: the walk groups that count as the citizens' (snapshot.home_set: the biggest and every one with a fifth of them,
-- the rule the sites ranking uses), from the group ids read at their tiles; all groups with a citizen when the module cannot say
function M.home_groups(K, cg)
  local ok, set = K.call('snapshot', 'home_set', cg)
  if ok and type(set) == 'table' then return set end
  local home = {}
  for _, g in ipairs(cg) do if math.type(g) == 'integer' and g > 0 then home[g] = true end end
  return home
end

-- open jobs of a kind the citizens can walk to: (reachable open, off the walk group, the sampled positions' flags)
function M.cv_reach(K, jc, kind)
  local open = math.tointeger(jc[kind .. '_open']) or 0
  local pts = jc[kind .. '_pts'] or {}
  if open == 0 or #pts == 0 then return open, 0, {} end
  local cpts = {}
  for _, id in ipairs((K.census.u or {}).ids or {}) do
    local u = df.unit.find(id)
    local okp, x, y, z = pcall(function() return u.pos.x, u.pos.y, u.pos.z end)
    if u and okp and math.tointeger(x) then cpts[#cpts + 1] = {x, y, z} end
  end
  local okc, cg = K.call('snapshot', 'groups', cpts, false)
  if not (okc and type(cg) == 'table') then return open, 0, {} end
  local home = M.home_groups(K, cg)
  local okj, jg = K.call('snapshot', 'groups', pts, true, home)      -- BUG-390: a tree answers the citizens' group when it touches it
  if not (okj and type(jg) == 'table') then return open, 0, {} end
  if next(home) == nil then return open, 0, {} end
  local far, nf = {}, 0
  for k = 1, #pts do
    local g = math.tointeger(jg[k]) or -1
    if g >= 0 and not home[g] then far[k], nf = true, nf + 1 end
  end
  local off = math.min(open, nf * open // #pts)
  return open - off, off, far
end

-- BUG-341 (CONTRACTS §7): the open FellTree jobs of the last job census and how many the citizens can walk to
-- {open, reach, far}; nil before the first tools pass
function M.fell_reach(K)
  local jc = st.jobc
  if type(jc) ~= 'table' then return nil end
  local reach, off = M.cv_reach(K, jc, 'fell')
  return {open = math.tointeger(jc.fell_open) or 0, reach = reach, far = off}
end

-- one detail's audit: the members that vanished without the kernel (p.cover.seen against the list now), a mode change
function M.cv_audit(K, p, name, wd, now_ids, labor)
  local cvp = p.cover
  local seen = type(cvp.seen[name]) == 'table' and cvp.seen[name] or {}
  local have = {}
  for _, id in ipairs(now_ids) do have[id] = true end
  local lost = {}
  for _, id in ipairs(seen) do
    local uid = math.tointeger(id)
    local u = uid and df.unit.find(uid)
    if uid and not have[uid] and not (st.wd_off or {})[name .. ':' .. uid] and u and not dfhack.units.isDead(u)
       and dfhack.units.isCitizen(u) and (u.military == nil or (math.tointeger(u.military.squad_id) or -1) < 0) then
      lost[#lost + 1] = uid
    end
  end
  -- the marks of the kernel's own removals are spent once the audit has seen them (review: they grew without bound and
  -- hid a later loss of a member the kernel had taken off and added again)
  for key in pairs(st.wd_off or {}) do
    if key:sub(1, #name + 1) == name .. ':' then st.wd_off[key] = nil end
  end
  local mode = wd.flags and math.tointeger(wd.flags.mode)
  local was = math.tointeger(cvp.mode[name])
  local wm = df.work_detail_mode or {}
  if #lost > 0 then
    cvp.lost[name] = (math.tointeger(cvp.lost[name]) or 0) + #lost
    -- do they still hold the detail's labor? (DF drops a member whose labor flag is not set: a hand-written
    -- assigned_units entry without the labor, note 54, would show 0 here)
    local still = 0
    for _, id in ipairs(lost) do
      local u = df.unit.find(id)
      if u and labor and labor_on(u, labor) then still = still + 1 end
    end
    K.log('warn', 'details: %s lost %d members the kernel did not take off (%d left, mode %s, %d of them still hold %s): %s',
          name, #lost, #now_ids, tostring(wm[mode] or mode), still, tostring(labor), table.concat(lost, ' '):sub(1, 120))
  end
  if mode and was and mode ~= was then
    K.log('warn', 'details: %s changed its mode %s -> %s (not the kernel)', name, tostring(wm[was] or was),
          tostring(wm[mode] or mode))
  end
  if mode then cvp.mode[name] = mode end
  return #lost
end

-- the plan of one daily pass (no DF write): rows per spec, the queue of adds and removals
function M.cover_plan(K, c, r)
  local cv, p, jc = c.cover, r.p, st.jobc
  local sc = c.starve or M.DEFAULTS.starve
  local li = df.global.plotinfo.labor_info
  local cu = K.census.u or {}
  local wm = df.work_detail_mode or {}
  local cvp = p.cover
  for _, k in ipairs({'mine', 'seen', 'zero', 'mode', 'lost'}) do cvp[k] = type(cvp[k]) == 'table' and cvp[k] or {} end
  local specs = M.cover_specs(cv)
  local adults, hold, alive = {}, {}, {}
  for _, id in ipairs(cu.ids or {}) do
    local u = df.unit.find(id)
    if u and not dfhack.units.isDead(u) then
      alive[id] = true
      if dfhack.units.isAdult(u) then
        adults[#adults + 1] = u
        for _, s in ipairs(specs) do if labor_on(u, s.labor) then hold[s.labor] = (hold[s.labor] or 0) + 1 end end
      end
    end
  end
  local wds = {}
  for _, w in ipairs(li.work_details) do wds[dfhack.df2utf(w.name)] = w end
  local safe = HUNT_MODES[K.mode()] == true and st.engine ~= 'modern'
  local cap_all = math.max(1, #adults * (math.tointeger(cv.share) or 50) // 100)    -- all the cover details together
  local rows, queue, members = {}, {}, {}
  local now = K.now().tick
  -- the details first: members per name (farm and gather exclude each other)
  for _, s in ipairs(specs) do
    local name, wd = find_detail(s.det and (sc.details or {})[s.det] or nil, s.labor)
    if name and M.TOOL_DETAILS[name] then name, wd = nil, nil end
    s.name, s.wd = name, wd
    if wd then
      local set, list = {}, {}
      for _, id in ipairs(wd.assigned_units) do
        set[id] = true
        if alive[id] then list[#list + 1] = id end
      end
      members[name] = {set = set, list = list}
    end
  end
  local in_cover = 0                                        -- members of the cover details now (each detail once)
  for _, m in pairs(members) do in_cover = in_cover + #m.list end
  for _, s in ipairs(specs) do
    local row = {key = s.key, labor = s.labor, name = s.name, holders = hold[s.labor] or 0, open = 0, reach = 0, far = 0,
                 cur = 0, want = 0, add = 0, rem = 0}
    rows[#rows + 1] = row
    if s.kind == 'by' then
      for _, tn in ipairs(s.types) do row.open = row.open + (math.tointeger((jc.by_open or {})[tn]) or 0) end
      row.reach = row.open
    else
      row.reach, row.far = M.cv_reach(K, jc, s.kind)
      row.open = math.tointeger(jc[s.kind .. '_open']) or 0
    end
    local wd = s.wd
    if not wd then
      row.why = row.open > 0 and 'no work detail grants ' .. s.labor or nil
    else
      local mem = members[s.name]
      row.cur, row.mode = #mem.list, math.tointeger(wd.flags and wd.flags.mode)
      M.cv_audit(K, p, s.name, wd, mem.list, s.labor)
      local thr = math.tointeger(cv[s.jobs]) or 20
      local per = math.max(1, math.tointeger(cv[s.per]) or 20)
      local mn = math.tointeger(cv[s.min or '']) or 1
      local mx = math.max(mn, math.tointeger(cv[s.max]) or 3)
      local want = 0
      if row.reach > thr then want = clamp((row.reach + per - 1) // per, mn, mx) end
      -- all the cover details together hold at most `share` percent of the adults (members that are there stay)
      row.want = math.max(math.min(want, cap_all - (in_cover - #mem.list)), math.min(want, #mem.list))
      local zk = s.key
      cvp.zero[zk] = row.open == 0 and (math.tointeger(cvp.zero[zk]) or 0) + 1 or 0
      local mine = type(cvp.mine[s.name]) == 'table' and cvp.mine[s.name] or {}
      local ml, dup = {}, {}
      for _, id in ipairs(mine) do
        local uid = math.tointeger(id)
        if uid and mem.set[uid] and alive[uid] and not dup[uid] then dup[uid], ml[#ml + 1] = true, uid end
      end
      row.mine = ml
      cvp.mine[s.name] = ml                       -- review: only the members still there (it grew with every re-add)
      if not safe then
        row.why = 'not in PEACE/RECOVERY or labormanager modern'
      elseif wm.EverybodyDoesThis ~= nil and row.mode == wm.EverybodyDoesThis then
        row.why = 'everybody-does-this (the jobs wait for another reason)'
      elseif row.want > row.cur then
        local excl = {}
        for _, o in ipairs(specs) do
          if o.key ~= s.key and o.name and members[o.name] and (s.key == 'farm' or s.key == 'gather') and
             (o.key == 'farm' or o.key == 'gather') then
            for id in pairs(members[o.name].set) do excl[id] = true end
          end
        end
        local farm_up = false                                -- farm jobs above the threshold: the PLANT holders plant
        for _, o in ipairs(rows) do
          if o.key == 'farm' and o.reach > (math.tointeger(cv.min_jobs) or 20) then farm_up = true end
        end
        local cand = M.gather_cand(K, c, mem.set, {skill = s.skill or false, excl = excl, labor = s.labor,
                                                   prefer = s.key == 'farm' and 'PLANT' or nil,
                                                   noprefer = s.key == 'gather' and farm_up and 'PLANT' or nil})
        local n = math.min(row.want - row.cur, math.max(1, math.tointeger(cv.step) or 4), #cand)
        for i = 1, n do queue[#queue + 1] = {name = s.name, id = cand[i], on = true, why = 'cover', n = row.want} end
        row.add = n
        if n < row.want - row.cur then row.why = string.format('no free citizen (%d of %d)', row.cur + n, row.want) end
      elseif (math.tointeger(cvp.zero[zk]) or 0) >= (math.tointeger(cv.idle_days) or 7) and #ml > 0 and row.cur > mn then
        table.sort(ml, function(a, b) return a > b end)
        for _, id in ipairs(ml) do
          if row.cur - row.rem <= mn then break end
          queue[#queue + 1] = {name = s.name, id = id, on = false, why = 'cover idle', n = mn}
          row.rem = row.rem + 1
        end
      end
      -- a member without the detail's labor gets it through the detail again, at most every repair_days
      if safe then
        local rd = (c.tools or {}).repair_days or 7
        st.fixes = st.fixes or {}
        for _, id in ipairs(mem.list) do
          local u = df.unit.find(id)
          local key = s.name .. ':' .. id
          if u and not labor_on(u, s.labor) and now - (st.fixes[key] or -1e12) >= rd * DAY then
            st.fixes[key] = now
            queue[#queue + 1] = {name = s.name, id = id, on = true, why = 'cover labor', n = row.want, labor = s.labor}
          end
        end
      end
    end
  end
  -- Fisherdwarves: audit only (M.tools staffs it)
  local fs
  for _, d in ipairs((c.tools or {}).details or {}) do if d.fish then fs = d.name end end
  if fs and wds[fs] then
    local list = {}
    for _, id in ipairs(wds[fs].assigned_units) do if alive[id] then list[#list + 1] = id end end
    M.cv_audit(K, p, fs, wds[fs], list, 'FISH')
    rows[#rows + 1] = {key = 'fish', name = fs, labor = 'FISH', holders = 0, open = math.tointeger(jc.fish_open) or 0,
                       reach = 0, far = 0, cur = #list, want = st.fish_want or 0, add = 0, rem = 0, audit = true}
  end
  return rows, queue, wds, alive
end

-- GatherPlants designations to withdraw: the ones off the walk group in two passes in a row, and every sampled one when
-- nobody worked on any GatherPlants job for stale_days (not while food or drink is low: gatherers are wanted then)
function M.cover_unmark(K, c, r, rows)
  local cv, p, jc = c.cover, r.p, st.jobc
  local cvp = p.cover
  if not HUNT_MODES[K.mode()] then return nil end
  local reach, off, far = M.cv_reach(K, jc, 'gather')
  local pts = jc.gather_pts or {}
  local prev, now_far = st.cv_far or {}, {}
  local list, seen = {}, {}
  local lim = math.tointeger(cv.unmark_max) or 200
  local n_far, n_stale = 0, 0
  -- a gate bridge that is not down splits the walk groups (the plants outside the wall lie off the citizens' group
  -- until it falls): then nothing is "off the walk group" for good
  local br = K.view().bridges
  local split = false
  for _, v in pairs(type(br) == 'table' and br or {}) do if v ~= 'down' then split = true end end
  for k, pt in ipairs(pts) do
    if far[k] and not split then
      local key = pt[1] .. ',' .. pt[2] .. ',' .. pt[3]
      now_far[key] = true
      if prev[key] and #list < lim and not seen[key] then seen[key] = true; list[#list + 1] = pt; n_far = n_far + 1 end
    end
  end
  st.cv_far = now_far
  local open = math.tointeger(jc.gather_open) or 0
  local taken = (math.tointeger(jc.gather) or 0) - open
  if open > 0 and taken == 0 then
    if not tonumber(cvp.gstale) then cvp.gstale = r.now end
  else cvp.gstale = nil end
  local fd = (r.days or {}).food_d or 9999
  local pre = (c.food or {}).pre_days or 30
  local stale = tonumber(cvp.gstale) and r.now - cvp.gstale >= (math.tointeger(cv.stale_days) or 30) * DAY
  if stale and fd >= pre and not p.famine then
    for k, pt in ipairs(pts) do
      local key = pt[1] .. ',' .. pt[2] .. ',' .. pt[3]
      if #list < lim and not seen[key] then seen[key] = true; list[#list + 1] = pt; n_stale = n_stale + 1 end
    end
  end
  if #list == 0 then return nil end
  return list, n_far, n_stale
end

function M.cover_run(K, c, r)
  local cv, p = c.cover, r.p
  if type(cv) ~= 'table' or cv.on == false then st.cover = nil; return true end
  if st.engine == 'modern' or st.engine == nil or type(st.jobc) ~= 'table' or not df.global.plotinfo.labor_info then
    return true
  end
  if type(p.cover) ~= 'table' then p.cover = {} end
  local cx = r.cv
  if not cx then
    local ok, rows, queue = pcall(M.cover_plan, K, c, r)
    if not ok then K.log('warn', 'details: cover plan failed: %s', tostring(rows)); return true end
    cx = {rows = rows, q = queue, added = {}, removed = {}}
    r.cv = cx
    r.cmds = r.cmds + 1
    return false
  end
  local e = table.remove(cx.q, 1)
  if e then
    r.cmds = r.cmds + 1
    if K.act.work_detail(e.name, e.id, e.on, {select = e.on or nil}) then
      local tgt = cx.added
      if e.on then
        if e.why == 'cover' then
          local m = type(p.cover.mine) == 'table' and p.cover.mine or {}
          p.cover.mine = m
          local l = type(m[e.name]) == 'table' and m[e.name] or {}
          l[#l + 1] = e.id
          m[e.name] = l
        end
      else
        M.cv_off(e.name, e.id)
        local l = p.cover.mine and p.cover.mine[e.name]
        for i = #(l or {}), 1, -1 do if math.tointeger(l[i]) == e.id then table.remove(l, i) end end
        tgt = cx.removed
      end
      if e.why == 'cover labor' then
        K.log('info', 'details: %s %s had no %s labor: set through the detail', e.name, unit_name(e.id), e.labor or '?')
      else
        tgt[e.name] = tgt[e.name] or {}
        tgt[e.name][#tgt[e.name] + 1] = e.id
        K.emit('WORK_DETAIL', 'B', string.format('%s %s %s (%s, target %d)', e.name, e.on and '+' or '-',
                                                 unit_name(e.id), e.why, e.n),
               {detail = e.name, unit = e.id, on = e.on and 1 or 0, n = e.n, why = e.why})
      end
    end
    return false
  end
  if not cx.unmarked then
    cx.unmarked = true
    local ok, list, nf, ns = pcall(M.cover_unmark, K, c, r, cx.rows)
    if ok and list then
      r.cmds = r.cmds + 1
      local okw, n = K.act.plant_ungather(list)
      n = okw and math.tointeger(n) or 0
      -- (review: nothing withdrawn -- the shrubs were not marked any more -- is no line every day)
      if n > 0 then
        K.log('info', 'gather: %d GatherPlants designations withdrawn (%d off the walk group, %d unworked for %d days)',
              n, nf or 0, ns or 0, math.tointeger(c.cover.stale_days) or 30)
      end
      cx.withdrawn = n
      return false
    elseif not ok then K.log('warn', 'details: withdraw failed: %s', tostring(list)) end
  end
  -- finish: log the changes, remember the members (the next pass's audit) and the rows (inspect)
  local li = df.global.plotinfo.labor_info
  local wds = {}
  for _, w in ipairs(li.work_details) do wds[dfhack.df2utf(w.name)] = w end
  for _, row in ipairs(cx.rows) do
    local nm = row.name
    if nm and wds[nm] then
      local ids = {}
      for _, id in ipairs(wds[nm].assigned_units) do ids[#ids + 1] = id end
      p.cover.seen[nm] = json.array(ids)
      row.now = #ids
    end
    local a, d = cx.added[nm or ''], cx.removed[nm or '']
    if a or d then
      local who = {}
      for _, id in ipairs(a or {}) do who[#who + 1] = unit_name(id) end
      K.log('info', 'details: %s %s%s (%s %d unclaimed, %d reachable; target %d; holders %d)', nm,
            a and ('+' .. #a .. ' (' .. table.concat(who, ', '):sub(1, 90) .. ')') or '',
            d and (' -' .. #d) or '', row.key, row.open, row.reach, row.want, row.holders)
    end
  end
  for _, k in ipairs({'mine', 'seen', 'zero', 'mode', 'lost'}) do
    local t = p.cover[k]
    if getmetatable(t) == nil then p.cover[k] = json.object(t) end
  end
  for k, v in pairs(p.cover.mine) do p.cover.mine[k] = json.array(v) end
  st.cover = {rows = cx.rows, withdrawn = cx.withdrawn or 0, day = r.now}
  K.persist.touch('m.economy')
  return true
end

function T.cover(K, c, r) if r.day then return M.cover_run(K, c, r) end end

---------------------------------------------------------------- the famine crew (BUG-340)
-- Run 15c Inkintense y378-y383 (food 0-9 d for a year, 31 hungry, 3 starved): `inspect workload` 2 of 39 idle, 4417
-- unclaimed jobs, the one FarmPlot 86,87,133 'not suspended, no builder has taken it' (a FarmPlot wants the PLANT labor),
-- Planters and Plant gatherers on everybody-does-this: every dwarf held every labor, the busy ones hauled, built and
-- cleaned, and nobody's job was the food. gather_low and cover_plan stop at an everybody-does-this detail ('the jobs wait
-- for another reason'). In a famine (food below famine_days) or below famine_days of drink, daily, not in labormanager's
-- modern mode, the kernel names a food crew: per spec (M.FCREW) up to famine_crew[n] specialists of the spec's detail
-- through act.work_detail(opts.only, keep = M.FCREW_KEEP): they keep the food labors and give up the everybody-does-this
-- ones, so a planter plants and builds the farm plot, a cook cooks. Candidates as the gatherers' (M.gather_cand: never a
-- soldier, noble, doctor, mood, tool member or sole key-labor holder; idle and skilled first), no patient. New members only
-- in PEACE/RECOVERY (a gatherer or a surface planter walks outside: never toward hostiles); at most famine_crew.share
-- percent of the adults, famine_crew.step a day. His shortage back at off_days (M.fcrew_cause): he goes back
-- (act.work_detail off with opts.only gives the everybody labors back; one who was a member before, or of an
-- everybody-does-this detail, joins again as a plain member). State p.fcrew {t, ids, d (id -> detail), w (id -> 1: member before), k (id -> 'food' |
-- 'drink': the shortage he was named for; review fix merge15: he goes back when that one is over), l (id -> the labors
-- the crew took away or he had of the detail before: only those come back, BUG-340 second review fix), x (id -> 1: the
-- player took him off his detail; never named again while the famine lasts)}; st.fcrew feeds the food decisions (auto
-- 'crew').
M.FCREW = {
  {key = 'farm', det = 'planters', labor = 'PLANT', skill = 'PLANT', n = 'farmers'},
  {key = 'cook', names = {'Cooks', 'Cooking', 'Cook'}, labor = 'COOK', skill = 'COOK', n = 'cooks'},
  {key = 'brew', names = {'Brewers', 'Brewing', 'Brewer'}, labor = 'BREWER', skill = 'BREWING', n = 'brewers'},
  {key = 'gather', det = 'gatherers', labor = 'HERBALIST', skill = 'HERBALISM', n = 'gatherers'},
}
M.FCREW_KEEP = {'PLANT', 'HERBALIST', 'COOK', 'BREWER', 'FISH', 'CLEAN_FISH', 'DISSECT_FISH', 'PROCESSPLANT', 'MILLER',
                'BUTCHER', 'HAUL_FOOD'}

-- farm plots that stand or are placed (built or not: a FarmPlot construction job wants a PLANT holder too)
function M.farm_plots_any()
  local ok, n = pcall(function() return #df.global.world.buildings.other.FARM_PLOT end)
  return ok and (math.tointeger(n) or 0) or 0
end

-- BUG-618 (Run 16b i2 Valleyhame y373: the food crew came at 8 food days, the third famine of the fort; 'no cook ingredient', 'hunt: no
-- bolts', food 8 -> 0 within 6 days): the food days below which the crew starts: famine_days or famine_crew.pre_days (20), whichever is
-- higher (the crew goes back at off_days 30, so the band 20..30 is a hysteresis, not a flutter)
function M.fcrew_line(c)
  local cf = type(c.famine_crew) == 'table' and c.famine_crew or M.DEFAULTS.famine_crew
  local pre = math.tointeger(cf.pre_days) or 0
  return math.max(c.famine_days or 10, pre)
end

-- how many crew members a spec wants now (0: none), and why
function M.fcrew_want(K, c, r, s, wd)
  local cf = c.famine_crew or M.DEFAULTS.famine_crew
  local n = math.tointeger(cf[s.n]) or 0
  if n <= 0 or not wd then return 0 end
  local p, inv, days = r.p, r.inv or {}, r.days or {}
  local lim = c.famine_days or 10
  local fam = p.famine ~= nil or (days.food_d or 9999) < M.fcrew_line(c)      -- BUG-618: before the famine
  local f = M.facts_now(K, r)
  if s.key == 'farm' then return fam and M.farm_plots_any() > 0 and n or 0 end
  if s.key == 'cook' then return fam and ws_any(f, {'workshop:Kitchen'}) and M.cook_n(inv) > 0 and n or 0 end
  if s.key == 'brew' then
    local g = c.gather or M.DEFAULTS.gather
    local brew = (math.tointeger(inv.brew_p) or 0) + (math.tointeger(inv.brew_g) or 0)
    return (days.drink_d or 9999) < (g.drink_d or 60) and (fam or (days.drink_d or 9999) < lim) and
           ws_any(f, {'workshop:Still'}) and brew > 0 and n or 0
  end
  if s.key == 'gather' then
    local wm = df.work_detail_mode or {}
    local g = c.gather or M.DEFAULTS.gather
    local jc = st.jobc
    local open = type(jc) == 'table' and math.tointeger(jc.gather_open) or 0
    return fam and wm.EverybodyDoesThis ~= nil and wd.flags and wd.flags.mode == wm.EverybodyDoesThis and
           open >= (g.min_jobs or 10) and n or 0
  end
  return 0
end

-- the work detail of that name (nil: none)
function M.fcrew_wd(d)
  local wd
  pcall(function()
    for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do
      if dfhack.df2utf(w.name) == d then wd = w end
    end
  end)
  return wd
end

-- Review fix (merge15): one crew member goes back (act.work_detail off with opts.only gives the everybody-does-this labors
-- back, also to one already off the detail); with `rejoin` one who was a member before, or of an everybody-does-this
-- detail, joins again as a plain member. why: the WORK_DETAIL text's reason. false: act refused (he is dropped anyway).
function M.fcrew_release(K, pc, uid, d, why, rejoin)
  -- BUG-340 second review fix: only the labors the crew took away come back (pc.l; an older state without it: every
  -- everybody-does-this labor), never one the player had switched off himself
  local l = type(pc.l) == 'table' and type(pc.l[tostring(uid)]) == 'table' and pc.l[tostring(uid)] or nil
  if not K.act.work_detail(d, uid, false, {only = true, labors = l}) then return false end
  M.cv_off(d, uid)
  if rejoin then
    local wm, wd = df.work_detail_mode or {}, M.fcrew_wd(d)
    local every = wd ~= nil and wm.EverybodyDoesThis ~= nil and wd.flags.mode == wm.EverybodyDoesThis
    if (type(pc.w) == 'table' and pc.w[tostring(uid)]) or every then K.act.work_detail(d, uid, true) end
  end
  K.emit('WORK_DETAIL', 'B', string.format('%s - %s (%s)', d, unit_name(uid), why),
         {detail = d, unit = uid, on = 0, n = 0, why = 'famine_crew over'})
  return true
end

-- Review fix (merge15): the shortage a member was named for (p.fcrew.k: 'food' or 'drink'; an older state without k:
-- a member of the brew detail drink, every other one food)
function M.fcrew_cause(pc, uid, d)
  local k = type(pc.k) == 'table' and pc.k[tostring(uid)]
  if k == 'food' or k == 'drink' then return k end
  for _, s in ipairs(M.FCREW) do
    if s.key == 'brew' then for _, n in ipairs(s.names) do if n == d then return 'drink' end end end
  end
  return 'food'
end

-- BUG-340 second review fix: the labors a unit has on now (set of labor numbers)
function M.fcrew_labors(u)
  local s = {}
  pcall(function()
    local ul = df.unit_labor
    local lo, hi = ul._first_item, ul._last_item
    if type(lo) == 'number' and type(hi) == 'number' then
      for l = math.max(0, lo), hi do if u.status.labors[l] then s[l] = true end end
    else
      for _, l in pairs(ul) do if type(l) == 'number' and u.status.labors[l] then s[l] = true end end
    end
  end)
  return s
end

-- the labors to give back after a crew join: those on before and off after, and those of the detail he had before
function M.fcrew_taken(before, after, wd)
  local r = {}
  for l in pairs(before) do
    local own = false
    pcall(function() own = wd.allowed_labors[l] and true or false end)
    if not after[l] or own then
      local n = df.unit_labor and df.unit_labor[l]
      r[#r + 1] = type(n) == 'string' and n or l
    end
  end
  table.sort(r, function(a, b) return tostring(a) < tostring(b) end)
  return r
end

function M.fcrew_run(K, c, r)
  local cf, p = c.famine_crew, r.p
  local days = r.days or {}
  local fd, dd = days.food_d or 9999, days.drink_d or 9999
  local lim = c.famine_days or 10
  local pc = type(p.fcrew) == 'table' and type(p.fcrew.ids) == 'table' and p.fcrew or nil
  if type(cf) ~= 'table' or cf.on == false then
    st.fcrew = nil
    -- Review fix (merge15): the crew switched off gives its members back (they stayed specialized before)
    -- (second review fix: not in modern labormanager, which sets the labors itself; the state is dropped all the same)
    local ok, li = pcall(function() return df.global.plotinfo.labor_info end)
    if pc and st.engine == 'modern' then p.fcrew = nil end
    if pc and st.engine ~= 'modern' and ok and li then
      local n = 0
      for _, id in ipairs(pc.ids) do
        local uid = math.tointeger(id)
        local d = uid and type(pc.d) == 'table' and pc.d[tostring(uid)]
        if uid and d and M.fcrew_release(K, pc, uid, d, 'famine crew switched off', true) then n = n + 1 end
      end
      r.cmds = r.cmds + 1
      K.log('info', 'famine crew switched off: %d specialists back to every labor', n)
      p.fcrew = nil
    end
    return
  end
  if st.engine == 'modern' or st.engine == nil or not df.global.plotinfo.labor_info then return end
  local off = math.tointeger(cf.off_days) or 30
  local cu = K.census.u or {}
  local alive, adults = {}, 0
  for _, id in ipairs(cu.ids or {}) do
    local u = df.unit.find(id)
    if u and not dfhack.units.isDead(u) then
      alive[id] = u
      if dfhack.units.isAdult(u) then adults = adults + 1 end
    end
  end
  local cap = math.max(1, adults * (math.tointeger(cf.share) or 25) // 100)
  -- the members still there. Review fix (merge15): a drafted or moody one, one off his detail (the player, DF) and one
  -- whose shortage is over (food or drink back at off_days: the one he was named for, not both) goes back with his
  -- everybody labors (they stayed off for good before); a dead or departed one is only dropped
  local ids, dmap, wmap, kmap, lmap, by, out = {}, {}, {}, {}, {}, {}, {}
  -- BUG-340 second review fix: one released this run is not named again in the same run (excl below); one the player
  -- took off his detail stays out while the famine lasts (xmap, p.fcrew.x)
  local gone, xmap = {}, {}
  for k in pairs(pc and type(pc.x) == 'table' and pc.x or {}) do
    local x = math.tointeger(tonumber(k))
    if x then xmap[tostring(x)] = 1 end
  end
  local function back(uid, d, why, rejoin)
    gone[uid] = true
    if M.fcrew_release(K, pc, uid, d, why, rejoin) then out[#out + 1] = unit_name(uid) end
  end
  for _, id in ipairs(pc and pc.ids or {}) do
    local uid = math.tointeger(id)
    local u = uid and alive[uid]
    local d = uid and type(pc.d) == 'table' and pc.d[tostring(uid)]
    if u and d then
      local wd = M.fcrew_wd(d)
      local member = false
      if wd then for _, x in ipairs(wd.assigned_units) do if x == uid then member = true end end end
      local cause = M.fcrew_cause(pc, uid, d)
      if u.military and (math.tointeger(u.military.squad_id) or -1) >= 0 then
        back(uid, d, 'famine crew: drafted', true)
      elseif (u.mood or -1) >= 0 then
        back(uid, d, 'famine crew: in a mood', true)
      elseif not member then
        xmap[tostring(uid)] = 1
        back(uid, d, 'famine crew: no longer a member', false)
      elseif (cause == 'drink' and dd >= off) or (cause ~= 'drink' and fd >= off) then
        back(uid, d, string.format('famine crew over: food %d days, drink %d days', fd, dd), true)
      else
        ids[#ids + 1], dmap[tostring(uid)], kmap[tostring(uid)] = uid, d, cause
        if type(pc.w) == 'table' and pc.w[tostring(uid)] then wmap[tostring(uid)] = 1 end
        if type(pc.l) == 'table' and type(pc.l[tostring(uid)]) == 'table' then lmap[tostring(uid)] = pc.l[tostring(uid)] end
        by[d] = (by[d] or 0) + 1
      end
    end
  end
  -- Review fix (merge15): fewer adults (deaths, departures, soldiers): a crew above its share gives the last ones back
  while #ids > cap do
    local uid = table.remove(ids)
    local d = dmap[tostring(uid)]
    dmap[tostring(uid)], wmap[tostring(uid)], kmap[tostring(uid)], lmap[tostring(uid)] = nil, nil, nil, nil
    by[d] = (by[d] or 1) - 1
    back(uid, d, string.format('famine crew above its cap: %d of %d adults', cap, adults), true)
  end
  if #out > 0 then
    r.cmds = r.cmds + 1
    K.log('info', 'famine crew: food %d days, drink %d days (off at %d): %d specialists back to every labor (%s)', fd, dd,
          off, #out, table.concat(out, ', '):sub(1, 160))
  end
  local active = p.famine ~= nil or fd < M.fcrew_line(c) or dd < lim
  if not active then xmap = {} end
  local rows, names = {}, {}
  if active and HUNT_MODES[K.mode()] then
    local sc = c.starve or M.DEFAULTS.starve
    local step = math.max(1, math.tointeger(cf.step) or 2)
    local excl = {}
    for _, uid in ipairs(ids) do excl[uid] = true end
    for uid in pairs(gone) do excl[uid] = true end
    for k in pairs(xmap) do excl[math.tointeger(tonumber(k))] = true end
    local wm = df.work_detail_mode or {}
    for _, s in ipairs(M.FCREW) do
      local name, wd = find_detail(s.det and (sc.details or {})[s.det] or s.names, s.labor)
      if name and M.TOOL_DETAILS[name] then name, wd = nil, nil end
      local want = M.fcrew_want(K, c, r, s, wd)
      local have = name and by[name] or 0
      local row = {key = s.key, d = name, want = want, have = have}
      rows[#rows + 1] = row
      if want > have and #ids < cap and step > 0 then
        local every = wm.EverybodyDoesThis ~= nil and wd.flags and wd.flags.mode == wm.EverybodyDoesThis
        local member = {}
        if not every then for _, id in ipairs(wd.assigned_units) do member[id] = true end end
        local cand = M.gather_cand(K, c, member, {skill = s.skill, excl = excl, labor = s.labor, prefer = s.labor})
        for _, id in ipairs(cand) do
          if have >= want or #ids >= cap or step <= 0 then break end
          local u = alive[id]
          if u and not M.patient(u) then
            local was = false
            for _, x in ipairs(wd.assigned_units) do if x == id then was = true end end
            r.cmds = r.cmds + 1
            local before = M.fcrew_labors(u)
            local okd, err = K.act.work_detail(name, id, true, {only = true, keep = M.FCREW_KEEP, select = true})
            if not okd then row.why = ('%s refused: %s'):format(name, tostring(err)):sub(1, 60); break end
            if okd then
              excl[id], have, step = true, have + 1, step - 1
              ids[#ids + 1], dmap[tostring(id)] = id, name
              kmap[tostring(id)] = s.key == 'brew' and dd < lim and 'drink' or 'food'
              lmap[tostring(id)] = json.array(M.fcrew_taken(before, M.fcrew_labors(u), wd))
              if was and not every then wmap[tostring(id)] = 1 end
              names[#names + 1] = unit_name(id)
              K.emit('WORK_DETAIL', 'B', string.format('%s + %s (famine crew %s: food %d days, drink %d days, target %d)',
                                                       name, unit_name(id), s.key, fd, dd, want),
                     {detail = name, unit = id, on = 1, n = want, why = 'famine_crew'})
            end
          end
        end
        row.have = have
        if have < want and not row.why then row.why = string.format('no free citizen (%d of %d)', have, want) end
      elseif want > have then row.why = string.format('crew at its cap (%d of %d adults)', #ids, adults) end
    end
  end
  if #ids == 0 then
    st.fcrew = nil
    -- (second review fix: the player's removals are kept while the famine lasts, also with no member left)
    p.fcrew = next(xmap) and {t = pc and pc.t or r.now, ids = json.array({}), d = json.object({}), w = json.object({}),
                              k = json.object({}), l = json.object({}), x = json.object(xmap)} or nil
    return
  end
  table.sort(ids)
  p.fcrew = {t = pc and pc.t or r.now, ids = json.array(ids), d = json.object(dmap), w = json.object(wmap),
             k = json.object(kmap), l = json.object(lmap), x = json.object(xmap)}
  local cnt = {}
  for _, d in pairs(dmap) do cnt[d] = (cnt[d] or 0) + 1 end
  local parts = {}
  for d, n in pairs(cnt) do parts[#parts + 1] = string.format('%s %d', d, n) end
  table.sort(parts)
  st.fcrew = {n = #ids, text = table.concat(parts, ', '), rows = rows}
  if #names > 0 then
    K.log('warn', 'famine crew: food %d days, drink %d days: +%d food specialists (%s); crew %d (%s)', fd, dd, #names,
          table.concat(names, ', '):sub(1, 120), #ids, st.fcrew.text)
  end
end

function T.fcrew(K, c, r) if r.day then M.fcrew_run(K, c, r) end end

-- what keeps food from coming, for the food_low and famine decisions: {{id, text, cmd?}} by weight, and what the kernel
-- does about it itself (BUG-038): {{id, text}} (the fishery request, the gatherers). BUG-340: cmd = the command line that
-- fixes the blocker as it stands (M.FOOD_CMD; nil when only the kernel or DF can: cook, hungry, gather, hunt)
function M.food_block(K, c, r, inv)
  local f, out, auto = M.facts_now(K, r), {}, {}
  local function put(id, txt, cmd) out[#out + 1] = {id, txt, cmd} end
  -- BUG-059: hungry citizens and no prepared meal: the food days count raw food nobody cooks, say so first
  if (st.hungry_n or 0) > 0 and (inv.meals or 0) == 0 then
    local cw = st.cookw
    -- BUG-629: the kitchen stands and the cook ingredients lie there (M.cook_watch made the order again): not 'raw food is not cooked'
    if type(cw) == 'table' and cw.relax then
      put('hungry', string.format('%d hungry, 0 meals: kitchen idle with %d cook ingredients (order made again)', st.hungry_n, cw.ing or 0))
    else put('hungry', string.format('%d hungry, 0 meals: raw food is not cooked', st.hungry_n)) end
  end
  local raw = inv.fish_raw or 0
  if raw > 0 and not ws_any(f, M.FISHERY) then
    if st.fishery == 'asked' or st.fishery == 'queued' then          -- BUG-038: follow places it, nothing to decide
      auto[#auto + 1] = {'fishery', string.format('fishery %s (%d raw fish%s)', st.fishery, raw,
                                                  st.fishery == 'queued' and st.fishery_proj and (', ' .. st.fishery_proj)
                                                  or '')}
    else put('fishery', string.format('build a fishery (%d raw fish)', raw), M.FOOD_CMD.fishery) end
  end
  if type(st.fishw) == 'table' then       -- BUG-716: the fishery stands, the raw fish are not cleaned
    put('fish_clean', string.format('%d raw fish uncleaned for %d days: %s', st.fishw.raw or raw, st.fishw.d or 0, tostring(st.fishw.text or '')))
  end
  local sg = st.gather
  if type(sg) == 'table' then
    if (sg.n or 0) > 0 then auto[#auto + 1] = {'gather', string.format('%d gatherers added (%d gather jobs)', sg.n,
                                                                     sg.open or 0)}
    elseif sg.why then put('gather', 'gather: ' .. sg.why) end
  end
  -- BUG-340: the caravans are asked for food and seeds by the kernel itself (M.fd_wants), never the player's option
  if M.food_low(c, r) then auto[#auto + 1] = {'trade', 'caravans asked for food, seeds'} end
  -- BUG-340: the famine crew (food specialists) is the kernel's too
  local fcw = st.fcrew
  if type(fcw) == 'table' and (fcw.n or 0) > 0 then
    auto[#auto + 1] = {'crew', string.format('food crew %d (%s)', fcw.n, tostring(fcw.text or ''))}
  end
  if not ws_any(f, {'workshop:Kitchen'}) then
    local cut = f['cut:Kitchen'] and M.cut_text(r.p, 'Kitchen') or nil      -- BUG-654: it stands, nobody can walk to it
    if M.shop_asked(r.p, 'Kitchen') or M.shop_asked(r.p, 'Kitchen', 'cut') then
      auto[#auto + 1] = {'kitchen', cut and ('new Kitchen requested, the old one is cut off: ' .. cut) or 'Kitchen requested'}      -- BUG-618: the kernel asks itself
    else put('kitchen', cut and ('Kitchen cut off: ' .. cut) or 'no kitchen', M.FOOD_CMD.kitchen) end
  elseif M.cook_n(inv) <= 0 then put('cook', 'no ' .. M.cook_why(inv, f))
  elseif not M.labor_holder(K, 'COOK') then put('cook', 'nobody holds the COOK labor') end
  -- BUG-258 (live Inkintense: block [cook, fish_zone, hunt, farms] in a fort without a brook, 175 bolts and no
  -- crossbow): a fishing zone is no option where the scan met no water at all (z.seen 0; frozen or cavern water is
  -- still named), and hunting with no crossbow names the crossbow (its Bowyer's workshop), not bolts
  if st.fishzone and st.fishdry then      -- BUG-698: fishers stand at a zone with no fish
    local z = type(st.fishz) == 'table' and st.fishz or {}
    put('fish_dry', string.format('fishing: %d fishers, no Fish job and no raw fish for %d days: the water is fished out%s',
                                  st.fishers or 0, (type(r.p.fishdry) == 'table' and r.p.fishdry.days) or 0,
                                  type(z.why) == 'string' and z.why:find('fished out', 1, true) and (' (' .. z.why .. ')') or
                                  ' (a second fishing zone is searched)'))
  end
  if not st.fishzone then
    local z = st.fishz
    local why = type(z) == 'table' and type(z.why) == 'string' and z.why ~= 'painted' and z.why or nil
    if not (type(z) == 'table' and z.seen == 0 and not z.at) then put('fish_zone', why or 'no fishing zone') end
  end
  if hunters_spec(c) and (st.hunters or 0) == 0 then
    local h = st.hunt or {}
    if (inv.w_xbow or 0) + (inv.w_bow or 0) == 0 then
      local bolts = inv.bolts_free or inv.bolts or 0
      if r.s and r.s.live and (r.s.live['dfllm:gear_xbow'] or 0) > 0 then
        auto[#auto + 1] = {'xbow', string.format('crossbows ordered (%d bolts)', bolts)}
      elseif not ws_any(f, {'workshop:Bowyers'}) then
        -- BUG-618: with logs the gear plan asks for the shop itself (plan_gear); without, the player's command stays
        if M.shop_asked(r.p, 'Bowyers', 'gear') then auto[#auto + 1] = {'bowyer', "Bowyer's workshop requested"}
        else put('xbow', string.format("hunt: no crossbow, no Bowyer's workshop (%d bolts)", bolts), M.FOOD_CMD.bowyer) end
      else put('xbow', string.format('hunt: no crossbow (%d bolts)', bolts)) end
    elseif st.no_ammo or (inv.bolts_free or 0) == 0 then put('hunt', 'hunt: no bolts')
    elseif h.why == 'siege' or h.why == 'hold' then put('hunt', 'hunt: not in ' .. tostring(K.mode())) end
  end
  local fs = st.food or {}
  if (fs.need or 0) > (fs.tiles or 0) then
    put('farms', st.farm_lost and string.format('farms %d/%d tiles; %s lost (build_lost): cancel it, place elsewhere',
                                                fs.tiles or 0, fs.need or 0, tostring(st.farm_lost):sub(1, 12))
                 or string.format('farms %d/%d tiles', fs.tiles or 0, fs.need or 0),
        -- BUG-341 review: a surface farm only in PEACE (follow's own rule, BUG-302): planters never walk out in a fight
        K.mode() == 'PEACE' and M.FOOD_CMD.farms or M.FOOD_CMD.farms_room)
  end
  local ca = K.census.a
  if type(ca) == 'table' and (math.tointeger(ca.n) or 0) > 0 and not ws_any(f, (c.slaughter or {}).ws) then
    if M.shop_asked(r.p, 'Butchers') then auto[#auto + 1] = {'butcher', "Butcher's shop requested"}
    else put('butcher', "no butcher's shop", M.FOOD_CMD.butcher) end
  end
  return out, auto
end

-- BUG-618: the shop type was asked for by the kernel (p.wsask[why].s lists the types of the last request) and no shop stands yet
function M.shop_asked(p, t, why)
  local w = type(p.wsask) == 'table' and p.wsask[why or 'mandatory'] or nil
  return type(w) == 'table' and (',' .. tostring(w.s or '') .. ','):find(',' .. t .. ',', 1, true) ~= nil
end

-- BUG-618 (Run 16b i2 Valleyhame y372-y373: food 0-4 days with no kitchen and no butcher's shop, the famine decision only offered
-- the bp.place command lines and the fort waited for the player): below the pre-alarm line or in a famine the kernel asks for the
-- missing Kitchen (a meal feeds, raw plants do not) and, with tame animals standing, the Butchers itself (workshops why=mandatory,
-- follow places them; M.ws_ask paces the repeats); the decisions then list them under `auto`, not as the player's blockers
function M.food_shops(K, c, r)
  local p = r.p
  if not M.food_low(c, r) then return end
  local f, want = M.facts_now(K, r), {}
  if not ws_any(f, {'workshop:Kitchen'}) then want[#want + 1] = 'Kitchen' end
  local ca = K.census.a
  if type(ca) == 'table' and (math.tointeger(ca.n) or 0) > 0 and not ws_any(f, (c.slaughter or {}).ws) then want[#want + 1] = 'Butchers' end
  if #want == 0 then
    if type(p.wsask) == 'table' then p.wsask.mandatory = nil end
    return
  end
  M.ws_ask(K, p, 'mandatory', want, (c.food or {}).request_days or 14,
           string.format('workshops: food %d days and no %s', (r.days or {}).food_d or 0, table.concat(want, '/')))
end

-- BUG-340: the player's options besides the blockers' fixes, as command lines: butcher.mark while tame animals stand (the
-- verb keeps breeding pairs, pets and war animals), popcap.lower to the citizens now until food recovers
function M.food_more(K, r)
  local out = {}
  -- BUG-459 (Run 16d Orbblock y377: famine 7 -> 4 -> 1 day, the decision offered butcher.mark 'no animal to mark (7 tame ... stay)'):
  -- the options are the ones that can work now. trade.want food and seeds always can (the caravans bring what the list names; the
  -- kernel asks for them itself, the list is the player's word); butcher.mark only while the verb would mark an animal (pets, war and
  -- hunting animals, marked ones and one breeding pair per race stay)
  out[#out + 1] = {'trade.want', [[dfllm cmd trade.want '{"add":["food","seeds"]}']], true}
  local ca = K.census.a
  if type(ca) == 'table' and type(ca.list) == 'table' and #M.slaughter_pick(ca.list, {keep_f = 1, keep_m = 1, max = 1}) > 0 then
    out[#out + 1] = {'butcher.mark', [[dfllm cmd butcher.mark '{"n":2}']]}
  end
  local cit = math.tointeger(r and r.cit) or 0
  if cit > 0 then
    out[#out + 1] = {'popcap.lower', string.format([[dfllm cmd popcap.lower '{"cap":%d,"until":"food"}']], cit)}
  end
  return out
end

-- BUG-059 (Run 12 y503: 12 starved under "food 41 d", meals 0): hungry citizens while no prepared meal stands and the
-- food days are above the pre-alarm line (below it the food_low decision names it): one kern.log line, again after
-- 7 days or when the hungry count doubled
function M.hungry_warn(K, c, r)
  local p, n = r.p, st.hungry_n or 0
  local inv = r.inv or {}
  local fd = (r.days or {}).food_d or 9999
  if n == 0 or (inv.meals or 0) > 0 or fd < ((c.food or {}).pre_days or 30) then
    p.hungry_w = nil
    return
  end
  local w = type(p.hungry_w) == 'table' and p.hungry_w or nil
  if w and r.now - (math.tointeger(w.t) or 0) < 7 * DAY and n < 2 * (math.tointeger(w.n) or 0) then return end
  p.hungry_w = {t = r.now, n = n}
  -- BUG-345 (Run 15 Guildcleans y386: '0 cook ingredients' beside 517 cook-banned): the ban and its material are named
  local t = (inv.cook_ban or 0) > 0 and st.cban and st.cban[1]
  K.log('warn', 'food %d days but %d citizens hungry and no prepared meal: raw plants and seeds are not cooked (%d cook ' ..
        'ingredients%s, kitchen %s, COOK labor %s)', fd, n, M.cook_n(inv),
        t and string.format(', %d cook-banned: %s', inv.cook_ban, tostring(t[1])) or '',
        ws_any(M.facts_now(K, r), {'workshop:Kitchen'}) and 'built' or
          (M.facts_now(K, r)['cut:Kitchen'] and 'cut off (' .. tostring(M.cut_text(r.p, 'Kitchen')) .. ')' or 'missing'),
        M.labor_holder(K, 'COOK') and 'held' or 'on nobody')
end

-- the decision text: numbers, blockers (each names its fix), what the kernel does itself (BUG-038: `auto: ...`, never
-- cut), the player's other options (DECISION_NEEDED q <= 200 bytes); opts = every option, the blockers' first (d.opts)
-- BUG-258: xbow = no crossbow for the hunters; butcher.mark = the verb that marks surplus tame animals
-- BUG-340 (Run 15c Inkintense y378, 15d Drillchamber y379-y381: famine for weeks; the options `gather` (no verb) and
-- `trade.want food` (bad args; the verb replaces the whole want list) could not be sent): an option is offered only with
-- its command line (d.cmds, in the order of d.opts); the caravans' food and seeds and the gatherers are the kernel's (auto),
-- the fishing zone too (M.fish_zone paints it on safe water; the blocker names why none stands)
M.FOOD_OPTS = {fishery = 'fishery', kitchen = 'kitchen', xbow = 'bowyer', farms = 'farms', butcher = 'butcher'}
M.FOOD_CMD = {
  fishery = [[dfllm cmd bp.place '{"tpl":"workshops","site":"S1","p":{"only":"Fishery"}}']],
  kitchen = [[dfllm cmd bp.place '{"tpl":"workshops","site":"S1","p":{"only":"Kitchen"}}']],
  butcher = [[dfllm cmd bp.place '{"tpl":"workshops","site":"S1","p":{"only":"Butchers"}}']],
  bowyer = [[dfllm cmd bp.place '{"tpl":"workshops","site":"S1","p":{"only":"Bowyers"}}']],
  farms = [[dfllm cmd bp.place '{"tpl":"farms","site":"S1","p":{"surface":1}}']],
  farms_room = [[dfllm cmd bp.place '{"tpl":"farms","site":"S1"}']],         -- outside PEACE: an underground farm room
}
M.FOOD_CMDS_BYTES = 480                         -- d stays under kern's 1,024 bytes with q, block, opts and auto (JSON escapes); BUG-459: +trade.want
function M.food_q(fd, r, inv, bl, auto, more)
  local parts, opts, au, cmds, bytes = {}, {}, {}, {}, 0
  local function offer(o, cmd)
    if not cmd or bytes + #cmd > M.FOOD_CMDS_BYTES then return end
    opts[#opts + 1], cmds[#cmds + 1], bytes = o, cmd, bytes + #cmd
  end
  for _, b in ipairs(bl) do
    parts[#parts + 1] = b[2]:sub(1, 72)
    if M.FOOD_OPTS[b[1]] then offer(M.FOOD_OPTS[b[1]], b[3]) end
  end
  local names = {}
  for _, o in ipairs(more or {}) do
    if not o[3] then names[#names + 1] = o[1] end        -- BUG-459: a quiet option (trade.want) is in `auto` already
    offer(o[1], o[2])
  end
  for _, a in ipairs(auto or {}) do au[#au + 1] = a[2]:sub(1, 44) end
  local ap = #au > 0 and ('; auto: ' .. table.concat(au, ', ')) or ''
  local q = string.format('food %d d (%d cit, %s%d meals)', fd, r and r.cit or 0,
                          (st.hungry_n or 0) > 0 and (st.hungry_n .. ' hungry, ') or '', inv.meals or 0) ..
            (#parts > 0 and (': ' .. table.concat(parts, '; ')) or '')
  local tail = #names > 0 and ('. Also: ' .. table.concat(names, ', ')) or ''
  if #q + #ap + #tail > 200 then q = q:sub(1, math.max(30, 197 - #ap - #tail)) .. '...' end
  return (q .. ap .. tail):sub(1, 200), opts, cmds
end

-- the decision's d.block / d.auto ids and the head of its line: the first blocker, then 'auto: fishery, gather'
function M.food_head(bl, auto)
  local ids, aids = {}, {}
  for _, b in ipairs(bl) do ids[#ids + 1] = b[1] end
  for _, a in ipairs(auto or {}) do aids[#aids + 1] = a[1] end
  local h = {}
  if bl[1] then h[1] = bl[1][2] end
  if #aids > 0 then h[#h + 1] = 'auto: ' .. table.concat(aids, ', ') end
  return ids, #aids > 0 and aids or nil, #h > 0 and (': ' .. table.concat(h, '; ')) or ''
end

-- Run 11: cookable growths a kitchen exclusion keeps from the cooks (ban-cooking fruit or the kitchen screen; plump
-- helmets are no growth and stay banned, D-09) are let go once per food_low/famine episode: ban-cooking fruit --unban
function M.food_unban(K, c, r, inv)
  local p = r.p
  if not (p.famine or p.food_pre) then p.food_unban = nil; return end
  if p.food_unban or (inv.cook_ban_g or 0) <= 0 then return end
  p.food_unban = r.now
  r.cmdq[#r.cmdq + 1] = {'ban-cooking', 'fruit', '--unban'}
  K.log('warn', 'food %d days: %d cookable plant growths on the kitchen ban: ban-cooking fruit --unban',
        (r.days or {}).food_d or 0, inv.cook_ban_g)
end

-- BUG-345 (Run 15 Guildcleans y386: PrepareMeal 'no cook ingredient (517 cook-banned)', 0 meals beside 100 food days):
-- the baseline enables seedwatch, which watches every plant at 30 seeds and bans the cooking of each one with fewer
-- (Kitchen::denyPlantSeedCookery: PLANT and SEEDS), and clears that list only tens of thousands of ticks later (i2
-- commands.log: enable at tick 150019880, clear at 150049832); unwatching lifts no ban. When the kitchen has nothing to cook
-- while food lies on a kitchen exclusion, the exclusion goes (act.kitchen_include), at most COOK_REPAIR_N a day and each one
-- once a year at most. Kept: Gordon's rule (config `kitchen`, D-09: no exclusion row), the farmed crops (seedwatch guards
-- their seeds), every SEEDS exclusion (seeds are no food: never in st.kx).
M.COOK_REPAIR_N = 16
M.COOK_REPAIR_AGAIN = 336 * DAY
function M.cook_repair(K, c, r, inv)
  if not r.day or (inv.cook_in or 0) > 0 or (inv.cook_ban_x or 0) <= 0 or type(st.kx) ~= 'table' then return end
  local p = r.p
  if type(p.kit_rep) ~= 'table' then p.kit_rep = {} end
  local okc, bs = K.call('baseline', 'status')
  if not (okc and type(bs) == 'table' and type(bs.crops) == 'table') then return end    -- the farmed crops unknown: no lift
  local crops = {}
  for _, id in ipairs(bs.crops) do crops[id] = true end
  local done, names = 0, {}
  for _, e in ipairs(st.kx) do
    if done >= M.COOK_REPAIR_N then break end
    local plant = tostring(e.tok or ''):match('^PLANT:([^:]+):')
    local key = string.format('%s:%d:%d:%d', e.cat, e.sub, e.t, e.i)
    local last = math.tointeger(p.kit_rep[key])
    if (e.n or 0) > 0 and not (plant and crops[plant]) and not (last and r.now - last < M.COOK_REPAIR_AGAIN) then
      local ok, why = K.act.kitchen_include(e.cat, e.sub, e.t, e.i, 'Cook')
      if ok then
        p.kit_rep[key], done = r.now, done + 1
        names[#names + 1] = string.format('%s x%d', M.short_mat(e.tok), e.n)
      else K.log('warn', 'kitchen: %s stays on the ban: %s', tostring(e.tok), tostring(why)) end
    end
  end
  local n = 0
  for _ in pairs(p.kit_rep) do n = n + 1 end
  if n > 64 then p.kit_rep = {} end                 -- bounded: a dropped key only allows one more lift
  if done > 0 then
    K.log('warn', 'kitchen: nothing to cook, %d food items on kitchen exclusions (seedwatch or the kitchen screen; ' ..
          'farmed crops and D-09 stay): cooking allowed again for %s', inv.cook_ban_x, table.concat(names, ', '):sub(1, 200))
  end
end

-- BUG-629 (Run 16a i1 Basementflew y459: food 2,000+ days, 2,398 cook ingredients, the kitchen built, COOK held, meals 0 for 14 million ticks,
-- ONE dfllm:food order in the whole log; Run 16b i2 Valleyhame y377: 13 hungry, the order placed only with 10 ingredients at hand): a cook
-- labor on nobody is switched on for the best candidate (act.labor_set `cook`, idle first, then Cooking skill; no soldier, patient,
-- moody or noble), at most once a day. Returns 'have' (+ unit id), 'set' (+ unit id), 'none' or 'wait'
-- BUG-697 (Run 16c i3 Wallfree y431-y433: 'kitchen idle with 5 cook ingredients (order made again)', COOK labor 'held', 23 adults idle, the
-- meals 105 -> 0): `extra` adds a cook beside the holders when every holder has a job (a hunter, a hauler, a soldier's day off: the
-- labor is on, nobody stands at the kitchen); the holders are left out of the candidates then
function M.cook_labor(K, extra)
  return M.labor_assign(K, {labor = 'COOK', which = 'cook', skill = 'COOK', stamp = 'cookl', text = 'Cooking labor',
                            why = 'a kitchen stands, cook ingredients lie there, no meal and nobody had the labor'}, extra)
end

-- BUG-716 (Run 16c i3 Wallfree y423-y426: 965 -> 2,616 raw fish uncleaned, Fishery 'jobs 1, working 0', 17 of 33 adults idle, food 618 -> 183 days):
-- the same pick for the Fish cleaning labor (CLEAN_FISH)
function M.fish_labor(K, extra)
  return M.labor_assign(K, {labor = 'CLEAN_FISH', which = 'clean_fish', skill = 'PROCESSFISH', stamp = 'fishl', text = 'Fish cleaning labor',
                            why = 'a fishery stands, raw fish lie there uncleaned and nobody had the labor'}, extra)
end

-- the labor `o.labor` (act.labor_set `o.which`) on the best candidate: idle first, then the skill `o.skill`, no soldier, patient, moody or noble;
-- at most once a day (p[o.stamp]). `extra` adds one beside the holders (the holders are left out of the candidates then).
-- Returns 'have' (+ unit id), 'set' (+ unit id), 'none' or 'wait'
function M.labor_assign(K, o, extra)
  local cu = K.census.u
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' then return 'none' end
  local sid = df.job_skill and df.job_skill[o.skill]
  local cands = {}
  for _, id in ipairs(cu.ids) do
    local u = df.unit.find(id)
    if u and not dfhack.units.isDead(u) and dfhack.units.isAdult(u) and M.citizen(u) and (u.military.squad_id or -1) < 0
       and (u.mood or -1) < 0 then
      if M.labor_flag(u, o.labor) then
        if not extra then return 'have', id end
      elseif not M.patient(u) and not noble(u) then
        cands[#cands + 1] = {id = id, idle = (u.job == nil or u.job.current_job == nil) and 1 or 0,
                             sk = sid and dfhack.units.getNominalSkill(u, sid, true) or 0}
      end
    end
  end
  if #cands == 0 then return 'none' end
  local p, now = pstate(K), K.now().tick
  if now - (math.tointeger(p[o.stamp]) or -DAY) < DAY then return 'wait' end
  table.sort(cands, function(a, b)
    if a.idle ~= b.idle then return a.idle > b.idle end
    if a.sk ~= b.sk then return a.sk > b.sk end
    return a.id < b.id
  end)
  p[o.stamp] = now
  K.persist.touch('m.economy')
  local ok = K.act.labor_set(cands[1].id, o.which, true)
  if not ok then return 'none' end
  K.log('warn', '%s on for unit %d: %s', o.text, cands[1].id, o.why)
  return 'set', cands[1].id
end

-- BUG-697: some holder of the COOK labor (an adult citizen, no soldier) has no job right now (true), or none holds it / all are busy (false)
function M.cook_idle(K)
  local lid = df.unit_labor and df.unit_labor.COOK
  local cu = K.census.u
  if type(lid) ~= 'number' or type(cu) ~= 'table' then return true end
  local sold = {}
  for _, id in ipairs(cu.soldier_ids or {}) do sold[id] = true end
  for _, id in ipairs(cu.ids or {}) do
    local u = not sold[id] and df.unit.find(id)
    if u and dfhack.units.isAdult(u) and labor_on(u, lid) and (u.job == nil or u.job.current_job == nil) then return true end
  end
  return false
end

-- BUG-654 (Run 16a i1 Basementflew y459-y466: meals 0 for years beside 3,323 food days, `inspect workload` 'unreachable PrepareMeal x1'
-- (and ConstructChest, ConstructMechanisms): the fort's only Kitchen, Carpenters, Masons and Mechanics stood in the flooded level z117, on
-- a walk group no citizen is on; every fact here said 'workshop:Kitchen' = true, so cook_watch switched labors and remade orders, the food
-- decision said 'raw food is not cooked', nothing asked for a second kitchen; the manager gives a shop one job at a time, so the cut-off
-- Carpenters held the chest and the four hospital beds behind it): a workshop type whose EVERY built shop has no walkable tile on a
-- citizens' walk group round it (M.shop_reach, the ring of tiles a worker stands on) for CUT.days days in PEACE is cut off
-- (p.cutws[Type] = {t, at, grp, home, n}); facts() then counts the type as missing (f['cut:Type']), so the shop requests, the stall
-- reports and the piece routes treat it as missing. M.cut_scan (daily): ORDER_STUCK (B, kind workshop) once, and PROJECT_REQUEST
-- workshops why=cut (M.ws_ask, paced) for the types M.WS_PLACE can place: follow places a new one on the citizens' walk group.
-- A shop is judged by tiles: a ring tile on a walk group g > 0 off the citizens' is cut; a ring read in full with every tile unwalkable
-- (walls, deep water: group 0) is cut as walk group 0 (the flooded level); any hidden or unread ring tile with none walkable is unknown, never cut.
M.CUT = {days = 3, max_pts = 1500, citizens = 150}

function M.shop_ring(b)
  local x1, x2, y1, y2, z = math.tointeger(b.x1), math.tointeger(b.x2), math.tointeger(b.y1), math.tointeger(b.y2), math.tointeger(b.z)
  if not (x1 and x2 and y1 and y2 and z) then return nil end
  local pts = {}
  for x = x1 - 1, x2 + 1 do
    for y = y1 - 1, y2 + 1 do
      if x < x1 or x > x2 or y < y1 or y > y2 then pts[#pts + 1] = {x, y, z} end
    end
  end
  return pts, {x1 + (x2 - x1) // 2, y1 + (y2 - y1) // 2, z}
end

-- {Type = {n shops, ok (on a citizens' walk group), cutn (off them), cut = {at, grp}}}, the sorted home group ids; nil when the walk
-- groups cannot be read (no snapshot module, no citizen)
function M.shop_reach(K)
  local cpts = {}
  for _, id in ipairs((K.census.u or {}).ids or {}) do
    if #cpts >= M.CUT.citizens then break end
    local u = df.unit.find(id)
    local okp, x, y, z = pcall(function() return u.pos.x, u.pos.y, u.pos.z end)
    if u and okp and math.tointeger(x) then cpts[#cpts + 1] = {x, y, z} end
  end
  if #cpts == 0 then return nil end
  local okc, cg = K.call('snapshot', 'groups', cpts, false)
  if not (okc and type(cg) == 'table') then return nil end
  local home = M.home_groups(K, cg)
  if next(home) == nil then return nil end
  local pts, owner, shops = {}, {}, {}
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      local n = df.workshop_type[b.type]
      if n and built(b) then
        local ring, mid = M.shop_ring(b)
        if ring then
          local s = {type = n, at = mid, id = math.tointeger(b.id)}
          shops[#shops + 1] = s
          for _, pt in ipairs(ring) do
            if #pts < M.CUT.max_pts then pts[#pts + 1] = pt; owner[#pts] = s end
          end
        end
      end
    end
  end)
  if #pts == 0 then return {}, {} end
  local okj, jg = K.call('snapshot', 'groups', pts, false)
  if not (okj and type(jg) == 'table') then return nil end
  for k = 1, #pts do
    local s, g = owner[k], math.tointeger(jg[k]) or -1
    if g > 0 then
      if home[g] then s.ok = true elseif not s.seen or s.seen == 0 then s.seen = g end
    elseif g == 0 then
      s.blocked = (s.blocked or 0) + 1           -- read, and no walkable group: a wall or water 4-7 deep (snapshot WALKCH excludes '~')
    else
      s.unk = (s.unk or 0) + 1                   -- hidden, off the map or a fault: could be floor
    end
  end
  -- a fully flooded or walled ring (every tile read, none walkable, none hidden) is cut off too, as group 0: Basementflew's z117
  -- kitchen stood in 4-7 deep water, whose tiles have no walk group at all (the first pass judged only g > 0 and called it unknown)
  for _, s in ipairs(shops) do
    if not s.ok and not s.seen and (s.blocked or 0) > 0 and (s.unk or 0) == 0 then s.seen = 0 end
  end
  local by = {}
  for _, s in ipairs(shops) do
    local e = by[s.type]
    if not e then e = {n = 0, ok = 0, cutn = 0}; by[s.type] = e end
    e.n = e.n + 1
    if s.ok then e.ok = e.ok + 1
    elseif s.seen then
      e.cutn = e.cutn + 1
      e.cut = e.cut or {at = s.at, grp = s.seen}
      if s.id then e.dead = e.dead or {}; e.dead[#e.dead + 1] = {id = s.id, at = s.at, grp = s.seen} end    -- BUG-715
    end
  end
  local hg = {}
  for g in pairs(home) do hg[#hg + 1] = g end
  table.sort(hg)
  return by, hg
end

-- the cut-off types the kernel may ask a new shop of: {Type, ...} sorted
function M.cut_types(p)
  local out = {}
  for t in pairs(type(p.cutws) == 'table' and p.cutws or {}) do
    if M.WS_PLACE[t] then out[#out + 1] = t end
  end
  table.sort(out)
  return out
end

-- 'Kitchen at 29,112,117 (walk group 4, the citizens on 7)' for a confirmed cut-off type, else nil
function M.cut_text(p, t)
  local rec = type(p.cutws) == 'table' and p.cutws[t] or nil
  if type(rec) ~= 'table' then return nil end
  local at = type(rec.at) == 'table' and rec.at or {}
  return string.format('%s at %s,%s,%s (walk group %s, the citizens on %s)', t, tostring(at[1]), tostring(at[2]), tostring(at[3]),
                       tostring(rec.grp) == '0' and '0: no walkable tile round it' or tostring(rec.grp), tostring(rec.home))
end

-- BUG-715 (Run 16a i1 Basementflew y470-y480: a SECOND Kitchen 29,112,117 stood in the flooded level z117 beside a reachable one, the manager
-- gave it the PrepareMeal job, DF said 'unreachable PrepareMeal x1', meals stayed at 1 beside 1000-3000 food days, and no command removed a
-- dead workshop; BUG-654 judged only a type whose EVERY shop is cut off): a shop of a type that has a reachable shop and that no citizen can
-- walk to (walk group off the citizens', or a ring with no walkable tile) for CUT.days days in PEACE is DEAD (p.deadws[id] = {t, at, grp,
-- type, told}). It is named (ORDER_STUCK kind workshop, kern.log: where, why, which shop takes the jobs now) and retired (act.workshop_retire:
-- the manager's general orders off it, a Remove Building job); asked again after RETIRE_AGAIN days while it stands, at most
-- RETIRE_PER_RUN shops a day. A type with no reachable shop is BUG-654's case (a new one is asked for); nothing is removed there.
M.RETIRE_AGAIN = 30 * DAY
M.RETIRE_PER_RUN = 2

function M.dead_text(d, home)
  local at = type(d.at) == 'table' and d.at or {}
  return string.format('%s %s at %s,%s,%s (%s, the citizens on %s)', tostring(d.type), tostring(d.id), tostring(at[1]), tostring(at[2]), tostring(at[3]),
                       tostring(d.grp) == '0' and 'walk group 0: no walkable tile round it, flooded or walled' or ('walk group ' .. tostring(d.grp)),
                       tostring(home))
end

-- 'dead Kitchen 17 at 29,112,117 (walk group 0 ...), retired' for the first dead shop of the type in p.deadws, else nil (the stall texts)
function M.dead_note(p, t)
  local keys = {}
  for key, d in pairs(type(p.deadws) == 'table' and p.deadws or {}) do
    if type(d) == 'table' and d.type == t then keys[#keys + 1] = key end
  end
  if #keys == 0 then return nil end
  table.sort(keys)
  local d = p.deadws[keys[1]]
  return 'dead ' .. M.dead_text(d, nil):gsub(', the citizens on nil', '') .. (d.done and ', retired' or '')
end

function M.dead_scan(K, p, by, hg, now)
  local dead = type(p.deadws) == 'table' and p.deadws or {}
  local seen, changed = {}, false
  for t, e in pairs(by) do
    if e.ok > 0 and e.cutn > 0 then
      for _, s in ipairs(e.dead or {}) do
        local key = tostring(s.id)
        seen[key] = true
        local d = dead[key]
        if type(d) ~= 'table' then
          dead[key] = {t = now, at = s.at, grp = s.grp, type = t, id = s.id}
          changed = true
        end
      end
    end
  end
  for key in pairs(dead) do
    if not seen[key] then dead[key], changed = nil, true end            -- it stands on a citizens' walk group again, or is gone
  end
  local done = 0
  local keys = {}
  for key in pairs(dead) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local d = dead[key]
    local age = now - (math.tointeger(d.t) or now)
    local last = math.tointeger(d.done)
    if done < M.RETIRE_PER_RUN and age >= M.CUT.days * DAY and not (last and now - last < M.RETIRE_AGAIN) then
      local ok, res = K.act.workshop_retire(d.id)
      d.done, d.how = now, ok and (type(res) == 'table' and res.how or 'ok') or tostring(res)
      done, changed = done + 1, true
      local text = M.dead_text(d, hg and hg[1])
      local msg
      if ok then
        msg = string.format('dead workshop %s: no citizen can walk there, a reachable %s stands and takes the jobs; retired (%s%s)',
                            text, tostring(d.type), type(res) == 'table' and res.how or 'ok',
                            type(res) == 'table' and res.how ~= 'gone' and '; a builder has to reach it for the removal, the manager is off it' or '')
      else
        msg = string.format('dead workshop %s: no citizen can walk there, a reachable %s stands; the retire failed: %s', text, tostring(d.type), tostring(res))
      end
      K.log('warn', '%s', msg)
      K.emit('ORDER_STUCK', 'B', msg:sub(1, 200), {order = 0, job = tostring(d.type), n = 1, why = msg:sub(1, 100), kind = 'workshop',
             id = d.id, retired = ok and 1 or 0})
    end
  end
  if changed then
    p.deadws = next(dead) and dead or nil
    K.persist.touch('m.economy')
  end
end

function M.cut_scan(K, c, r)
  if not r.day or K.mode() ~= 'PEACE' then return end      -- a lockdown or a raised bridge splits the walk groups for a while
  local p, now = r.p, r.now
  local by, hg = M.shop_reach(K)
  if not by then return end
  local seen = type(p.cutseen) == 'table' and p.cutseen or {}
  local conf = type(p.cutws) == 'table' and p.cutws or {}
  local changed, fresh = false, {}
  for t, e in pairs(by) do
    if e.ok == 0 and e.cutn == e.n and e.cut then
      local s = seen[t]
      if type(s) ~= 'table' then
        s = {t = now, at = e.cut.at, grp = e.cut.grp}
        seen[t], changed = s, true
      end
      if not conf[t] and now - (math.tointeger(s.t) or now) >= M.CUT.days * DAY then
        conf[t] = {t = now, at = s.at, grp = s.grp, home = hg[1], n = e.n}
        fresh[#fresh + 1] = t
        changed = true
      end
    elseif seen[t] or conf[t] then
      seen[t], conf[t], changed = nil, nil, true             -- a shop of the type is on the citizens' walk group again
    end
  end
  for t in pairs(conf) do
    if not by[t] then conf[t], seen[t], changed = nil, nil, true end    -- no shop of the type stands any more: plainly missing
  end
  if changed then
    p.cutseen, p.cutws = next(seen) and seen or nil, next(conf) and conf or nil
    K.persist.touch('m.economy')
    r.f = facts(K, p)
  end
  table.sort(fresh)
  for _, t in ipairs(fresh) do
    local msg = string.format('workshop %s: no way for the citizens (%d shop%s), counted as missing: a new one is asked for',
                              M.cut_text(p, t), by[t].n, by[t].n == 1 and '' or 's')
    K.log('warn', '%s', msg)
    K.emit('ORDER_STUCK', 'B', msg:sub(1, 200), {order = 0, job = t, n = by[t].n, why = msg:sub(1, 100), kind = 'workshop'})
  end
  M.dead_scan(K, p, by, hg, now)
  local want = M.cut_types(p)
  if #want == 0 then
    if type(p.wsask) == 'table' then p.wsask.cut = nil end
    return
  end
  M.ws_ask(K, p, 'cut', want, (c.food or {}).request_days or 14,
           'workshops: cut off from the citizens (' .. (M.cut_text(p, want[1]) or want[1]) .. ')')
end

-- BUG-629 (see M.cook_labor): the stall watch (daily, T.watch). Stalled = the kitchen stands, the cook ingredients reach the planner's floor and
-- no meal stands. The days count while no own food order is open or the open one has not moved (amount left); at cook_stall_days
-- (6): a COOK labor on nobody is switched on, the open food order (a DF item condition that never holds, a job out that nobody
-- finishes: PrepareMeal is a KEEP_JOBS order, T.stale never looks at it) is taken down and the next one is made without any item
-- condition and at the top of the manager's list (p.cookw.relax, M.food_spec); one ORDER_STUCK (B) says so. Still no meal after
-- twice the days: the diagnosis is told again, once a month. The relax ends when meals reach the citizens' number.
function M.cook_watch(K, c, r)
  if not r.day then return end
  local p, inv = r.p, r.inv or {}
  local fc = type(c.food) == 'table' and c.food or M.DEFAULTS.food
  local need = math.max(1, math.tointeger(fc.cook_stall_days) or 6)
  local cw = type(p.cookw) == 'table' and p.cookw or nil
  local f = M.facts_now(K, r)
  local ing, meals = M.cook_n(inv), math.tointeger(inv.meals) or 0
  local kitchen = ws_any(f, {'workshop:Kitchen'})
  if not (kitchen and ing >= M.cook_floor(c, r) and meals == 0) then
    if cw then
      cw.d, cw.left = 0, nil
      if meals >= math.max(1, r.cit or 0) then p.cookw = nil end
      K.persist.touch('m.economy')
    end
    st.cookw = nil
    return
  end
  if not cw then cw = {d = 0, n = 0}; p.cookw = cw end
  local o = order_by_id(p.orders['dfllm:food'])
  local left = o and math.tointeger(o.amount_left) or nil
  local today = r.now // DAY
  if cw.day ~= today then
    cw.day = today
    if left and left > 0 and cw.left ~= left then cw.d = 0                    -- the order moved: the cooks are at work
    else cw.d = (cw.d or 0) + 1 end
    cw.left = left
  end
  st.cookw = {d = cw.d, n = cw.n or 0, relax = cw.relax ~= nil, ing = ing}
  K.persist.touch('m.economy')
  local holder = M.labor_holder(K, 'COOK')
  if cw.d < need then return end
  local act = {}
  if not holder then
    local how, uid = M.cook_labor(K)
    act[#act + 1] = how == 'set' and ('Cooking labor on for unit ' .. tostring(uid)) or 'nobody holds the COOK labor'
  elseif not M.cook_idle(K) and (r.p.famine or (st.hungry_n or 0) > 0) then
    -- BUG-697: every holder is busy elsewhere: one more cook, an idle adult first
    local how, uid = M.cook_labor(K, true)
    if how == 'set' then act[#act + 1] = 'every COOK holder busy: Cooking labor on for unit ' .. tostring(uid) end
  end
  local dn = M.dead_note(p, 'Kitchen')
  if dn then act[#act + 1] = dn end               -- BUG-715: the stall's cause when a second kitchen is unreachable
  if not cw.relax then
    cw.relax, cw.n, cw.told = r.now, (cw.n or 0) + 1, r.now
    local dropped = 0
    if left and left > 0 and K.act.order_remove(o.id) then
      dropped = 1
      p.orders['dfllm:food'], st.backoff['dfllm:food'] = nil, nil
    end
    act[#act + 1] = dropped == 1 and 'the food order was taken down, the next one has no item condition' or
                    'the next food order has no item condition'
    cw.d = 0
    local msg = string.format('cooking stalled %d days: kitchen built, %d cook ingredients, no meal, COOK labor %s, food order %s: %s',
                              need, ing, holder and 'held' or 'on nobody', left and ('x' .. left .. ' open') or 'none open',
                              table.concat(act, '; '))
    K.log('warn', '%s', msg)
    K.emit('ORDER_STUCK', 'B', msg:sub(1, 200), {order = o and o.id or 0, job = 'PrepareMeal', n = left or 0, days = need,
           why = ('cook stall: ' .. table.concat(act, '; ')):sub(1, 100), dropped = dropped, kind = holder and 'input' or 'worker'})
  elseif cw.d >= 2 * need and r.now - (math.tointeger(cw.told) or 0) >= 30 * DAY then
    cw.told = r.now
    local msg = string.format('cooking still stalled %d days after the order was made again: kitchen built, %d cook ingredients, no meal, ' ..
                              'COOK labor %s, food order %s (the kitchen may be cut off or its jobs cancel: inspect orders)',
                              cw.d, ing, holder and 'held' or 'on nobody', left and ('x' .. left .. ' open') or 'none open')
    K.log('warn', '%s', msg)
    K.emit('ORDER_STUCK', 'B', msg:sub(1, 200), {order = o and o.id or 0, job = 'PrepareMeal', n = left or 0, days = cw.d,
           why = 'cook stall: order without condition, still no meal', dropped = 0, kind = holder and 'input' or 'worker'})
  end
end

-- BUG-716 (Run 16c i3 Wallfree y423-y426: 965 raw fish -> 2,616 in a year beside 'Fishery jobs 1, working 0', 17 of 33 adults idle, cookable 0,
-- food 618 -> 183 days, the PrepareRawFish orders made no cleaned fish; the player could only read): the raw fish are the food, the fishery
-- cleans them. The watch (daily, T.watch): the fishery stands (a cut-off one is counted missing, BUG-654), raw fish lie there (>= fish.stall_raw 40)
-- and their number has not fallen by a fifth for fish.stall_days (6) days. Then the cause is looked at and told once (ORDER_STUCK, again after
-- 30 days): nobody holds Fish cleaning (the labor is switched on for an idle adult, act.labor_set clean_fish), every holder has a job (one more),
-- no PrepareRawFish order is open (the planner makes it at the next run), or a holder is idle and the fishery is just slower than the catch
-- (the text says so). st.fishw feeds the food decisions ('N raw fish uncleaned: ...').
M.FISH_STALL = {raw = 40, days = 6, again = 30 * DAY}
function M.fish_watch(K, c, r)
  if not r.day then return end
  local p, inv = r.p, r.inv or {}
  local F = type(c.fish) == 'table' and c.fish or {}
  local raw = inv.fish_raw or 0
  local f = M.facts_now(K, r)
  local need_raw = math.tointeger(F.stall_raw) or M.FISH_STALL.raw
  local need_days = math.max(1, math.tointeger(F.stall_days) or M.FISH_STALL.days)
  local fw = type(p.fishw) == 'table' and p.fishw or nil
  if not (ws_any(f, M.FISHERY) and raw >= need_raw) then
    if fw then p.fishw = nil; K.persist.touch('m.economy') end
    st.fishw = nil
    return
  end
  if not fw then fw = {base = raw, d = 0, day = r.now // DAY}; p.fishw = fw end
  local today = r.now // DAY
  if fw.day ~= today then
    fw.day = today
    if raw * 5 <= (fw.base or raw) * 4 then fw.base, fw.d = raw, 0         -- it fell by a fifth: the cleaners are at work
    else
      fw.d = (fw.d or 0) + 1
      if raw > (fw.base or 0) * 2 then fw.base = raw end                    -- a bigger catch is a new base
    end
  end
  K.persist.touch('m.economy')
  st.fishw = nil
  if fw.d < need_days then return end
  local holder = M.labor_holder(K, 'CLEAN_FISH')
  local o = order_by_id(p.orders[F.tag or 'dfllm:fish'])
  local left = o and math.tointeger(o.amount_left) or nil
  local act = {}
  if not holder then
    local how, uid = M.fish_labor(K)
    act[#act + 1] = how == 'set' and ('Fish cleaning labor on for unit ' .. tostring(uid)) or 'nobody holds the Fish cleaning labor'
  elseif (st.idle or 0) > 0 and not M.fish_idle(K) and raw >= 3 * need_raw then
    local how, uid = M.fish_labor(K, true)
    if how == 'set' then act[#act + 1] = 'every Fish cleaning holder is busy: the labor on for unit ' .. tostring(uid) end
  end
  if not left or left <= 0 then act[#act + 1] = 'no PrepareRawFish order is open' end
  if #act == 0 then act[#act + 1] = 'the fishery is slower than the catch' end
  st.fishw = {d = fw.d, raw = raw, text = table.concat(act, '; '):sub(1, 100)}
  if r.now - (math.tointeger(fw.told) or -M.FISH_STALL.again) >= M.FISH_STALL.again then
    fw.told = r.now
    local msg = string.format('raw fish not cleaned for %d days: %d raw fish, fishery built, Fish cleaning %s, order %s, adults idle %d%%: %s',
                              fw.d, raw, holder and 'held' or 'on nobody', left and ('x' .. left .. ' open') or 'none open', st.idle or 0,
                              table.concat(act, '; '))
    K.log('warn', '%s', msg)
    K.emit('ORDER_STUCK', 'B', msg:sub(1, 200), {order = o and o.id or 0, job = 'PrepareRawFish', n = left or 0, days = fw.d,
           why = ('fish stall: ' .. table.concat(act, '; ')):sub(1, 100), dropped = 0, kind = holder and 'input' or 'worker'})
  end
end

-- some holder of Fish cleaning (an adult citizen, no soldier) has no job right now
function M.fish_idle(K)
  local lid = df.unit_labor and df.unit_labor.CLEAN_FISH
  local cu = K.census.u
  if type(lid) ~= 'number' or type(cu) ~= 'table' then return true end
  local sold = {}
  for _, id in ipairs(cu.soldier_ids or {}) do sold[id] = true end
  for _, id in ipairs(cu.ids or {}) do
    local u = not sold[id] and df.unit.find(id)
    if u and dfhack.units.isAdult(u) and labor_on(u, lid) and (u.job == nil or u.job.current_job == nil) then return true end
  end
  return false
end

function T.plan(K, c, r)
  r.cands, r.planned, r.targets, r.route = {}, {}, {}, {}
  for _, key in ipairs({'bone', 'shell'}) do r.targets[key] = target(K, c, r, key) end
  r.gear = gear_pre(K, c, r, 0)
  r.targets.leather = target(K, c, r, 'leather') + (phase_ok(K, c.leather.from_phase) and r.gear.leather or 0)
  -- BUG-326: a SIEGE or BREACH of reflex's lone harmless picture is no real siege: who it took off goes back now
  if type(r.p.drill_off) == 'table' and next(r.p.drill_off) and M.HUNT_OFF[K.mode()] and not M.hunt_siege(K) then
    pcall(M.drill_restore, K)
  end
  r.hunt, r.hunt_why = hunt_want(K, c, r)
  st.hunt = {n = r.hunt, why = r.hunt_why}          -- M.route (care's MOOD_RISK names the leather route)
  r.fish, r.fish_why = fish_want(K, c, r)
  st.fish_want = r.fish
  r.gear = gear_pre(K, c, r, r.hunt)
  -- priority: needs (moods) first, then drink and food, then soldiers, then stock
  local urgent = {leather = need_n(r.p, 'leather', r.now) > 0, cloth = need_n(r.p, 'cloth', r.now) +
                  need_n(r.p, 'thread', r.now) > 0, bars = need_n(r.p, 'bars', r.now) > 0,
                  glass = need_n(r.p, 'glass', r.now) + (r.glass_cut or 0) > 0}
  local list = {{1.5, plan_supply}, {2, function() plan_containers(K, c, r, 'barrels') end},
                {urgent.leather and 1 or 4, plan_leather}, {urgent.cloth and 1 or 3.5, plan_cloth},
                {2.9, M.plan_picks}, {2.91, M.plan_axes}, {3.4, M.plan_training},
                {urgent.bars and 1 or 3, plan_metal}, {urgent.bars and 1.1 or 3.1, plan_steel}, {3.2, plan_gear},
                {3.25, M.metal_plan}, {3.26, M.trade_goods}, {urgent.glass and 1.2 or 3.3, M.glass_plan}, {5, function() plan_containers(K, c, r, 'bins') end}}
  table.sort(list, function(a, b) return a[1] < b[1] end)
  for _, e in ipairs(list) do e[2](K, c, r) end
  if r.day then
    -- mood stock incl. care's forbidden reserve (held items are not in the census: forbidden)
    if phase_ok(K, c.mood_from_phase or 'P1') then
      local ms = math.tointeger((K.plan.supply or {}).mood_stock) or 10
      for _, key in ipairs(c.mood_keys or {}) do stock_low(K, r.p, key, have(r, key), ms) end
    end
    gear_report(K, c, r)
  end
  st.sup = {targets = r.targets, route = r.route, held = r.held}
  r.cmds = r.cmds + 1                              -- a slice of its own (planning + military kpi)
end

function T.tools(K, c, r)
  local okt, nt = pcall(tools, K, c, r.p, r.inv, st.engine, r)
  if not okt then K.log('warn', 'tool details: %s', tostring(nt)) end
  r.cmds = r.cmds + 1                              -- a slice of its own (every citizen's skills and labors)
end

function T.orders(K, c, r)
  r.oi, r.made = r.oi or 1, r.made or 0
  local now = r.now
  while r.oi <= #r.cands do
    if r.made >= (c.orders_per_day or 6) then return true end
    local cd = r.cands[r.oi]
    r.oi = r.oi + 1
    if not live(r.p.orders[cd.tag]) and now >= (st.backoff[cd.tag] or 0) then
      local spec = copy(cd.spec)
      local conds = {}
      for _, x in ipairs(spec.item_conditions or {}) do conds[#conds + 1] = x end   -- drop nil holes (fuel)
      spec.item_conditions = #conds > 0 and conds or nil
      if spec.material_category and #spec.material_category == 0 then spec.material_category = nil end
      spec.tag, spec.amount_total, spec.frequency = cd.tag, cd.n, spec.frequency or 'OneTime'
      if M.mood_top(r.p, cd.tag) then spec.top = true end   -- BUG-315: a mood's material first in the work orders
      local ok, id = K.act.workorder(spec)
      r.cmds, r.made = r.cmds + 1, r.made + 1
      if ok then
        r.p.orders[cd.tag] = id
        local uses = json.object{}
        for k, v in pairs(cd.uses or {}) do if v > 0 then uses[k] = v end end
        r.p.meta[cd.tag] = {uses = uses, out = cd.out or 1}
        K.log('info', 'order %s x%d (%s)', cd.tag, cd.n, cd.why or '')
      else
        st.backoff[cd.tag] = now + 3 * DAY                 -- retry in 3 days
      end
      return r.oi > #r.cands
    end
  end
  return true
end

function T.wood(K, c, r)
  local okw, nw = pcall(wood_orders, K, c, r)
  if not okw then K.log('warn', 'wood orders: %s', tostring(nw)) end
end

-- autochop target: the free logs economy keeps plus the wood still ordered plus a margin (live L3: logs 82 -> 9
-- while the furniture fallback ran); applied when it moved by `step` or more
function T.chop(K, c, r)
  local w = c.wood or M.DEFAULTS.wood
  local need = floor_of(c, r.p, r, 'wood') + (r.s.used.wood or 0) + (r.planned.wood or 0) + (w.margin or 20)
  local mn = clamp(need, w.chop_min or 60, (w.cap or 400) - (w.band or 90))
  local mx = clamp(math.max(w.chop_max or 150, mn + (w.band or 90)), mn + 1, w.cap or 400)
  st.chop = {mn, mx}
  local base = ((K.cfg.baseline or {}).baseline or {}).autochop or {}
  local cur = st.chop_applied or {math.tointeger(base.min) or (w.chop_min or 60), math.tointeger(base.max) or (w.chop_max or 150)}
  if math.abs(mn - cur[1]) < (w.step or 10) and math.abs(mx - cur[2]) < (w.step or 10) then return true end
  r.cmds = r.cmds + 1
  if K.act.run('autochop', 'target', fmt(mx), fmt(mn)) then
    st.chop_applied = {mn, mx}
    K.log('info', 'autochop target %d %d (floor %d, wood ordered %d)', mx, mn, floor_of(c, r.p, r, 'wood'),
          (r.s.used.wood or 0) + (r.planned.wood or 0))
  end
end

-- fiber crops the fort has seeds of: autofarm threshold up while cloth is short (thread comes from them), back to
-- autofarm's own default threshold after. The default is read once a boot from `autofarm status` ("Default: N";
-- autofarm.plug.dll); fiber_on is never below it (a "raise" to less than the default would plant fewer fibers),
-- fiber_off stands in when status names none
function T.farm(K, c, r)
  local Cc = c.cloth
  if type(Cc) ~= 'table' or st.af_off then return true end         -- BUG-058: autofarm disabled: no thresholds
  local crops = {}
  for _, id in ipairs(Cc.fiber or {}) do if (st.seeds[id] or 0) > 0 then crops[#crops + 1] = id end end
  if #crops == 0 then return true end
  if not r.fiber_on and r.p.farm == nil then return true end   -- never raised: autofarm's own thresholds stay
  if st.farm_default == nil then
    r.cmds = r.cmds + 1
    local ok, out = K.act.run('autofarm', 'status')
    local d = ok and tostring(out or ''):match('[Dd]efault[^0-9\n]*([0-9]+)')
    st.farm_default = d and math.tointeger(tonumber(d)) or false
    return false                                   -- the threshold in the next frame (one command per frame)
  end
  local base = st.farm_default or Cc.fiber_off or 50
  local val = r.fiber_on and math.max(Cc.fiber_on or 100, base) or base
  local sig = fmt(val) .. ':' .. table.concat(crops, ',')
  if r.p.farm == sig then return true end
  r.cmds = r.cmds + 1
  if K.act.run('autofarm', 'threshold', fmt(val), table.unpack(crops)) then
    r.p.farm = sig
    K.log('info', 'autofarm threshold %d for %s (cloth %d, target %d)', val, table.concat(crops, ' '), have(r, 'cloth'),
          r.targets.cloth or 0)
  end
end

-- the food crops' autofarm thresholds follow the citizens (live L5: autofarm's default 50 stopped the plump helmets
-- at 40 in stock for 53 dwarves). The crops are the ones `autofarm status` lists (it knows which the fort can farm),
-- minus the fiber crops (T.farm, which runs after it and reuses the default read here); status is read once a boot
-- and again after status_days (live L5: re-reading on every change of the seed kinds read it 13 times in 62 days).
function T.crops(K, c, r)
  local fc = c.food
  if type(fc) ~= 'table' or not r.day or st.af_off then return true end
  local cs = st.crops
  if type(cs) ~= 'table' or r.now - cs.read >= (fc.status_days or 7) * DAY then
    r.cmds = r.cmds + 1
    local ok, out = K.act.run('autofarm', 'status')
    local list, default = M.parse_autofarm(ok and out or '')
    st.crops = {read = r.now, list = list}
    if st.farm_default == nil then st.farm_default = default or false end
    return false                                   -- the threshold in the next frame (one command per frame)
  end
  local fiber = {}
  for _, id in ipairs((c.cloth or {}).fiber or {}) do fiber[id] = true end
  local crops = {}
  for _, e in ipairs(cs.list) do if not fiber[e.id] then crops[#crops + 1] = e.id end end
  table.sort(crops)
  if #crops == 0 then return true end
  local lo = math.max(fc.crops_min or 50, st.farm_default or 0)
  local step = math.max(1, fc.crops_step or 10)
  local val = (r.cit or 0) * (fc.crops_per_dwarf or 4)
  val = math.max(lo, math.min(val - val % step, math.max(lo, fc.crops_max or 400)))
  local sig = fmt(val) .. ':' .. table.concat(crops, ',')
  if r.p.crops == sig then return true end
  r.cmds = r.cmds + 1
  if K.act.run('autofarm', 'threshold', fmt(val), table.unpack(crops)) then
    r.p.crops = sig
    K.log('info', 'autofarm threshold %d for the food crops %s (%d citizens)', val, table.concat(crops, ' '), r.cit or 0)
  end
end

-- staged library imports (DESIGN Ã‚Â§5.5) plus plan.orders / season orders; each library once
function T.imports(K, c, r)
  local p = r.p
  if not r.imp then
    local want, seen = {}, {}
    local function addlib(lib) if not p.imported[lib] and not seen[lib] then seen[lib] = true; want[#want + 1] = lib end end
    for _, s in ipairs(c.stages or {}) do if M.stage_ready(s, r.f, p.cit) then addlib(s.lib) end end
    -- BUG-202 (live Earthboat: the plan's basic, rockstock and furnace libraries at P0 with 7 dwarves, 80-90 orders, the
    -- project's doors and beds at places 82-88 of 89): a plan or season library is held by the gate of its config stage
    local season = type(K.plan.seasons) == 'table' and K.plan.seasons[K.now().season + 1]
    for _, src in ipairs({(K.plan.orders or {}).import, season and season.orders and season.orders.import}) do
      for _, lib in ipairs(type(src) == 'table' and src or {}) do
        if M.lib_ready(K, c, lib, r.f, p.cit) then addlib(lib) end
      end
    end
    local own = {}
    for _, id in pairs(p.orders) do own[id] = true end
    local q = {}
    for _, lib in ipairs(want) do
      if has_signature((c.signatures or {})[lib], own) then
        p.imported[lib] = K.now().tick
        K.log('info', 'orders %s already present: not imported again', lib)
      else q[#q + 1] = lib end
    end
    r.imp = {q = q, n = 0, post = {}}
  end
  local imp = r.imp
  local lib = table.remove(imp.q, 1)
  if lib then
    r.cmds = r.cmds + 1
    if K.act.orders_import(lib) then
      p.imported[lib] = K.now().tick
      imp.n = imp.n + 1
      if imp.n == 1 then imp.post = {'sort', 'recheck'} end
    end
    return false
  end
  local sub = table.remove(imp.post, 1)
  if sub then
    r.cmds = r.cmds + 1
    K.act.orders(sub)
    return #imp.post == 0
  end
  return true
end

-- an ore pile next to the smelter (`stockpiles import metalore`, the stockpile settings screen), once per boot and
-- pile, while a smelter stands
function T.piles(K, c, r)
  local op = (c.metal or {}).ore_pile
  if type(op) ~= 'table' or not ws_any(r.f, (c.metal or {}).smelter) then return true end
  if not r.pile_ids then
    local want = {}
    for _, n in ipairs(op.names or {}) do want[n:lower()] = true end
    r.pile_ids = {}
    pcall(function()
      for _, sp in ipairs(df.global.world.buildings.other.STOCKPILE) do
        if want[dfhack.df2utf(sp.name or ''):lower()] and not (st.piles or {})[sp.id] then r.pile_ids[#r.pile_ids + 1] = sp.id end
      end
    end)
  end
  local id = table.remove(r.pile_ids, 1)
  if not id then return true end
  r.cmds = r.cmds + 1
  st.piles = st.piles or {}
  if K.act.run('stockpiles', 'import', op.import or 'metalore', '-s', fmt(id)) then
    st.piles[id] = true
    K.log('info', 'stockpile %d: %s settings (ore for the smelter)', id, op.import or 'metalore')
  end
  return #r.pile_ids == 0
end

-- labor KPIs; PEACE days feed baseline's labormanager A/B test
function T.status(K, c, r)
  local ok, out = K.act.run('labormanager', 'status')
  r.cmds = r.cmds + 1
  local n, age, job = M.parse_status(ok and out or nil)
  local fresh = n and stale_filter(K, c, r.p, n, age, job) or nil
  st.starving = fresh or 0
  if fresh and K.mode() == 'PEACE' and K.enabled('baseline') then K.call('baseline', 'labor_day', fresh) end
end

function T.idle(K, c, r)
  st.idle = idle_pct(K)
  local rock = stone_free(c, r)
  if idle_rule(K, c, r.p, r.inv, rock) then r.cmds = r.cmds + 1 end
end

-- FR-39 (every run): make-item orders without item_subtype are removed before a dwarf takes their job
function T.guard(K, c, r)
  local g = c.order_guard or M.DEFAULTS.order_guard
  local p = r.p
  if not r.bad then
    r.bad, r.bad_n = unsafe_orders(), 0
    st.bad = #r.bad
    local live, n = {}, 0
    for _, e in ipairs(r.bad) do live[tostring(e.id)] = true end
    for key in pairs(p.badseen) do if not live[key] then p.badseen[key] = nil end end
    for _, o in ipairs(orders_all()) do if (o.amount_left or 0) > 0 then n = n + 1 end end
    st.orders = {n = n, bad = st.bad, stuck = st.orders and st.orders.stuck or 0, sws = st.orders and st.orders.sws,
                 slab = st.orders and st.orders.slab, ws = st.orders and st.orders.ws}
  end
  local e = table.remove(r.bad, 1)
  if not e then return true end
  local key, dropped = tostring(e.id), false
  if g.drop ~= false and r.bad_n < (g.per_run or 4) then
    r.cmds, r.bad_n = r.cmds + 1, r.bad_n + 1
    dropped = K.act.order_remove(e.id) == true
    if dropped then
      st.bad = math.max(0, st.bad - 1)
      st.orders.bad, st.orders.n = st.bad, math.max(0, st.orders.n - 1)
    end
  end
  if p.badseen[key] ~= 1 then
    p.badseen[key] = 1
    K.log('error', 'order %d %s x%d has no item_subtype (DF 53.16 crashes): %s', e.id, e.job, e.left,
          dropped and 'removed' or 'still listed')
    K.emit('ORDER_BAD', 'A', string.format('manager order %d %s x%d has no item_subtype (DF 53.16 crash): %s', e.id,
                                           e.job, e.left, dropped and 'removed' or 'still listed'),
           {order = e.id, job = e.job, dropped = dropped and 1 or 0})
  end
  return #r.bad == 0
end

-- BUG-061 (daily, the start of T.ocheck): the job lists of the built workshops (OF.shops: building.jobs, each job names
-- its order) and which of those jobs belong to an order that cannot run (M.order_reasons): a workshop type with at least
-- slabs.jam_min of them, half of its jobs or more, has its slots full of cancelling jobs. oq.ctx.jam[key] = the line,
-- st.jam the first one (state orders.jam), oq.shops the lists (T.stale, inspect orders)
function M.jam_scan(K, c, oq)
  local sc, sk = c.slabs or M.DEFAULTS.slabs, c.stale or M.DEFAULTS.stale
  local shops = M.OF.shops(built, sk.jobs_max)
  oq.shops = shops
  st.jam = nil
  if shops.n == 0 then return end
  local by = {}
  for _, o in ipairs(orders_all()) do by[o.id] = o end
  local jam, keys = {}, {}
  for key in pairs(shops.keys) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local e = shops.keys[key]
    local blocked, why_of, checked = {}, {}, {}
    for _, j in ipairs(e.list) do
      local o = by[j.order]
      if o and not checked[j.order] then
        checked[j.order] = true                  -- one reading per order, not per job (a jam holds dozens of its jobs)
        local why = M.order_reasons(o, oq.ctx)
        if why then blocked[j.order], why_of[j.job] = true, why:sub(1, 40) end
      end
    end
    local text, n = M.OF.jam_text(key, e, blocked, why_of, sc.jam_min)
    e.blocked = n
    if text then
      jam[key] = text
      st.jam = st.jam or text:sub(1, 80)
      -- BUG-515: the orders whose jobs fill the slots (blocked by a missing input, a job of theirs in this shop) are the
      -- jam's culprits; order_prune takes the one-time ones away
      oq.jamc = oq.jamc or {}
      local seen = {}
      for _, j in ipairs(e.list) do
        if blocked[j.order] and not seen[j.order] then
          seen[j.order] = true
          oq.jamc[#oq.jamc + 1] = {id = j.order, key = key}
        end
      end
    end
  end
  if next(jam) then oq.ctx.jam = jam end
end

-- BUG-205: one ORDER_STUCK kind=workshop per missing shop type with its order count (d.n), when an order of
-- that type was not told yet; again for that type with news (an order not told) after 7 days and 10 min (util/cadence,
-- p.wsstuck[label]); counts as one report of report_per_day. BUG-225: the same for kind input and worker, one per
-- 'kind:why' label, with up to 3 order ids in the text (a lone order keeps the old 'order N JOB cannot run' text)
function M.ws_stuck(K, p, oq, oc)
  if type(p.wsstuck) ~= 'table' then p.wsstuck = json.object{} end
  local T0 = K.now()
  local labels = {}
  for label in pairs(oq.wsg) do labels[#labels + 1] = label end
  table.sort(labels)
  for label in pairs(p.wsstuck) do if not oq.wsg[label] then p.wsstuck[label] = nil end end
  for _, label in ipairs(labels) do
    local g = oq.wsg[label]
    local rec = p.wsstuck[label]
    if #g.new > 0 and oq.told < (oc.report_per_day or 3)
       and (type(rec) ~= 'table' or CAD.elapsed(rec, T0, 7 * DAY, CAD.WALL_S)) then
      oq.told = oq.told + 1
      p.wsstuck[label] = {t = T0.tick, w = T0.wall}
      for _, e in ipairs(g.new) do e.rec.told = 1 end
      local e1 = g.new[1]
      local kd = g.kind or 'workshop'
      local msg
      if kd ~= 'workshop' and #g.ids == 1 then
        msg = string.format('order %d %s cannot run for %d days: %s', e1.id, e1.job, g.days, e1.why)
      else
        local more = {}
        for _, id in ipairs(g.ids) do if id ~= e1.id and #more < 2 then more[#more + 1] = tostring(id) end end
        msg = string.format('%d order(s) cannot run for %d days: %s (order %d %s%s%s)', #g.ids, g.days, e1.why, e1.id,
                            e1.job, #more > 0 and (', ' .. table.concat(more, ', ')) or '', #g.ids > 3 and ', ...' or '')
      end
      K.emit('ORDER_STUCK', 'B', msg:sub(1, 200),
             {order = e1.id, job = e1.job, why = e1.why, days = g.days, dropped = 0, kind = kd, n = #g.ids})
    end
  end
end

-- BUG-267/270 (live Earthboat: 11 orders, Loom x3, Clothier x3, Millstone x2, Quern, WoodFurnace, waited 344 days for
-- their shops; Drillchamber 37 of 55 orders 'workshop missing'; gear 'body 0/5 no leatherworks'): one PROJECT_REQUEST
-- workshops why=`why` (missing | gear) d.types = `types` (follow places only those, wake.py). A type a pending workshops
-- project builds (M.ws_queued) or runner's mandatory request asks for is left out. p.wsask[why] = {t, w, k, s = the types
-- asked}: the k-th unanswered repeat of the same set waits days * 2^(k-1) game days AND wall_s * 2^(k-1) wall seconds
-- (k <= backoff); a type not asked before starts over at k 1. Returns the types asked or nil.
M.WSASK = {wall_s = 900, backoff = 4}
function M.ws_ask(K, p, why, types, days, msg)
  local okm, mand = K.call('runner', 'req_types', 'wsm')
  local skip = {}
  for _, t in ipairs(okm and type(mand) == 'table' and mand or {}) do skip[t] = true end
  local want = {}
  for _, t in ipairs(types) do
    if not skip[t] and not M.ws_queued(K, t) then want[#want + 1] = t; skip[t] = true end
  end
  if #want == 0 then return nil end
  table.sort(want)
  if type(p.wsask) ~= 'table' then p.wsask = json.object{} end
  local rec, T0 = p.wsask[why], K.now()
  if type(rec) == 'table' then
    local had, new = {}, false
    for t in tostring(rec.s or ''):gmatch('[^,]+') do had[t] = true end
    for _, t in ipairs(want) do if not had[t] then new = true end end
    if new then rec = nil
    else
      local fx = 1 << (math.min(math.max(1, math.tointeger(rec.k) or 1), M.WSASK.backoff) - 1)
      if not CAD.elapsed(rec, T0, days * DAY * fx, M.WSASK.wall_s * fx) then return nil end
    end
  end
  local key = table.concat(want, ',')
  p.wsask[why] = {t = T0.tick, w = T0.wall, k = (type(rec) == 'table' and (math.tointeger(rec.k) or 1) or 0) + 1, s = key}
  K.log('info', '%s: asking for %s', msg, key)
  K.emit('PROJECT_REQUEST', 'B', (msg .. ': ' .. key):sub(1, 200), {tpl = 'workshops', n = #want, why = why, types = want})
  return want
end

-- BUG-267: the shops the stuck orders miss (T.ocheck's oq.wsg groups of kind workshop). A type the workshops template
-- places (M.WS_PLACE) and no request of its own owns (M.WS_OWN: Farmers FR-73, Fishery Run 11, Tanners BUG-042) is asked
-- for once its oldest order waited WSMISS.req_days (M.ws_ask why=missing); an order whose shop the kernel cannot ask for
-- (Millstone needs power, WoodFurnace, MagmaForge, a custom shop) is removed (act.order_remove, the work orders screen)
-- after WSMISS.cancel_days, at most drop_max a day, with kern.log and one ORDER_STUCK dropped=1. State st.wsmiss.
M.WSMISS = {req_days = 14, cancel_days = 112, drop_max = 10}
M.WS_PLACE = {}
for _, t in ipairs({'Carpenters', 'Masons', 'Craftsdwarfs', 'Jewelers', 'MetalsmithsForge', 'Bowyers', 'Clothiers',
                    'Leatherworks', 'Tanners', 'Loom', 'GlassFurnace', 'Mechanics', 'Still', 'Kitchen', 'Butchers',
                    'Fishery', 'Farmers', 'Quern', 'Ashery', 'Dyers', 'Kennels', 'Siege'}) do M.WS_PLACE[t] = true end
M.WS_OWN = {Farmers = true, Fishery = true, Tanners = true}
function M.ws_missing(K, p, oq)
  local want, drop, n, days = {}, {}, 0, 0
  for _, g in pairs(oq.wsg or {}) do
    local t = g.kind == 'workshop' and type(g.wsk) == 'string' and g.wsk:match(':(.+)$')
    if t and not M.WS_OWN[t] then
      if M.WS_PLACE[t] then
        if g.days >= M.WSMISS.req_days then want[#want + 1] = t; n, days = n + #g.ids, math.max(days, g.days) end
      elseif g.days >= M.WSMISS.cancel_days then
        for _, id in ipairs(g.ids) do drop[#drop + 1] = {id = id, t = t, days = g.days} end
      end
    end
  end
  table.sort(want)
  local sm = {want = want, asked = 0, dropped = 0}
  st.wsmiss = sm
  if #want == 0 then
    if type(p.wsask) == 'table' then p.wsask.missing = nil end
  else
    local asked = M.ws_ask(K, p, 'missing', want, M.WSMISS.req_days,
                           string.format('workshops: %d order(s) wait up to %d days for a missing shop', n, days))
    sm.asked = asked and #asked or 0
  end
  table.sort(drop, function(a, b) return a.id < b.id end)
  local gone, ts = {}, {}
  for _, e in ipairs(drop) do
    if #gone >= M.WSMISS.drop_max then break end
    if K.act.order_remove(e.id) == true then
      gone[#gone + 1] = tostring(e.id)
      if not ts[e.t] then ts[e.t] = true; ts[#ts + 1] = e.t end
      p.ostuck[tostring(e.id)] = nil
    end
  end
  if #gone == 0 then return end
  sm.dropped = #gone
  local msg = string.format('%d order(s) removed after %d+ days without a %s (the kernel cannot ask for it): %s', #gone,
                            M.WSMISS.cancel_days, table.concat(ts, '/'), table.concat(gone, ', '))
  K.log('warn', '%s', msg)
  K.emit('ORDER_STUCK', 'B', msg:sub(1, 200), {order = math.tointeger(tonumber(gone[1])) or 0, job = 'workshop',
         why = ('no ' .. table.concat(ts, '/')):sub(1, 80), days = drop[1].days, dropped = 1, kind = 'workshop',
         n = #gone})
end

-- BUG-315 (Run 15 Drillchamber y377: `inspect orders` 192 -> 194 open, 73-95 stuck: 28 x 'no bars:INORGANIC:BISMUTH_BRONZE',
-- 15 x 'no bars:INORGANIC:IRON', the gear orders made again every 1-2 days (commands.log: 28 MakeGloves x1), library
-- imports that never run; the mood's bag (435) and charcoal (437) waited 30 days behind them). The daily prune at the end
-- of T.ocheck: (1) of stuck orders (p.ostuck, stuck_days or more) with the same job, item subtype, material and reason one
-- is kept (the one a tag tracks, else the oldest), the others are removed; (2) above orders.cap open orders the longest
-- stuck ones past prune_days go too, oldest first. Only one-time orders, at most prune_per_day a day; never an order the
-- planned buildings, a mood, the dead, the hospital or the player ask for (M.PRUNE_KEEP jobs, M.PRUNE_KEEP_TAG tags). A
-- removed own order clears its tag and waits backoff_days. kern.log and one ORDER_STUCK (B, kind prune) a day
M.PRUNE_KEEP = {ConstructBlocks = true, ConstructCoffin = true, ConstructMechanisms = true, MakeChain = true,
                MakeBucket = true, MakeCage = true, ConstructSlab = true, EngraveSlab = true, MakeBag = true,
                MakeCharcoal = true, CollectSand = true, MakeRawGlass = true, CutGlass = true, CutGems = true, SpinThread = true,
                WeaveCloth = true, TanAHide = true, ProcessPlants = true, PrepareMeal = true, CustomReaction = true,
                CollectWebs = true, MakeBarrel = true}
for _, e in pairs(M.PIECES) do M.PRUNE_KEEP[e.job] = true end
M.PRUNE_KEEP_TAG = {'dfllm:piece_', 'dfllm:redo_', 'dfllm:slab', 'dfllm:mech', 'dfllm:sand', 'dfllm:bag', 'dfllm:charcoal',
                    'dfllm:glass', 'dfllm:cutglass', 'dfllm:cutgems', 'dfllm:webs', 'dfllm:thread', 'dfllm:cloth', 'dfllm:tan', 'dfllm:drink',
                    'dfllm:food', 'dfllm:stand_', 'dfllm:cmd', 'dfllm:coffin', 'dfllm:chain', 'dfllm:bucket'}
-- BUG-315: while a strange mood wants a material (care's need, p.needs[key].care), the orders of the chains that make it
-- (sand, bags, charcoal, glass, thread, cloth, leather) go first in the work orders (act.workorder top), not behind the queue
M.MOOD_TOP = {'dfllm:sand', 'dfllm:bag', 'dfllm:charcoal', 'dfllm:glass', 'dfllm:cutglass', 'dfllm:cutgems', 'dfllm:webs', 'dfllm:thread', 'dfllm:cloth',
              'dfllm:tan'}
function M.mood_top(p, tag)
  local on = false
  for _, m in pairs(type(p.needs) == 'table' and p.needs or {}) do
    if type(m) == 'table' and type(m.care) == 'table' then on = true; break end
  end
  if not on then return false end
  for _, pre in ipairs(M.MOOD_TOP) do if tostring(tag):sub(1, #pre) == pre then return true end end
  return false
end

function M.order_prune(K, c, p, now, oq)
  local oc = c.orders or M.DEFAULTS.orders
  local cap, pdays = math.tointeger(oc.cap) or 120, math.tointeger(oc.prune_days) or 30
  local per = math.tointeger(oc.prune_per_day) or 30
  local sd = math.tointeger(oc.stuck_days) or 3
  local day = now // DAY
  if p.prune_day ~= day then p.prune_day, p.prune_n = day, 0 end
  if per <= 0 or (p.prune_n or 0) >= per then return 0 end
  local tag_of, keep_id = {}, {}
  for tag, id in pairs(p.orders) do
    tag_of[id] = tag
    for _, pre in ipairs(M.PRUNE_KEEP_TAG) do
      if tostring(tag):sub(1, #pre) == pre then keep_id[id] = true; break end
    end
  end
  local one = df.workquota_frequency_type and df.workquota_frequency_type.OneTime
  local open_n, cands, groups = 0, {}, {}
  for _, o in ipairs(orders_all()) do
    local left = math.tointeger(o.amount_left) or 0
    if left > 0 then
      open_n = open_n + 1
      local rec = p.ostuck[tostring(o.id)]
      local okn, job = pcall(job_name, o)
      local days = type(rec) == 'table' and (now - (math.tointeger(rec.since) or now)) // DAY or -1
      if days >= sd and okn and type(job) == 'string' and not M.PRUNE_KEEP[job] and not keep_id[o.id]
         and (one == nil or o.frequency == nil or o.frequency == one) then
        local sig = string.format('%s:%s:%s:%s:%s', job, tostring(o.item_subtype), tostring(o.mat_type),
                                  tostring(o.mat_index), tostring(rec.why))
        local e = {id = o.id, days = days, sig = sig, job = job, why = rec.why}
        cands[#cands + 1] = e
        local g = groups[sig]
        if not g then g = {}; groups[sig] = g end
        g[#g + 1] = e
      end
    end
  end
  local drop, dropped = {}, {}
  for _, g in pairs(groups) do
    if #g > 1 then
      table.sort(g, function(a, b)
        local ta, tb = tag_of[a.id] ~= nil, tag_of[b.id] ~= nil
        if ta ~= tb then return ta end
        return a.id < b.id
      end)
      for i = 2, #g do drop[#drop + 1] = g[i]; dropped[g[i].id] = 'duplicate' end
    end
  end
  -- BUG-515 (Run 16c i3 Sealcertain y385-y386: 'JAM forges slots full of cancelling jobs (MakeWeapon x3: no bars BRONZE)', the
  -- hospital well's chain (order 576) waited 99 days behind bronze weapons that never had bars): the orders whose jobs fill a
  -- jammed shop's slots and cannot run (jam_scan, p.ostuck for stuck_days) go, one-time ones only and under the same keep
  -- rules as the rest of the prune; a standing order stays and is named in the event
  local jamk = {}
  if oq and type(oq.jamc) == 'table' then
    local byid = {}
    for _, e in ipairs(cands) do byid[e.id] = e end
    for _, jc in ipairs(oq.jamc) do
      local e = byid[jc.id]
      if e and not dropped[e.id] then
        drop[#drop + 1] = e
        dropped[e.id] = 'jam'
        jamk[jc.key] = (jamk[jc.key] or 0) + 1
      end
    end
  end
  table.sort(drop, function(a, b) return a.id < b.id end)
  if cap > 0 and open_n - #drop > cap then
    table.sort(cands, function(a, b) if a.days ~= b.days then return a.days > b.days end return a.id < b.id end)
    local over = open_n - #drop - cap
    for _, e in ipairs(cands) do
      if over <= 0 then break end
      if not dropped[e.id] and e.days >= pdays then
        drop[#drop + 1] = e
        dropped[e.id] = 'over the cap'
        over = over - 1
      end
    end
  end
  local gone, first = {}, nil
  for _, e in ipairs(drop) do
    if (p.prune_n or 0) >= per then break end
    if K.act.order_remove(e.id) then
      p.prune_n = (p.prune_n or 0) + 1
      gone[#gone + 1] = string.format('%d %s (%s)', e.id, e.job, dropped[e.id])
      first = first or e
      p.ostuck[tostring(e.id)] = nil
      local tag = tag_of[e.id]
      if tag then p.orders[tag], st.backoff[tag] = nil, now + (oc.backoff_days or 10) * DAY end
    end
  end
  if #gone == 0 then return 0 end
  local jt = {}
  for key, n in pairs(jamk) do jt[#jt + 1] = string.format('%s %d', key:match(':(.+)$') or key, n) end
  table.sort(jt)
  local msg = string.format('order queue: %d of %d open orders removed (stuck duplicates%s%s): %s', #gone, open_n,
                            cap > 0 and string.format(', above the cap of %d', cap) or '',
                            #jt > 0 and ('; jam: ' .. table.concat(jt, ', ')) or '',
                            table.concat(gone, ', ', 1, math.min(#gone, 8)) .. (#gone > 8 and ', ...' or ''))
  K.log('warn', '%s', msg)
  K.emit('ORDER_STUCK', 'B', msg:sub(1, 200), {order = first.id, job = first.job,
         why = ('prune: ' .. tostring(first.why)):sub(1, 80), days = first.days, dropped = 1, kind = 'prune', n = #gone})
  K.persist.touch('m.economy')
  return #gone
end

-- FR-01 (daily): orders that cannot run (workshop, input on the citizens' walk group, worker) for stuck_days;
-- sliced: ORDER_SLICE orders per frame
local ORDER_SLICE = 50
function T.ocheck(K, c, r)
  local oc = c.orders or M.DEFAULTS.orders
  local p = r.p
  local oq = r.oq
  if not oq then
    local ids = {}
    for _, o in ipairs(orders_all()) do if (o.amount_left or 0) > 0 then ids[#ids + 1] = o.id end end
    oq = {ids = ids, i = 1, ctx = order_ctx(K, c, r), seen = {}, stuck = 0, told = 0, steel = {}, steel_left = 0,
          sws = 0, slab = 0, wsn = {}, stand = {}, wsg = {}}
    r.oq = oq
    -- FR-73: the standing cloth orders wait for thread and plants by design: no stuck report for them
    for tag, id in pairs(p.orders) do
      if tostring(tag):sub(1, 12) == 'dfllm:stand_' then oq.stand[id] = true end
    end
    -- BUG-061: which workshop types have their slots full of jobs that cannot run (their orders get the reason)
    local okj, errj = pcall(M.jam_scan, K, c, oq)
    if not okj then K.log('warn', 'jam scan: %s', tostring(errj)) end
  end
  local last = math.min(#oq.ids, oq.i + ORDER_SLICE - 1)
  for k = oq.i, last do
    local o = order_by_id(oq.ids[k])
    local why, job, kind
    if o and (o.amount_left or 0) > 0 and not oq.stand[o.id] then why, job, kind = M.order_reasons(o, oq.ctx) end
    if why then
      local key = tostring(o.id)
      oq.seen[key] = true
      if why:find('bars:INORGANIC:STEEL', 1, true) or why:find('bars:STEEL', 1, true) then   -- plan_steel
        oq.steel[#oq.steel + 1] = o.id
        oq.steel_left = oq.steel_left + (o.amount_left or 0)
      end
      local rec = p.ostuck[key]
      if type(rec) ~= 'table' then rec = {since = r.now}; p.ostuck[key] = rec end
      rec.why, rec.job = why:sub(1, 120), tostring(job):sub(1, 40)   -- Run 11: room for the cook ingredients' why
      -- BUG-059: a missing mandatory workshop is told apart from a labor or detail problem (and from a missing input)
      rec.kind = kind and (kind.ws and 'workshop' or kind.worker and 'worker' or kind.jam and 'jam' or 'input') or nil
      local days = (r.now - (math.tointeger(rec.since) or r.now)) // DAY
      if days >= (oc.stuck_days or 3) then
        oq.stuck = oq.stuck + 1
        if kind and kind.ws then oq.sws, oq.wsn[kind.ws] = oq.sws + 1, (oq.wsn[kind.ws] or 0) + 1 end
        if kind and kind.worker then oq.slab = oq.slab + 1 end
        if kind and kind.worker and rec.job == 'ConstructMechanisms' then M.mech_labor_note(K) end     -- BUG-730: nobody makes the mechanisms
        -- BUG-205 (live Earthboat: ORDER_STUCK x45 in 2 months, one per imported order whose workshop is missing): a
        -- missing workshop is one event per shop type at the end of the pass (M.ws_stuck)
        -- BUG-225 (live i3: 12x 'no bars:INORGANIC:IRON' and 9x 'no rock' in a month, one per order): a missing input
        -- or worker is one event per kind and reason the same way
        if kind and (kind.ws or rec.kind == 'input' or rec.kind == 'worker') then
          local gk = kind.ws or (rec.kind .. ':' .. rec.why)
          local g = oq.wsg[gk] or {ids = {}, new = {}, days = 0, kind = kind.ws and 'workshop' or rec.kind, wsk = kind.wsk}
          oq.wsg[gk] = g
          g.ids[#g.ids + 1], g.days = o.id, math.max(g.days, days)
          if rec.told ~= 1 then g.new[#g.new + 1] = {rec = rec, id = o.id, job = rec.job, why = rec.why} end
        elseif rec.told ~= 1 and oq.told < (oc.report_per_day or 3) then
          rec.told, oq.told = 1, oq.told + 1
          K.emit('ORDER_STUCK', 'B', string.format('order %d %s cannot run for %d days: %s', o.id, rec.job, days, rec.why),
                 {order = o.id, job = rec.job, why = rec.why, days = days, dropped = 0, kind = rec.kind})
        end
      end
    end
  end
  oq.i = last + 1
  r.cmds = r.cmds + 1                            -- a slice of its own (orders, labor holders)
  if oq.i <= #oq.ids then return false end
  for key in pairs(p.ostuck) do if not oq.seen[key] then p.ostuck[key] = nil end end
  M.ws_stuck(K, p, oq, oc)
  local okm, errm = pcall(M.ws_missing, K, p, oq)   -- BUG-267: ask for the missing shops, drop the hopeless orders
  if not okm then K.log('warn', 'missing workshops: %s', tostring(errm)) end
  local okp, errp = pcall(M.order_prune, K, c, p, r.now, oq)   -- BUG-315: stuck duplicates and the queue above its cap; BUG-515: jam culprits
  if not okp then K.log('warn', 'order prune: %s', tostring(errp)) end
  st.jobord = oq.shops and oq.shops.by_order or st.jobord   -- BUG-315: the orders whose jobs are out (scan_orders)
  local wl = {}
  for label, n in pairs(oq.wsn) do wl[#wl + 1] = {label, n} end
  table.sort(wl, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
  local ws = {}
  for i = 1, math.min(3, #wl) do ws[i] = string.format('%s x%d', wl[i][1], wl[i][2]) end
  st.orders = {n = #oq.ids, bad = st.bad or 0, stuck = oq.stuck, sws = oq.sws, slab = oq.slab,
               ws = table.concat(ws, ', '):sub(1, 60), jam = st.jam}
  oq.done = true
  local sh = {}                                   -- BUG-061: the workshops' job lists (inspect orders)
  for key, e in pairs(oq.shops and oq.shops.keys or {}) do
    sh[#sh + 1] = {ws = key, shops = e.shops, jobs = e.jobs, working = e.working, blocked = e.blocked or 0}
  end
  table.sort(sh, function(a, b) return a.ws < b.ws end)
  st.shops = sh
  st.steel = {n = #oq.steel, left = oq.steel_left, ids = {table.unpack(oq.steel, 1, math.min(10, #oq.steel))}}
  return true
end

---------------------------------------------------------------- B2: slabs, stale orders, standing cloth orders
-- BUG-061 (Run 13 y523, 31 EngraveSlab orders: the masons' slots held jobs that cancelled at once). The slab pass:
--   * counts the unengraved slabs (OF.slabs) and the EngraveSlab / ConstructSlab orders;
--   * keeps min(slabs.max_orders, unengraved slabs) EngraveSlab orders (the oldest) and removes the rest, naming them
--     in kern.log; ORDER_STUCK (B) once per episode (util/cadence); autoslab.cpp queues an order per ghost again every
--     1289 ticks, so the same pass runs at the first "unengraved slab" cancel report too (M.slab_event);
--   * orders ConstructSlab first (slabs.restock_cap blank slabs at most) when ghosts or engrave orders want slabs and
--     the stock and the open ConstructSlab orders do not cover them (note 56: autoslab ran, no blank slab for the new
--     ghosts); state in st.slab (inspect orders).
-- BUG-177 (live i4: after a reload view.care was nil for ~15k ticks and the slab pass read 0 ghosts, so the restock cap
-- min(ghosts, restock_cap) was 0): the ghosts from care's published view, else from census.g while it is fresh (two
-- days, as care's memorial pass reads it), else nil (unknown)
M.slab_ghosts = function(K, now)
  local care = (K.view() or {}).care
  local g = type(care) == 'table' and math.tointeger(care.ghosts) or nil
  if g then return math.max(0, g) end
  local cg = K.census.g
  if type(cg) == 'table' and type(cg.ids) == 'table' and now - (math.tointeger(cg.tick) or -DAY * 3) < DAY * 2 then
    return #cg.ids
  end
  return nil
end

-- BUG-518 (Run 16b i2 Brotherarrow y385: five corpses in tree crowns could not be buried, a ghost scared a citizen to death): the
-- dead citizens whose bodies nobody can walk to (care.unreach_ids, with a historical figure) want a memorial slab too, before the
-- ghost comes; the ones that are ghosts already are in census.g and not counted twice
function M.slab_extra(K)
  local ok, ul = K.call('care', 'unreach_ids')
  if not (ok and type(ul) == 'table') then return {} end
  local isg = {}
  local cg = K.census.g
  for _, id in ipairs(type(cg) == 'table' and type(cg.ids) == 'table' and cg.ids or {}) do isg[math.tointeger(id) or id] = true end
  local out = {}
  for _, id in ipairs(ul) do if not isg[id] then out[#out + 1] = id end end
  return out
end

function M.slab_pass(K, c, r)
  local sc, OF = c.slabs, M.OF
  local jt = df.job_type.EngraveSlab
  if type(sc) ~= 'table' or jt == nil then return end
  local p, now = r.p, r.now
  local cs = df.job_type.ConstructSlab
  local eng, cons, engf = {}, 0, {}
  for _, o in ipairs(orders_all()) do
    local n = math.tointeger(o.amount_left) or 0
    if n > 0 then
      if o.job_type == jt then
        eng[#eng + 1] = o.id
        local okf, hf = pcall(function() return o.specdata.hist_figure_id end)     -- BUG-078: whose slab
        engf[o.id] = okf and math.tointeger(hf) or -1
      elseif cs ~= nil and o.job_type == cs then cons = cons + n end
    end
  end
  table.sort(eng)
  local sl = OF.slabs(sc.scan_max)
  local ghosts = M.slab_ghosts(K, now)
  local gunk = ghosts == nil
  ghosts = (ghosts or 0) + (gunk and 0 or #M.slab_extra(K))      -- BUG-518: + the unreachable bodies
  local sb = {blank = sl.blank, busy = sl.busy, held = sl.held, built = sl.built, memorial = sl.memorial, engrave = #eng,
              cons = cons, ghosts = ghosts, removed = 0, ordered = 0, engraved = 0, unserved = 0}
  st.slab, st.slab_t = sb, now
  local function cmd() if r.cmds then r.cmds = r.cmds + 1 end end
  -- the EngraveSlab orders that may stand
  -- a blank slab a running job holds keeps that job's order (removing it would orphan the job)
  local _, drop = OF.engrave_split(eng, sl.blank + sl.busy, sc.max_orders)
  local day = now // DAY
  if p.slab_day ~= day then p.slab_day, p.slab_n = day, 0 end
  local removed = {}
  for _, id in ipairs(drop) do
    if (p.slab_n or 0) >= (sc.drop_per_day or 60) then break end
    cmd()
    if K.act.order_remove(id) then
      p.slab_n = (p.slab_n or 0) + 1
      removed[#removed + 1] = id
      for tag, oid in pairs(p.orders) do if oid == id then p.orders[tag] = nil end end
    end
  end
  sb.removed = #removed
  if #removed > 0 then
    local list = table.concat(removed, ',', 1, math.min(#removed, 12)) .. (#removed > 12 and (' +' .. (#removed - 12)) or '')
    local T0 = K.now()
    local why = sl.blank == 0 and 'no unengraved slab' or 'more orders than unengraved slabs'
    -- BUG-183 (live i4: 35 identical warn lines, one per economy pass, while autoslab re-queued the order each time): the
    -- warn goes with the ORDER_STUCK cadence; the removals between two announcements are logged at debug and counted
    local due = CAD.due(p.slab_ann, T0, {}, {why}, {ticks = CAD.TICKS, wall_s = CAD.WALL_S})
    local quiet = due and (math.tointeger(p.slab_quiet) or 0) or 0
    K.log(due and 'warn' or 'debug', 'EngraveSlab: %d orders, %d unengraved slabs (%d in jobs, %d held), %d ghosts: orders %s ' ..
          'removed, %d kept (at most %d)%s', #eng, sl.blank, sl.busy, sl.held, ghosts, list, #eng - #removed, sc.max_orders or 3,
          quiet > 0 and string.format('; %d more removed since the last warn', quiet) or '')
    if not due then p.slab_quiet = (math.tointeger(p.slab_quiet) or 0) + #removed end
    if due then
      p.slab_ann, p.slab_quiet = CAD.mark(T0, {}, {why}), nil
      K.emit('ORDER_STUCK', 'B', string.format('%d EngraveSlab orders removed (%s: %d unengraved slabs, %d ghosts): %s',
                                               #removed, why, sl.blank, ghosts, list):sub(1, 200),
             {order = removed[1], job = 'EngraveSlab', why = ('slab: ' .. why):sub(1, 60), n = #removed, dropped = 1})
    end
  elseif #drop == 0 then
    p.slab_ann = CAD.quiet(p.slab_ann)
  end
  M.slab_engrave(K, c, r, sl, sb, eng, engf, removed)
  if gunk then                     -- BUG-177: no ghost count yet: no restock on a guessed 0, no request either
    sb.why = 'ghost count unknown: care has not published since the boot and census.g is stale'
    K.persist.touch('m.economy')
    return
  end
  -- ConstructSlab first. BUG-133 (Run 14: 41 ghosts, ConstructSlab x3, x1, x4 in 200 game years at restock_cap 5): the
  -- cap is min(ghosts, restock_cap 20), and the ghosts counted are the ones that still want a blank slab: no memorial
  -- (loose, in a build job or placed) and no EngraveSlab order (sb.gneed; every ghost while census.g is stale)
  local gneed = sb.gneed or ghosts
  local n, want = OF.restock(sl.blank, cons, gneed, #eng - #removed + sb.engraved, math.min(ghosts, sc.restock_cap or 20))
  sb.want = want
  local f = r.f or {}
  -- BUG-182: a standing ConstructSlab order nobody can work (no mason's workshop) leaves n = 0: the reason is said too
  if n <= 0 and gneed > 0 and not f['workshop:Masons'] then sb.why = 'no Masons' end
  if n > 0 then
    local free = stone_free(c, r)
    if not f['workshop:Masons'] then sb.why = 'no Masons'
    elseif free < n then
      -- BUG-736 (Run 16c i3 Doorwings: ghosts 27541 / 28225, bodies in tree crowns, 'no ConstructSlab ... 0 free boulders for 2 slabs' for 100 d beside 400
      -- logs): DF makes slabs of stone only (a coffin needs a body a hauler reaches); the text says what the fort has and what it takes
      local i = r.inv or {}
      sb.why = string.format('%d free boulders for %d slabs (ore %d, flux %d, refused %d, out of reach %d; a slab is stone only, logs make coffins for ' ..
                             'bodies a hauler reaches: trade.want stone or dig hard stone)', free, n, i.ore or 0, i.flux or 0, i.rock_bad or 0,
                             i.rock_far or 0)
    else
      local tag = 'dfllm:slab'
      if not live(p.orders[tag]) and now >= (st.backoff[tag] or 0) then
        cmd()
        local ok, id = K.act.workorder({job = 'ConstructSlab', material = 'INORGANIC', frequency = 'OneTime',
                                        amount_total = n, tag = tag})
        if ok then
          p.orders[tag] = id
          sb.ordered = n
          r.planned = r.planned or {}
          r.planned.rock = (r.planned.rock or 0) + n
          K.log('info', 'order %s x%d (slabs: %d unengraved, %d ghosts, %d engrave orders)', tag, n, sl.blank, ghosts,
                #eng - #removed)
        else st.backoff[tag] = now + 3 * DAY end
      end
    end
  end
  M.slab_why(K, c, r, sb, ghosts, f)
  K.persist.touch('m.economy')
end

-- BUG-133 (Run 14: sb.why 'no Masons' stood for years in inspect orders only; the masons' shop was lost at 284.35M and the
-- rebuild policy held the workshops project): the reason no blank slab is ordered goes to kern.log once per reason and
-- again only after util/cadence's window; while ghosts stand and no mason's workshop does, PROJECT_REQUEST workshops
-- why=slabs types=[Masons] (follow places the masons' shop alone, the rebuild policy lets it run while ghosts wait) at
-- most every food.request_days (p.slab_wsreq)
M.SLAB_REQ = {wall_s = 900, backoff = 4}
function M.slab_why(K, c, r, sb, ghosts, f)
  local p, now = r.p, r.now
  local T0 = K.now()
  if sb.why and sb.why ~= '' then
    if CAD.due(p.slab_why, T0, {}, {sb.why}, {ticks = CAD.TICKS, wall_s = CAD.WALL_S}) then
      p.slab_why = CAD.mark(T0, {}, {sb.why})
      K.log('warn', 'slabs: no ConstructSlab for %d ghosts (%d want a slab, %d blank, %d memorials): %s', ghosts,
            sb.gneed or ghosts, sb.blank, sb.memorial, sb.why)
    end
  else p.slab_why = CAD.quiet(p.slab_why) end
  -- BUG-200 (live i4 round 3: PROJECT_REQUEST why=slabs types=[Masons] every 21-26 game days, ~3 real minutes, with
  -- follow off): the request record is {t, w, k, n = ghosts}; the k-th unanswered repeat waits request_days * 2^(k-1)
  -- game days AND 900 s * 2^(k-1) wall seconds (k <= 4); more ghosts start over at k 1; a standing Masons clears it
  if f['workshop:Masons'] then p.slab_wsreq = nil end
  if ghosts <= 0 or f['workshop:Masons'] then return end
  local rec = p.slab_wsreq
  if math.type(rec) == 'integer' or math.type(rec) == 'float' then rec = {t = math.tointeger(rec), k = 1} end
  if type(rec) ~= 'table' then rec = nil end
  local k = rec and math.max(1, math.tointeger(rec.k) or 1) or 0
  if rec and ghosts > (math.tointeger(rec.n) or ghosts) then k = 1; rec.k = 0 end   -- news: the base period only
  if k > 0 then
    local fx = 1 << (math.min(k, M.SLAB_REQ.backoff) - 1)
    local every = ((c.food or {}).request_days or 14) * DAY * fx
    local t = math.tointeger(rec.t) or 0
    if now >= t and not CAD.elapsed(rec, T0, every, M.SLAB_REQ.wall_s * fx) then return end
  end
  -- review: a workshops project already queued (paused by the rebuild policy, still digging) is not asked for again:
  -- follow would place a second masons' shop beside it. BUG-181 (live i4: a pending workshops project with skip=Masons
  -- held the request back): only one that builds the Masons (M.ws_queued)
  local q = M.ws_queued(K, 'Masons')
  if q then sb.asked = 'queued'; sb.queued = q; return end
  -- BUG-200: runner's mandatory request (BUG-184, its own backoff) already asks for the Masons: not a second time
  local okm, mand = K.call('runner', 'req_types', 'wsm')
  if okm and type(mand) == 'table' then
    for _, t in ipairs(mand) do if t == 'Masons' then sb.asked = 'mandatory'; return end end
  end
  p.slab_wsreq = {t = now, w = T0.wall, k = (rec and (math.tointeger(rec.k) or 1) or 0) + 1, n = ghosts}
  sb.asked = 1
  K.emit('PROJECT_REQUEST', 'B', string.format("workshops: no mason's workshop for the memorial slabs of %d ghost(s)", ghosts),
         {tpl = 'workshops', n = 1, why = 'slabs', types = {'Masons'}})
end

-- BUG-078 (Run 14 note 69: autoslab enabled, 79 slabs, two ghosts waiting for years, 0 EngraveSlab orders): a ghost that
-- stood `slabs.engrave_days` days (0 = off; the plugin queues one order per ghost every 1289 ticks, so it has had its
-- chance) with a figure, no memorial and no EngraveSlab order of its own gets one through act.engrave_order, as many as
-- the free blank slabs and slabs.max_orders allow after the trim above (so the next pass does not remove them). The
-- ghost list is census.g (sense; not trusted older than two days); the age is the first day this module saw the ghost
-- (persisted p.slab_ghost). A ghost without a historical figure (unit.hist_figure_id < 0) cannot be served by the plugin
-- or by us: reported once (p.slab_skip), never retried; an act failure is retried after 7 days; a figure whose order the
-- "Needs ..." pruner removed (needs_cancel, p.slab_drop) waits orders.backoff_days (J2). sb.unserved counts them.
function M.slab_engrave(K, c, r, sl, sb, eng, engf, removed)
  local sc, p, now = c.slabs, r.p, r.now
  local days = sc.engrave_days
  if days == nil then days = 3 end
  local cg = K.census.g
  if type(cg) ~= 'table' or type(cg.ids) ~= 'table' or now - (math.tointeger(cg.tick) or -DAY * 3) >= DAY * 2 then return end
  local seen = json.object(type(p.slab_ghost) == 'table' and p.slab_ghost or {})
  local skip = json.object(type(p.slab_skip) == 'table' and p.slab_skip or {})
  local isghost, ids = {}, {}
  for _, id in ipairs(cg.ids) do
    local sid = tostring(math.tointeger(id) or id)
    isghost[sid] = true
    ids[#ids + 1] = {id = math.tointeger(id), sid = sid}
    if seen[sid] == nil then seen[sid] = now end
  end
  -- BUG-518: the dead whose bodies nobody can walk to are served like ghosts (their slab before the haunting)
  for _, id in ipairs(M.slab_extra(K)) do
    local sid = tostring(math.tointeger(id) or id)
    if not isghost[sid] then
      isghost[sid] = true
      ids[#ids + 1] = {id = math.tointeger(id), sid = sid}
      if seen[sid] == nil then seen[sid] = now end
    end
  end
  for sid in pairs(seen) do if not isghost[sid] then seen[sid] = nil end end
  for sid in pairs(skip) do if not isghost[sid] then skip[sid] = nil end end
  p.slab_ghost, p.slab_skip = seen, skip
  -- J2: figures whose order the "Needs ..." pruner removed wait orders.backoff_days (an own order's rule)
  local drop = json.object(type(p.slab_drop) == 'table' and p.slab_drop or {})
  local bo = ((c.orders or M.DEFAULTS.orders).backoff_days or 10) * DAY
  for k, t in pairs(drop) do if now - (math.tointeger(t) or 0) >= bo then drop[k] = nil end end
  p.slab_drop = drop
  local gone = {}
  for _, id in ipairs(removed or {}) do gone[id] = true end
  local ordered = {}
  for _, id in ipairs(eng) do if not gone[id] and (engf[id] or -1) >= 0 then ordered[engf[id]] = true end end
  -- BUG-133: served = a memorial placed or in a build job; a loose one waits for care to place it (no second order);
  -- gneed = the ghosts with a figure that have neither a memorial nor an order (they want a blank slab)
  sb.served, sb.loose, sb.gneed = 0, 0, 0
  for _, g in ipairs(ids) do
    local u = g.id and df.unit.find(g.id)
    local hf = u and math.tointeger(u.hist_figure_id) or -1
    if hf >= 0 then
      if sl.placed[hf] or sl.build[hf] then sb.served = sb.served + 1
      elseif sl.loose[hf] then sb.loose = sb.loose + 1
      elseif not ordered[hf] then sb.gneed = sb.gneed + 1 end
    end
  end
  local cand = {}
  table.sort(ids, function(a, b)
    local sa, sb2 = seen[a.sid], seen[b.sid]
    if sa ~= sb2 then return sa < sb2 end
    return (a.id or 0) < (b.id or 0)
  end)
  for _, g in ipairs(ids) do
    if days > 0 and g.id and now - seen[g.sid] >= days * DAY then
      local u = df.unit.find(g.id)
      local hf = u and math.tointeger(u.hist_figure_id) or -1
      local sk = skip[g.sid]
      if hf < 0 then
        sb.unserved = sb.unserved + 1
        if sk == nil then
          skip[g.sid] = json.object{why = 'no_hf', t = now}
          K.log('warn', 'EngraveSlab: ghost unit %d has no historical figure: no slab can be ordered for it (reported once)',
                g.id)
        end
      elseif sl.topics[hf] or ordered[hf] then
        skip[g.sid] = nil                                      -- served: a memorial exists or the plugin's order stands
      elseif drop[tostring(hf)] then
        sb.unserved = sb.unserved + 1                          -- J2: its order was removed after the cancels: back off
      elseif type(sk) == 'table' and sk.why ~= 'no_hf' and now - (math.tointeger(sk.t) or 0) < 7 * DAY then
        sb.unserved = sb.unserved + 1                           -- an act failure: back off
      else
        cand[#cand + 1] = {id = g.id, hf = hf, sid = g.sid, age = (now - seen[g.sid]) // DAY}
      end
    end
  end
  sb.aged = #cand
  if #cand == 0 then return end
  local standing = #eng - #removed
  local room = math.min((sc.max_orders or 3) - standing, sl.blank - math.max(0, standing - sl.busy))
  for i = 1, math.min(room, #cand) do
    local g = cand[i]
    if r.cmds then r.cmds = r.cmds + 1 end
    local ok, res = K.act.engrave_order(g.hf)
    if ok then
      sb.engraved = sb.engraved + 1
      K.log('info', 'EngraveSlab order %s for ghost unit %d (hf %d, %d days without a memorial or an order): the autoslab ' ..
            'plugin queued none (%d blank slabs, %d orders standing, %d ghosts)', tostring(res), g.id, g.hf, g.age, sl.blank,
            standing, #ids)
    else
      skip[g.sid] = json.object{why = tostring(res):sub(1, 40), t = now}
      sb.unserved = sb.unserved + 1
    end
  end
end

-- the first "unengraved slab" cancel of a window (slabs.trigger_ticks): the pass now, outside a daily run
function M.slab_event(K, c)
  local sc = c.slabs
  if type(sc) ~= 'table' then return end
  local now = K.now().tick
  if st.slab_t and now - st.slab_t < (sc.trigger_ticks or 600) then return end
  M.slab_pass(K, c, M.view_run(K))
end

function T.slabs(K, c, r)
  local ok, err = pcall(M.slab_pass, K, c, r)
  if not ok then K.log('warn', 'slab pass: %s', tostring(err)) end
  r.cmds = r.cmds + 1
  return true
end

-- BUG-060 (Run 13 y508): why a stale order gets no job, in the words of what the pre-pass saw
function M.stale_reason(c, r, oq, o, job, mc, days)
  local parts = {}
  local ws = OL.workshops(job, mc) or {}
  local key
  for _, w in ipairs(ws) do if r.f[w] then key = w; break end end
  local e = key and oq.shops and oq.shops.keys[key]
  if oq.ctx.jam_ids and oq.ctx.jam_ids[o.id] and oq.ctx.jam and key and oq.ctx.jam[key] then
    parts[#parts + 1] = oq.ctx.jam[key]
  elseif e then
    parts[#parts + 1] = string.format('%s: %d shop%s, %d jobs (%d working), none from this order', key:match(':(.+)$') or key,
                                      e.shops, e.shops == 1 and '' or 's', e.jobs, e.working)
  end
  if mc == 'rock' then parts[#parts + 1] = string.format('%d free boulders', stone_free(c, r))
  elseif mc == 'wood' then parts[#parts + 1] = string.format('%d logs', r.inv.wood or 0) end
  return table.concat(parts, '; '):sub(1, 110)
end

-- BUG-730 (Run 16d i4 Pagedsculpture y373-y374: the planned traps waited for trapparts for months, ConstructMechanisms x2, x13, x8 'no job for 12 days
-- (Mechanics: 1 shop, 1 jobs, none from this order; 33 free boulders)': only reported): a mechanism order that cannot run (no worker with the
-- Mechanics labor) or is stale asks for the dwarf who makes it first: mechanic_labor puts the labor on the best idle candidate when nobody
-- holds it. The note it adds to the stale reason
function M.mech_labor_note(K)
  local ok, lab, uid = pcall(M.mechanic_labor, K)
  if not ok then return '' end
  if lab == 'set' then return string.format('; Mechanics labor set on for unit %d', int(uid) or 0) end
  if lab == 'none' then return '; no citizen can take the Mechanics labor' end
  return ''
end

-- BUG-224: the order's shop type (the first built one, as M.stale_reason names it) when its shops hold other jobs, at
-- least one a shop: {key, e = oq.shops.keys entry}; nil when the shops stand empty (the order itself is the problem)
function M.shop_busy(oq, r, job, mc)
  for _, w in ipairs(OL.workshops(job, mc) or {}) do
    if (r.f or {})[w] then
      local e = oq.shops and oq.shops.keys[w]
      if e and (e.jobs or 0) > 0 and e.jobs >= math.max(1, e.shops or 1) then return {key = w, e = e} end
      return nil
    end
  end
end

-- BUG-224: one shop holds >= M.BUSY_WAIT waiting jobs (shop jobs - working, per shop) while citizens with its labor stand
-- idle: PROJECT_REQUEST workshops why=busy types=[Carpenters|Masons] (follow places one more shop of that type), at
-- most every food.request_days and 15 min (util/cadence, p.busyreq[type]); not while a workshops project builds one
M.BUSY_LABOR = {['workshop:Carpenters'] = 'CARPENTER', ['workshop:Masons'] = 'MASON'}
M.BUSY_WAIT = 3
function M.busy_request(K, c, r, b)
  local lab = M.BUSY_LABOR[b.key]
  local e, p = b.e, r.p
  local shops = math.max(1, e.shops or 1)
  local wait = (e.jobs or 0) - (e.working or 0)
  if not lab or wait < M.BUSY_WAIT * shops then return end
  local li = df.unit_labor and df.unit_labor[lab]
  local cu = K.census.u
  local idle, sold = 0, {}
  for _, id in ipairs(type(cu) == 'table' and cu.soldier_ids or {}) do sold[id] = true end   -- as idle_pct: no soldiers
  for _, id in ipairs(li and type(cu) == 'table' and cu.ids or {}) do
    local u = not sold[id] and df.unit.find(id) or nil
    local okl, has = pcall(function() return u.status.labors[li] == true end)
    if u and okl and has and (u.job == nil or u.job.current_job == nil) then idle = idle + 1 end
  end
  if idle == 0 then return end
  local t = b.key:match(':(.+)$')
  if M.ws_queued(K, t) then return end
  if type(p.busyreq) ~= 'table' then p.busyreq = json.object{} end
  local T0 = K.now()
  local rec = p.busyreq[t]
  if type(rec) == 'table' and not CAD.elapsed(rec, T0, ((c.food or {}).request_days or 14) * DAY, 900) then return end
  p.busyreq[t] = {t = T0.tick, w = T0.wall}
  K.log('info', 'workshops: %s busy (%d shop%s, %d jobs waiting, %d idle with %s): one more asked for', t, shops,
        shops == 1 and '' or 's', wait, idle, lab)
  K.emit('PROJECT_REQUEST', 'B', string.format('workshops: one more %s (%d shop%s, %d jobs waiting, %d idle %s)', t,
                                               shops, shops == 1 and '' or 's', wait, idle, lab:lower()),
         {tpl = 'workshops', n = 1, why = 'busy', types = {t}})
end

-- BUG-060 (daily, after T.ocheck): one-time validated orders without conditions that make no job. The state per order
-- (p.ostale: amount left, since when) restarts when the amount changes or a job from the order stands in a workshop
-- (job.order_id); `stale.days` (`stale.wait_days` while a planned building waits for that piece) later it is stale:
--   1. a stone furniture order with a wood variant, logs and a carpenter's shop: re-entered in wood (act.order_material,
--      the work orders screen: the carpenters built the 11 doors of Run 13 at once);
--   2. else a simple order (job, stone or wood, amount) is made again (a new one first, then the old one removed);
--   3. else it is reported only. ORDER_STUCK (B) once per order, at most stale.per_day actions a day; only in PEACE and
--   RECOVERY (the clock stands still otherwise). Orders with a known blocker are ORDER_STUCK's (T.ocheck), except the
--   victims of a jam (oq.ctx.jam_ids).
function T.stale(K, c, r)
  local sc, oq = c.stale, r.oq
  if type(sc) ~= 'table' or not (oq and oq.done) or not oq.shops then return true end
  local p = r.p
  local sq = r.sq
  local one = df.workquota_frequency_type.OneTime
  if not sq then
    sq = {i = 1, cand = {}, wait = {}, seen = {}}
    r.sq = sq
    for _, q in ipairs(r.jb and r.jb.mq or {}) do
      local e = M.PIECES[q.label]
      if e and (q.n or 0) > 0 then sq.wait[e.job] = true end
    end
  end
  local calm = HUNT_MODES[K.mode()] == true
  local jam_ids = oq.ctx.jam_ids or {}
  local last = math.min(#oq.ids, sq.i + ORDER_SLICE - 1)
  for k = sq.i, last do
    local o = order_by_id(oq.ids[k])
    local left = o and math.tointeger(o.amount_left) or 0
    local okv, valid = false, false
    if o then okv, valid = pcall(function() return o.status.validated == true end) end
    local okn, job = false, nil
    if o then okn, job = pcall(job_name, o) end
    if o and left > 0 and okv and valid and okn and type(job) == 'string' and o.frequency == one and not keep_order(o)
       and (o.item_conditions == nil or #o.item_conditions == 0) and not oq.stand[o.id]
       and (not oq.seen[tostring(o.id)] or jam_ids[o.id]) then
      local mc = OL.mat_class(o, M.is_metal)
      if OL.workshops(job, mc) and job ~= 'EngraveSlab' and not OL.unsafe(job, o.item_subtype) then
        local key = tostring(o.id)
        sq.seen[key] = true
        local rec = p.ostale[key]
        local has = oq.shops.by_order[o.id] ~= nil
        if type(rec) ~= 'table' or rec.left ~= left or has then
          -- BUG-224 (live: the stale record was rebuilt without sw and redo, and 'only reported' came again): the
          -- switch marks stay; told stays while the amount does
          local old = type(rec) == 'table' and rec or {}
          rec = {left = left, since = r.now, sw = old.sw, redo = old.redo, told = old.left == left and old.told or nil}
          p.ostale[key] = rec
        elseif not calm then
          rec.since = math.min(r.now, (math.tointeger(rec.since) or r.now) + DAY)    -- the clock waits for PEACE
        end
        local days = (r.now - (math.tointeger(rec.since) or r.now)) // DAY
        local need = sq.wait[job] and (sc.wait_days or 3) or (sc.days or 10)
        if days >= need and calm then
          sq.cand[#sq.cand + 1] = {o = o, id = o.id, key = key, rec = rec, days = days, job = job, mc = mc, left = left}
        end
      end
    end
  end
  sq.i = last + 1
  r.cmds = r.cmds + 1
  if sq.i <= #oq.ids then return false end
  for key, rec in pairs(p.ostale) do
    if not sq.seen[key] then
      -- BUG-224: a marked order out of the stale pass for a while (stuck, a job standing) keeps its mark while it exists
      if M.stale_mark(p, key) and order_by_id(math.tointeger(tonumber(key))) then rec.left = -1
      else p.ostale[key] = nil end
    end
  end
  table.sort(sq.cand, function(a, b) if a.days ~= b.days then return a.days > b.days end return a.id < b.id end)
  local day = r.now // DAY
  if p.stale_day ~= day then p.stale_day, p.stale_n = day, 0 end
  local wj = {}
  for _, j in ipairs((c.wood_orders or {}).jobs or {}) do wj[j] = true end
  for _, e in ipairs(sq.cand) do
    if (p.stale_n or 0) >= (sc.per_day or 6) then break end
    local o, rec = order_by_id(e.id), e.rec
    if o and (math.tointeger(o.amount_left) or 0) == e.left then
      local def = false
      for _, pe in pairs(M.PIECES) do if pe.job == e.job then def = pe.def == true end end
      local why = M.stale_reason(c, r, oq, o, e.job, e.mc, e.days)
      if e.job == 'ConstructMechanisms' then why = (why .. M.mech_labor_note(K)):sub(1, 150) end     -- BUG-730
      local act, dropped = nil, 0
      if rec.sw ~= 1 and e.mc == 'rock' and wj[e.job] and (r.f or {})['workshop:Carpenters']
         and M.wood_left(c, r, def) >= e.left and K.act.order_material(e.id, 'wood') then
        act = 'wood'
        rec.sw, rec.since = 1, r.now
        r.planned.wood = (r.planned.wood or 0) + e.left
        if r.rk then r.rk = r.rk - e.left end
      else
        -- made again in the other class when that one has the room (a wood order the carpenters never take, stone
        -- plenty), else in its own
        -- BUG-224 (live i3: '1 shop, 5 jobs (1 working), none from this order' made a wood chest again in stone, and
        -- wood_orders switched it back): a busy shop keeps the class (M.shop_busy, a second shop asked for instead);
        -- stone only above wood_orders' own threshold, so the two rules never undo each other
        local mc2 = e.mc
        local busy = M.shop_busy(oq, r, e.job, e.mc)
        if busy then M.busy_request(K, c, r, busy) end
        local bb = math.max(10, math.tointeger((c.wood_orders or {}).boulders_below) or 20)
        if not busy and e.mc == 'wood' and wj[e.job] and (r.f or {})['workshop:Masons']
           and stone_free(c, r) >= e.left + bb then
          mc2 = 'rock'
        end
        local spec = M.OF.simple_spec(o, e.job, mc2)
        local ok_mat = spec and ((mc2 == 'rock' and stone_free(c, r) >= e.left) or
                                 (mc2 == 'wood' and M.wood_left(c, r, def) >= e.left))
        local rd = math.tointeger(rec.redo) or 0
        if ok_mat and rd < (math.tointeger(sc.redo_max) or M.DEFAULTS.stale.redo_max) then
          spec.tag = 'dfllm:redo_' .. tostring(e.id)
          spec.top = true                    -- BUG-203: first in the work orders, not behind the queue it starved in
          r.cmds = r.cmds + 1
          local ok, nid = K.act.workorder(spec)
          if ok and K.act.order_remove(e.id) then
            act, dropped = 'again' .. (mc2 ~= e.mc and ' in stone' or ''), 1
            p.ostale[e.key] = nil
            -- I3: the kernel's own order (a piece, a slab, the idle backlog) keeps its tag on the new order: else the
            -- planner saw its tag gone and entered the same order a second time beside the made-again one
            if int(nid) then
              for tag, oid in pairs(p.orders) do if oid == e.id then p.orders[tag] = nid end end
              -- BUG-201 (live Earthboat: 11x 're-entered in wood', 7x 'made again in stone' for the same doors): the new
              -- order keeps the switch mark; one made in the other class is marked too, so it is never switched back
              p.ostale[tostring(nid)] = {left = e.left, since = r.now, redo = rd + 1,
                                         sw = (rec.sw == 1 or mc2 ~= e.mc) and 1 or nil}
            end
          end
        end
      end
      if act or rec.told ~= 1 then
        p.stale_n = (p.stale_n or 0) + 1
        rec.told = 1
        local verb = act == 'wood' and 're-entered in wood' or (act and ('made ' .. act) or 'only reported')
        K.log('warn', 'order %d %s x%d: no job for %d days (%s): %s', e.id, e.job, e.left, e.days, why, verb)
        K.emit('ORDER_STUCK', 'B', string.format('order %d %s x%d stale: no job for %d days (%s): %s', e.id, e.job, e.left,
                                                 e.days, why, verb):sub(1, 200),
               {order = e.id, job = e.job, why = ('stale: ' .. why):sub(1, 100), n = e.left, days = e.days,
                dropped = dropped})
      end
    end
  end
  K.persist.touch('m.economy')
  return true
end

-- FR-73 (daily): the standing thread and cloth orders (config standing.list), each once its workshops stand, from the
-- phase of the moodable workshops. Monthly orders sit at amount 0 between their months, so "ordered" means the order
-- still exists, not that it has an amount left. A removal (the "Needs ..." pruner) waits orders.backoff_days.
function T.stand(K, c, r)
  local sc = c.standing
  if type(sc) ~= 'table' or not phase_ok(K, sc.from_phase or 'P1') then return true end
  local p, list = r.p, sc.list or {}
  r.si = r.si or 1
  while r.si <= #list do
    local e = list[r.si]
    r.si = r.si + 1
    if type(e) == 'table' and type(e.tag) == 'string' and e.tag:sub(1, 12) == 'dfllm:stand_' and type(e.spec) == 'table'
       and not order_by_id(p.orders[e.tag]) and (e.ws == nil or ws_any(r.f, e.ws)) and r.now >= (st.backoff[e.tag] or 0) then
      local spec = copy(e.spec)
      spec.tag, spec.amount_total, spec.frequency = e.tag, sc.amount or 30, sc.frequency or 'Monthly'
      r.cmds = r.cmds + 1
      local ok, id = K.act.workorder(spec)
      if ok then
        p.orders[e.tag] = id
        K.log('info', 'standing order %s: %s x%d %s', e.tag, spec.job, spec.amount_total, spec.frequency)
      else st.backoff[e.tag] = r.now + 3 * DAY end
      return r.si > #list
    end
  end
  M.farmers_request(K, c, r)
  return true
end

-- FR-73: the Farmer's Workshop (ProcessPlants, SpinThread) is the plan's: P1 builds it with the moodable shops; a fort
-- that went past P1 without one (reclaimed, adopted late) asks follow for it, at most every standing.request_days and
-- never while a workshops project is pending (like the tannery request)
function M.farmers_request(K, c, r)
  local sc = c.standing
  local p = r.p
  if ws_any(r.f, {'workshop:Farmers'}) then p.farm_req = nil; return end
  if p.farm_req and r.now - (math.tointeger(p.farm_req) or 0) < (sc.request_days or 14) * DAY then return end
  local okp, pend = K.call('runner', 'pending', 'workshops')
  if okp and type(pend) == 'number' and pend > 0 then return end
  p.farm_req = r.now
  K.emit('PROJECT_REQUEST', 'B', "workshops: no farmer's workshop (thread, cloth and plant processing wait for it)",
         {tpl = 'workshops', n = 1, why = 'farmers'})
end

-- FR-16 (daily): suspended ConstructBuilding jobs. BUG-009/004/005 (Run 9 live test: 25 construction jobs suspended
-- for 30+ real minutes, every caravan lost; "resumed 2" every day while DF suspended them again within 5 s): the
-- builder cancels "Item blocking site" when a forbidden item lies on the footprint (nobody hauls a forbidden item
-- away), and buildingplan waits for materials that lie forbidden. Steps over frames:
--   jobs     the list (M.suspended_jobs) and the per-job records p.jres: a job resumed earlier and found suspended
--            again counts a resume that did not hold (live: DF suspended them again ~2,000 ticks after a resume, so
--            a job seen unsuspended at one pass proves nothing); a build stage that advanced resets the count;
--            records of jobs that are gone (built, removed) drop out
--   jsite    per job with a footprint, one a frame (PEACE/RECOVERY): the items on its revealed tiles
--            (snapshot.items_at). Forbidden ones are unforbidden; skipped: the job's own materials, merchant goods,
--            care's mood-reserve holds (care lets go of one on a site itself), corpses and dead dwarves' items
--            (burial's); everything else is counted as other
--   jmat     per planned building: its job_items without an item; forbidden loose items of that class on revealed
--            tiles of the citizens' walk group are unforbidden (as many as missing), else the class is missing
--   jfree    the unforbids, one item_flag a frame (jobs.unforbid_per_day)
--   jresume  act.job_resume of the jobs nobody keeps suspended (PEACE/RECOVERY)
--   jcheck   a frame later: a job suspended again is no resume but a failed one; JOBS_SUSPENDED (B) when the
--            numbers change, with the reason (`item blocking site: N forbidden, M other`); jobs.fail_alarm failed
--            resumes -> DECISION_NEEDED build_blocked (A, util/cadence); a trade depot after depot_move_after:
--            a new site (jmove)
--   jmove    the depot site search (sliced), then runner.depot_move
local CORPSE_T = {CORPSE = true, CORPSEPIECE = true}
local MAT_BUSY = {'in_job', 'in_building', 'trader', 'removed', 'garbage_collect', 'construction', 'hostile',
                  'in_inventory', 'dump', 'melt', 'owned', 'artifact', 'encased', 'spider_web', 'dead_dwarf'}
local function tname(it)
  local ok, t = pcall(function() return df.item_type[it:getType()] end)
  return ok and t or nil
end

local function held_set(K, jb)
  if not jb.held then
    local ok, h = K.call('care', 'held_ids')
    jb.held = ok and type(h) == 'table' and h or {}
  end
  return jb.held
end

local function queue_free(jb, id, why)
  if jb.queued[id] then return end
  jb.queued[id] = true
  jb.frees[#jb.frees + 1] = {id = id, why = why}
end

-- BUG-405 (Run 16b i2 Ostgate y397: a trap at 88,101,130 'suspended ... 1 corpse' for 36 days, the builder cancels 'Item
-- blocking site' and nobody hauls a corpse nobody marked): is the corpse (or its part) a stranger's, an enemy or an
-- animal that died on the site? A fort member's body is care's (burial, a coffin), never dumped here. False when the unit
-- cannot be read: nothing is dumped on a guess.
function M.stray_corpse(it)
  local ok, yes = pcall(function()
    local uid = it.unit_id
    if math.type(uid) ~= 'integer' or uid < 0 then return false end
    local u = df.unit.find(uid)
    if u == nil then return false end
    return dfhack.units.isOwnGroup(u) ~= true and dfhack.units.isCitizen(u) ~= true
  end)
  return ok and yes == true
end

-- the items on one footprint: counted and queued (no write here)
local function site_items(K, jb, j, items)
  local s = {forb = 0, other = 0, corpse = 0, held = 0}
  local held = held_set(K, jb)
  for _, e in ipairs(items) do
    local it = df.item.find(int(e[1]) or -1)
    local f = it and it.flags
    if f and not (f.in_job or f.in_building or f.trader or f.removed or f.garbage_collect or f.construction) then
      if CORPSE_T[tname(it) or ''] or f.dead_dwarf then
        s.corpse = s.corpse + 1
        if not f.dead_dwarf and not held[it.id] and not f.dump and M.stray_corpse(it) then
          s.moved = (s.moved or 0) + 1                  -- BUG-405: unforbid and dump it, the haulers carry it off the site
          queue_free(jb, it.id, 'corpse')
        end
      elseif held[it.id] then s.held = s.held + 1
      elseif f.forbid then
        s.forb = s.forb + 1
        queue_free(jb, it.id, 'site')
      else s.other = s.other + 1 end
    end
  end
  j.site = s
  jb.forb, jb.other = jb.forb + s.forb, jb.other + s.other + s.corpse + s.held
  jb.corpse, jb.held_n = jb.corpse + s.corpse, jb.held_n + s.held
end

-- the reason of one job in words (JOBS_SUSPENDED, build_blocked, inspect workload, trade's DEPOT_MISSING)
local function job_why(j)
  local s = j.site
  if s and s.forb + s.other + s.corpse + s.held > 0 then
    local more = {}
    if s.corpse > 0 then more[#more + 1] = s.corpse .. ' corpse' end
    if s.held > 0 then more[#more + 1] = s.held .. ' mood reserve' end
    return string.format('item blocking site: %d forbidden, %d other%s%s', s.forb, s.other + s.corpse + s.held,
                         #more > 0 and (' (' .. table.concat(more, ', ') .. ')') or '',
                         j.cancel and ('; cancelled: ' .. j.cancel) or '')
  end
  if j.planned and j.mat and j.mat ~= '' then return 'waiting for ' .. j.mat end
  if j.cancel then return 'cancelled: ' .. j.cancel end
  return j.why
end

-- the latest CANCEL_JOB report of a construction within one tile of the footprint (st.bcancel, newest last)
local function cancel_at(rc)
  if not rc then return nil end
  for i = #(st.bcancel or {}), 1, -1 do
    local e = st.bcancel[i]
    if e.z == rc.z and e.x >= rc.x1 - 1 and e.x <= rc.x2 + 1 and e.y >= rc.y1 - 1 and e.y <= rc.y2 + 1 then
      return e.why
    end
  end
end

function T.jobs(K, c, r)
  local jc = c.jobs or M.DEFAULTS.jobs
  local p = r.p
  local list, all = M.suspended_jobs(400)
  local jb = {list = list, i = 0, frees = {}, queued = {}, kept = 0, planned = 0, forb = 0, other = 0,
              corpse = 0, held_n = 0, freed = 0, freed_by = {}, sites = 0, mats = {}, mq = nil, mi = 0,
              writes = HUNT_MODES[K.mode()] == true, tried = {}}
  r.jb = jb
  for key in pairs(p.jres) do
    local id = int(key)
    if not (id and all[id]) then p.jres[key] = nil end               -- built, removed or cancelled
  end
  for _, j in ipairs(list) do
    local rec = p.jres[tostring(j.id)]
    if type(rec) == 'table' then
      if j.stage and int(rec.st) and j.stage > int(rec.st) then rec.n = 0 end   -- the building advanced
      if rec.pend == 1 then rec.n, rec.pend = (int(rec.n) or 0) + 1, 0 end    -- resumed earlier, suspended again
    end
    j.cancel = cancel_at(j.rect)
    if j.planned then jb.planned = jb.planned + 1 elseif j.kept then jb.kept = jb.kept + 1 end
  end
  K.persist.touch('m.economy')
  return true
end

function T.jsite(K, c, r)
  local jb, jc = r.jb, c.jobs or M.DEFAULTS.jobs
  if not jb or not jb.writes then return true end
  while jb.i < #jb.list do
    jb.i = jb.i + 1
    local j, rc = jb.list[jb.i], jb.list[jb.i].rect
    if rc and jb.sites < (jc.sites_per_day or 40) then
      jb.sites = jb.sites + 1
      local ok, items = K.call('snapshot', 'items_at', rc.x1, rc.y1, rc.x2, rc.y2, rc.z)
      if ok and type(items) == 'table' then site_items(K, jb, j, items) end
      r.cmds = r.cmds + 1                                             -- one footprint a frame
      if jb.i < #jb.list then return false end
    end
  end
  return true
end

-- one class a planned building waits for: the items.other vectors and a label
local BM_VECS = {'BOULDER', 'BLOCKS', 'WOOD', 'BAR'}
-- BUG-476 (Run 16b i2 Roadvises y378/y381: the temple's offering place 'waits for tool x1' 58 and 240 days, no order made the tool):
-- a TOOL a planned building asks for by use (job_item.has_tool_use) has its own class; M.TOOL_PIECES: tool_uses name ->
-- {label (the class), kind (MATERIAL_SHORT name), sub (the raws id of the tool), job}
M.TOOL_PIECES = {PLACE_OFFERING = {label = 'altar', kind = 'altar', sub = 'ITEM_TOOL_ALTAR', job = 'MakeTool'}}
M.TOOL_BY_LABEL = {altar = M.TOOL_PIECES.PLACE_OFFERING}
-- whether the tool item's definition lists the use (itemdef_toolst.tool_use)
function M.tool_has_use(it, tu)
  local ok, yes = pcall(function()
    local def = dfhack.items.getSubtypeDef(it:getType(), it:getSubtype())
    for _, u in ipairs(def.tool_use) do if u == tu then return true end end
    return false
  end)
  return ok and yes == true
end

-- the open manager orders (amount left) that make this tool piece, by the tool's raws index
function M.tool_orders(tp)
  local idx
  pcall(function()
    for i, d in ipairs(df.global.world.raws.itemdefs.tools) do
      if d.id == tp.sub then idx = i - 1; break end
    end
  end)
  local n = 0
  pcall(function()
    local jt = df.job_type[tp.job]
    for _, o in ipairs(df.global.world.manager_orders.all) do
      -- idx unknown (the raws cannot be read): every open order of the job counts, fewer orders rather than a flood
      if o.job_type == jt and (idx == nil or o.item_subtype == idx) and (math.tointeger(o.amount_left) or 0) > 0 then
        n = n + math.tointeger(o.amount_left)
      end
    end
  end)
  return n
end

function M.tool_use_name(tu)
  if math.type(tu) ~= 'integer' or tu < 0 then return nil end
  local n = df.tool_uses and df.tool_uses[tu]
  return type(n) == 'string' and n or nil
end
local function need_class(nd)
  if nd.t >= 0 then
    local n = df.item_type[nd.t]
    local tp = n == 'TOOL' and M.TOOL_PIECES[M.tool_use_name(nd.tu) or '']
    if tp then return {n}, tp.label end
    if type(n) == 'string' then return {n}, n:lower() end
  elseif nd.bm then return BM_VECS, 'building material' end
end

-- BUG-044 (Run 11 y483-y497, the seal door 115,73,143 stood open for 14 game years, status said only "stalled"): what the
-- building on one tile and its construction job wait for, read-only (the building sheet and the job list). {none = true}
-- when nothing stands there, else {id, kind, sub, stage, max, built, job, susp, work, who, planned, kept, items, need,
-- cancel, site, line}. `who` names the component that keeps a suspended job suspended: 'buildingplan' (a planned building
-- suspends its job itself until its materials are attached; a resume by hand is undone at once), 'suspendmanager'
-- (isKeptSuspended: preventblocking, water, a designation in the way), else 'DF' (the builder cancelled: the latest
-- CANCEL_JOB report near the tile, else the items on the tile, else no cause is readable). `line` is the one-line answer
-- (SEAL_STUCK wait, PROJECT_BLOCKED parts, kern.log). The classes a planned building waits for carry what the fort has:
-- free items of the class and the items its open piece orders still make (`piece_ord` = open / not validated).
-- BUG-298 (Run 15c Inkintense y374-y376: the seal door 92,99,133 'not suspended, no builder has taken it' for years with
-- 8-10 idle dwarves; the door lies outside Kern+ (y 30-73)): is the tile x,y,z outside the burrow the builders are kept
-- to? A civil alert keeps every citizen in its burrows; a burrow's unit list keeps its members there. Read-only (the
-- alerts screen, the burrows screen). {name, why = 'alert' | 'assigned', n, of, text} when the civil alert is on and the
-- tile lies in none of its burrows, or when most free adult citizens (no soldier) are assigned to burrows that all lack
-- the tile; else nil
function M.burrow_out(K, x, y, z)
  local pos = xyz2pos(x, y, z)
  local function holds(bid)
    local b = df.burrow.find(bid)
    if not b then return true end                          -- unknown: no restriction claimed
    return dfhack.burrows.isAssignedTile(b, pos) == true, dfhack.df2utf(b.name)
  end
  local al = df.global.plotinfo.alerts
  local idx = math.tointeger(al.civ_alert_idx) or 0
  if idx ~= 0 and al.list[idx] then
    local first, inside = nil, false
    for _, bid in ipairs(al.list[idx].burrows) do
      local yes, name = holds(bid)
      first = first or name
      if yes then inside = true end
    end
    if not inside and first then
      return {name = first, why = 'alert', text = string.format('outside the burrow %s (civil alert on)', first)}
    end
  end
  local cu = K.census.u
  local sold = {}
  for _, id in ipairs(type(cu) == 'table' and cu.soldier_ids or {}) do sold[id] = true end
  local free, kept, names = 0, 0, {}
  for _, id in ipairs(type(cu) == 'table' and cu.ids or {}) do
    local u = not sold[id] and df.unit.find(id)
    if u and dfhack.units.isAdult(u) then
      free = free + 1
      local any, inside, name = false, false, nil
      for _, bid in ipairs(u.burrows or {}) do
        any = true
        local yes, nm = holds(bid)
        name = name or nm
        if yes then inside = true end
      end
      if any and not inside then
        kept = kept + 1
        if name then names[name] = (names[name] or 0) + 1 end
      end
    end
  end
  if free == 0 or 2 * kept <= free then return nil end
  local best, bn = nil, 0
  for nm, c in pairs(names) do if c > bn or (c == bn and nm < best) then best, bn = nm, c end end
  best = best or '?'
  return {name = best, why = 'assigned', n = kept, of = free,
          text = string.format('outside the burrow %s (%d of %d free citizens assigned to it)', best, kept, free)}
end

-- BUG-313 (Run 15: the refuge hatches 55,82,133 (Earthboat), 89,72,137 (Drillchamber) and 86,53,126 (Inkintense) 'not
-- suspended, no builder has taken it; 1 item attached' for hundreds of days beside idle dwarves, re-placed in vain; each sits
-- on an up/down stair inside a shaft, walls on all 8 sides of its level): true when every neighbour of x,y,z on its level is
-- revealed and none is a tile a builder stands on (snapshot legend); nil when one is hidden; else false. Read-only
M.STAND_C = {['.'] = true, ['<'] = true, ['>'] = true, X = true, r = true, ['+'] = true, ['^'] = true, ['='] = true,
             w = true}
function M.boxed_in(K, x, y, z)
  for dy = -1, 1 do
    for dx = -1, 1 do
      if dx ~= 0 or dy ~= 0 then
        local ok, t = K.call('snapshot', 'tile', x + dx, y + dy, z)
        if not (ok and type(t) == 'table' and type(t.c) == 'string') then return nil end
        if M.STAND_C[t.c] then return false end
      end
    end
  end
  return true
end

-- BUG-329 (Run 15c Inkintense y374-y378: FarmPlot 86,87,133 job 152960, doors 64,47,128 / 75,34,131 / 92,99,133 and the
-- hatch 86,53,126 'not suspended, no builder has taken it' for 80 to 1,000 days beside 10-23 idle adults; Drillchamber's
-- hatch 89,72,137, Earthboat's 55,82,133): the line ended there, the reason was never named. DF gives a ConstructBuilding
-- job only to a citizen with the building's labor on, who reaches its attached items. The labor per building type is the
-- table of DFHack's labormanager (plugins/labormanager/joblabormapper.cpp, jlfunc_construct_bld: furniture, doors and
-- hatches Furniture hauling, farm plots Farming, traps and mechanisms Mechanics; workshops and constructions by material,
-- not checked here). Read-only.
M.BUILD_LABOR = {FarmPlot = 'PLANT', Hive = 'BEEKEEPING', Trap = 'MECHANIC', GearAssembly = 'MECHANIC',
                 AxleHorizontal = 'MECHANIC', AxleVertical = 'MECHANIC', Rollers = 'MECHANIC'}
for _, k in ipairs({'Chair', 'Bed', 'Table', 'Coffin', 'Door', 'Floodgate', 'Box', 'Weaponrack', 'Armorstand', 'Cabinet',
                    'Statue', 'WindowGlass', 'WindowGem', 'Cage', 'NestBox', 'TractionBench', 'Slab', 'Chain', 'GrateFloor',
                    'GrateWall', 'Hatch', 'BarsFloor', 'BarsVertical', 'Bookcase', 'Instrument', 'DisplayFurniture'}) do
  M.BUILD_LABOR[k] = 'HAUL_FURNITURE'
end
M.LABOR_WORD = {PLANT = 'Farming (fields)', HAUL_FURNITURE = 'Furniture hauling', MECHANIC = 'Mechanics',
                BEEKEEPING = 'Beekeeping'}
-- the reasons a job nobody takes may have, as far as they are readable: {'no free adult citizen has the labor ...', ...};
-- sets rec.labor = {labor, with it, free adults}, rec.nolabor (none has it), rec.item_bad (an attached item forbidden or
-- off the citizens' walk group: snapshot.far), rec.unposted (DF's job board holds it not: posting_index < 0)
function M.nobuilder_why(K, rec, j)
  local out = {}
  local ln = M.BUILD_LABOR[rec.kind or '']
  local li = ln and df.unit_labor and df.unit_labor[ln]
  local cu = K.census.u
  if type(li) == 'number' and type(cu) == 'table' then
    local sold, of, n = {}, 0, 0
    for _, id in ipairs(cu.soldier_ids or {}) do sold[id] = true end
    for _, id in ipairs(cu.ids or {}) do
      local u = not sold[id] and df.unit.find(id) or nil
      local oka, adult = pcall(function() return dfhack.units.isAdult(u) end)
      if u and oka and adult then
        of = of + 1
        local okl, has = pcall(function() return u.status.labors[li] == true end)
        if okl and has then n = n + 1 end
      end
    end
    rec.labor = {ln, n, of}
    if of > 0 and n == 0 then
      rec.nolabor = true
      out[#out + 1] = string.format('no free adult citizen has the labor %s on (0 of %d; a work detail grants it)',
                                    M.LABOR_WORD[ln] or ln, of)
    end
  end
  pcall(function()
    local k = 0
    for _, ref in ipairs(j.items) do
      local it = ref.item
      k = k + 1
      if k > 4 then break end
      local f = it and it.flags
      if f and not f.in_building then
        local ix, iy, iz = dfhack.items.getPosition(it)
        local okt, tn = pcall(function() return df.item_type[it:getType()] end)
        local what = okt and type(tn) == 'string' and tn:lower() or 'item'
        if f.forbid then
          rec.item_bad = true
          out[#out + 1] = string.format('its %s %s is forbidden', what, ix and string.format('at %d,%d,%d', ix, iy, iz) or '')
        elseif ix and far(K, ix, iy, iz) then
          rec.item_bad = true
          out[#out + 1] = string.format('its %s at %d,%d,%d lies off the citizens\' walk group', what, ix, iy, iz)
        end
      end
    end
  end)
  local okp, pi = pcall(function() return j.posting_index end)
  if okp and int(pi) and int(pi) < 0 then
    rec.unposted = true
    out[#out + 1] = 'on no DF job posting (posting_index ' .. tostring(pi) .. ')'
  end
  return out
end

function M.build_state(K, x, y, z)
  x, y, z = int(x), int(y), int(z)
  if not (x and y and z) then return nil end
  local okf, b = pcall(dfhack.buildings.findAtTile, x, y, z)
  if not (okf and b) then return {none = true, line = string.format('nothing stands at %d,%d,%d', x, y, z)} end
  local rec = {}
  building_info(rec, nil, b)
  rec.id = rec.bld
  local oks, mx = pcall(function() return b:getMaxBuildStage() end)
  rec.max = oks and int(mx) or nil
  rec.built = rec.stage ~= nil and rec.max ~= nil and rec.stage >= rec.max
  if rec.kind == 'Workshop' or rec.kind == 'Furnace' then
    local okt, sub = pcall(function() return (rec.kind == 'Workshop' and df.workshop_type or df.furnace_type)[b.type] end)
    if okt and type(sub) == 'string' then rec.sub = sub end
  end
  if rec.built then rec.line = 'built'; return rec end
  local j
  pcall(function()
    local cb = df.job_type.ConstructBuilding
    for _, jb in ipairs(b.jobs) do if jb.job_type == cb then j = jb; break end end
  end)
  if not j then rec.line = 'no construction job'; return rec end
  rec.job = j.id
  local oksu, su = pcall(function() return j.flags.suspend == true end)
  rec.susp = oksu and su
  local okw, wk = pcall(dfhack.job.getWorker, j)
  rec.work = okw and wk ~= nil
  local oki, ni = pcall(function() return #j.items end)
  rec.items = oki and int(ni) or 0
  local head = string.format('job %s', tostring(rec.job))
  if not rec.susp then
    rec.line = rec.work and (head .. ' runs: a builder works at it') or (head .. ' not suspended, no builder has taken it')
    if not rec.work then                                     -- BUG-298: the burrow the builders keep to
      local okb, bo = pcall(M.burrow_out, K, x, y, z)
      if okb and type(bo) == 'table' then
        rec.burrow, rec.bwhy = bo.name, bo.why
        rec.line = rec.line .. ': ' .. bo.text
      end
      local okx, bx = pcall(M.boxed_in, K, x, y, z)          -- BUG-313: no tile beside it to build from
      if okx and bx == true then
        rec.boxed = true
        rec.line = rec.line .. ': walled in on its level (no tile beside it to build from)'
      end
      local okn, why = pcall(M.nobuilder_why, K, rec, j)      -- BUG-329: the labor, the items, the job board
      if okn and type(why) == 'table' and #why > 0 then rec.line = rec.line .. ': ' .. table.concat(why, '; ') end
      -- BUG-679 (Run 16d i4 Trumpetrealms y444-y456: 'Door 65,121,141: job 1191999 not suspended, no builder has taken it: outside the' - the
      -- projects cut the line at 80 characters, the cause came last and never showed): the same answer, the cause first
      local cause = {}
      if rec.bwhy then cause[#cause + 1] = (rec.line:match(': (outside the burrow[^:;]*)')) or ('outside the burrow ' .. tostring(rec.burrow)) end
      if rec.boxed then cause[#cause + 1] = 'walled in on its level' end
      if okn and type(why) == 'table' then for _, w in ipairs(why) do cause[#cause + 1] = w end end
      -- BUG-721 (Run 16b i2 Whirledrampart: 'no builder has taken it (no cause readable)', 27 ConstructBuilding unclaimed beside 12 idle adults): no
      -- readable cause is a statement of what was read: the labor holders, the items attached to the job, the one way left (busy or no path)
      local nneed = 0
      pcall(function() for _, el in ipairs(j.job_items.elements) do nneed = nneed + (int(el.quantity) or 1) end end)
      local lab = type(rec.labor) == 'table' and string.format('labor %d/%d', int(rec.labor[2]) or 0, int(rec.labor[3]) or 0) or 'labor unread'
      rec.short = #cause > 0 and ('no builder: ' .. table.concat(cause, '; '))
                  or string.format('no builder took it: no cause readable (%s, items %d/%d, in burrow, not walled in); busy or no path: inspect workload, reach',
                                   lab, rec.items or 0, nneed)
    end
    return rec
  end
  local sm, bp = plugin('suspendmanager'), plugin('buildingplan')
  local plan_f = first_fn(bp, {'isPlannedBuilding'})
  local kept_f = first_fn(sm, {'isKeptSuspended', 'suspendmanager_isKeptSuspended'})
  local desc_f = first_fn(sm, {'suspensionDescription', 'suspendmanager_suspensionDescription', 'getSuspendReason'})
  if plan_f then
    local okp, v = pcall(plan_f, b)
    rec.planned = okp and v == true
  end
  if not rec.planned and kept_f then
    local okk, v = pcall(kept_f, j)
    if okk and v then
      rec.kept = true
      local okd, d = false, nil
      if desc_f then okd, d = pcall(desc_f, j) end
      rec.desc = okd and type(d) == 'string' and d ~= '' and dfhack.df2utf(d):sub(1, 60) or 'kept suspended'
    end
  end
  if rec.planned then
    rec.who, rec.need = 'buildingplan', job_missing(j)
    local parts = {}
    local inv = K.census.i or {}
    for _, nd in ipairs(rec.need) do
      local vecs, label = need_class(nd)
      label = label or 'item'
      local part = string.format('%s x%d', label, nd.n)
      local e = M.PIECES[label]
      local key = vecs and nd.t >= 0 and M.PIECE_INV[df.item_type[nd.t] or '']
      if e or key then
        local tail = {}
        if key then tail[#tail + 1] = string.format('%d free', int(inv[key]) or 0) end
        if e then
          local jt, n, uv = df.job_type[e.job], 0, 0
          for _, o in ipairs(orders_all()) do
            if o.job_type == jt and (int(o.amount_left) or 0) > 0 then
              n = n + int(o.amount_left)
              local okv, valid = pcall(function() return o.status.validated end)
              if okv and valid == false then uv = uv + int(o.amount_left) end
            end
          end
          rec.piece_ord = {n, uv}
          tail[#tail + 1] = string.format('%d ordered', n) .. (uv > 0 and string.format(', %d not validated', uv) or '')
        end
        part = part .. ' (' .. table.concat(tail, ', ') .. ')'
      end
      parts[#parts + 1] = part
    end
    rec.line = string.format('%s suspended by buildingplan: waits for %s', head,
                             #parts > 0 and table.concat(parts, ', ') or 'its materials')
  elseif rec.kept then
    rec.who = 'suspendmanager'
    rec.line = string.format('%s suspended by suspendmanager: %s', head, rec.desc)
  else
    rec.who = 'DF'
    rec.cancel = cancel_at(rec.rect)
    local bits = {}
    if rec.cancel then bits[#bits + 1] = 'cancelled "' .. rec.cancel .. '"' end
    if rec.rect then
      local oki2, items = K.call('snapshot', 'items_at', rec.rect.x1, rec.rect.y1, rec.rect.x2, rec.rect.y2, rec.rect.z)
      if oki2 and type(items) == 'table' then
        local site = {forb = 0, other = 0}
        for _, e in ipairs(items) do
          local it = df.item.find(int(e[1]) or -1)
          local f = it and it.flags
          if f and not (f.in_job or f.in_building or f.trader or f.removed or f.garbage_collect or f.construction) then
            if f.forbid then site.forb = site.forb + 1 else site.other = site.other + 1 end
          end
        end
        rec.site = site
        if site.forb + site.other > 0 then
          bits[#bits + 1] = string.format('%d forbidden and %d other items on the tile', site.forb, site.other)
        end
      end
      -- BUG-329 (Earthboat y383-y384: refuge hatches on the refuge stair 'suspended by DF ... no cause readable'): DF
      -- suspends a construction whose site a creature stands on; the citizens standing there now (a stair the fort walks)
      local okw, nu = pcall(function()
        local rc, c, cu = rec.rect, 0, K.census.u
        for _, id in ipairs(type(cu) == 'table' and cu.ids or {}) do
          local u = df.unit.find(id)
          local ux, uy, uz
          if u then ux, uy, uz = dfhack.units.getPosition(u) end
          if uz == rc.z and ux and ux >= rc.x1 and ux <= rc.x2 and uy >= rc.y1 and uy <= rc.y2 then c = c + 1 end
        end
        return c
      end)
      if okw and int(nu) and nu > 0 then
        rec.units = nu
        bits[#bits + 1] = string.format('%d citizen%s on the site now (a walked tile: DF suspends it)', nu,
                                        nu == 1 and '' or 's')
      end
      -- BUG-679 (Run 16d i4 Trumpetrealms: depot4 / depot5 'suspended by DF ... no cause readable' 32-53 days while the stuck merchants of the
      -- last caravan stood at 84,77,139, on the depot's own footprint): a creature of any kind on the site suspends it, not only a citizen
      local oko, tot, names = pcall(function()
        local rc, kinds, n = rec.rect, {}, 0
        local okq, us = K.call('snapshot', 'units_at', rc.x1, rc.y1, rc.x2, rc.y2, rc.z)       -- the visible living units there
        for _, e in ipairs(okq and type(us) == 'table' and us or {}) do
          local u = df.unit.find(e[1])
          if u and not dfhack.units.isCitizen(u) then
            local k = dfhack.units.isMerchant(u) and 'merchant' or dfhack.units.isInvader(u) and 'invader'
                      or dfhack.units.isAnimal(u) and 'animal' or 'other'
            kinds[k] = (kinds[k] or 0) + 1
            n = n + 1
          end
        end
        local list = {}
        for k, c in pairs(kinds) do list[#list + 1] = string.format('%d %s', c, k) end
        table.sort(list)
        return n, table.concat(list, ', ')
      end)
      if oko and int(tot) and tot > 0 then
        rec.foreign = tot
        bits[#bits + 1] = string.format('%d other creature%s on the site now (%s): DF suspends a construction a creature stands on', tot,
                                        tot == 1 and '' or 's', names)
      end
    end
    rec.line = string.format('%s suspended by DF (not buildingplan, not suspendmanager): %s', head,
                             #bits > 0 and table.concat(bits, '; ') or 'no cause readable')
    rec.short = 'suspended by DF: ' .. (#bits > 0 and table.concat(bits, '; ') or 'no cause readable (resumed daily)')   -- BUG-679: cause first
  end
  if rec.who == 'buildingplan' or rec.who == 'suspendmanager' then rec.short = (rec.line:gsub('^job %S+ ', '')) end   -- BUG-679: no job id first
  return rec
end

-- one usable loose item of a class: {free = not forbidden, take = forbidden and fit to unforbid}
local function mat_item(K, jb, it, nd)
  local f = it.flags
  for _, k in ipairs(MAT_BUSY) do if f[k] then return nil end end
  if nd.mt >= 0 and (it.mat_type ~= nd.mt or (nd.mi >= 0 and it.mat_index ~= nd.mi)) then return nil end
  if nd.tu and not M.tool_has_use(it, nd.tu) then return nil end         -- BUG-476
  if CORPSE_T[tname(it) or ''] then return nil end
  if not f.forbid then return 'free' end
  if held_set(K, jb)[it.id] or jb.queued[it.id] then return nil end
  local x, y, z = dfhack.items.getPosition(it)
  if not x or not known_tile(K, x, y, z) or far(K, x, y, z) then return nil end
  return 'take'
end

function T.jmat(K, c, r)
  local jb, jc = r.jb, c.jobs or M.DEFAULTS.jobs
  if not jb then return true end
  if not jb.mq then                                   -- the classes the planned buildings wait for, summed
    jb.mq = {}
    local by = {}
    for _, j in ipairs(jb.list) do
      local labels = {}
      for _, nd in ipairs(j.need or {}) do
        local vecs, label = need_class(nd)
        label = label or 'item'
        labels[#labels + 1] = string.format('%s x%d', label, nd.n)
        if vecs then
          local fire = nd.bm and j.fire == true or nil      -- BUG-466: the fire-safe building material of a furnace / forge is its own class
          local key = string.format('%s:%d:%d%s', label, nd.mt, nd.mi, fire and ':fire' or '')
          local q = by[key]
          if not q then
            q = {key = key, label = label, vecs = vecs, mt = nd.mt, mi = nd.mi, n = 0, free = 0, forb = 0, jobs = {}, fire = fire,
                 tu = M.TOOL_BY_LABEL[label] and nd.tu or nil}      -- BUG-476: a tool class counts only tools of that use
            by[key] = q
            jb.mq[#jb.mq + 1] = q
          end
          q.n = q.n + nd.n
          q.jobs[#q.jobs + 1] = j
        end
      end
      j.mat = table.concat(labels, ', ')
    end
    table.sort(jb.mq, function(a, b) return a.key < b.key end)
  end
  jb.mi = jb.mi + 1
  local q = jb.mq[jb.mi]
  if not q then return true end
  local budget, take = jc.mat_scan or 2000, 0
  for _, vn in ipairs(q.vecs) do
    local okv, v = pcall(function() return df.global.world.items.other[vn] end)
    for _, it in ipairs(okv and v or {}) do
      if budget <= 0 then break end
      budget = budget - 1
      local ok, kind = pcall(mat_item, K, jb, it, q)
      if ok and kind == 'free' then q.free = q.free + 1
      elseif ok and kind == 'take' then
        q.forb = q.forb + 1
        if jb.writes and take < q.n then
          take = take + 1
          queue_free(jb, it.id, 'material')
        end
      end
    end
  end
  local tail = q.forb > 0 and string.format(' (%d forbidden%s)', q.forb, jb.writes and ', unforbidding' or '')
               or (q.free > 0 and string.format(' (%d free)', q.free) or ' (none in reach: missing)')
  for _, j in ipairs(q.jobs) do j.mat = (j.mat or '') .. tail end
  if q.forb == 0 and q.free == 0 then jb.mats[#jb.mats + 1] = string.format('%s x%d', q.label, q.n) end
  r.cmds = r.cmds + 1                                 -- one class a frame
  return jb.mi >= #jb.mq
end

function T.jfree(K, c, r)
  local jb, jc = r.jb, c.jobs or M.DEFAULTS.jobs
  if not jb or not jb.writes then return true end
  local lim = jc.unforbid_per_day or 60
  while #jb.frees > 0 and jb.freed < lim do
    local e = table.remove(jb.frees, 1)
    local it = df.item.find(e.id)
    if it and e.why == 'corpse' then                  -- BUG-405: a stranger's corpse on a site: unforbidden and dumped
      r.cmds = r.cmds + 1
      local ok = true
      if it.flags.forbid then ok = K.act.item_flag(e.id, 'forbid', false) and ok end
      if ok and not it.flags.dump and K.act.item_flag(e.id, 'dump', true) then
        jb.freed_by.corpse = (jb.freed_by.corpse or 0) + 1
      end
      return #jb.frees == 0 or jb.freed >= lim
    elseif it and it.flags.forbid then
      r.cmds = r.cmds + 1
      if K.act.item_flag(e.id, 'forbid', false) then
        jb.freed = jb.freed + 1
        jb.freed_by[e.why] = (jb.freed_by[e.why] or 0) + 1
      end
      return #jb.frees == 0 or jb.freed >= lim
    end
  end
  return true
end

function T.jresume(K, c, r)
  local jb, jc = r.jb, c.jobs or M.DEFAULTS.jobs
  if not jb then return true end
  for _, j in ipairs(jb.list) do
    if not j.planned and not j.kept and #jb.tried < (jc.release_per_day or 20) then jb.tried[#jb.tried + 1] = j.id end
  end
  if #jb.tried > 0 and jb.writes then
    r.cmds = r.cmds + 1                               -- jcheck reads the flags in the next frame
    local ok, n = K.act.job_resume(jb.tried)
    jb.sent = ok and (int(n) or 0) or 0
  else
    jb.tried = {}
  end
  return true
end

-- the flags of these construction jobs now: {[id] = true} for the suspended ones
local function suspended_now(ids)
  local want, out = {}, {}
  for _, id in ipairs(ids) do want[id] = true end
  if next(want) == nil then return out end
  pcall(function()
    local link, i = df.global.world.jobs.list.next, 0
    while link and i < 50000 do
      local j = link.item
      if j and want[j.id] and j.flags.suspend then out[j.id] = true end
      link, i = link.next, i + 1
    end
  end)
  return out
end

-- a trade depot that keeps failing (BUG-005): a new site, at most every move_days, PEACE only, and only without a
-- fortcore manifest depot (the bailey is the design there: the operator decides)
local function depot_move_due(K, jc, p, j, rec)
  if j.kind ~= 'TradeDepot' or (int(rec.n) or 0) < (jc.depot_move_after or 5) or K.mode() ~= 'PEACE' then return false end
  if type(K.manifest().depot) == 'table' then return false end
  local t = int(p.depot_moved)
  return t == nil or K.now().tick - t >= (jc.move_days or 28) * DAY
end

function T.jcheck(K, c, r)
  local jb, jc, p = r.jb, c.jobs or M.DEFAULTS.jobs, r.p
  if not jb then return true end
  local now = K.now().tick
  local again = suspended_now(jb.tried)
  local resumed, failed = 0, 0
  local tried = {}
  for _, id in ipairs(jb.tried) do tried[id] = true end
  st.jinfo = {}
  local blocked, toks, why_cnt = {}, {}, {}
  for _, j in ipairs(jb.list) do
    local key = tostring(j.id)
    local rec = p.jres[key]
    if type(rec) ~= 'table' then rec = {n = 0, r = 0, t = now}; p.jres[key] = rec end
    rec.k, rec.b, rec.st = j.kind or 'building', j.bld or -1, j.stage
    if j.rect then rec.x, rec.y, rec.z = j.rect.x1, j.rect.y1, j.rect.z end
    if tried[j.id] then
      rec.r = (int(rec.r) or 0) + 1
      if again[j.id] then rec.n, failed = (int(rec.n) or 0) + 1, failed + 1   -- suspended again within a frame
      else rec.pend, resumed = 1, resumed + 1 end
    end
    local why = job_why(j)
    rec.why = why:sub(1, 80)
    local kind = j.planned and 'buildingplan: waiting for materials' or (j.site and (j.site.forb + j.site.other +
                 j.site.corpse + j.site.held) > 0 and 'item blocking site') or (j.cancel and 'cancelled: ' .. j.cancel)
                 or j.why
    why_cnt[kind:sub(1, 60)] = (why_cnt[kind:sub(1, 60)] or 0) + 1
    if j.bld then st.jinfo[j.bld] = {fails = int(rec.n) or 0, resumes = int(rec.r) or 0, why = rec.why, kind = rec.k} end
    if (int(rec.n) or 0) >= (jc.fail_alarm or 3) then
      blocked[#blocked + 1] = {j = j, rec = rec}
      local tk = why:match('^([%a ]+)') or why
      toks[#toks + 1] = (tk:gsub('%s+$', ''))
      if not jb.move and depot_move_due(K, jc, p, j, rec) then jb.move = {j = j, rec = rec} end
    end
  end
  K.persist.touch('m.economy')
  -- JOBS_SUSPENDED (B): when the numbers or the reasons change, never the same line every day
  local why = why_line(why_cnt, 3)
  local extra = ''
  if jb.forb + jb.other > 0 then
    extra = string.format('; on the sites %d forbidden (%d unforbidden), %d other', jb.forb, jb.freed_by.site or 0,
                          jb.other)
  end
  if (jb.freed_by.corpse or 0) > 0 then extra = extra .. string.format('; %d corpses on sites marked for dumping', jb.freed_by.corpse) end
  if (jb.freed_by.material or 0) > 0 then extra = extra .. string.format('; %d materials unforbidden', jb.freed_by.material) end
  if #jb.mats > 0 then extra = extra .. '; missing ' .. table.concat(jb.mats, ', ') end
  local sig = string.format('%d/%d/%d/%d/%d/%d/%s', #jb.list, resumed, failed, jb.kept, jb.planned, #blocked, why .. extra)
  if sig ~= st.jobs_sig and (#jb.list > 0 or resumed > 0) then
    K.emit('JOBS_SUSPENDED', 'B', string.format('construction jobs: %d suspended, %d resumed, %d suspended again, %d kept, '
                                                .. '%d planned (%s)%s', #jb.list, resumed, failed, jb.kept, jb.planned,
                                                why, extra):sub(1, 200),
           {suspended = #jb.list, released = resumed, resuspended = failed, kept = jb.kept, planned = jb.planned,
            why = why:sub(1, 200), forbidden = jb.forb, other = jb.other, unforbidden = jb.freed,
            missing = table.concat(jb.mats, ', '):sub(1, 200), blocked = #blocked})
  end
  st.jobs_sig = sig
  local list = {}
  for i = 1, math.min(8, #blocked) do
    local b = blocked[i]
    list[i] = {job = b.j.id, kind = b.rec.k, pos = b.j.rect and {b.j.rect.x1, b.j.rect.y1, b.j.rect.z} or nil,
               fails = int(b.rec.n) or 0, why = b.rec.why}
  end
  st.jobs = {suspended = #jb.list, released = resumed, resuspended = failed, kept = jb.kept, planned = jb.planned,
             why = why_cnt, forbidden = jb.forb, other = jb.other, unforbidden = jb.freed, missing = jb.mats,
             blocked = list}
  -- DECISION_NEEDED build_blocked (A): jobs whose resumes did not hold fail_alarm times, with the reason; again only
  -- for another job or reason, not before max(7 game days, 10 min wall clock) (BUG-008 rule)
  if #blocked > 0 then
    local ids = {}
    for i, b in ipairs(blocked) do ids[i] = b.j.id end
    table.sort(toks)
    local T0 = K.now()
    if CAD.due(p.jblk, T0, ids, toks) then
      p.jblk = CAD.mark(T0, ids, toks)
      local b = blocked[1]
      local at = b.j.rect and string.format(' at %d,%d,%d', b.j.rect.x1, b.j.rect.y1, b.j.rect.z) or ''
      local q = string.format('%d construction job(s) suspended again after %d+ resumes: %s%s (%s)%s; inspect workload, '
                              .. 'remove the blocker or bp.cancel and place it elsewhere', #blocked, jc.fail_alarm or 3,
                              b.rec.k, at, b.rec.why, #blocked > 1 and string.format(' and %d more', #blocked - 1) or '')
      K.emit('DECISION_NEEDED', 'A', q:sub(1, 200), {id = 'build_blocked', q = q:sub(1, 200), n = #blocked, jobs = ids})
    end
  else
    p.jblk = CAD.quiet(p.jblk)
  end
  -- jobs suspendmanager keeps suspended for held_days: preventblocking is the fort's decision; asked once, again
  -- only when more jobs are kept, not before max(7 game days, 10 min wall clock) (BUG-008 rule)
  if jb.kept > 0 then p.held = p.held or r.now else p.held = nil end
  local held = p.held and (r.now - p.held) // DAY or 0
  local kept_ids = {}
  for _, j in ipairs(jb.list) do if j.kept then kept_ids[#kept_ids + 1] = j.id end end
  local T1 = K.now()
  local last = p.held_woke and {t = p.held_woke, w = p.held_woke_w, ids = p.held_ids or {}, toks = {}} or nil
  if p.held and held >= (jc.held_days or 3) and pb_choice(c, p) ~= 'off' and CAD.due(last, T1, kept_ids, {}) then
    p.held_woke, p.held_woke_w, p.held_ids = r.now, T1.wall, kept_ids
    K.emit('DECISION_NEEDED', 'A', string.format('%d construction jobs kept suspended by suspendmanager for %d days',
                                                 jb.kept, held),
           {id = 'preventblocking', q = string.format('%d jobs kept suspended (%s): jobs.release {"preventblocking":false} ' ..
                                                      'lets them build, or remove what blocks them?', jb.kept, why):sub(1, 200)})
  end
  return true
end

-- BUG-005 (Run 9: the depot site at the shaft head, where armies and wild animals pass, never got built and four
-- caravans left without trade): after depot_move_after failed resumes the depot moves inside the entrance, off the
-- army route. The new 5x5 footprint lies inside a free ring (7x7 of revealed roofed floor without designation or
-- building), at least move_gap tiles from every entrance and from the manifest's approach (outer bridges, Z1/Z2,
-- kill boxes, edge), on the citizens' walk group and reachable from its entrance, with no item on it. Searched: up
-- to two entrances (seal.entrances), move_r tiles around each on its level and move_dz levels below, move_probes
-- tile reads a frame; the fit nearest to its entrance wins, then runner.depot_move removes the stuck depot and
-- queues the new one.
local function approach_of(m)
  local boxes = {}
  for _, b in pairs(type(m.bridges) == 'table' and m.bridges or {}) do
    if type(b) == 'table' and b.role == 'outer' and type(b.fp) == 'table' then boxes[#boxes + 1] = b.fp end
  end
  for _, k in ipairs({'Z1', 'Z2'}) do
    for _, bb in ipairs((type(m.zones) == 'table' and m.zones[k]) or {}) do boxes[#boxes + 1] = bb end
  end
  for _, kb in ipairs(type(m.killboxes) == 'table' and m.killboxes or {}) do
    if type(kb) == 'table' and type(kb.bbox) == 'table' then boxes[#boxes + 1] = kb.bbox end
  end
  for _, e in ipairs(type(m.edge) == 'table' and m.edge or {}) do
    if type(e) == 'table' and int(e[1]) then boxes[#boxes + 1] = {e[1], e[2], e[3], e[1], e[2], e[3]} end
  end
  return boxes
end

-- the 5x5 footprint centred on (cx, cy) keeps gap tiles from every entrance and approach box (one z either way)
local function off_route(mv, cx, cy, z, gap)
  for _, e in ipairs(mv.all) do
    if math.abs(e[3] - z) <= 1 and math.max(math.abs(e[1] - cx), math.abs(e[2] - cy)) - 2 < gap then return false end
  end
  for _, b in ipairs(mv.boxes) do
    local x0, y0, z0, x1, y1, z1 = int(b[1]), int(b[2]), int(b[3]), int(b[4]), int(b[5]), int(b[6])
    if x0 and y0 and z0 and x1 and y1 and z1 and z >= z0 - 1 and z <= z1 + 1 and cx + 2 >= x0 - gap
       and cx - 2 <= x1 + gap and cy + 2 >= y0 - gap and cy - 2 <= y1 + gap then return false end
  end
  return true
end

-- the 7x7 free squares of a scanned level as candidates {x, y, z, d, e}
local function level_sites(mv, L, gap)
  local ok = function(i, j) return i >= 0 and j >= 0 and i < L.w and j < L.h and L.g[j * L.w + i] == true end
  for j = 3, L.h - 4 do
    for i = 3, L.w - 4 do
      local fit = true
      for dj = -3, 3 do
        for di = -3, 3 do if not ok(i + di, j + dj) then fit = false; break end end
        if not fit then break end
      end
      local cx, cy = L.x0 + i, L.y0 + j
      if fit and off_route(mv, cx, cy, L.z, gap) then
        mv.cands[#mv.cands + 1] = {cx, cy, L.z, d = math.max(math.abs(cx - L.e[1]), math.abs(cy - L.e[2]))
                                   + 8 * math.abs(L.z - L.e[3]), e = L.e}
      end
    end
  end
end

local function move_done(K, jc, r)
  local jb, p = r.jb, r.p
  local mv, mvj = jb.mv or {}, jb.move
  local now = K.now().tick
  p.depot_try = now
  table.sort(mv.cands or {}, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    if a[3] ~= b[3] then return a[3] > b[3] end
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
  local pick
  for i, cnd in ipairs(mv.cands or {}) do
    if i > 6 then break end
    local okf, isfar = K.call('snapshot', 'far', cnd[1], cnd[2], cnd[3])
    local okr, reach = K.call('snapshot', 'reach', {x = cnd.e[1], y = cnd.e[2], z = cnd.e[3]},
                              {x = cnd[1], y = cnd[2], z = cnd[3]})
    local oki, items = K.call('snapshot', 'items_at', cnd[1] - 2, cnd[2] - 2, cnd[1] + 2, cnd[2] + 2, cnd[3])
    if not (okf and isfar == true) and not (okr and reach == false) and not (oki and type(items) == 'table' and #items > 0) then
      pick = cnd
      break
    end
  end
  local rc = mvj.j.rect
  local from = rc and string.format('%d,%d,%d', rc.x1 + 2, rc.y1 + 2, rc.z) or '?'
  if not pick then
    local why = mv.fail or string.format('no free 7x7 roofed floor within %d tiles of %d entrance(s)', jc.move_r or 12,
                                         #(mv.ents or {}))
    st.depot_move = {from = from, ok = 0, why = why}
    K.log('warn', 'trade depot at %s stuck after %d failed resumes (%s): no new site: %s', from, int(mvj.rec.n) or 0,
          mvj.rec.why or '?', why)
    return true
  end
  local okc, ok, res = K.call('runner', 'depot_move', {pick[1], pick[2], pick[3]},
                              string.format('stuck after %d failed resumes: %s', int(mvj.rec.n) or 0, mvj.rec.why or '?'),
                              rc and {rc.x1, rc.y1, rc.z} or nil)
  if okc and ok then
    p.depot_moved = now
    st.depot_move = {from = from, to = string.format('%d,%d,%d', pick[1], pick[2], pick[3]), ok = 1,
                     proj = tostring(res)}
    K.log('warn', 'trade depot moved from %s to %d,%d,%d (%s): %s', from, pick[1], pick[2], pick[3], tostring(res),
          mvj.rec.why or '?')
  else
    st.depot_move = {from = from, ok = 0, why = tostring(okc and res or ok)}
    K.log('warn', 'trade depot move from %s failed: %s', from, tostring(okc and res or ok))
  end
  return true
end

function T.jmove(K, c, r)
  local jb, jc, p = r.jb, c.jobs or M.DEFAULTS.jobs, r.p
  if not jb or not jb.move then return true end
  if not jb.mv then
    if int(p.depot_try) and K.now().tick - int(p.depot_try) < 7 * DAY then return true end   -- a search found nothing lately
    local okc, ents = K.call('seal', 'entrances')
    local mv = {ents = {}, all = {}, q = {}, qi = 1, cands = {}, boxes = approach_of(K.manifest())}
    for _, e in ipairs(okc and type(ents) == 'table' and ents or {}) do
      local x, y, z = int(type(e) == 'table' and e[1]), int(type(e) == 'table' and e[2]), int(type(e) == 'table' and e[3])
      if x and y and z then
        mv.all[#mv.all + 1] = {x, y, z}
        if #mv.ents < 2 then mv.ents[#mv.ents + 1] = {x, y, z} end
      end
    end
    for _, e in ipairs(mv.ents) do
      for dz = 0, -(jc.move_dz or 2), -1 do mv.q[#mv.q + 1] = {e = e, z = e[3] + dz} end
    end
    if #mv.ents == 0 then mv.fail = 'no entrance known (seal.entrances)' end
    jb.mv = mv
  end
  local mv = jb.mv
  local L = mv.L
  if not L then
    local q = mv.q[mv.qi]
    if not q then return move_done(K, jc, r) end
    local R = jc.move_r or 12
    L = {x0 = q.e[1] - R, y0 = q.e[2] - R, w = 2 * R + 1, h = 2 * R + 1, z = q.z, e = q.e, g = {}, j = 0}
    mv.L = L
  end
  local probes = jc.move_probes or 150
  while L.j < L.h and probes > 0 do
    local y, row = L.y0 + L.j, {}
    for i = 0, L.w - 1 do
      local ok, t = K.call('snapshot', 'tile', L.x0 + i, y, L.z)
      if not ok then
        mv.fail, mv.qi, mv.L = 'no tile reader', #mv.q + 1, nil
        r.cmds = r.cmds + 1
        return false
      end
      if type(t) == 'table' and t.c == '.' and (t.dig or '') == '' and (t.bld or '') == '' then row[#row + 1] = i end
    end
    probes = probes - L.w
    if #row > 0 then                                  -- roofed floor only (one open-sky query per row)
      local pts = {}
      for k, i in ipairs(row) do pts[k] = {L.x0 + i, y, L.z} end
      local ok, res = K.call('snapshot', 'outside_near', pts, 0)
      for k = 1, #row do
        if not (ok and type(res) == 'table' and res[k] == 0) then row[k] = false end
      end
    end
    for _, i in ipairs(row) do if i then L.g[L.j * L.w + i] = true end end
    L.j = L.j + 1
  end
  r.cmds = r.cmds + 1                                 -- move_probes tile reads a frame
  if L.j < L.h then return false end
  level_sites(mv, L, jc.move_gap or 3)
  mv.L, mv.qi = nil, mv.qi + 1
  return false
end

-- public (K.call, trade's DEPOT_MISSING): the last daily pass on the construction job of building bld_id:
-- {fails = resumes that did not hold, resumes, why, kind} or nil when it was not suspended then
function M.build_info(K, bld_id)
  local e = (st.jinfo or {})[int(bld_id) or -1]
  if not e then return nil end
  return {fails = e.fails, resumes = e.resumes, why = e.why, kind = e.kind}
end

-- the fort's preventblocking decision applied once per boot (suspendmanager set preventblocking ...)
function T.pb(K, c, r)
  local want = pb_choice(c, r.p)
  if not want or st.pb == want then return true end
  r.cmds = r.cmds + 1
  if K.act.run('suspendmanager', 'set', 'preventblocking', want == 'on' and 'true' or 'false') then
    st.pb = want
    K.log('info', 'suspendmanager preventblocking %s (fort decision)', want)
  end
end

-- FR-40 (daily): ids of dead or departed citizens leave every work detail
function T.prune(K, c, r)
  local cu = K.census.u
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' or #cu.ids == 0 then return true end
  local alive, stale = {}, 0
  for _, id in ipairs(cu.ids) do alive[id] = true end
  pcall(function()
    for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do
      for _, id in ipairs(w.assigned_units) do if not alive[id] then stale = stale + 1 end end
    end
  end)
  if stale == 0 or st.pruned == stale then return true end
  r.cmds = r.cmds + 1
  local ok, n = K.act.work_detail_prune(cu.ids)
  st.pruned = stale                       -- insane or resident members stay: no daily repeat for them
  if ok and (math.tointeger(n) or 0) > 0 then
    K.log('info', 'work details: %d ids of dead or departed citizens removed', n)
    st.pruned = stale - n
  end
end

-- FR-17 (daily): every empty season slot of a built farm plot gets a crop that grows then and there
function T.farmslots(K, c, r)
  if not r.fills then
    r.fills = farm_fills(K, (c.farms or M.DEFAULTS.farms).per_day or 16, nil, M.food_low(c, r), M.fiber_plan(K, c, r),
                         M.cook_plan(K, c, r))
    if K.census.i and st.farm then K.census.i.farm_plots, K.census.i.farm_empty = st.farm.plots, st.farm.empty end
    r.filled = 0
  end
  local f = table.remove(r.fills, 1)
  if not f then
    if r.filled > 0 then K.log('info', 'farm plots: %d empty season slots filled', r.filled) end
    return true
  end
  r.cmds = r.cmds + 1
  if K.act.farm_crop(f.id, f.s, f.crop) then r.filled = r.filled + 1; M.af_note(r.p, f) end
  return #r.fills == 0 and r.filled == 0
end

-- BUG-618: food that fell over food.trend_days (food_plan's st.food.falling) and stands under twice the pre-alarm line, before the
-- pre-alarm itself: only the caravans' wants use it
function M.food_early(c, r)
  local pre = (c.food or {}).pre_days or 30
  local fd = (r.days or {}).food_d or 9999
  return pre > 0 and fd >= pre and fd < 2 * pre and type(st.food) == 'table' and st.food.falling == true
end

-- food below the pre-alarm line (or a famine): the slots take the edible crops first, autofarm steps aside
function M.food_low(c, r)
  return ((r.days or {}).food_d or 9999) < ((c.food or {}).pre_days or 30) or (r.p and r.p.famine ~= nil) or M.gap_low(c, r) or false
end

-- BUG-716 (Run 16c i3 Wallfree / Doorwings y377-y380 and y426-y432: the autumn harvest gave 119 food days, the winter froze the water, the fish
-- were gone, the stock ran out in the spring every year: food 129 -> 0 days before the first spring crop): in AUTUMN and WINTER a stock under
-- `food.gap_days` (110, 0 = off: about the winter and the spring until the first crop) counts as low, so the edible crops come first, the
-- caravans are asked for food, the kitchen and butcher are requested and the hunters hunt, long before the 30-day pre-alarm. Never a DECISION
-- of its own (food_pre and the famine keep their own lines).
function M.gap_low(c, r)
  local gd = (c.food or {}).gap_days
  if gd == nil then gd = 110 end
  if type(gd) ~= 'number' or gd <= 0 or type(r.now) ~= 'number' then return false end
  local season = (r.now % 403200) // 100800
  return (season == 2 or season == 3) and ((r.days or {}).food_d or 9999) < gd
end

-- BUG-058 (Run 13 y512: the slot of the running season was -1 again 30 s after the kernel set it): the slots the kernel
-- wrote are remembered (p.af.fs: 'plot:season' -> crop), and a later pass counts the ones found emptied or changed
function M.af_note(p, f)
  if type(p.af) ~= 'table' then p.af = {} end
  if type(p.af.fs) ~= 'table' then p.af.fs = {} end
  p.af.fs[tostring(f.id) .. ':' .. f.s] = f.crop
end

function M.af_wiped(p)
  local af = p.af
  if type(af) ~= 'table' or type(af.fs) ~= 'table' then return 0, 0 end
  local n, gone = 0, 0
  for key, crop in pairs(af.fs) do
    local id, s = key:match('^(%d+):(%d)$')
    local b = id and df.building.find(math.tointeger(tonumber(id)))
    local cur = nil
    if b then pcall(function() cur = b.plant_id[math.tointeger(tonumber(s))] end) end
    if cur == nil then af.fs[key] = nil; gone = gone + 1
    elseif cur ~= crop then
      n = n + 1
      af.fs[key] = nil
    end
  end
  return n, gone
end

-- BUG-058: the kernel is the sole writer of the season slots. farms.autofarm 'auto': autofarm is disabled below
-- af_off_days food days (it sets a slot to -1 when its own counts say nothing is short) or when slots the kernel wrote
-- were emptied or changed again, and enabled again from af_on_days food days after af_hold_days, never after two wipes;
-- 'off': disabled at every boot; 'keep': never touched. One DFHack command a player may run (disable / enable autofarm).
-- Returns true when it issued a command.
function M.af_policy(K, c, r, wiped)
  local fc = c.farms or M.DEFAULTS.farms
  local mode = fc.autofarm or 'auto'
  local p = r.p
  if mode == 'keep' then st.af_off = false; return false end
  if type(p.af) ~= 'table' then p.af = {} end
  local af = p.af
  local fd = (r.days or {}).food_d or 9999
  if wiped > 0 then af.wiped = (math.tointeger(af.wiped) or 0) + wiped end
  local off = tonumber(af.off)
  local want, why
  if mode == 'off' then want, why = true, 'config'
  elseif off then
    local back = r.now - off >= (fc.af_hold_days or 14) * DAY and fd >= (fc.af_on_days or 90) and not p.famine and
                 (math.tointeger(af.wiped) or 0) < 2
    want = not back
  else
    want = fd < (fc.af_off_days or 30) or wiped > 0
    why = wiped > 0 and string.format('%d season slots it emptied or changed again', wiped) or
          string.format('food %d days', fd)
  end
  st.af_off = want and true or false
  if want and (not off or not st.af_sent) then
    st.af_sent = true
    if K.act.run('disable', 'autofarm') then
      if not off then
        af.off, af.why = r.now, why
        K.log('warn', 'autofarm disabled (%s): the kernel fills the season slots', why)
      end
    end
    return true
  elseif not want and off then
    if K.act.run('enable', 'autofarm') then
      af.off, af.why, st.af_sent = nil, nil, nil
      K.log('info', 'autofarm enabled again (food %d days)', fd)
    end
    return true
  end
  return false
end

-- BUG-058 (Run 13 y512/513): the slots of the running season are filled at once, right after the census (the daily
-- farmslots task sits near the end of the run and the module was demoted: 8 plots stood at -1 for weeks), the edible crops
-- first when food is low, and a crop of the wrong kind for the plot (surface crops underground) is replaced
function T.slotnow(K, c, r)
  local fc = c.farms or M.DEFAULTS.farms
  if not r.sn then
    local wiped = M.af_wiped(r.p)
    r.sn = {issued = false, wiped = wiped}
    if M.af_policy(K, c, r, wiped) then r.cmds = r.cmds + 1; r.sn.issued = true; return false end
  end
  local sn = r.sn
  if not sn.fills then
    local fp = M.fiber_plan(K, c, r)
    M.fiber_note(K, c, r, fp)
    sn.fills = farm_fills(K, fc.now_max or 24, K.now().season, M.food_low(c, r), fp, M.cook_plan(K, c, r))
    sn.n = 0
  end
  local f = table.remove(sn.fills, 1)
  if not f then
    if sn.n > 0 then
      K.log('info', 'farm plots: %d slots of the running season filled at once%s', sn.n,
            M.food_low(c, r) and ' (food low: edible crops first)' or '')
    end
    return true
  end
  r.cmds = r.cmds + 1
  if K.act.farm_crop(f.id, f.s, f.crop) then sn.n = sn.n + 1; M.af_note(r.p, f) end
  return false
end

-- FR-23/FR-50 (daily, PEACE/RECOVERY): forbidden containers of drink/food/seeds and forbidden seeds on revealed,
-- reachable tiles are unforbidden; in a starvation forbidden food too (FR-25)
-- BUG-506 (Run 16a i1 Basementflew y406, 2015 drink units forbidden for ~100 days, 'drink 4-15 d' beside 736 d): after
-- the siege the mode flipped PEACE <-> ALERT for a wandering predator (events: MODE PEACE>ALERT hostile / ALERT>PEACE
-- quiet, ~129k ticks); this daily task ran only in PEACE / RECOVERY, so the one unforbid came at the first quiet day.
-- ALERT and DRILL (the fort is inside, nothing hostile is near the stock) unforbid too; SIEGE / BREACH still do not.
-- BUG-570 (Run 16b i2 Brotherarrow y406: forbidden food 'unforbid held back: mode SIEGE' beside 78-82 hungry, 9 dead): ... except in a
-- SIEGE whose lockdown has a hunger or thirst emergency (siege.starve_state): food and drink are unforbidden then, up to 200 a day.
-- The forbidden stock's age (dfd, days) and what held the unforbid back (dfwhy) go into the state's stock.
M.FORBID_MODES = {PEACE = true, RECOVERY = true, ALERT = true, DRILL = true}
M.FORBID_STARVE_PER_DAY = 200
function M.siege_starving(K)
  if K.mode() ~= 'SIEGE' then return nil end
  local ok, sv = K.call('siege', 'starve_state')
  return ok and type(sv) == 'table' and sv or nil
end
-- BUG-597 (Run 16b i2 Brotherarrow y414, BREACH: 640 drinks and 14 food forbidden, `unforbid held back: mode BREACH`, round 36's unforbid ran in a
-- SIEGE hunger emergency only): in a SIEGE or BREACH with the civ alert sounding, the food and drink INSIDE the burrows that confine the citizens
-- (siege.alert_names: Tiefe+, Kern+) is unforbidden like in PEACE; the hostile is not in those burrows (seal refuses a burrow with one), what lies
-- outside them stays forbidden. Returns the burrow ids, or nil (another mode, the alert silent, no such burrow)
function M.confine_burrows(K)
  local mode = K.mode()
  if mode ~= 'SIEGE' and mode ~= 'BREACH' then return nil end
  local ok, names = K.call('siege', 'alert_names')
  if not (ok and type(names) == 'table' and #names > 0) then return nil end
  local ids = {}
  pcall(function()
    for _, b in ipairs(df.global.plotinfo.burrows.list) do
      local nm = dfhack.df2utf(b.name)
      for _, n in ipairs(names) do
        if n == nm and nm ~= 'Pflege+' then ids[#ids + 1] = b.id end
      end
    end
  end)
  return #ids > 0 and ids or nil
end
function M.forbid_note(inv, mode, skipped, d, starving)
  local forb = (math.tointeger(inv.drink_forb) or 0) + (math.tointeger(inv.food_forb) or 0)
  if forb <= 0 then return 0, nil end
  d = (d or 0) + 1
  if not (M.FORBID_MODES[mode] or starving) then return d, ('mode ' .. tostring(mode)):sub(1, 40) end
  if (skipped or 0) > 0 then return d, string.format('%d off the walk group', skipped) end
  return d, nil
end
function T.forbid(K, c, r)
  local inv0 = K.census.i or {}
  local sv = M.siege_starving(K)                                 -- BUG-570
  local conf = not sv and M.confine_burrows(K) or nil            -- BUG-597
  if not r.dfd_done then
    r.dfd_done = true
    st.dfd, st.dfwhy = M.forbid_note(inv0, K.mode(), st.forb_skip, st.dfd, sv ~= nil or conf ~= nil)
  end
  -- BUG-594: the day of the last fight (SIEGE / BREACH) and the days after it in which loose forbidden food is freed too
  local fc, dfl = c.forbid or M.DEFAULTS.forbid, M.DEFAULTS.forbid
  local nowt = K.now().tick
  local mode0 = K.mode()
  if mode0 == 'SIEGE' or mode0 == 'BREACH' then r.p.fought = nowt end
  local after = math.tointeger(fc.after_days) or dfl.after_days
  local post = false
  if math.tointeger(r.p.fought) then
    post = after > 0 and mode0 ~= 'SIEGE' and mode0 ~= 'BREACH' and nowt - r.p.fought <= after * DAY
    if nowt - r.p.fought > math.max(after, 0) * DAY then r.p.fought = nil end
  end
  if not (M.FORBID_MODES[K.mode()] or sv or conf) then return true end
  if not r.fx then
    r.fx, r.fx_n, r.fx_why = {}, 0, {}
    -- FR-76: a fort whose stock was forbidden in bulk (a reclaimed one: 3026 of 3058 drinks) is not a player's choice
    local inv = K.census.i or {}
    local nf = (inv.drink_forb or 0) + (inv.food_forb or 0)
    local bmin = math.tointeger(fc.burst_min) or dfl.burst_min
    r.burst = bmin > 0 and nf >= bmin and nf or nil
    local held = 0
    for _, e in ipairs(st.fix or {}) do
      -- BUG-697 (Run 16c i3 Wallfree y431-y433: 'no cook ingredient (6 raw fish to clean, 5 forbidden)' through the whole famine): a famine
      -- (food below famine_days) frees the loose forbidden food too, whether or not a citizen is already starving
      if e.why ~= 'food' or r.p.starve or r.p.famine or r.burst or sv or post or conf then r.fx[#r.fx + 1] = e else held = held + 1 end
    end
    -- BUG-594: loose food / drink items that stay forbidden say so (the brief read 'the kernel has not freed them' without a cause)
    if held > 0 and not st.dfwhy then st.dfwhy = string.format('%d food/drink kept (forbidden by hand?)', held):sub(1, 40) end
    -- BUG-023 (Run 11): forbidden picks/axes nobody carries, as many as members of a tool detail lack that tool while
    -- its jobs wait (tool_check's st.tneed)
    for kind, n in pairs(st.tneed or {}) do
      local k = 0
      for _, e in ipairs((st.tool_items or {})[kind] or {}) do
        if e.forb and k < n then k = k + 1; r.fx[#r.fx + 1] = {id = e.id, why = kind} end
      end
    end
  end
  local lim = r.burst and (math.tointeger(fc.burst_per_day) or dfl.burst_per_day) or fc.per_day or 30
  if sv or conf then lim = math.max(lim, M.FORBID_STARVE_PER_DAY) end     -- BUG-570, BUG-597
  local per_call = r.burst and M.BURST_SLICE or 1               -- FR-76: item flags are cheap, a burst takes many a frame
  local did = 0
  while #r.fx > 0 and r.fx_n < lim do
    local e = table.remove(r.fx, 1)
    local it = df.item.find(e.id)
    local f = it and it.flags
    if f and f.forbid and not (f.trader or f.in_building or f.garbage_collect or f.removed) then
      local x, y, z = dfhack.items.getPosition(it)
      if x and conf and not sv and not M.td_in_burrows(conf, {x, y, z}) then
        r.fx_out = (r.fx_out or 0) + 1                   -- BUG-597: a lockdown frees what lies inside the confinement burrows only
      elseif x and known_tile(K, x, y, z) and not far(K, x, y, z) then
        r.cmds = r.cmds + 1
        did = did + 1
        if K.act.item_flag(e.id, 'forbid', false) then
          r.fx_n = r.fx_n + 1
          r.fx_why[e.why] = (r.fx_why[e.why] or 0) + 1
        end
        if #r.fx > 0 and r.fx_n < lim and did >= per_call then return false end
      else
        r.fx_skip = (r.fx_skip or 0) + 1                 -- BUG-506: forbidden but hidden / off the walk group
      end
    end
  end
  st.forb_skip = r.fx_skip
  if conf and (r.fx_out or 0) > 0 and not st.dfwhy then
    st.dfwhy = string.format('%d kept outside %s', r.fx_out, 'the confinement burrows'):sub(1, 40)
  end
  if r.fx_n > 0 then
    K.log('info', 'unforbidden: %s%s', why_line(r.fx_why, 4),
          r.burst and string.format(' (a forbidden stock: %d drink + food units, up to %d a day)', r.burst, lim) or '')
  end
  return true
end

---------------------------------------------------------------- BUG-053: the tool pile
-- Run 11 y487 (16 free picks 'loose' at 157,57,139 for 1081 days) and Run 12 y501 (a reclaimed fort, pick_free 100 for 144
-- days): the only weapon pile the kernel builds, fortcore's melt pile, refuses picks and battle axes on purpose
-- (baseline melt_keep), nothing else gives a tool a home, so a free tool lies where it fell. Once usable tools (free, on
-- the citizens' walk group, unowned) lie loose while members lack them for `pile_days`, tool_check asks for a weapons
-- stockpile `dfllm-tools` (act.tool_pile, the stockpiles screen) on revealed plain floor near the detail's open jobs;
-- DF's haulers fill it and the kernel never moves an item itself. Afterwards the pile is restricted to picks and battle
-- axes (stockpiles import, as baseline does for the melt pile). One attempt per `pile_every` days.

-- where the detail works: the first open job on the citizens' walk group, else a member, else the first loose tool
-- BUG-188 (live i4 y725: the first open dig job was a cavern-check shaft in raw rock at z122, no floor within 12 tiles;
-- the members' area at 44,92,129 had a site): the centres in order, each {at, by}: open jobs with plain floor beside them
-- (at most 2; a shaft in solid rock has none), the members, the stockpile the tools sit in (take), the first loose tool
M.PILE_CENTRES, M.PILE_RETRY_DAYS = 4, 1
function M.pile_open(K, p)
  for dx = -1, 1 do
    for dy = -1, 1 do
      local ok, t = K.call('snapshot', 'tile', p[1] + dx, p[2] + dy, p[3])
      if ok and type(t) == 'table' and t.c == '.' then return true end
    end
  end
  return false
end
function M.pile_centres(K, spec, jc, cur, pos, take)
  local out, seen, njob = {}, {}, 0
  local function add(x, y, z, by)
    local key = string.format('%d,%d,%d', x, y, z)
    if #out < M.PILE_CENTRES and not seen[key] then seen[key] = true; out[#out + 1] = {at = {x, y, z}, by = by} end
  end
  for _, p in ipairs(type(jc) == 'table' and jc[(spec.jobs or '') .. '_pts'] or {}) do
    if njob >= 2 then break end
    if not far(K, p[1], p[2], p[3]) and M.pile_open(K, p) then njob = njob + 1; add(p[1], p[2], p[3], 'job') end
  end
  for _, u in ipairs(cur or {}) do
    local ok, x, y, z = pcall(function() return u.pos.x, u.pos.y, u.pos.z end)
    x, y, z = ok and math.tointeger(x), ok and math.tointeger(y), ok and math.tointeger(z)
    if x and y and z and not far(K, x, y, z) then add(x, y, z, 'member') end
  end
  if math.tointeger(take) then
    pcall(function()
      local b = df.building.find(take)
      if b then add((b.x1 + b.x2) // 2, (b.y1 + b.y2) // 2, b.z, 'source pile') end
    end)
  end
  if pos and not far(K, pos[1], pos[2], pos[3]) then add(pos[1], pos[2], pos[3], 'tool') end
  return out
end
function M.pile_center(K, spec, jc, cur, pos)
  local c = M.pile_centres(K, spec, jc, cur, pos)[1]
  return c and c.at or nil
end

-- the ids of the stockpile buildings named dfllm-tools
function M.tool_piles()
  local ids = {}
  pcall(function()
    for _, sp in ipairs(df.global.world.buildings.other.STOCKPILE) do
      if dfhack.df2utf(sp.name or '') == 'dfllm-tools' then ids[#ids + 1] = sp.id end
    end
  end)
  table.sort(ids)
  return ids
end

-- the pile's state for TOOL_BLOCKED: its text (d.pile) or, with token, a cause token (a new state is news)
function M.pile_text(p, token)
  local rec = type(p) == 'table' and type(p.tpile) == 'table' and p.tpile or nil
  if not rec or not rec.state then return nil end
  if token then return 'pile:' .. tostring(rec.state) end
  local at = type(rec.at) == 'table' and rec.at or nil
  if rec.state == 'placed' and at then
    return (string.format('dfllm-tools placed at %d,%d,%d (%dx%d)', at[1], at[2], at[3], rec.w or 3, rec.h or 2) ..
            (math.tointeger(rec.take) and string.format(', takes from %d', rec.take) or '')):sub(1, 80)
  elseif rec.state == 'exists' then return 'dfllm-tools stands'
  end
  return (tostring(rec.state) .. ': ' .. tostring(rec.why or '?')):sub(1, 80)
end

-- the nearest w x h block of revealed plain floor to the centre q.at on its level (the citizens' walk group, off the attack
-- path, no building, no pending designation): its top-left tile, or nil and why; at most `pile_reads` tile reads
function M.pile_site(K, tc, q)
  local w, h = tc.pile_w or 3, tc.pile_h or 2
  -- BUG-188 (live i4: 300 reads gave up at ring 7 of 12): the budget covers the whole (2R+w) x (2R+h) square
  local R = tc.pile_r or 12
  local budget = math.max(tc.pile_reads or 300, (2 * R + w) * (2 * R + h))
  local cx, cy, cz = q.at[1], q.at[2], q.at[3]
  local reads, seen = 0, {}
  local function floor_at(x, y)
    local key = x * 100000 + y
    if seen[key] ~= nil then return seen[key] end
    reads = reads + 1
    local ok, t = K.call('snapshot', 'tile', x, y, cz)
    local good = ok and type(t) == 'table' and t.c == '.' and (t.bld == nil or t.bld == '') and (t.dig == nil or t.dig == '')
                 and not t.cav and not far(K, x, y, cz) and not M.attack_path(K, {x, y, cz})
    seen[key] = good == true
    return seen[key]
  end
  for d = 0, R do
    for dx = -d, d do
      for dy = -d, d do
        if math.max(math.abs(dx), math.abs(dy)) == d then
          local ax, ay, fit = cx + dx, cy + dy, true
          for ix = 0, w - 1 do
            for iy = 0, h - 1 do
              if reads >= budget then return nil, string.format('the %d tile reads are spent', budget) end
              if not floor_at(ax + ix, ay + iy) then fit = false; break end
            end
            if not fit then break end
          end
          if fit then return {ax, ay, cz} end
        end
      end
    end
  end
  return nil, string.format('no %dx%d plain floor within %d tiles of %s%d,%d,%d', w, h, R, q.by and (q.by .. ' ') or '',
                            cx, cy, cz)
end

-- the lacking members ask for the equipment update again at the next pass (the tools have a new home: tools.equip_update)
function M.pile_ask_again(spec)
  for key in pairs(st.fixes or {}) do
    if type(key) == 'string' and key:sub(1, #spec + 1) == spec .. ':' then st.fixes[key] = nil end
  end
end

-- daily (after T.forbid): restrict a pile that stands (once), else place one when tool_check asked for it
function T.toolpile(K, c, r)
  if not r.day or not HUNT_MODES[K.mode()] then return true end       -- PEACE / RECOVERY, as the unforbid
  local tc, p = c.tools or {}, r.p
  local q = st.tpile_req
  st.tpile_req = nil                                   -- tool_check asks again every day the need lasts
  local rec = type(p.tpile) == 'table' and p.tpile or {}
  local ids = M.tool_piles()
  if #ids > 0 then
    if rec.set ~= 1 and (rec.fail or 0) < 3 then
      local id = string.format('%d', ids[1])
      r.cmds = r.cmds + 1
      local ok1 = K.act.run('stockpiles', 'import', '-m', 'disable', 'cat_weapons', '-s', id)
      local ok2 = ok1 and K.act.run('stockpiles', 'import', '-m', 'enable', 'cat_weapons', '-f', 'pick,battle axe', '-s', id)
      if ok2 then
        rec.set = 1
        K.log('info', 'tool pile: dfllm-tools (%s) takes picks and battle axes only', id)
        if type(rec.spec) == 'string' then M.pile_ask_again(rec.spec) end
      else
        rec.fail = (rec.fail or 0) + 1
        K.log('warn', 'tool pile: dfllm-tools (%s) could not be restricted to picks and battle axes (try %d)', id, rec.fail)
      end
    end
    if rec.state ~= 'placed' then rec.state = 'exists' end
    p.tpile = json.object(rec)
    return true
  end
  if not q or tc.pile == false or type(K.act.tool_pile) ~= 'function' then return true end
  -- BUG-188: a search that found no site is tried again after PILE_RETRY_DAYS, not after pile_every
  local wait = rec.state == 'nosite' and M.PILE_RETRY_DAYS or (tc.pile_every or 28)
  if rec.t and r.now - rec.t < wait * DAY then return true end
  local site, why, c0
  local whys = {}
  for _, c in ipairs(type(q.ats) == 'table' and q.ats or {{at = q.at}}) do
    local s, wy = M.pile_site(K, tc, {at = c.at, by = c.by})
    if s then site, c0 = s, c; break end
    whys[#whys + 1] = tostring(wy)
  end
  why = table.concat(whys, '; ')
  r.cmds = r.cmds + 1
  local out = {t = r.now}
  if site then
    local ok, n = K.act.tool_pile(site, tc.pile_w or 3, tc.pile_h or 2, q.take)
    if ok then
      out.state, out.at, out.w, out.h, out.spec = 'placed', json.array(site), tc.pile_w or 3, tc.pile_h or 2, q.spec
      out.take = q.take                                -- BUG-128: the stockpile it takes from (quickfort take_from)
      M.pile_ask_again(q.spec)
      out.by = c0 and c0.by or nil
      K.log('info', 'tool pile: dfllm-tools %dx%d at %d,%d,%d for the %ss lying loose (%s lack them; searched from %s %s)',
            out.w, out.h, site[1], site[2], site[3], q.kind, q.spec, tostring(c0 and c0.by or 'centre'),
            c0 and string.format('%d,%d,%d', c0.at[1], c0.at[2], c0.at[3]) or '?')
    else
      out.state, out.why = 'refused', tostring(n):sub(1, 60)
      K.log('warn', 'tool pile: dfllm-tools at %d,%d,%d refused: %s', site[1], site[2], site[3], tostring(n))
    end
  else
    out.state, out.why = 'nosite', tostring(why):sub(1, 120)
    -- a daily retry logs at debug only: warn once per pile_every while it keeps failing (the reason names the centres,
    -- and a member centre moves every day, so comparing the text alone would warn daily)
    local wt = rec.state == 'nosite' and math.tointeger(rec.wt) or nil
    local warn = not wt or r.now - wt >= (tc.pile_every or 28) * DAY
    out.wt = warn and r.now or wt
    K.log(warn and 'warn' or 'debug', 'tool pile: no site: %s', tostring(why))
  end
  p.tpile = json.object(out)
  return true
end

-- FR-25 (daily): food_d <= starve.days with hungry citizens. Steps over frames: gatherers and planters join
-- their details (not in modern labormanager mode), reachable visible edible shrubs are marked for gathering,
-- and the citizens who cannot reach food are named (DECISION_NEEDED starvation, every report_days)
function T.starve(K, c, r)
  local sc = c.starve or M.DEFAULTS.starve
  local p = r.p
  if not r.sv then
    local fd = (r.days or {}).food_d or 9999
    local hungry = fd <= (sc.days or 0) and hungry_ids(K, sc.hunger or 50000) or {}
    if #hungry == 0 then
      if p.starve then p.starve = nil; K.log('info', 'starvation over: %d food days', fd) end
      st.starve = nil
      return true
    end
    if type(p.starve) ~= 'table' then
      p.starve = {since = r.now, woke = 0}
      K.log('warn', 'starvation: %d food days, %d hungry citizens', fd, #hungry)
    end
    r.sv = {hungry = hungry, step = 'details', q = {}, vi = 1, idx = 0, cand = {}, added = 0, marked = 0}
    if st.engine ~= 'modern' then
      local planters = farm_tiles() > 0 and (sc.planters or 0) or 0
      -- BUG-697: with many adults idle a starvation puts more of them on the plants (gatherers_max), not four
      -- (PEACE / RECOVERY only: the gatherers walk out to the shrubs, a fight holds them at the base number)
      local gath = sc.gatherers or 0
      if HUNT_MODES[K.mode()] then gath = M.famine_scale(gath, sc.gatherers_max or gath, r.cit, 5, st.idle) end
      for _, d in ipairs({{key = 'gatherers', labor = 'HERBALIST', skill = 'HERBALISM', n = (sc.gatherers or 0) > 0 and gath or 0},
                          {key = 'planters', labor = 'PLANT', skill = 'PLANT', n = planters}}) do
        local name, wd = find_detail((sc.details or {})[d.key], d.labor)
        if name and d.n > 0 then
          local have = 0
          for _ in ipairs(wd.assigned_units) do have = have + 1 end
          local member = {}
          for _, id in ipairs(wd.assigned_units) do member[id] = true end
          local cand = {}
          local cu = K.census.u
          local sold = {}
          for _, id in ipairs(cu.soldier_ids or {}) do sold[id] = true end
          for _, id in ipairs(cu.ids or {}) do
            local u = not member[id] and not sold[id] and df.unit.find(id)
            if u and dfhack.units.isAdult(u) and not noble(u) and not ((u.mood or -1) >= 0) then
              local sid = df.job_skill[d.skill]
              cand[#cand + 1] = {id = id, idle = (u.job == nil or u.job.current_job == nil) and 1 or 0,
                                 sk = sid and dfhack.units.getNominalSkill(u, sid, true) or 0}
            end
          end
          table.sort(cand, function(a, b)
            if a.idle ~= b.idle then return a.idle > b.idle end
            if a.sk ~= b.sk then return a.sk > b.sk end
            return a.id < b.id
          end)
          for i = 1, math.max(0, math.min(#cand, d.n - have)) do
            r.sv.q[#r.sv.q + 1] = {detail = name, unit = cand[i].id, n = d.n}
          end
        end
      end
    end
  end
  local sv = r.sv
  if sv.step == 'details' then
    local e = table.remove(sv.q, 1)
    if e then
      r.cmds = r.cmds + 1
      if K.act.work_detail(e.detail, e.unit, true) then
        sv.added = sv.added + 1
        K.emit('WORK_DETAIL', 'B', string.format('%s + %s (starvation, target %d)', e.detail, unit_name(e.unit), e.n),
               {detail = e.detail, unit = e.unit, on = 1, n = e.n, why = 'starvation'})
      end
      return false
    end
    sv.step = 'scan'
  end
  if sv.step == 'scan' then
    local vecs = {'shrub_dry', 'shrub_wet'}
    local budget = sc.plants_per_slice or 400
    while sv.vi <= #vecs and budget > 0 and #sv.cand < (sc.plants_max or 200) do
      local okv, vec = pcall(function() return df.global.world.plants[vecs[sv.vi]] end)
      local n = okv and vec and #vec or 0
      while sv.idx < n and budget > 0 and #sv.cand < (sc.plants_max or 200) do
        local pl = vec[sv.idx]
        sv.idx, budget = sv.idx + 1, budget - 1
        local okp, pos, mat = pcall(function() return pl.pos, pl.material end)
        if okp and pos and edible(mat, sc.plants) then
          local okm, marked = pcall(function() return dfhack.designations.isPlantMarked(pl) end)
          if not (okm and marked) and known_tile(K, pos.x, pos.y, pos.z) and not far(K, pos.x, pos.y, pos.z) then
            sv.cand[#sv.cand + 1] = {pos.x, pos.y, pos.z}
          end
        end
      end
      if sv.idx >= n then sv.vi, sv.idx = sv.vi + 1, 0 end
    end
    r.cmds = r.cmds + 1                          -- a slice of its own
    if sv.vi <= #vecs and #sv.cand < (sc.plants_max or 200) then return false end
    sv.step = 'mark'
    return false
  end
  if sv.step == 'mark' then
    sv.step = 'report'
    if #sv.cand > 0 then
      r.cmds = r.cmds + 1
      local ok, n = K.act.plant_gather(sv.cand)
      sv.marked = ok and (math.tointeger(n) or 0) or 0
      return false
    end
  end
  -- report: who cannot reach food (the census's reachable food samples)
  local cut = cut_off(K, sv.hungry)
  local names = {}
  for i = 1, math.min(4, #cut) do names[#names + 1] = unit_name(cut[i]) end
  local fd = (r.days or {}).food_d or 0
  st.starve = {hungry = #sv.hungry, cut = cut, marked = sv.marked, added = sv.added, unreach = st.unreach or 0}
  local empty = not (st.food_pos and #st.food_pos > 0)       -- BUG-299: nothing edible lies free
  K.log('warn', 'starvation: %d hungry, %s; %d shrubs marked for gathering, %d helpers added',
        #sv.hungry, empty and 'no food left (the stock is empty)' or string.format('%d cannot reach food', #cut),
        sv.marked, sv.added)
  if r.now - (math.tointeger(p.starve.woke) or -1e12) >= (sc.report_days or 2) * DAY then
    p.starve.woke = r.now
    local who = #cut > 0 and ('cannot reach food: ' .. table.concat(names, ', ') .. (#cut > #names and (' +' .. (#cut - #names)) or ''))
                or (empty and 'no food left to eat (the stock is empty, not cut off)' or 'all can reach food')
    K.emit('DECISION_NEEDED', 'A', string.format('starvation: %d hungry, food %d days, %s', #sv.hungry, fd,
                                                 empty and 'no food left' or string.format('%d cannot reach food', #cut)),
           {id = 'starvation', q = string.format('%s; %d shrubs marked, +%d gatherers/planters, %d food items unreachable: ' ..
                                                 'open a path, bring food in, farms or trade?', who, sv.marked, sv.added,
                                                 st.unreach or 0):sub(1, 200)})
  end
  return true
end

function T.finish(K, c, r)
  if r.day then
    r.p.last_day = r.start
    -- Run 10: the classes a strange mood missed within leather.memory_days (state stock.mood_miss, plan propose/check)
    local miss = {}
    for key in pairs(r.p.mseen) do
      if M.mood_missed(c, r.p, key, r.now) and #key <= 12 then miss[#miss + 1] = key end
    end
    table.sort(miss)
    st.out = {drink_d = r.days.drink_d, food_d = r.days.food_d, meals = r.inv.meal_kinds, hungry = st.hungry_n or 0,
              starving = st.starving or 0, idle = st.idle or 0, mood_miss = {table.unpack(miss, 1, math.min(8, #miss))}}
  end
  K.persist.touch('m.economy')
end

local FULL = {'guard', 'days', 'kitchen', 'appoint', 'food', 'fishz', 'gather', 'watch', 'cmdq', 'engine', 'labor_fix',
              'scan', 'slabs', 'slotnow', 'ocheck', 'slaughter', 'plan', 'prune', 'tools', 'cover', 'fcrew', 'starve', 'forbid', 'toolpile',
              'jobs', 'jsite', 'jmat', 'stale', 'jmake', 'jfree', 'jresume',
              'jcheck', 'jmove', 'pb', 'orders', 'stand', 'wood', 'chop', 'crops',
              'farm', 'farmslots', 'imports', 'piles', 'status', 'idle', 'finish'}
local RUSH = {'guard', 'scan', 'plan', 'tools', 'orders', 'wood', 'chop', 'farm', 'finish'}
M.TASKS = {full = FULL, rush = RUSH}

local function new_run(K, c, start)
  local p = pstate(K)
  local cu = K.census.u
  local cit = (cu and math.tointeger(cu.cit)) or ((p.cit or 0) > 0 and p.cit) or 7
  p.cit = cit
  local rush = st.rush
  st.rush = false
  local day = not rush or p.last_day == nil or start - p.last_day >= DAY
  return {p = p, inv = K.census.i, cit = cit, now = start, start = start, day = day, tasks = day and FULL or RUSH,
          i = 1, cmds = 0, cmdq = {}, days = st.days or {drink_d = 9999, food_d = 9999}, held = {},
          s = {live = {}, used = {}}, f = {}, cands = {}, planned = {}, targets = {}, route = {}, hunt = 0}
end

local function run_slice(K, c)
  local r = st.run
  r.cmds = 0
  local guard = 0
  while r.i <= #r.tasks do
    local name = r.tasks[r.i]
    local okc, done = pcall(T[name], K, c, r)
    if not okc then
      K.log('warn', 'economy task %s: %s', name, tostring(done))
      st.task_errs = (st.task_errs or 0) + 1
      done = true
    end
    if done ~= false then r.i = r.i + 1 end
    guard = guard + 1
    if r.cmds >= (c.slice_cmds or 1) or guard >= 40 then break end
  end
  return r.i > #r.tasks
end

---------------------------------------------------------------- hook API (CONTRACTS Ã‚Â§7 proposal, live L4)
local function route_of(key, inv, f)
  inv, f = inv or {}, f or {}
  if key == 'wood' then return true, 'chop'
  elseif key == 'rock' then return false, 'no route: stone dig (runner/LLM)'
  elseif key == 'bone' or key == 'shell' then return true, 'hunt'
  elseif key == 'hides' then return true, 'hunt'
  elseif key == 'leather' then return true, (inv.hides or 0) > 0 and 'tan' or 'hunt+tan'
  elseif key == 'cloth' then return true, (inv.thread or 0) > 0 and 'weave' or 'thread+weave'
  elseif key == 'thread' then return true, 'process plants'
  elseif key == 'fuel' then return true, 'charcoal'
  elseif key == 'glass' then return true, 'sand + glass furnace + fuel'
  elseif key == 'bars' then
    if (inv.ore or 0) > 0 then return true, 'smelt' end
    return false, 'no ore: exploration dig or trade'
  end
  return false, 'no route: mining/trade'
end

-- Run 10 (Handlelock: a fey mood died for two leather while no tannery stood): what supplies a mood class now and what
-- blocks it, for care's MOOD_RISK text, e.g. 'no tannery (asked), hunt: no bolts, butcher, trade.want leather';
-- '' for an unknown key
function M.route(K, key, via)
  key = key_of(key)
  if not KEYS[key] then return '' end
  if key == 'gems' or key == 'glass' then return M.glass_route(K, key, via) end   -- Run 11
  local inv, f, c = K.census.i or {}, st.f or {}, M.conf(K)
  local sup = st.sup or {route = {}}
  if key == 'leather' or key == 'hides' then
    local parts, rl = {}, tostring(sup.route.leather or '')
    if not ws_any(f, (c.leather or {}).ws) then parts[1] = rl:find('^no tannery') and rl or 'no tannery'
    elseif (inv.hides or 0) > 0 then parts[1] = string.format('tan %d hides', inv.hides) end
    local h, hn = st.hunt or {}, st.hunters or 0
    if (inv.w_xbow or 0) + (inv.w_bow or 0) == 0 then parts[#parts + 1] = 'hunt: no crossbow'
    elseif st.no_ammo then parts[#parts + 1] = 'hunt: no bolts'
    elseif hn > 0 then parts[#parts + 1] = string.format('hunt: %d hunter%s', hn, hn == 1 and '' or 's')
    elseif h.why == 'no game' then parts[#parts + 1] = 'hunt paused (no game)'
    elseif h.why == 'siege' or h.why == 'hold' then parts[#parts + 1] = 'hunt: not in ' .. tostring(K.mode())
    else parts[#parts + 1] = 'hunt' end
    parts[#parts + 1] = 'butcher'
    parts[#parts + 1] = 'trade.want leather'
    return table.concat(parts, ', ')
  elseif key == 'bars' then
    if (inv.ore or 0) > 0 then
      return ws_any(f, (c.metal or {}).smelter) and string.format('smelt %d ore', inv.ore)
             or string.format('%d ore, no smelter', inv.ore)
    end
    -- BUG-520: no ore: melting metal items is a second source (a Smelter melts what is marked for melt)
    return string.format('no ore: explore dig (plan), trade.want bar:iron, or melt metal items (%d marked, %s)', inv.melt or 0,
                         ws_any(f, (c.metal or {}).smelter) and 'a smelter stands' or 'no smelter')
  elseif key == 'bone' or key == 'shell' then
    -- BUG-520 (Run 16a-d: bone moods died with 'butcher.mark: no animal to mark'): route 'hunt' hid that nothing can be slaughtered
    local txt = M.mood_hint(K, key)
    return txt and (txt .. '; trade.want bone') or 'butcher, hunt, trade.want bone'
  end
  local _, txt = route_of(key, inv, f)
  return tostring(sup.route[key] or txt)
end

function M.need(K, key, n, who, days)
  key = key_of(key)
  if not KEYS[key] then return false, 'unknown key ' .. tostring(key) end
  local c = M.conf(K)
  n, who = math.tointeger(n) or 0, tostring(who or 'any'):sub(1, 40)
  local p = pstate(K)
  local m = p.needs[key]
  if type(m) ~= 'table' then m = json.object{}; p.needs[key] = m end
  local prev = m[who]
  if n <= 0 then
    m[who] = nil
    K.persist.touch('m.economy')
    return true, 'cleared'
  end
  local d = clamp(math.tointeger(days) or c.need_days or 30, 1, 112)
  m[who] = {n = n, untl = K.now().tick + d * DAY}
  K.persist.touch('m.economy')
  if type(prev) ~= 'table' or (math.tointeger(prev.n) or 0) < n then
    st.rush = true
    local rt = c.rush_ticks or 100
    if (M.every.ticks or EVERY) > rt then M.every = {ticks = rt} end
    K.log('info', 'need %s %d (%s, %d days)', key, n, who, d)
  end
  return route_of(key, K.census.i, st.f)
end

function M.reserve(K, key, n, who)
  key = key_of(key)
  if not KEYS[key] then return false, 'unknown key ' .. tostring(key) end
  n, who = math.tointeger(n) or 0, tostring(who or 'any'):sub(1, 40)
  local p = pstate(K)
  local m = p.reserves[key]
  if type(m) ~= 'table' then m = json.object{}; p.reserves[key] = m end
  m[who] = n > 0 and n or nil
  K.persist.touch('m.economy')
  local c = M.conf(K)
  return true, math.max(math.tointeger((c.reserve or {})[key]) or 0, holder_floor(p, key), need_n(p, key, K.now().tick))
end

function M.supply(K)
  local p = pstate(K)
  local c = M.conf(K)
  local inv = K.census.i or {}
  local sup = st.sup or {targets = {}, route = {}, held = {}}
  local now = K.now().tick
  local out = {}
  for key in pairs(KEYS) do
    local held = sup.held[key] or 0
    local fl = math.max(math.tointeger((c.reserve or {})[key]) or 0, holder_floor(p, key), need_n(p, key, now))
    local _, route = route_of(key, inv, st.f)
    out[key] = {have = (inv[key] or 0) + held, held = held, floor = fl, route = sup.route[key] or route,
                want = sup.targets[key] or math.max(need_n(p, key, now), 0)}
  end
  return out
end

-- BUG-199 (live round 3: after back-to-back reloads status had no stock line for ~21 game days; the item census runs
-- before T.days, paced at 3 ms/s over 48.8k items): at boot the stock days of the save's last daily run (persisted
-- p.prev / p.hist, p.days_t) are published at once (early, no labor) when that run is at most two days old (or of
-- unknown age: a save from before this fix); an older value is left to the kernel's carry, which names its age.
-- The first run after the boot holds a boost (util/sched BOOST.shares.economy) until T.days ran.
M.FIRST_BOOST_MS = 20 * 60 * 1000
function M.boot_out(K, p)
  st.first, st.first_ms = true, K.now().ms
  if st.out or type(p) ~= 'table' or type(p.prev) ~= 'table' then return end
  local dr, fo = math.tointeger(p.prev.drink), math.tointeger(p.prev.food)
  if not (dr and fo) or #p.hist.drink == 0 or #p.hist.food == 0 then return end
  local at, now = math.tointeger(p.days_t), K.now().tick
  if at and (at > now or now - at > 2 * DAY) then return end
  st.out = {drink_d = M.days(dr, p.hist.drink), food_d = M.days(fo, p.hist.food), meals = math.tointeger(p.meals),
            hungry = 0, mood_miss = {}, early = true, boot = true}
end

-- BUG-199: the first run since the boot asks for the boost each step until T.days published the stock days; at most
-- M.FIRST_BOOST_MS real time (a run that never reaches T.days, faults: not boosted for good)
function M.first_boost(K)
  if type(K.boost) ~= 'function' then return end
  local ms = K.now().ms
  if st.first and st.first_ms and ms and ms - st.first_ms > M.FIRST_BOOST_MS then
    st.first = false
    K.log('warn', 'economy: the first run since the boot did not reach the stock days in %d min: boost dropped',
          M.FIRST_BOOST_MS // 60000)
  end
  if st.first then K.boost('first run since the boot')
  elseif st.first == false then
    st.first = nil
    if type(K.unboost) == 'function' then K.unboost() end
  end
end

---------------------------------------------------------------- module
function M.init(K)
  st = {census = nil, run = nil, rate = {}, cancels = {}, looped = {}, backoff = {}, bars_by = {}, ores = {},
        seeds = {}, f = {}}
  orec, wdef, adef = {}, {}, {}
  M.act = K.act
  rcache, pinfo, pidx, ecache, plugins = {}, {}, nil, {}, {}
  skip_mask, mask_check, mask_bad = make_skip_mask(), M.MASK_CHECK, nil
  do                                             -- BUG-665: the in_job bit of the flag word (nil: per-flag read)
    local okb, bit = pcall(function() return df.item_flags.in_job end)
    M.JOB_BIT = okb and math.type(bit) == 'integer' and bit >= 0 and bit <= 31 and (1 << bit) or nil
  end
  M.every = {ticks = EVERY}
  M.boot_out(K, pstate(K))
  local ok, err = pcall(kitchen, K, M.conf(K), nil)
  if not ok then K.log('warn', 'kitchen exclusion: %s', tostring(err)) end
end

function M.step(K, budget, ctx)
  local c = M.conf(K)
  M.first_boost(K)
  if not (ctx and ctx.cont) or not (st.census or st.run) then
    st.census, st.run = {acc = new_acc(c), ci = 1, idx = 0, errs = 0, start = K.now().tick}, nil
    do                                             -- BUG-743: the gear pieces military wrote off
      local okk, ids = K.call('military', 'stuck_ids')
      st.census.acc.stuck = okk and type(ids) == 'table' and ids or nil
    end
    st.census.acc.far = function(it, strict)
      local x, y, z = dfhack.items.getPosition(it)
      if not x then return false end
      local ok, far = K.call('snapshot', 'far', x, y, z, strict == true or nil)   -- BUG-665: strict = no walkable group counts as far
      return ok == true and far == true
    end
    mcache, tcache, bolt_sub = {}, {}, {}
    if (M.every.ticks or EVERY) ~= EVERY then M.every = {ticks = EVERY} end   -- the rush run is this one
  end
  if st.census then
    if not census_slice(c) then return 'more' end
    local cs = st.census
    st.census = nil
    if cs.errs > 0 then K.log('warn', 'census: %d unreadable items (%s)', cs.errs, cs.err) end
    if mask_bad then
      mask_bad = false
      K.log('warn', 'census: the item flag mask disagreed with the flag reads; reading flags one by one')
    end
    publish(K, c, cs.acc)
    st.run = new_run(K, c, cs.start)
  end
  if not run_slice(K, c) then return 'more' end
  st.f = st.run.f
  st.run = nil
end

-- WP8-internal (baseline, right after its seedwatch task): re-add a cook exclusion seedwatch dropped
function M.kitchen_check(K)
  local ok, err = pcall(kitchen, K, M.conf(K), st.out and st.out.food_d)
  if not ok then K.log('warn', 'kitchen exclusion: %s', tostring(err)) end
  return ok
end

-- CONTRACTS Ã‚Â§7: orders library already imported
function M.imported(K, lib)
  local p = K.persist.get('m.economy')
  return type(p) == 'table' and type(p.imported) == 'table' and p.imported[lib] ~= nil
end

function M.state(K)
  local o = st.out
  local r = {}
  if o then
    r.stock = {drink_d = o.drink_d, food_d = o.food_d, meals = o.meals}
    if (o.hungry or 0) > 0 then r.stock.hungry = o.hungry end              -- BUG-059
    -- BUG-177: the early stock (T.days of the first run) has no labor yet: the kernel carries its last known values
    if not o.early then r.labor = {starving = o.starving, idle = math.max(0, math.min(100, o.idle))} end
    local iw = st.idle_why     -- FR-77: why the adults have no job (the daily scan's own-state classes)
    if iw and r.labor then
      r.labor.n, r.labor.sold, r.labor.held = iw.n, iw.sold, iw.held
      r.labor.why = {rest = iw.why.rest, hurt = iw.why.hurt, mood = iw.why.mood, free = iw.why.free}
    end
    -- Run 10 (plan propose/check: ore exploration and leather as plan goals): metal ore boulders, bars and leather
    -- (care's forbidden reserve included), the metal route ('explore' = no ore while metal is wanted) and the classes a
    -- strange mood missed within leather.memory_days
    local inv, sup = K.census.i or {}, st.sup or {}
    local held, route = sup.held or {}, sup.route or {}
    r.stock.ore = math.max(0, math.tointeger(inv.ore) or 0)
    r.stock.bars = math.max(0, (math.tointeger(inv.bars) or 0) + (math.tointeger(held.bars) or 0))
    r.stock.leather = math.max(0, (math.tointeger(inv.leather) or 0) + (math.tointeger(held.leather) or 0))
    r.stock.metal = tostring(route.bars or ''):sub(1, 24)
    if o.mood_miss and #o.mood_miss > 0 then r.stock.mood_miss = {table.unpack(o.mood_miss)} end
    -- Run 11 (plan propose/check: a stone dig, picks in trade.want): free stone and what the open rock orders, walls
    -- and needs want of it; picks in the fort and the Miners' demand
    if st.rock then
      r.stock.rock, r.stock.rock_need = math.max(0, st.rock.free or 0), math.max(0, st.rock.need or 0)
      if st.rock.soil then r.stock.rsoil = 1 end       -- BUG-438: the stone digs found only soil (plan propose digs deeper)
    end
    do                                                 -- BUG-677: the wall material a ring / plug can use (bp sites / bp.place aqshaft refuse without it)
      local okw, ws = pcall(M.wall_stock, K)
      if okw and type(ws) == 'table' then r.stock.wall = math.max(0, math.tointeger(ws.have) or 0) end
    end
    do                                                 -- BUG-586: DF itself refuses the rock jobs (BUG-545): no mechanism, no stone trap, no traction bench
      local okh, hd = pcall(M.hard_denied, K.census.i or {}, K.now().tick)
      if okh and hd then r.stock.rhard = 1 end
    end
    if type(st.mech) == 'table' then                   -- BUG-611: free mechanisms and what plan_mech found for the shortfall (plan: no traps without parts)
      -- BUG-681: the parts a citizen can walk to (mech.rfree), not every free one in the world; an older save's state has none: the raw count
      r.stock.mfree = math.max(0, math.tointeger(st.mech.rfree) or math.tointeger(st.mech.free) or 0)
      if (math.tointeger(st.mech.ffar) or 0) > 0 then r.stock.mfar = math.tointeger(st.mech.ffar) end
      if type(st.mech.route) == 'string' then r.stock.mroute = st.mech.route:sub(1, 16) end
      r.stock.mtp = math.max(0, math.tointeger(st.mech.traps) or 0)       -- BUG-628: trap parts the planned traps wait for
    end
    if st.picks then r.stock.picks, r.stock.pick_want = st.picks.have, st.picks.want end
    -- Run 11: metal short for the soldiers (M.metal_plan: plan check's metal route gate) and the metal items marked for
    -- melting (the invaders' gear in the melt pile)
    if st.metal then r.stock.mshort = st.metal.short and 1 or 0 end
    r.stock.melt = math.max(0, math.tointeger(inv.melt) or 0)
    -- BUG-042: why the stills do not brew while drink is below the target ('no validated brew order: manager office
    -- 18631 has no chair')
    if st.dwhy then r.stock.dwhy = tostring(st.dwhy):sub(1, 80) end
    if st.bshort then r.stock.bshort = 1 end      -- BUG-382: the runner's gather zone follows the brewable plants too
    -- FR-76: drink and food units the census counts as forbidden (a reclaimed fort's stock: the status says so)
    if (math.tointeger(inv.drink_forb) or 0) > 0 then r.stock.dforb = math.tointeger(inv.drink_forb) end
    if (math.tointeger(inv.food_forb) or 0) > 0 then r.stock.fforb = math.tointeger(inv.food_forb) end
    -- BUG-506: how many daily runs the forbidden stock has stood and what held the unforbid back
    if (st.dfd or 0) > 0 and (r.stock.dforb or r.stock.fforb) then
      r.stock.dfd = math.tointeger(st.dfd)
      if st.dfwhy then r.stock.dfwhy = tostring(st.dfwhy):sub(1, 40) end
    end
  end
  local od = st.orders
  if od then r.orders = {n = od.n or 0, bad = od.bad or 0, stuck = od.stuck or 0} end   -- FR-01/FR-39
  -- BUG-059: of the stuck orders, the ones that miss a workshop (and which), the ones that miss a worker
  if r.orders and (od.sws or 0) > 0 then r.orders.stuck_ws, r.orders.ws = od.sws, od.ws end
  if r.orders and (od.slab or 0) > 0 then r.orders.stuck_lab = od.slab end
  if od and od.jam then r.orders.jam = tostring(od.jam):sub(1, 80) end   -- BUG-061: a workshop type's slots are jammed
  -- BUG-042: orders waiting for validation, the days the oldest waits, and why (once past orders.unval_days)
  local uv = st.unval
  if r.orders and type(uv) == 'table' then
    r.orders.unval, r.orders.uval_d = math.max(0, uv.n or 0), math.max(0, uv.d or 0)
    if uv.why then r.orders.mgr = tostring(uv.why):sub(1, 80) end
  end
  -- BUG-233: what the kernel does about it (M.mgr_bypass: the workshop tasks, or the workshop it asked for)
  if r.orders and st.byp then r.orders.byp = tostring(st.byp):sub(1, 80) end
  return r
end

---------------------------------------------------------------- inbox verbs
local FREQ = {OneTime = true, Daily = true, Monthly = true, Seasonally = true, Yearly = true}

-- order.add {job, amount, item_subtype?, material?, material_category?, reaction?, hf?, frequency?} (FR-39, hf: BUG-078): one
-- manager order through act.workorder (tag dfllm:cmd); make-item jobs without item_subtype are refused
M.verbs['order.add'] = function(K, args, cmd)
  local job = args.job
  if type(job) ~= 'string' or not job:match('^[A-Za-z]+$') then return false, 'job must be a job type name' end
  local okj, jt = pcall(function() return df.job_type[job] end)
  if not okj or type(jt) ~= 'number' then return false, 'unknown job ' .. job end
  local amount = math.tointeger(args.amount)
  if not amount or amount < 1 or amount > 999 then return false, 'amount must be 1..999' end
  if OL.unsafe(job, args.item_subtype) then
    return false, job .. ' needs item_subtype (ITEM_...): DF 53.16 crashes without one (FR-39)'
  end
  -- BUG-078: the memorial slab order names its dead figure (the job is EngraveSlab); only that job takes `hf`
  if job == 'EngraveSlab' then
    local hf = math.tointeger(args.hf)
    if not hf or hf < 0 then return false, 'EngraveSlab needs hf (the historical figure of the ghost)' end
    if amount ~= 1 then return false, 'EngraveSlab: amount must be 1 (one slab per figure)' end
    local oke, res = K.act.engrave_order(hf)
    if not oke then return false, 'engrave_order: ' .. tostring(res) end
    K.log('info', 'order EngraveSlab for hf %d added by %s (%s)', hf, tostring(cmd and cmd.by), tostring(res))
    return true, string.format('order %s EngraveSlab hf %d', tostring(res), hf), {order = math.tointeger(res) or -1}
  elseif args.hf ~= nil then
    return false, 'hf belongs to EngraveSlab only'
  end
  local spec = {job = job, amount_total = amount, frequency = 'OneTime', tag = 'dfllm:cmd'}
  if args.frequency ~= nil then
    if not FREQ[args.frequency] then return false, 'bad frequency' end
    spec.frequency = args.frequency
  end
  for _, k in ipairs({'item_subtype', 'material', 'reaction'}) do
    if args[k] ~= nil then
      if type(args[k]) ~= 'string' or #args[k] > 80 then return false, k .. ' must be a string' end
      spec[k] = args[k]
    end
  end
  -- BUG-666 (Run 16d i4 Trumpetrealms y438: the only door order was 'Make rock door' beside 99 logs and 0 usable stone, the player found no verb for
  -- a wooden door): `mat` is the short way: wood = material_category [wood] (the Carpenters), rock = material INORGANIC (the Masons)
  if args.mat ~= nil then
    if args.mat ~= 'wood' and args.mat ~= 'rock' then return false, 'mat must be wood or rock' end
    if args.material ~= nil or args.material_category ~= nil then return false, 'mat replaces material and material_category: give one of them' end
    if args.mat == 'wood' then spec.material_category = {'wood'} else spec.material = 'INORGANIC' end
  end
  if args.material_category ~= nil then
    if type(args.material_category) ~= 'table' or #args.material_category == 0 then return false, 'material_category must be a list' end
    local mc = {}
    for _, v in ipairs(args.material_category) do
      if type(v) ~= 'string' or not v:match('^[a-z0-9_]+$') then return false, 'bad material_category' end
      mc[#mc + 1] = v
    end
    spec.material_category = mc
  end
  local ok, id = K.act.workorder(spec)
  if not ok then return false, 'workorder: ' .. tostring(id) end
  K.log('info', 'order %s x%d added by %s (order %s)', job, amount, tostring(cmd and cmd.by), tostring(id))
  return true, string.format('order %s %s x%d', tostring(id), job, amount), {order = math.tointeger(id) or -1}
end

-- orders.cancel {id? | stuck?, force?} (BUG-526, Run 16c i3 Sealcertain: 36 stuck orders and a jammed forge, no verb to remove one):
-- takes ONE manager order off the work orders screen (id; list them with `inspect what=orders`) or, with stuck=true, up to
-- CANCEL_MAX of the orders the kernel's ledger calls stuck (p.ostuck, ORDER_STUCK). The supply orders (brewing, meals, barrels,
-- raw fish: keep_order) are refused unless force=true. A kernel-owned order (one with a tag) is not entered again for
-- orders.backoff_days; jobs it already made keep running (act.order_remove).
M.CANCEL_MAX = 40
M.verbs['orders.cancel'] = function(K, args, cmd)
  local p = pstate(K)
  local id = math.tointeger(args.id)
  if args.id ~= nil and (not id or id < 0) then return false, 'orders.cancel: id must be an order id (dfllm cmd inspect what=orders)' end
  if args.force ~= nil and type(args.force) ~= 'boolean' then return false, 'orders.cancel: force must be true or false' end
  if args.stuck ~= nil and type(args.stuck) ~= 'boolean' then return false, 'orders.cancel: stuck must be true or false' end
  if (id ~= nil) == (args.stuck == true) then return false, 'orders.cancel: give either id=<order> or stuck=true' end
  local ids = {}
  if id then ids[1] = id
  else
    for key in pairs(p.ostuck or {}) do
      local n = math.tointeger(tonumber(key))
      if n then ids[#ids + 1] = n end
    end
    table.sort(ids)
    while #ids > M.CANCEL_MAX do table.remove(ids) end
    if #ids == 0 then return true, 'orders.cancel: no order is stuck', {removed = 0, kept = 0} end
  end
  local c = M.conf(K)
  local backoff = ((c.orders or {}).backoff_days or 10) * DAY
  local now = K.now().tick
  local gone, kept = {}, {}
  for _, oid in ipairs(ids) do
    local o = order_by_id(oid)
    if not o then
      if id then return false, string.format('orders.cancel: no order %d (it is done or gone)', oid) end
      p.ostuck[tostring(oid)] = nil
    elseif keep_order(o) and args.force ~= true then
      kept[#kept + 1] = oid
      if id then
        return false, string.format('orders.cancel: order %d is a supply order (brewing, meals, barrels, fish): add force=true to remove it', oid)
      end
    else
      local okn, jn = pcall(job_name, o)
      local left = math.tointeger(o.amount_left) or 0
      if K.act.order_remove(oid) then
        gone[#gone + 1] = oid
        p.ostuck[tostring(oid)], p.ocancel[tostring(oid)], p.ostale[tostring(oid)] = nil, nil, nil
        for tag, oi in pairs(p.orders) do
          if oi == oid then p.orders[tag], st.backoff[tag] = nil, now + backoff end
        end
        K.log('warn', 'order %d %s x%d removed by %s (orders.cancel)', oid, okn and tostring(jn) or '?', left,
              tostring(cmd and cmd.by))
      elseif id then return false, 'orders.cancel: the work orders screen refused to remove order ' .. oid end
    end
  end
  K.persist.touch('m.economy')
  return true, string.format('orders.cancel: %d order%s removed%s%s', #gone, #gone == 1 and '' or 's',
                             #gone > 0 and (' (' .. table.concat(gone, ',', 1, math.min(#gone, 12)) .. (#gone > 12 and ',..' or '') .. ')') or '',
                             #kept > 0 and (', ' .. #kept .. ' supply order(s) kept (force=true)') or ''),
         {removed = #gone, kept = #kept, ids = json.array({table.unpack(gone, 1, math.min(#gone, 40))})}
end

-- BUG-734: stone.use {mat, economic?} -- the stone-use screen for one stone type the fort holds as boulders: economic false (the default)
-- frees it for furniture and blocks (the masons may use it up; an ore or a flux stone is then no reserve), true marks it economic again.
-- The player's own decision when no plain hard stone exists (the DECISION no_hard_stone names the command); any mode.
M.verbs['stone.use'] = function(K, args, cmd)
  local nm = type(args.mat) == 'string' and args.mat:gsub('^[Ii][Nn][Oo][Rr][Gg][Aa][Nn][Ii][Cc]:', ''):lower() or nil
  if not nm or nm == '' then return false, 'stone.use: mat must be a stone name (the DECISION names it, e.g. chalk)' end
  if args.economic ~= nil and type(args.economic) ~= 'boolean' then return false, 'stone.use: economic must be true or false' end
  local eco = args.economic == true
  local idx, n, tok = nil, 0, nil
  pcall(function()
    local v = df.global.world.items.other.BOULDER
    for i = 0, #v - 1 do
      local it = v[i]
      local f = it and it.flags
      if f and not f.removed and not f.garbage_collect and not f.trader and it.mat_type == 0 then
        local t = dfhack.matinfo.decode(0, it.mat_index):getToken()
        if type(t) == 'string' and (t:gsub('^INORGANIC:', '')):lower() == nm then
          idx, tok = it.mat_index, t
          n = n + 1
        end
      end
    end
  end)
  if not idx then return false, string.format('stone.use: the fort holds no %s boulder (names: dfllm cmd inspect what=workload)', nm) end
  local o = ore_of(idx)
  if o.soft and not eco then return false, string.format('stone.use: %s is soft stone (no furniture or blocks from it): the game refuses it, not the stone-use screen', nm) end
  local ok, done, how = pcall(K.act.stone_economic, idx, eco)
  if not ok or done ~= true then return false, 'stone.use: ' .. tostring(ok and how or done) end
  orec[idx] = nil                                        -- the census reads the raws and the mark afresh
  st.hard = nil                                          -- the denial memory goes with it (BUG-648)
  K.persist.touch('m.economy')
  K.log('warn', 'economy: stone.use %s by %s: %s (%d boulders)', tok or nm, tostring(cmd and cmd.by), eco and 'marked economic' or 'cleared for furniture', n)
  return true, string.format('stone.use: %s %s (%d boulders in the fort); the next census counts it %s', nm,
                             eco and 'marked economic' or 'freed for furniture and blocks', n, eco and 'unusable' or 'usable'),
         {mat = nm, boulders = n, economic = eco, ore = o.metals ~= nil or nil, flux = o.flux or nil}
end

-- jobs.release {all?, preventblocking?} (FR-16): resumes suspended construction jobs (all = also the ones
-- suspendmanager keeps; buildingplan's planned ones never) and/or sets suspendmanager's preventblocking, a
-- decision economy keeps (persisted) and applies again after every load
local NO_BUILD = {SIEGE = true, BREACH = true, DRILL = true}
M.verbs['jobs.release'] = function(K, args, cmd)
  if args.all ~= nil and type(args.all) ~= 'boolean' then return false, 'all must be true or false' end
  if args.preventblocking ~= nil and type(args.preventblocking) ~= 'boolean' then
    return false, 'preventblocking must be true or false'
  end
  local p = pstate(K)
  local msg = {}
  if args.preventblocking ~= nil then
    local want = args.preventblocking and 'on' or 'off'
    if not K.act.run('suspendmanager', 'set', 'preventblocking', args.preventblocking and 'true' or 'false') then
      return false, 'suspendmanager set preventblocking failed'
    end
    p.pb, st.pb = want, want
    K.persist.touch('m.economy')
    msg[#msg + 1] = 'preventblocking ' .. want
  end
  local list = M.suspended_jobs(400)
  local ids, cnt, kept, planned = {}, {}, 0, 0
  for _, j in ipairs(list) do
    cnt[j.why] = (cnt[j.why] or 0) + 1
    if j.planned then planned = planned + 1
    elseif j.kept and args.all ~= true then kept = kept + 1
    elseif #ids < 200 then ids[#ids + 1] = j.id end
  end
  local n = 0
  if #ids > 0 then
    if NO_BUILD[K.mode()] then return false, 'not in ' .. K.mode() .. ' (builders would leave the shelter)' end
    local ok, res = K.act.job_resume(ids)
    n = ok and (math.tointeger(res) or 0) or 0
  end
  msg[#msg + 1] = string.format('resumed %d of %d suspended construction jobs (kept %d, planned %d; unverified: the '
                                .. 'daily pass unforbids items on the sites and checks the resumes a frame later)', n,
                                #list, kept, planned)
  if args.all == true and pb_choice(M.conf(K), p) ~= 'off' and n > 0 then
    msg[#msg + 1] = 'suspendmanager may suspend blocking ones again (preventblocking on)'
  end
  return true, table.concat(msg, '; '), {resumed = n, suspended = #list, kept = kept, planned = planned,
                                         why = json.object(cnt)}
end

---------------------------------------------------------------- inspect (read-only, <= 8 KB)
local function top(map, n)
  local list = {}
  for k, v in pairs(map or {}) do list[#list + 1] = {k, v} end
  table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
  local r = {}
  for i = 1, math.min(n, #list) do r[#r + 1] = {why = list[i][1], n = list[i][2]} end
  return r
end

-- inspect what=orders (FR-01/FR-39): open manager orders with their blockers, cancels and stuck days; the unsafe,
-- stuck and cancelling ones first, as many as fit the 8 KB reply (`more` = the ones left out)
local INSPECT_BYTES = 7000
M.inspect.orders = function(K, args)
  local p = pstate(K)
  local all, n = {}, 0
  local now = K.now().tick
  for _, o in ipairs(orders_all()) do
    if (o.amount_left or 0) > 0 then
      n = n + 1
      if #all < 200 then
        local key = tostring(o.id)
        local okn, job = pcall(job_name, o)
        local okv, valid = pcall(function() return o.status.validated == true end)
        local e = {id = o.id, job = okn and tostring(job) or '?', name = order_name(o):sub(1, 40), left = o.amount_left,
                   valid = okv and valid and 1 or 0}
        local rank = 3
        if okn and OL.unsafe(job, o.item_subtype) then e.unsafe, rank = 1, 0 end
        local rec = p.ostuck[key]
        if type(rec) == 'table' then
          e.why, e.days, e.kind = rec.why, (now - (math.tointeger(rec.since) or now)) // DAY, rec.kind
          rank = math.min(rank, 1)
        end
        local cr = p.ocancel[key]
        if type(cr) == 'table' then e.cancels, e.cancel_why, rank = cr.n, cr.why, math.min(rank, 2) end
        all[#all + 1] = {rank, e}
      end
    end
  end
  table.sort(all, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2].id < b[2].id end)
  -- B2: the slab pass (BUG-061), the workshops' job lists and jam, the orders that wait without a job (BUG-060)
  local extra = {}
  if st.slab then extra.slabs = st.slab end
  if st.shops then extra.shops = json.array(st.shops) end
  if st.jam then extra.jam = st.jam end
  local stale = {}
  for key, rec in pairs(p.ostale) do
    local d = (now - (math.tointeger(rec.since) or now)) // DAY
    if d >= 1 then stale[#stale + 1] = {id = math.tointeger(tonumber(key)) or -1, days = d, left = rec.left} end
  end
  table.sort(stale, function(a, b) if a.days ~= b.days then return a.days > b.days end return a.id < b.id end)
  while #stale > 12 do table.remove(stale) end
  if #stale > 0 then extra.stale = json.array(stale) end
  local oke, enc0 = pcall(json.encode, extra)
  local list, bytes = {}, oke and #enc0 or 0
  for _, x in ipairs(all) do
    local ok, enc = pcall(json.encode, x[2])
    bytes = bytes + (ok and #enc or 200) + 1
    if bytes > INSPECT_BYTES then break end
    list[#list + 1] = x[2]
  end
  local od = st.orders or {}
  local data = {n = n, stuck = od.stuck or 0, bad = od.bad or 0, list = json.array(list), more = n - #list}
  for k, v in pairs(extra) do data[k] = v end
  return true, string.format('%d open orders, %d stuck, %d unsafe%s', n, od.stuck or 0, od.bad or 0,
                             st.jam and (', JAM ' .. st.jam) or ''), data
end

-- the census' pick and axe counts (inspect workload `tools`): all, free (nobody carries them), of them in a bin,
-- reserved by a squad uniform, marked for melting, owned; and the forbidden ones nobody carries (BUG-023)
function M.tool_counts(inv)
  local t = {}
  for _, k in ipairs({'pick', 'axe'}) do
    t[k] = inv['w_' .. k] or 0
    for _, s in ipairs({'free', 'bin', 'res', 'forb', 'melt', 'own', 'far', 'use'}) do t[k .. '_' .. s] = inv['w_' .. k .. '_' .. s] or 0 end
  end
  return t
end

-- inspect what=workload key=tools (BUG-023 round 5): the tool details' diagnosis, every free tool and member record of
-- tool_check's last daily pass (M.tool_diag), the census counts
function M.inspect_tools(K)
  local out = {}
  for name, dg in pairs(st.tdiag or {}) do
    local ps, us = {}, {}
    for _, x in ipairs(dg.picks) do ps[#ps + 1] = M.td_pick_str(x) end
    for _, x in ipairs(dg.units) do us[#us + 1] = M.td_unit_str(x) end
    local b = (st.tblk or {})[name] or {}
    out[#out + 1] = {detail = name, tool = b.tool, n = b.n, of = b.of, jobs = b.jobs, days = b.days, keys = dg.keys,
                     why = dg.texts, civ = dg.civ, ww = dg.ww, picks = json.array(ps), units = json.array(us)}
  end
  table.sort(out, function(x, y) return x.detail < y.detail end)
  local first = out[1]
  local okp, p = pcall(pstate, K)
  return true, first and string.format('%d tool details blocked; %s: %s', #out, first.detail, first.why[1] or '?') or
                 'no tool detail blocked', {blocked = json.array(out), tools = M.tool_counts(K.census.i or {}),
                                            pile = okp and M.pile_text(p) or nil, piles = #M.tool_piles(),
                                            stale = {pick = (st.tstale or {}).pick or 0, axe = (st.tstale or {}).axe or 0}}
end

-- inspect what=workload (FR-40): adults without a job, unclaimed jobs by type, top cancel reasons, free tools,
-- suspended construction jobs and the starvation report. Run 10 (Handlelock) listed 45 PlantSeeds jobs as unclaimed
-- that were all taken and 32 GatherPlants jobs outside the wall that nobody could reach. Now a job is unclaimed only
-- without a worker and, when DF's job board (world.jobs.postings) is readable, with a live posting (`waiting` = jobs
-- neither worked nor posted); an unclaimed job on no citizen's walk group (snapshot.groups; a wall or trunk counts by
-- its neighbours) is `unreachable`, and an idle adult whose walk group holds no unclaimed job while there are some is
-- `idle_noreach` (idle, no reachable work). `blocked`: the tool details' TOOL_BLOCKED state (BUG-023; with key=tools only
-- their diagnosis, M.inspect_tools); `cloth`: thread, spider webs (none of them collected, BUG-024) and care's naked count.
local JOB_SCAN = 50000
local function job_board()
  local set, n = {}, 0
  local ok = pcall(function()
    for _, ps in ipairs(df.global.world.jobs.postings) do
      local j = ps.job
      if j and not (ps.flags and ps.flags.dead) then set[j.id] = true; n = n + 1 end
    end
  end)
  return ok and n > 0 and set or nil
end

-- inspect what=workload key=details (BUG-057, note 54: who resets the work details?): Planters, the plant gathering
-- detail and Fisherdwarves with their mode, members, the ones the kernel added, the ones that vanished without the
-- kernel, and the last cover pass (jobs unclaimed / reachable / holders / members / target / why not)
function M.inspect_details(K)
  local p = K.persist.get('m.economy')
  p = type(p) == 'table' and p or {}
  local cvp = type(p.cover) == 'table' and p.cover or {}
  local c = M.conf(K)
  local wm = df.work_detail_mode or {}
  local names = {}
  for _, s in ipairs(M.cover_specs(type(c.cover) == 'table' and c.cover or {})) do
    local nm = find_detail(s.det and ((c.starve or {}).details or {})[s.det] or nil, s.labor)
    if nm and not M.TOOL_DETAILS[nm] then names[#names + 1] = nm end
  end
  for _, d in ipairs((c.tools or {}).details or {}) do if d.fish then names[#names + 1] = d.name end end
  local list, parts = {}, {}
  for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do
    local nm = dfhack.df2utf(w.name)
    for _, want in ipairs(names) do
      if nm == want then
        local mode = math.tointeger(w.flags and w.flags.mode)
        local mine = type((cvp.mine or {})[nm]) == 'table' and #cvp.mine[nm] or 0
        local lost = math.tointeger((cvp.lost or {})[nm]) or 0
        list[#list + 1] = {detail = nm, mode = tostring(wm[mode] or mode), members = #w.assigned_units, mine = mine,
                           lost = lost}
        parts[#parts + 1] = string.format('%s %d members (%s%s%s)', nm, #w.assigned_units, tostring(wm[mode] or mode),
                                          mine > 0 and (', ' .. mine .. ' added by the kernel') or '',
                                          lost > 0 and (', ' .. lost .. ' vanished without it') or '')
      end
    end
  end
  local rows = {}
  for _, row in ipairs((st.cover or {}).rows or {}) do
    rows[#rows + 1] = {key = row.key, detail = row.name, labor = row.labor, open = row.open, reach = row.reach,
                       far = row.far, holders = row.holders, cur = row.cur, want = row.want, add = row.add, rem = row.rem,
                       why = row.why}
  end
  local af = type(p.af) == 'table' and p.af or {}
  return true, (#parts > 0 and table.concat(parts, '; ') or 'no detail found'):sub(1, 400),
         {details = json.array(list), rows = json.array(rows), withdrawn = (st.cover or {}).withdrawn or 0,
          autofarm = {off = af.off ~= nil and 1 or 0, why = af.why, wiped = math.tointeger(af.wiped) or 0,
                      engine_off = st.af_off and 1 or 0}}
end

-- FR-90 (Run 14 note 98): inspect what=items key=trash, read only: loose items, DumpItem jobs, the dump zones, the reason the
-- jobs cancel (lua/dfllm/trash.lua); st.dump = what cancel() saw of the "Dump item" cancels today
M.inspect.items = function(K, args)
  local key = type(args) == 'table' and args.key or nil
  if key ~= 'trash' then return false, 'items: key must be trash' end
  return require('dfllm.trash').inspect(K, st.dump)
end

M.inspect.workload = function(K, args)
  if type(args) == 'table' and args.key == 'tools' then return M.inspect_tools(K) end
  if type(args) == 'table' and args.key == 'details' then return M.inspect_details(K) end
  -- BUG-044: key 'build:x,y,z' = what the building on that tile and its job wait for (build_state), read-only
  local bx, by, bz = tostring(type(args) == 'table' and args.key or ''):match('^build:(%-?%d+),(%-?%d+),(%-?%d+)$')
  if bx then
    local r = M.build_state(K, tonumber(bx), tonumber(by), tonumber(bz))
    return r ~= nil, r and r.line or 'bad tile', r
  end
  local cu = K.census.u or {}
  local sold = {}
  for _, id in ipairs(cu.soldier_ids or {}) do sold[id] = true end
  local idle, idle_at, adults, pts = {}, {}, 0, {}
  for _, id in ipairs(cu.ids or {}) do
    local u = df.unit.find(id)
    if u then
      local okp, x, y, z = pcall(function() return u.pos.x, u.pos.y, u.pos.z end)
      pts[#pts + 1] = okp and x and {x, y, z} or false
      if not sold[id] and dfhack.units.isAdult(u) then
        adults = adults + 1
        if u.job == nil or u.job.current_job == nil then idle[#idle + 1] = id; idle_at[#idle] = #pts end
      end
    end
  end
  local posted = job_board()
  local open_t, open_p, waiting, sus, total = {}, {}, 0, 0, 0
  pcall(function()
    local link, i = df.global.world.jobs.list.next, 0
    while link and i < JOB_SCAN do
      local j = link.item
      if j then
        total = total + 1
        if j.flags.suspend then sus = sus + 1
        else
          local okw, w = pcall(dfhack.job.getWorker, j)
          if okw and w == nil then
            if posted and not posted[j.id] then waiting = waiting + 1
            else
              open_t[#open_t + 1] = df.job_type[j.job_type] or '?'
              local okp, x, y, z = pcall(function() return j.pos.x, j.pos.y, j.pos.z end)
              open_p[#open_p + 1] = okp and x and {x, y, z} or false
            end
          end
        end
      end
      link, i = link.next, i + 1
    end
  end)
  local okc, cg = K.call('snapshot', 'groups', pts, false)
  cg = okc and type(cg) == 'table' and cg or {}
  local home = M.home_groups(K, cg)
  local okj, jg = K.call('snapshot', 'groups', open_p, true, home)     -- BUG-390
  jg = okj and type(jg) == 'table' and jg or {}
  local known = next(home) ~= nil
  -- FR-72 (Run 12 y504: 275 GatherPlants jobs, HERBALIST on nobody, '0 without reachable work'): a job type of
  -- cover.labors whose labor no adult citizen holds is not work for the idle: counted apart, named in the line
  local lab_of = type(M.conf(K).cover) == 'table' and type(M.conf(K).cover.labors) == 'table' and M.conf(K).cover.labors
                 or {}
  local hold = {}
  for _, lb in pairs(lab_of) do hold[lb] = 0 end
  for _, id in ipairs(cu.ids or {}) do
    local u = not sold[id] and df.unit.find(id)
    if u and dfhack.units.isAdult(u) then
      for lb in pairs(hold) do if labor_on(u, lb) then hold[lb] = hold[lb] + 1 end end
    end
  end
  local open, far, by_grp, by_nl, n_open, n_far, nolab = {}, {}, {}, {}, 0, 0, {}
  for k, tn in ipairs(open_t) do
    local g = math.tointeger(jg[k]) or -1
    if known and g >= 0 and not home[g] then
      far[tn], n_far = (far[tn] or 0) + 1, n_far + 1
    else
      open[tn], n_open = (open[tn] or 0) + 1, n_open + 1
      local key = g > 0 and g or 'any'
      if lab_of[tn] and hold[lab_of[tn]] == 0 then
        by_nl[key] = (by_nl[key] or 0) + 1
        nolab[tn] = (nolab[tn] or 0) + 1
      else by_grp[key] = (by_grp[key] or 0) + 1 end
    end
  end
  -- FR-77: every idle adult gets one reason: his own state (mood, hurt, rest: M.idle_flags), else the job board and the
  -- walk groups: no reachable work, no labor holder (every reachable open job needs a labor nobody holds), no work at all
  -- (held when the kernel holds projects back by a rule of its own, else nowork), or free (reachable work with a holder
  -- exists and he has none yet). `idle_probe` lists the raw fields of a few `free` ones for the next live look.
  local sold_n = #(cu.soldier_ids or {})
  local rq, rd = runner_queue(K)
  local held_n = M.held_projects(K, type(rd) == 'table' and rd.n or nil)
  local all_unheld = n_open > 0
  if all_unheld then
    local holders = {}
    pcall(function()
      for _, id in ipairs(cu.ids or {}) do
        local u = not sold[id] and df.unit.find(id)
        if u and dfhack.units.isAdult(u) then
          for tn in pairs(open) do
            local ln = M.JOB_LABOR[tn]
            if ln then
              local lid = df.unit_labor and df.unit_labor[ln]     -- the labor by name or by its id
              if labor_on(u, ln) or (type(lid) == 'number' and labor_on(u, lid)) then holders[tn] = true end
            end
          end
        end
      end
    end)
    for tn in pairs(open) do
      local ln = M.JOB_LABOR[tn]
      -- a job type without a known labor, or a labor this game does not name, is not judged
      if not ln or holders[tn] or type(df.unit_labor and df.unit_labor[ln]) ~= 'number' then all_unheld = false; break end
    end
  end
  local why_n = {}
  for _, c in ipairs(M.IDLE_CLASSES) do why_n[c] = 0 end
  local probe = {}
  for k, id in ipairs(idle) do
    local u = df.unit.find(id)
    local c = u and M.idle_class(M.idle_flags(u))
    if not c then
      local g = math.tointeger(cg[idle_at[k]]) or -1
      if n_open + n_far > 0 and g > 0 and (by_grp[g] or 0) + (by_grp.any or 0) == 0 then
        c = ((by_nl[g] or 0) + (by_nl.any or 0) > 0) and 'nolabor' or 'noreach'   -- FR-72: only jobs nobody holds the labor for
      elseif n_open == 0 then c = (n_far == 0 and held_n > 0) and 'held' or 'nowork'
      elseif all_unheld then c = 'nolabor'
      else c = 'free' end
    end
    why_n[c] = why_n[c] + 1
    if c == 'free' and #probe < 5 and u then
      local o = {id = id}
      pcall(function() o.sleepy = u.counters2.sleepiness_timer end)
      pcall(function() o.tired = u.counters2.exhaustion end)
      pcall(function() o.hunger, o.thirst = u.counters2.hunger_timer, u.counters2.thirst_timer end)
      pcall(function() o.mood = u.mood end)
      pcall(function() o.acts = #u.actions end)
      probe[#probe + 1] = o
    end
  end
  local noreach = why_n.noreach
  local why = {}
  for k, v in pairs(st.why_prev or {}) do why[k] = v end
  for k, v in pairs(st.why or {}) do why[k] = (why[k] or 0) + v end
  local function jobs_of(map, n)
    local list = {}
    for _, e in ipairs(top(map, n)) do list[#list + 1] = {job = e.why, n = e.n} end
    return list
  end
  local inv = K.census.i or {}
  local names = {}
  for i = 1, math.min(10, #idle) do names[i] = {id = idle[i], name = unit_name(idle[i]):sub(1, 40)} end
  local sj = st.jobs
  local jobs = sj and {suspended = sj.suspended, released = sj.released, kept = sj.kept, planned = sj.planned,
                       why = top(sj.why, 5), resuspended = sj.resuspended or 0, forbidden = sj.forbidden or 0,
                       other = sj.other or 0, unforbidden = sj.unforbidden or 0, missing = json.array(sj.missing or {}),
                       blocked = json.array(sj.blocked or {}), depot_move = st.depot_move} or json.object{}
  local sv = st.starve
  local blocked = {}
  for name, b in pairs(st.tblk or {}) do
    blocked[#blocked + 1] = {detail = name, tool = b.tool, n = b.n, of = b.of, jobs = b.jobs, days = b.days, why = b.why,
                             forb = b.forb, blk = b.blk, blk_why = b.blk_why and b.blk_why:sub(1, 120) or nil}
  end
  table.sort(blocked, function(x, y) return x.detail < y.detail end)
  local care = (K.view() or {}).care
  local webs, near, thread = inv.webs or 0, inv.webs_near or 0, inv.thread or 0
  local cloth = {thread = thread, webs = webs, webs_near = near,
                 naked = type(care) == 'table' and math.tointeger(care.naked) or nil}
  if thread == 0 and webs > 0 then
    cloth.why = near > 0 and string.format('no collected thread: %d webs on the walk group (weavers collect them)', near)
                or 'no collected thread: the webs lie off the citizens\' walk group'
  end
  local nl_list = {}
  for tn, n in pairs(nolab) do nl_list[#nl_list + 1] = {job = tn, n = n, labor = lab_of[tn]} end
  table.sort(nl_list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.job < b.job end)
  local data = {adults = adults, idle = #idle, idle_noreach = noreach, idle_nolabor = why_n.nolabor, idle_why = why_n,
                soldiers = sold_n, held_projects = held_n, idle_probe = json.array(probe), nolabor = json.array(nl_list),
                idle_units = names, jobs = total,
                suspended = sus, waiting = posted and waiting or nil,
                unclaimed = jobs_of(open, 12), unreachable = jobs_of(far, 8), cancels = top(why, 8),
                tools = M.tool_counts(inv),
                blocked = json.array(blocked), cloth = cloth,
                construction = jobs,
                -- Run 11: stone against the rock orders, picks against the Miners, pieces nothing in the fort can make
                stone = st.rock or json.object{}, picks = st.picks or json.object{}, short = json.array(st.short or {}),
                starve = sv and {hungry = sv.hungry, cut = #sv.cut, cut_units = {table.unpack(sv.cut, 1, math.min(10, #sv.cut))},
                                 marked = sv.marked, added = sv.added, unreach = sv.unreach} or json.object{}}
  -- BUG-037 (Run 11 y449: '15 without reachable work, 0 unclaimed jobs' while six projects stood queued for months): the
  -- runner's queue is named as the reason ('runner: 6 projects queued behind 3 slot holders without progress (...)')
  data.runner = rd
  -- BUG-654: workshop types no citizen can walk to (p.cutws, M.cut_scan) and the jobs posted at them: the reason of an 'unreachable
  -- PrepareMeal' (a Kitchen in a flooded level), not only the count
  local pc, cut_l, cut_t = pstate(K), {}, {}
  for _, t in ipairs(M.cut_types(pc)) do
    local rec = pc.cutws[t]
    cut_l[#cut_l + 1] = {type = t, at = rec.at, grp = rec.grp, home = rec.home, n = rec.n,
                         days = math.max(0, (K.now().tick - (math.tointeger(rec.t) or K.now().tick)) // DAY)}
    cut_t[#cut_t + 1] = M.cut_text(pc, t)
  end
  data.shops_cut = json.array(cut_l)
  local cut_s = #cut_t > 0 and ('workshops cut off: ' .. table.concat(cut_t, '; ')) or nil
  -- the clause names the classes that are not zero (the reply is cut at 300 bytes; all numbers are in data.idle_why)
  local CL = {rest = 'rest', hurt = 'hurt', mood = 'mood', held = 'held by the kernel', nolabor = 'no labor holder',
              noreach = 'no reachable work', nowork = 'no work', free = 'free'}
  local parts = {}
  for _, c in ipairs(M.IDLE_CLASSES) do
    if why_n[c] > 0 then
      local more = ''
      if c == 'nolabor' and #nl_list > 0 then      -- FR-72: which open jobs lack a holder, and of which labor
        local ds = {}
        for i = 1, math.min(2, #nl_list) do
          ds[i] = string.format('%s %d need %s', nl_list[i].job, nl_list[i].n, nl_list[i].labor)
        end
        more = ' (' .. table.concat(ds, ', ') .. ')'
      end
      parts[#parts + 1] = string.format('%s %d%s', CL[c], why_n[c], more)
    end
  end
  if sold_n > 0 then parts[#parts + 1] = string.format('%d soldiers not counted', sold_n) end
  return true, string.format('%d of %d adults without a job (%s), %d unclaimed jobs, %d unreachable', #idle, adults,
                             #parts > 0 and table.concat(parts, ', ') or 'none', n_open, n_far)
                .. (cut_s and ('; ' .. cut_s) or '') .. (rq and ('; ' .. rq) or ''), data
end

return M
