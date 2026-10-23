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
  pieces = {max_n = 6, report_days = 28, tag = 'dfllm:piece_'},
  rock = {drop_per_day = 20, request_days = 7, rooms = 4},
  -- Run 11: 2 picks for the Miners' target and 1 iron bar: a pick from the first metal with a spare bar at a forge,
  -- else economy.trade_wants asks the caravans for picks (trade puts it before plan.trade.want)
  picks = {tag = 'dfllm:pick', metals = {'COPPER', 'BISMUTH_BRONZE', 'BRONZE', 'IRON', 'STEEL'}, max_jobs = 2},
  -- Run 11 (Kilrudrabed y431-y441: no metal ore on the site, bars 0 for ten years, the caravans were never asked for
  -- iron; 10 soldiers at worn 58 % lost siege 8): metal is short while soldiers are wanted, they wear < `worn` %, no ore
  -- boulder of a gear metal lies in the fort and the gear-metal bars are below what the soldiers' metal slots want
  -- (M.metal_plan). Then trade_wants asks every caravan for `wants` in this order (n = the bars short, or that slot's
  -- missing pieces) after picks and axes up to `tools` (military's tools-first minimum), and the fort keeps `crafts`
  -- crafts to sell for it (MakeCrafts in free stone, else wood above idle.wood_min; at most `craft_jobs` an order)
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
  -- BUG-053 (Run 11 y487: 16 free picks 'loose' for 1081 days; Run 12 y501, a reclaimed fort: pick_free 100 for 144 days):
  -- free tools a detail's members lack for `stale_days` (no member-side cause: labor, tool2) stop counting as stock
  -- (plan_picks, metal_plan: the forge and the caravans make up the picks); usable ones that lie loose get a weapons
  -- stockpile `dfllm-tools` after `pile_days` (act.tool_pile, `pile_w` x `pile_h`, on revealed plain floor within
  -- `pile_r` tiles of the open jobs, at most `pile_reads` tile reads, one attempt per `pile_every` days); `pile` false = none
  tools = {shrink_days = 3, block_days = 3, repair_days = 7, equip_update = true,
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
                      {name = 'Fisherdwarves', skill = 'FISH', labor = 'FISH', fish = true, per = 15, max = 3,
                       min = 3, min_per = 6}}},
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
  fishing = {r = 48, levels = 6, tiles = 1500, min_flow = 2, side = 3, scan_days = 7, reads = 200, checks = 160,
             max_water = 3000},
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
  food = {yield = 1, per_dwarf = 3, plot_tiles = 35, plots_max = 4, want_days = 90, trend_days = 14,
          request_days = 14, pre_days = 30, crops_per_dwarf = 4, crops_min = 50, crops_max = 400, crops_step = 10,
          status_days = 7, meals_per_dwarf = 2, cit_per_job = 2},
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
  cloth = {from_phase = 'P1', per_naked = 3, max_jobs = 10, loom = {'workshop:Loom'},
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
  glass = {from_phase = 'P3', raw = 3, bags = 2, max_jobs = 5, request_days = 14, report_days = 28,
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
             leather = {job = 'MakeHelm', sub = 'ITEM_HELM_HELM', n = 1}},
            {cat = 'pants', who = 'all', metal = {job = 'MakePants', sub = 'ITEM_PANTS_GREAVES', bars = 2},
             leather = {job = 'MakePants', sub = 'ITEM_PANTS_LEGGINGS', n = 1}},
            {cat = 'gloves', who = 'all', per = 2, out = 2, metal = {job = 'MakeGloves', sub = 'ITEM_GLOVES_GAUNTLETS', bars = 1},
             leather = {job = 'MakeGloves', sub = 'ITEM_GLOVES_GLOVES', n = 1}},
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
  -- its chair and table (M.office_check: `office`)
  orders = {stuck_days = 3, needs_drop = 10, backoff_days = 10, report_per_day = 3, manager_days = 3, unval_days = 2},
  -- BUG-042: the manager's Office zone needs a chair (and a table: the live fix was both) to validate work orders; a
  -- missing one is placed on a free floor tile of the zone (runner.repair: quickfort build, buildingplan waits for the
  -- item) at most every retry_days; zones larger than max_tiles are searched only that far
  office = {table = true, retry_days = 7, max_tiles = 400},
  -- BUG-061 (Run 13 y523: 31 EngraveSlab orders, "Needs unengraved slab", filled the masons' slots with jobs that
  -- cancelled at once; doors, coffins, tables and blocks waited ten game years; autoslab.cpp queues one EngraveSlab order
  -- per ghost every 1289 ticks and no ConstructSlab): at most `max_orders` EngraveSlab orders stand, never more than
  -- there are unengraved slabs, the rest are removed (at most `drop_per_day`; again at the first "unengraved slab"
  -- cancel past `trigger_ticks`); ConstructSlab is ordered first for the ghosts and the open engrave orders (at most
  -- `restock_cap` blank slabs); `jam_min` blocked jobs in a workshop type's slots (half of them at least) are a jam
  slabs = {max_orders = 3, restock_cap = 5, drop_per_day = 60, trigger_ticks = 600, scan_max = 2000, jam_min = 3},
  -- BUG-060 (Run 13 y508: 11 ConstructDoor INORGANIC orders, validated, made no job for months, five builds waited for
  -- doors; wood doors ordered by hand were built at once): a one-time validated order with no job in any workshop and an
  -- unchanged amount for `days` days (`wait_days` when a planned building waits for that piece) is stale: a stone
  -- furniture order is re-entered in wood, else a simple order is made again, else it is reported; at most `per_day`
  -- a day, only in PEACE and RECOVERY; `jobs_max` workshop jobs are read
  stale = {days = 10, wait_days = 3, per_day = 6, jobs_max = 2000},
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
  drink = {low_d = 60},
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
  farms = {per_day = 16, now_max = 24, autofarm = 'auto', af_off_days = 30, af_on_days = 90, af_hold_days = 14},
  forbid = {per_day = 30,
            -- FR-76 (Run 12 Trussroads, a reclaimed fort: 3026 of 3058 drinks, all food and 61 barrels forbidden, the
            -- status said "drink 46d!"): from burst_min forbidden drink + food units the items themselves are
            -- unforbidden whatever their reason (the 30 a day and "food only in a starvation" kept them forbidden for
            -- ever), burst_per_day a day, M.BURST_SLICE per frame; 0 = never a burst
            burst_per_day = 400, burst_min = 100},
  -- FR-25: below `days` food days with citizens over `hunger` (DF's "hungry" is 50000)
  starve = {days = 0, hunger = 50000, plants_max = 200, plants_per_slice = 400, report_days = 2, gatherers = 4,
            planters = 4, plants = {'GRASS_WHEAT_CAVE', 'MUSHROOM_HELMET_PLUMP', 'POD_SWEET', 'BUSH_QUARRY',
                                    'MUSHROOM_CUP_DIMPLE'},
            details = {planters = {'Planters'}, gatherers = {'Plant gatherers', 'Gatherers', 'Herbalists'}}},
  -- BUG-038 (Run 11, y451: food_low at 26 days, 450 unclaimed GatherPlants jobs, nobody gathered): below food.pre_days
  -- (the food_low line, famine included) with >= min_jobs unclaimed GatherPlants jobs, the plant gathering detail
  -- (starve.details.gatherers) gets members up to n (M.gather_low); the ones economy added leave at off_days food days
  -- BUG-042: also below drink_d drink days while the brewable plants (census brew_p + brew_g) cannot brew the deficit
  -- to the drink target (5 drinks a plant); the members stay until food >= off_days and drink >= drink_off (or enough
  -- brewable plants)
  gather = {n = 4, min_jobs = 10, off_days = 60, drink_d = 60, drink_off = 100},
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

local function phase_ok(K, from)
  if from == nil then return true end
  local ph = (K.view() or {}).phase
  return type(ph) == 'string' and ph >= from
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
      v = ok1 and (math.tointeger(k1) or -1) >= 0
      if not v and sub ~= -1 then
        local ok2, k2 = pcall(kit.findExclusion, {Cook = true}, itype, -1, t, i)
        v = ok2 and (math.tointeger(k2) or -1) >= 0
      end
    end
    row[i] = v
  end
  return v
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
function M.tool_listed(a, k, e, isfar)
  local list = a.tool_items[k]
  if #list < M.TOOL_LIST then list[#list + 1] = e; return end
  if isfar then return end
  for i = #list, 1, -1 do
    if list[i].far then list[i] = e; return end
  end
end
-- the order the diagnosis reads the listed tools in: free on the citizens' group, free on another, forbidden
function M.tool_rank(e) return e.forb and 3 or (e.far and 2 or 1) end
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
    if cat == 'WEAPON' then M.tool_forb(a, it) end
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
        if not M.cook_banned(a, cat, it) then a.cook_in = a.cook_in + n
        else
          a.cook_ban = a.cook_ban + n
          if cat == 'PLANT_GROWTH' then a.cook_ban_g = a.cook_ban_g + n end   -- M.food_unban
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
    local mt = it.mat_type
    if mt == 3 or mt == 4 or mt == 5 then a.gems_glass = a.gems_glass + n end
  elseif cat == 'ROUGH' then
    local mt = it.mat_type
    if mt == 3 or mt == 4 or mt == 5 then a.glass = a.glass + n; reach_mark(a, it, 'glass') else a.gems = a.gems + n end
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
  elseif cat == 'WOOD' then a.wood = a.wood + n; reach_mark(a, it, 'wood')
  elseif M.PIECE_INV[cat] then
    -- Run 11: free doors, hatch covers, grates and blocks (not built in, not taken by a job): what a seal piece or a
    -- planned building can use now (T.jmake, economy.mat_for)
    if not f.in_job then a[M.PIECE_INV[cat]] = a[M.PIECE_INV[cat]] + n end
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
    a.rock = a.rock + n
    if it.mat_type == 0 then
      local r = ore_of(it.mat_index)
      if r.metals and r.token then
        a.ore = a.ore + n
        local o = a.ores[r.token]
        if not o then o = {n = 0, metals = r.metals}; a.ores[r.token] = o end
        o.n = o.n + n
        reach_mark(a, it, 'ore:' .. r.token)
      end
      if r.flux then a.flux = a.flux + n end
      if r.econ or r.soft then a.rock_bad = (a.rock_bad or 0) + n
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
        elseif not f.owned and not f.melt then a['w_' .. k .. '_use'] = a['w_' .. k .. '_use'] + 1 end
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
      else
        local mf = mat_flags(it)
        if mf and mf.IS_METAL then a['g_' .. g] = a['g_' .. g] + 1; a.g_metal = a.g_metal + 1
        elseif mf and mf.LEATHER then a['g_' .. g] = a['g_' .. g] + 1 end
      end
    end
  end
end

local ZERO = {'drink', 'food', 'meals', 'cloth', 'leather', 'bone', 'shell', 'gems', 'bars', 'bolts', 'wood', 'fuel',
              'drink_forb', 'food_forb', 'cookable', 'barrels', 'barrels_empty', 'bins', 'bins_empty', 'rock', 'ore', 'rock_bad',
              'flux', 'hides', 'thread', 'thread_plant', 'thread_silk', 'thread_yarn', 'bolts_free', 'w_pick', 'w_axe',
              'w_xbow', 'w_bow', 'g_body', 'g_head', 'g_pants', 'g_gloves', 'g_shoes', 'g_shield', 'g_weapon', 'g_xbow',
              'g_quiver', 'g_metal', 'fish_raw', 'food_nocook', 'seeds_ok', 'seeds_forb', 'w_pick_free', 'w_axe_free',
              'w_pick_bin', 'w_axe_bin', 'w_pick_res', 'w_axe_res', 'webs', 'webs_near', 'glass', 'gems_glass', 'sand',
              'bags', 'doors', 'hatches', 'grates', 'blocks_free', 'cook_in', 'cook_ban', 'cook_ban_g', 'food_inedible', 'food_far',
              'w_pick_forb', 'w_axe_forb', 'w_pick_melt', 'w_axe_melt', 'w_pick_own', 'w_axe_own', 'melt',
              'w_pick_far', 'w_axe_far', 'w_pick_use', 'w_axe_use',
              'brew_p', 'brew_g', 'chairs', 'tables'}
local function new_acc(c)
  local fs = {}
  for _, k in ipairs(c.food_cats or {}) do fs[k] = true end
  local nocook = {}
  for _, e in ipairs(c.kitchen or {}) do
    if e.what == 'Cook' and e.item == 'PLANT' and type(e.plant) == 'string' then nocook[e.plant] = true end
  end
  local a = {kinds = {}, food_set = fs, bars_by = {}, ores = {}, seeds = {}, nocook = nocook, fix = {}, fix_seen = {},
             reach = {}, food_pos = {}, res = {}, tool_items = {pick = {}, axe = {}}, web_probes = 0, kc = {}, ined = {},
             bc = {}}
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
  st.fix, st.reach, st.food_pos, st.unreach = a.fix, a.reach, a.food_pos, a.unreach or 0
  st.tool_items, st.web_pos = a.tool_items, a.web_pos
  st.ined = M.top(a.ined, 3)                         -- Run 11: the inedible food materials (M.cook_why)
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
             stone = (i.rock or 0) - math.max((i.ore or 0) + (i.flux or 0), i.rock_bad or 0) >= 60}
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
  local parts, raw = {}, inv.fish_raw or 0
  if raw > 0 then
    parts[1] = string.format('%d raw fish %s', raw, ws_any(f or {}, M.FISHERY) and 'to clean' or 'need a fishery')
  end
  if (inv.food_inedible or 0) > 0 then
    local t = st.ined and st.ined[1]
    parts[#parts + 1] = string.format('%d inedible%s', inv.food_inedible,
                                      t and (' (' .. tostring(t[1]):gsub('^PLANT:', '') .. ')') or '')
  end
  if (inv.food_far or 0) > 0 then parts[#parts + 1] = string.format('%d cut off', inv.food_far) end
  if (inv.food_forb or 0) > 0 then parts[#parts + 1] = string.format('%d forbidden', inv.food_forb) end
  if (inv.cook_ban or 0) > 0 then parts[#parts + 1] = string.format('%d cook-banned', inv.cook_ban) end
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
        if (mc and mc.wood) or df.job_type[o.job_type] == 'MakeCharcoal' then s.used.wood = (s.used.wood or 0) + left end
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

-- care's pull hooks (live L4): reserved() -> {class = n}, mood_wants() -> {{cls, n}} | {class = n}
local function care_hooks(K, r)
  r.held = {}
  local res = care_hook(K, 'reserved')
  if type(res) == 'table' then
    for k, v in pairs(res) do
      local key, n = key_of(k), count_of(v)
      if KEYS[key] and n and n > 0 then r.held[key] = (r.held[key] or 0) + n end
    end
  end
  local wants = {}
  r.glass_cut = 0                                -- Run 11: "cut gems" the moods miss (cut glass serves them)
  local w = care_hook(K, 'mood_wants')
  if type(w) == 'table' then
    for k, v in pairs(w) do
      local key, n
      if type(k) == 'number' and type(v) == 'table' then key, n = key_of(v.cls or v.class or v.key), count_of(v.n or 1)
      else key, n = key_of(k), count_of(v) end
      if KEYS[key] and n and n > 0 then
        wants[key] = (wants[key] or 0) + n
        if type(v) == 'table' and v.glass == 'cut' then r.glass_cut = r.glass_cut + n end
      end
    end
  end
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
local function meal_jobs(c, r, e)
  local fc = c.food
  if e.key ~= 'food_d' or type(fc) ~= 'table' then return 0, e.max_jobs or 20 end
  local cit, inv = r.cit or 0, r.inv
  local want = cit * (fc.meals_per_dwarf or 0) - (inv.meals or 0)
  -- what a cook may use: EDIBLE_COOKED food that is no meal and not on the kitchen's Cook ban (plump helmets)
  local ingredients = M.cook_n(inv)
  local jobs = (want > 0 and ingredients >= 10) and (math.min(want, ingredients) + e.per_job - 1) // e.per_job or 0
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
      add(r, {tag = e.tag, spec = e.spec, n = math.min(jobs, cap), why = why})
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
-- target, `need` while one of them has an open need. Hunters roam outside the walls: in ALERT, SIEGE, BREACH or a
-- DRILL ("nobody outside at T+1,200") they are wanted nowhere, and tools() takes them off the detail at once (reason
-- 'mode'), not after shrink_days.
local HUNT_MODES = {PEACE = true, RECOVERY = true}
local function hunt_want(K, c, r)
  local spec = hunters_spec(c)
  if not spec then return 0, 'none' end
  local mode = K.mode()
  if not HUNT_MODES[mode] then return 0, 'mode' end
  if r.p.famine or r.p.food_pre then return spec.famine or 0, r.p.famine and 'famine' or 'food low' end
  if mode ~= 'PEACE' then return 0, 'mode' end
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
-- outside the walls, like hunters, and tools() takes them off at once in any other mode
local function fish_want(K, c, r)
  local spec
  for _, d in ipairs((c.tools or {}).details or {}) do if d.fish then spec = d end end
  if not spec then return 0, 'none' end
  st.fishzone = fishing_zone()
  local mode = K.mode()
  if not HUNT_MODES[mode] or (mode ~= 'PEACE' and not r.p.famine) then return 0, 'mode' end
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
  return math.max(fl, clamp(((r.cit or 0) + per - 1) // per, 1, spec.max or 3)), r.p.famine and 'famine' or 'food'
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

local function plan_leather(K, c, r)
  local L = c.leather
  local want = target(K, c, r, 'leather') + (phase_ok(K, L.from_phase) and r.gear.leather or 0)
  r.targets.leather = want
  if have(r, 'leather') >= want or open(r, L.tag) then return end
  if not ws_any(r.f, L.ws) then return M.tannery_request(K, c, r, L) end
  if (r.inv.hides or 0) > 0 and (r.p.hides_days or 0) >= (L.after_days or 2) then
    local n = math.min(left(c, r, 'hides'), want - have(r, 'leather'), L.max_jobs or 10)
    if add(r, {tag = L.tag, spec = L.spec, n = n, uses = {hides = 1}, why = 'leather'}) then r.route.leather = 'tan' end
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
  -- BUG-024: spider webs are no thread; a CollectWebs hint only for webs on the citizens' walk group
  local thread, webs, near = r.inv.thread or 0, r.inv.webs or 0, r.inv.webs_near or 0
  st.cloth = {deficit = math.max(0, deficit), thread = thread, webs = webs, near = near}
  if r.day and deficit > 0 and thread == 0 and near > 0 and st.web_hint ~= near then
    local wp = st.web_pos
    K.log('info', 'cloth short by %d, no collected thread: %d spider webs on the citizens\' walk group%s: weavers collect ' ..
          'them (WEAVER labor, webs not forbidden)', deficit, near, wp and string.format(' (e.g. %d,%d,%d)', wp[1], wp[2], wp[3]) or '')
  end
  if r.day then st.web_hint = (deficit > 0 and thread == 0 and near > 0) and near or nil end
  if deficit <= 0 then return end
  if ws_any(r.f, Cc.loom) then
    for _, w in ipairs(Cc.weave or {}) do
      if deficit <= 0 then break end
      if not open(r, w.tag) then
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
      for i, m in ipairs(missing) do words[i] = STEEL_WORDS[m] or m end
      K.emit('DECISION_NEEDED', 'A', string.format('steel: %d orders (%s) wait for steel bars; missing %s', need.n,
                                                   table.concat(ids, ',', 1, math.min(4, #ids)),
                                                   table.concat(missing, ', ')),
             {id = 'steel', q = ('missing ' .. table.concat(words, '; ') .. ': dig or trade for it (trade.want bar:steel), ' ..
                                 'or remove the steel orders?'):sub(1, 200)})
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

local function plan_gear(K, c, r)
  local g = c.gear
  local forge, lw = ws_any(r.f, g.forge), ws_any(r.f, g.leatherworks)
  local magma = r.f['workshop:MagmaForge'] == true
  local fc = fuel_cond(r)
  for _, it in ipairs(g.items or {}) do
    local rec = r.gear.cats[it.cat]
    local tag = 'dfllm:gear_' .. it.cat
    if rec and rec.miss > 0 then
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
          for _, m in ipairs(forge and g.metals or {}) do
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
          else why[#why + 1] = lw and 'leather' or 'leatherworks' end
        end
        if rec.route == 'none' and it.wood then
          local n = ws_any(r.f, it.wood.ws) and math.min(jobs, left(c, r, 'wood'), maxj) or 0
          if n > 0 then
            add(r, {tag = tag, spec = wood_spec(c, r, base(it.wood)), n = n, out = it.out or 1, cat = it.cat,
                    uses = {wood = 1}, why = 'gear'})
            rec.route = 'wood'
          else why[#why + 1] = 'wood' end
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
-- free boulders a mason may take: ores and flux are economic stone (DF's default stone use settings keep them
-- from furniture and blocks; care's reserve counts the same way), minus the rock floor
local function stone_free(c, r)
  local inv = r.inv
  local n = (inv.rock or 0) - math.max((inv.ore or 0) + (inv.flux or 0), inv.rock_bad or 0)
  return math.max(0, n - floor_of(c, r.p, r, 'rock'))
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
  local n = 0
  for _, o in ipairs(orders_all()) do
    if n >= (w.per_day or 8) or budget <= 0 then break end
    if open_of(o) and o.mat_type == 0 and o.amount_left <= budget then
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
local function kitchen(K, c, food_d)
  if decision(K, 'D-09') == 'yes' and food_d and food_d < (c.famine_days or 10) then return end
  for _, e in ipairs(c.kitchen or {}) do
    local mi = dfhack.matinfo.find(e.plant, e.mat)            -- as ban-cooking.lua:67
    local it = df.item_type[e.item]
    if mi and it and dfhack.kitchen.findExclusion({[e.what] = true}, it, -1, mi.type, mi.index) < 0 then
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

local function idle_pct(K)
  local cu = K.census.u
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' then return nil end
  local sold = {}
  for _, id in ipairs(cu.soldier_ids or {}) do sold[id] = true end
  local n, idle = 0, 0
  for _, id in ipairs(cu.ids) do
    local u = not sold[id] and df.unit.find(id)
    if u and not dfhack.units.isChild(u) and not dfhack.units.isBaby(u) then
      n = n + 1
      local j = u.job
      if j == nil or j.current_job == nil then idle = idle + 1 end
    end
  end
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
  local ok = K.act.order_remove(oid)
  if not ok then return end
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
  st.cancels[key] = (st.cancels[key] or 0) + 1
  local n = st.cancels[key]
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
  K.emit('CANCEL_LOOP', 'B', string.format('%s cancelled %d times today%s', job, n,
                                           rock and ' (stone short of the rock orders: no recheck)' or ''),
         {order = oid or -1, job = job, n = n})
  if st.rechecked ~= day and not rock then   -- orders.txt: recheck stops cancellation spam of stale conditions
    st.rechecked = day
    K.act.orders('recheck')
  end
end

-- leaving PEACE while hunters (or fishers) are out: the next run (tool details) within rush_ticks takes them off
-- the detail, not up to a day later (drills check "nobody outside" at T+1,200)
M.on.MODE = function(K, ev)
  if type(ev) ~= 'table' or ev.to == 'PEACE' or ((st.hunters or 0) == 0 and (st.fishers or 0) == 0) then return end
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
  local ok, res = K.act.appoint(args.code, args.unit)
  if not ok then return false, 'appoint: ' .. tostring(res) end
  local p = pstate(K)
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
    local okc, res = K.act.manager_office()
    if okc and res == 'assigned' then K.log('warn', 'manager had no office: free Office zone assigned') end
    local oko, err = pcall(M.office_check, K, c, p)
    if not oko then K.log('warn', 'office check: %s', tostring(err)) end
  end
  if M.manager_watch(K, p, c) then p.uv, st.unval = nil, nil; return end   -- Run 11: injured, in a mood, gone
  M.unval_watch(K, p, c)
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
    st.office = {why = 'the manager has no office zone', fix = 'an Office zone with a chair and a table for him ' ..
                 '(bp.place office)'}
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
    st.office.fix = #none > 0 and string.format('not built: no free %s; add it at a workshop by hand (its order waits ' ..
                                                'for him too)', table.concat(none, ', no '))
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

-- BUG-042: why an available manager validates nothing: the office (st.office) and its fix tail, else the manager by
-- name
function M.unval_why(K)
  local o = st.office
  if type(o) == 'table' and o.why then
    local tail = (o.at and (': ' .. o.at .. ' placed') or '') .. (o.fix and ((o.at and '; ' or ': ') .. o.fix) or '')
    return o.why, tail
  end
  local mg = M.manager_state(K)
  local who = type(mg) == 'table' and mg.name and ('manager ' .. mg.name) or 'the manager'
  return who .. ' validates nothing (his office has a chair and a table)', ': inspect the manager (job, path to the office)'
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
  local why, fix = M.unval_why(K)
  st.unval.why = why
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
    if cn then
      if (cn.thirst_timer or 0) >= a.thirst then thirsty = thirsty + 1 end
      if (cn.hunger_timer or 0) >= a.hunger then hungry = hungry + 1 end
    end
  end
  return thirsty, hungry
end

local function alarm_check(K, c, p, days)
  local a = c.alarm or M.DEFAULTS.alarm
  local okn, thirsty, hungry = pcall(needs, K, a)
  if not okn then thirsty, hungry = 0, 0 end
  local why
  if thirsty >= a.units then why = string.format('thirst %d', thirsty)
  elseif hungry >= a.units then why = string.format('hunger %d', hungry)
  elseif days.drink_d < a.days then why = string.format('drink %d d', days.drink_d)
  elseif days.food_d < a.days then why = string.format('food %d d', days.food_d) end
  if why ~= st.alarm then K.log(why and 'warn' or 'info', 'supply alarm %s', why or 'over') end
  st.alarm, st.thirsty, st.hungry = why, thirsty, hungry
  local now = K.now().tick
  if (thirsty >= a.units or days.drink_d < a.days) and now - (p.thirst_woke or -1e9) >= 7 * DAY then
    p.thirst_woke = now
    K.emit('DECISION_NEEDED', 'A', string.format('thirst: %d citizens thirsty, drink %d days', thirsty, days.drink_d),
           {id = 'thirst', q = string.format('%d thirsty, drink %d d: water near the fort (well), brewing, barrels?',
                                             thirsty, days.drink_d)})
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
    elseif (u.mood or -1) >= 0 then r.why = 'manager ' .. r.name .. ' in a strange mood' end
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
  for pass = 1, 3 do                          -- one on the citizens' group first, a far one, a forbidden one (BUG-023, Run 11) last
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
function M.tool_diag(K, spec, kind, without, cur, jc, pop)
  local dg = {picks = {}, units = {}, keys = {}, texts = {}, civ = 0, ww = 0, pop = pop}
  pcall(function() dg.upw = df.global.plotinfo.equipment.update.weapon == true or nil end)   -- DF has not run it yet
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
  for pass = 1, 3 do                                        -- the free tools first (BUG-053: those on the citizens' group), then the forbidden ones
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
    end
    pcall(function()
      r.upd = u.uniform.pickup_flags.update == true or nil
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
  local nojob = where{U, function(r) return r.jobs == 0 end}
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
    add('none', string.format('nothing visible: the free %ss are in DF\'s list, the members have the labor, reach them '
                              .. 'and are no work tool pair', kind))
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
  if #without == 0 or open == 0 or free + forb == 0 then
    st.tblk[spec.name], st.tdiag[spec.name], st.tstale[kind] = nil, nil, nil
    p.tblk[spec.name] = rec.ann and json.object{ann = CAD.quiet(rec.ann)} or nil
    return
  end
  rec.since = math.tointeger(rec.since) or r.now
  local days = (r.now - rec.since) // DAY
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
               use = inv['w_' .. kind .. '_use'] or 0, pos = pos}
  local okd, dg = pcall(M.tool_diag, K, spec, kind, without, cur, jc, pop)
  if not okd then K.log('warn', '%s: tool diagnosis failed: %s', spec.name, tostring(dg)); dg = nil end
  local ctoks = {table.unpack(toks)}
  for _, k in ipairs(dg and dg.keys or {}) do ctoks[#ctoks + 1] = 'b:' .. k end
  -- BUG-053: free tools the members lack for stale_days with no member-side cause stop counting as stock; usable ones
  -- that lie loose get a tool pile (T.toolpile) after pile_days
  local memberside = false
  for _, k in ipairs(dg and dg.keys or {}) do if k == 'labor' or k == 'tool2' then memberside = true end end
  -- the count is fixed when the tools turn stale (rec.stn): picks made or bought afterwards are stock again, or the forge
  -- would go on making picks for members DF hands none to
  if days >= (tc.stale_days or 14) and free > 0 and not memberside then
    rec.stn = math.min(free, math.tointeger(rec.stn) or free)
    st.tstale[kind] = rec.stn
  else
    rec.stn, st.tstale[kind] = nil, nil
  end
  if tc.pile ~= false and days >= (tc.pile_days or 7) and pop.use > 0 and not memberside then
    local at = M.pile_center(K, spec, jc, cur, pos)
    st.tpile_req = at and {kind = kind, spec = spec.name, at = at} or nil
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
      if eqn > 0 then d.eq, d.eq_days = eqn, eqd or 0 end
      if forb > 0 then d.forb = forb end
      local ptxt = M.pile_text(r.p)
      if ptxt then d.pile = ptxt end
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
      for _, id in ipairs(keep_ids) do
        local u = cit[id]
        local ok_u = u and dfhack.units.isAdult(u) and u.military.squad_id < 0 and not taken[id]
        if ok_u then cur[#cur + 1] = u
        elseif mine[id] then
          if set(spec, id, false, taken[id] and ('in ' .. taken[id]) or 'not eligible', tgt) then mine[id] = nil end
        end                                      -- the player's member that is not eligible stays and does not count
      end
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
        for _, u in ipairs(adults) do
          if not member[u.id] and not taken[u.id] and u.military.squad_id < 0 and soft_ok(u) then cand[#cand + 1] = u end
        end
        table.sort(cand, function(a, b)
          local sa, sb = skill(a), skill(b)
          if sa ~= sb then return sa > sb end
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
      elseif #cur > tgt then
        ps.low = ps.low or now
        -- hunters outside the walls while the fort leaves PEACE: off the detail now (siege reflex, drills); every
        -- member then, also the player's
        local at_once = r ~= nil and ((spec.ranged ~= nil and r.hunt_why == 'mode') or
                                      (spec.fish ~= nil and r.fish_why == 'mode'))
        if at_once or now - ps.low >= (tc.shrink_days or 3) * DAY then
          local out, stay = {}, {}
          for _, u in ipairs(cur) do
            if at_once or mine[u.id] then out[#out + 1] = u else stay[#stay + 1] = u end
          end
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
  return changes
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
    local q, opts = M.food_q(fd, r, inv, bl, auto)
    local ids, aids, head = M.food_head(bl, auto)
    K.emit('DECISION_NEEDED', 'A', string.format('famine: %d food days, %d drink days%s', fd, dd, head),
           {id = 'famine', q = q, food = fd, block = ids, opts = opts, auto = aids})
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
  st.food = {tiles = tiles, need = need, falling = falling, fd = fd}
  if tiles >= need or not (fd < (fc.want_days or 90) or falling) then return end
  local okp, pend = K.call('runner', 'pending', 'farms')
  if okp and (math.tointeger(pend) or 0) > 0 then return end
  -- BUG-058 (DECISIONS 9; Run 11: five farms projects build_lost and parked, no soil): one lost for good stops the
  -- requests until it is cancelled or the farms are placed elsewhere
  local okl, nl, lid = K.call('runner', 'lost', 'farms')
  if okl and (math.tointeger(nl) or 0) > 0 then
    if st.farm_lost ~= lid then
      K.log('warn', 'farms: project %s lost to build_lost (no soil there?): no further farms request until it is ' ..
            'cancelled (bp.cancel) or the farms are placed elsewhere', tostring(lid))
    end
    st.farm_lost = lid
    return
  end
  st.farm_lost = nil
  if p.farm_req and r.now - (math.tointeger(p.farm_req) or 0) < (fc.request_days or 14) * DAY then return end
  local pt = math.max(1, math.tointeger(fc.plot_tiles) or 35)
  local plots = clamp((need - tiles + pt - 1) // pt, 1, fc.plots_max or 4)
  p.farm_req = r.now
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
  local q, opts = M.food_q(fd, r, inv, bl, auto)
  K.emit('DECISION_NEEDED', 'A', string.format('food low: %d food days (famine below %d)%s', fd, lim, head),
         {id = 'food_low', q = q, food = fd, block = ids, opts = opts, auto = aids})
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
  if plants == 0 then put('plants', 'no brewable plants') end
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
  if d >= (math.tointeger((K.plan.supply or {}).drink_d) or 170) then return nil end
  local bl = M.drink_block(K, c, r, r.inv or {})
  return bl[1] and bl[1][2]:sub(1, 80) or nil
end

-- BUG-042: the drink pre-alarm: below drink.low_d (and from alarm.days on, where DECISION_NEEDED thirst speaks), a
-- class-A DECISION_NEEDED drink_low with the days, why the stills do not brew and what the kernel did; once per
-- episode, again with news (a new cause, below 30 days) after max(7 days, 10 min) (util/cadence)
function M.drink_low(K, c, r)
  local p, dd = r.p, (r.days or {}).drink_d or 9999
  local low = math.tointeger(((c.drink or {}).low_d)) or 0
  st.dwhy = M.drink_why(K, c, r)
  if dd >= low then
    if p.drink_pre then p.drink_pre = nil; K.log('info', 'drink pre-alarm over: %d drink days', dd) end
    if type(p.drink_rep) == 'table' then p.drink_rep = CAD.quiet(p.drink_rep) end
    return
  end
  if dd < ((c.alarm or M.DEFAULTS.alarm).days or 10) then return end      -- the thirst wake speaks now
  local now = K.now()
  if not p.drink_pre then
    p.drink_pre = now.tick
    K.log('warn', 'drink pre-alarm: %d drink days (< %d)%s', dd, low, st.dwhy and (': ' .. st.dwhy) or '')
  end
  local bl, auto = M.drink_block(K, c, r, r.inv or {})
  local ids, aids, head = M.food_head(bl, auto)
  local toks = {dd < 30 and 'below30' or 'below60'}
  for _, id in ipairs(ids) do toks[#toks + 1] = id end
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
    elseif key == 'slab_blank' then return st.slab == nil or (st.slab.blank or 0) > 0 end   -- B2: M.slab_pass counts them
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
    kind.ws = label
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
        out[#out + 1] = {t = int(ji.item_type) or -1, mt = int(ji.mat_type) or -1, mi = int(ji.mat_index) or -1,
                         n = math.min(miss, 50), bm = okb and bm or false}
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

-- the crop for empty slot s (0-based) of a plot whose crops are `crops` (raw indices): a crop of the plot that
-- grows then with usable seeds, else the crop with the most usable seeds that grows then and there, else the
-- plot's own crop that grows then (underground crops grow all year)
function M.slot_crop(crops, under, s, seeds, food)
  local function fits(inf) return inf and inf.under == under and inf.seasons[s + 1] == true end
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
    for _, pid in ipairs(crops) do if fits(plant_info(pid)) and ok(pid) then return pid end end
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
local function farm_fills(K, max, only, food)
  local fills, plots, empty = {}, 0, 0
  pcall(function()
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
            if not pid or pid < 0 or wrong then
              if not wrong then empty = empty + 1 end
              local crop = under ~= nil and #fills < max and M.slot_crop(crops, under, s, st.seeds or {}, food) or nil
              -- a crop of the wrong kind is replaced only by one with usable seeds (a wrong reading of the tile must not
              -- cost a planted slot)
              if crop and wrong then
                local ci = plant_info(crop)
                if not (ci and ((st.seeds or {})[ci.id] or 0) > 0) then crop = nil end
              end
              if crop and crop ~= pid then fills[#fills + 1] = {id = b.id, s = s, crop = crop, wrong = wrong or nil} end
            end
          end
        end
      end
    end
  end)
  if only == nil then st.farm = {plots = plots, empty = empty} end
  return fills
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
    if cn and (cn.hunger_timer or 0) >= lim then r[#r + 1] = id end
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
local function cut_off(K, ids)
  local samples, r = st.food_pos or {}, {}
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
  validation_watch(K, r.p, c)
  alarm_check(K, c, r.p, r.days)
  famine(K, c, r.p, r.days, r.inv, r)
  food_pre(K, c, r.p, r.days, r.inv, r)
  M.food_unban(K, c, r, r.inv)
  M.drink_low(K, c, r)                             -- BUG-042
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
  local r = {}
  for i = 1, math.min(#cand, math.max(0, (sc.max or 10) - marked)) do r[i] = cand[i] end
  return r
end

-- live L6 (Paddletribes): two strange moods waited for a bone with tame surplus animals at hand and failed or
-- needed a manual slaughter. An open mood need for bone or leather with none of it in stock marks ONE surplus
-- animal (same keep rules), at most every `mood_days`.
local function mood_animal_need(r)
  local needs = r.p.needs or {}
  for _, key in ipairs({'bone', 'leather'}) do
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
    if mood then pick_sc = {keep_f = sc.keep_f, keep_m = sc.keep_m, max = 1} end
    r.sl, r.sl_n = M.slaughter_pick(type(ca) == 'table' and ca.list, pick_sc), 0
    p[t_key] = r.now
    if mood and #r.sl > 0 then K.log('warn', 'mood needs %s: animal %d marked for slaughter', mood, r.sl[1]) end
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
               no_bags = 'no bags (spare cloth/leather + its shop)', no_fuel = 'no fuel (wood furnace + wood, or magma)'}
M.GLASS_SHORT = {no_sand = 'no sand revealed', no_bags = 'no bags', no_fuel = 'no fuel'}

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
    if x and y and z and okt and type(v) == 'table' and v.c == '.' and not far(K, x, y, z) and #cand < 8 then
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
  if not CAD.due(p.glass_rep, T, {}, g.block, {ticks = (G.report_days or 28) * DAY, wall_s = CAD.WALL_S}) then return end
  p.glass_rep = CAD.mark(T, {}, g.block)
  local parts = {}
  for _, b in ipairs(g.block) do parts[#parts + 1] = M.GLASS_WHY[b] or b end
  K.emit('GLASS_BLOCKED', 'B', string.format('glass for moods (%d raw, %d cut) blocked: %s', g.raw, g.cut,
                                             table.concat(parts, '; ')):sub(1, 200),
         {why = {table.unpack(g.block)}, raw = g.raw, cut = g.cut})
end

function M.glass_plan(K, c, r)
  local G, p, inv, now = c.glass, r.p, r.inv, r.now
  st.glass = nil
  if type(G) ~= 'table' or not phase_ok(K, c.mood_from_phase or 'P1') then return end
  local nat = math.max(0, (inv.gems or 0) - (inv.gems_glass or 0))          -- natural gems (no glass)
  local raw_need, cut_need, res = need_n(p, 'glass', now), r.glass_cut or 0, M.gem_reserve(K)
  local missed = M.mood_missed(c, p, 'gems', now) or M.mood_missed(c, p, 'glass', now)
  local standing = nat == 0 and (missed or (phase_ok(K, G.from_phase) and have(r, 'gems') < res))
  if raw_need + cut_need <= 0 and not standing then
    p.glass_rep = CAD.quiet(p.glass_rep)         -- the chain is off: a blocker that comes back is news
    return
  end
  local cut = cut_need + (standing and math.max(0, res - have(r, 'gems')) or 0)
  local raw = raw_need + (standing and (G.raw or 3) or 0) + cut
  r.targets.glass = raw
  local g = {raw = raw, cut = cut, have = inv.glass or 0, block = {}, ord = {}}
  st.glass = g
  local f, mx = r.f, G.max_jobs or 5
  local fur, magma, jew = ws_any(f, G.furnace), f[G.magma] == true, ws_any(f, G.jeweler)
  if not fur then M.glass_shop(K, c, r, g, 'no glass furnace')
  elseif cut > 0 and not jew then M.glass_shop(K, c, r, g, "no jeweler's") end
  local raw_short = math.max(0, raw - (inv.glass or 0) - (r.s.live[G.make.tag] or 0))
  local sand_short = math.max(0, raw_short - (inv.sand or 0) - (r.s.live[G.sand.tag] or 0))
  if sand_short > 0 then
    if M.sand_zones() > 0 then g.zone = 'zone' else M.glass_sand(K, c, r, g) end
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

-- economy.route for gems and raw glass (care's MOOD_RISK): via 'glass' = the missing gems filter takes cut glass; any
-- other gems need is a rough gem, which no glass replaces
function M.glass_route(K, key, via)
  if key == 'gems' and via ~= 'glass' then
    return 'rough gems: mine a gem vein or trade.want gem (glass is no rough gem)'
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
  local s = (key == 'gems' and 'cut glass: ' or 'raw glass: ') .. table.concat(parts, ', ')
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
  return math.max(0, (r.inv.wood or 0) - fl - (r.s.used.wood or 0) - (r.planned.wood or 0))
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
  local why = {}
  if not e.wood then why[#why + 1] = free >= n and 'no Masons' or 'no rock' end
  why[#why + 1] = wood >= n and 'no Carpenters' or 'no logs'
  return nil, string.format('no material for %s: %s', e.kind, table.concat(why, ', '))
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

-- what buildingplan builds a wall of now: via (the setting: blocks, boulders, logs, bars), nil + the setting to
-- switch on (only that material is there), or nil, why
function M.bm_route(r, s, kind)
  local inv = r.inv
  for _, e in ipairs(M.BM) do
    if s[e[1]] and (inv[e[2]] or 0) > 0 then return e[1] end
  end
  for _, k in ipairs(M.BM_ON) do
    for _, e in ipairs(M.BM) do
      if e[1] == k and (inv[e[2]] or 0) > 0 then return nil, nil, k end
    end
  end
  return nil, 'no material for ' .. (kind or 'wall') .. ': no rock, no blocks, no logs'
end

-- what a building waiting for building material is called in MATERIAL_SHORT: a wall (construction), the trade depot
-- (Run 11: destroyed in siege 3), a workshop, else a building
M.BM_KIND = {Construction = 'wall', TradeDepot = 'depot', Workshop = 'workshop', Furnace = 'workshop'}
function M.bm_kind(q)
  local j = (q.jobs or {})[1]
  return j and M.BM_KIND[j.kind or ''] or (j and 'building') or 'wall'
end

-- economy.mat_for(kind, n) (CONTRACTS §7): can the fort make n of a seal piece now? kind = door, hatch, grate, wall
-- (or a furniture kind of M.PIECES). Returns via ('item', 'rock', 'wood'; walls: 'blocks', 'boulders', 'logs', 'bars',
-- 'setting' when economy switches a buildingplan material on; 'unknown' before the first census) or nil, why
function M.mat_for(K, kind, n)
  n = math.max(1, math.tointeger(n) or 1)
  if not K.census.i then return 'unknown' end
  local c, r = M.conf(K), M.view_run(K)
  if kind == 'wall' or kind == 'depot' or kind == 'workshop' then
    local via, why, set = M.bm_route(r, M.bp_settings(), kind)
    if set then return 'setting', 'buildingplan ' .. set .. ' goes on' end
    return via, why
  end
  local e = M.PIECE_KIND[kind]
  if not e then return nil, 'unknown piece ' .. tostring(kind) end
  return M.piece_route(c, r, e, n)
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
function M.rock_dig(K, c, r, walls)
  local rc = c.rock
  local free = stone_free(c, r)
  local need = (r.rk or M.rock_open()) + (walls or 0) + need_n(r.p, 'rock', r.now)
  st.rock = {free = free, need = need, open = r.rk or 0}
  if type(rc) ~= 'table' or need <= free or K.mode() ~= 'PEACE' or (r.inv.w_pick or 0) == 0 then return end
  if ((st.jobc or tool_jobs()).dig or 0) > 0 then return end                -- the miners have digging
  local okb, bl = K.call('runner', 'dig_backlog')
  if okb and (int(bl) or 0) > 0 then return end
  local okp, pend = K.call('runner', 'pending', 'bedrooms')
  if okp and (int(pend) or 0) > 0 then return end
  local last = int(r.p.rockreq)
  if last and r.now - last < (rc.request_days or 7) * DAY then return end
  r.p.rockreq = r.now
  local n = rc.rooms or 4
  K.emit('PROJECT_REQUEST', 'B', string.format('bedrooms x%d: a stone dig, %d free boulders < %d wanted (rock orders, ' ..
                                               'walls), the miners have nothing to dig', n, free, need),
         {tpl = 'bedrooms', n = n, why = 'rock', short = need - free})
end

-- Run 11: the missing items of planned buildings (T.jmat's classes without a free or forbidden item) get an order in
-- the material the fort has; walls switch buildingplan's material on when that is all there is; the rest is short
function T.jmake(K, c, r)
  local jb, pc = r.jb, c.pieces
  if not jb or type(pc) ~= 'table' then return true end
  local short, walls, s = {}, 0, nil
  for _, q in ipairs(jb.mq or {}) do
    if q.label == 'building material' then
      s = s or M.bp_settings()
      local kind = M.bm_kind(q)
      local via, why, set = M.bm_route(r, s, kind)
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
          elseif not via then short[#short + 1] = {kind = e.kind, n = k, why = why} end
        end
        -- a seal piece whose stone order queues behind the other rock orders (no logs for wood): the player hears it
        if e.def and wait then
          short[#short + 1] = {kind = e.kind, n = need, pre = 'stone queued for', why = 'behind the other rock orders, ' ..
                               ((r.f or {})['workshop:Carpenters'] and 'no logs' or 'no Carpenters'), queued = true}
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
  if wj[jn] and r.f['workshop:Carpenters'] and M.wood_left(c, r, def) >= n and K.act.order_material(oid, 'wood') then
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
  K.log('warn', 'order %d %s x%d removed: "%s", %d free stone for %d in rock orders, no logs for it (%d logs)', oid,
        jn, n, why, stone_free(c, r), r.rk, r.inv.wood or 0)
  K.emit('ORDER_STUCK', 'B', string.format('order %d %s removed: "%s", stone short of the rock orders, no logs for it',
                                           oid, jn, tostring(why):sub(1, 60)),
         {order = oid, job = tostring(jn):sub(1, 40), why = ('no rock: ' .. tostring(why)):sub(1, 60), n = n,
          dropped = 1})
  return true
end

-- Run 11: picks for the Miners (their demand before the tool cap, BUG-023, against every pick in the fort): a pick
-- from the first metal with a spare bar at a forge, else economy.trade_wants asks the caravans for them
-- BUG-053: the tools of a kind the fort can hand out: every tool of the census less the free ones the members lacked for
-- tools.stale_days without a member-side cause (tool_check's st.tstale; 16 and 100 loose picks counted as stock for 1081
-- and 144 days while the miners held none, so no pick was made or asked for)
function M.tools_have(inv, kind)
  return math.max(0, (inv['w_' .. kind] or 0) - ((st.tstale or {})[kind] or 0))
end

function M.plan_picks(K, c, r)
  local pc = c.picks
  local want, have = (st.want or {}).pick or 0, M.tools_have(r.inv, 'pick')
  local pk = {have = have, want = want, short = math.max(0, want - have), route = ''}
  st.picks = pk
  if type(pc) ~= 'table' or pk.short == 0 then return end
  if open(r, pc.tag) then pk.route = 'forge'; return end
  local g = c.gear or {}
  local forge, magma = ws_any(r.f, g.forge), r.f['workshop:MagmaForge'] == true
  for _, m in ipairs(forge and pc.metals or {}) do
    local tok = 'INORGANIC:' .. m
    local n = math.min(pk.short, left(c, r, 'bars:' .. tok), left(c, r, 'bars'), magma and pk.short or left(c, r, 'fuel'),
                       pc.max_jobs or 2)
    if n > 0 then
      add(r, {tag = pc.tag, spec = {job = 'MakeWeapon', item_subtype = 'ITEM_WEAPON_PICK', material = tok,
                                    item_conditions = {cond(1 + floor_of(c, r.p, r, 'bars'), 'BAR', {material = tok}),
                                                       fuel_cond(r)}},
              n = n, uses = {['bars:' .. tok] = 1, bars = 1, fuel = magma and 0 or 1}, why = 'picks for the miners'})
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
  local mt = st.metal
  for _, w in ipairs(type(mt) == 'table' and mt.short and mt.wants or {}) do
    local e = by[w.buy]
    if e then e.n, e.metal = math.max(e.n, w.n), 1
    else e = {buy = w.buy, n = w.n, why = w.why, metal = 1}; r[#r + 1] = e; by[w.buy] = e end
  end
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
-- projects: fortcore stage 1 lists a fishery too, built long ago in a fort whose later stages still run
function M.fishery_proj(K, ws)
  local pd = K.persist.get('projects')
  for _, P in ipairs(type(pd) == 'table' and type(pd.list) == 'table' and pd.list or {}) do
    local id = type(P) == 'table' and P.tpl == 'workshops' and P.done ~= 1 and tostring(P.id or '')
    local d = id and id:match('^[%w_.%-]+$') and K.persist.get('bp.' .. id)
    local m = type(d) == 'table' and type(d.manifest) == 'table' and d.manifest.workshops
    for _, w in ipairs(type(m) == 'table' and m or {}) do
      if type(w) == 'table' and ('workshop:' .. tostring(w.type)) == (ws or M.FISHERY)[1] then
        local b = tostring(P.blocked or '')
        return {id = id, stage = P.stage, pct = P.pct, halted = (b ~= '' and b ~= 'stalled') and b or nil}
      end
    end
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

-- the search of this run: levels and box around the citizens, or nil (a zone stands, nothing wanted, mode, cadence)
function M.fish_start(K, c, r)
  local F, p = c.fishing, r.p
  if type(F) ~= 'table' or not rawget(K.act, 'fish_zone') then return nil end
  local spec
  for _, d in ipairs((c.tools or {}).details or {}) do if d.fish then spec = d end end
  if not spec then return nil end
  st.fishzone = fishing_zone()                      -- fish_want reads it again in T.plan
  if st.fishzone then st.fishz = {zone = true}; return nil end
  local fd = (r.days or {}).food_d or 9999
  if not (p.famine or p.food_pre or fd < ((c.food or {}).want_days or 90)) then st.fishz = nil; return nil end
  local last = type(p.fishz) == 'table' and p.fishz or nil
  if last then st.fishz = last end
  if not HUNT_MODES[K.mode()] then return nil end
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
              ice = 0, cav = 0, shallow = 0, nobank = 0, path = 0, checked = 0, wi = 1, found = {}}
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
    if up.c == '_' then
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
  local rec = {t = r.now, ice = fz.ice, cav = fz.cav}
  if site then
    r.cmds = r.cmds + 1
    local ok, n = K.act.fish_zone(site.water, F.side or 3, site.up == true)
    local w, bk = site.water, site.bank
    if ok then
      rec.at, rec.bank, rec.inside, rec.why = w, bk, site.inside and 1 or 0, 'painted'
      K.log('info', 'fishing: zone dfllm-fish at %d,%d,%d (%s; bank %d,%d,%d), food %d days', w[1], w[2], w[3],
            site.inside and 'roofed, inside' or 'open sky', bk[1], bk[2], bk[3], (r.days or {}).food_d or 0)
    else
      rec.why = ('fishing zone at %d,%d,%d refused: %s'):format(w[1], w[2], w[3], tostring(n)):sub(1, 80)
      K.log('warn', 'fishing: %s', rec.why)
    end
  else
    rec.why = M.fish_none(fz)
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
  if pg and fd >= (g.off_days or 60) and not (dshort and dd < (g.drink_off or 0)) then   -- food (and drink) back
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
  local dlow = dd < (g.drink_d or 0) and dshort
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
  local okj, jg = K.call('snapshot', 'groups', pts, true)
  if not (okc and okj and type(cg) == 'table' and type(jg) == 'table') then return open, 0, {} end
  local home = {}
  for _, g in ipairs(cg) do if math.type(g) == 'integer' and g > 0 then home[g] = true end end
  if next(home) == nil then return open, 0, {} end
  local far, nf = {}, 0
  for k = 1, #pts do
    local g = math.tointeger(jg[k]) or -1
    if g >= 0 and not home[g] then far[k], nf = true, nf + 1 end
  end
  local off = math.min(open, nf * open // #pts)
  return open - off, off, far
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

-- what keeps food from coming, for the food_low and famine decisions: {{id, text}} by weight, and what the kernel
-- does about it itself (BUG-038): {{id, text}} (the fishery request, the gatherers)
function M.food_block(K, c, r, inv)
  local f, out, auto = M.facts_now(K, r), {}, {}
  local function put(id, txt) out[#out + 1] = {id, txt} end
  -- BUG-059: hungry citizens and no prepared meal: the food days count raw food nobody cooks, say so first
  if (st.hungry_n or 0) > 0 and (inv.meals or 0) == 0 then
    put('hungry', string.format('%d hungry, 0 meals: raw food is not cooked', st.hungry_n))
  end
  local raw = inv.fish_raw or 0
  if raw > 0 and not ws_any(f, M.FISHERY) then
    if st.fishery == 'asked' or st.fishery == 'queued' then          -- BUG-038: follow places it, nothing to decide
      auto[#auto + 1] = {'fishery', string.format('fishery %s (%d raw fish%s)', st.fishery, raw,
                                                  st.fishery == 'queued' and st.fishery_proj and (', ' .. st.fishery_proj)
                                                  or '')}
    else put('fishery', string.format('build a fishery (%d raw fish)', raw)) end
  end
  local sg = st.gather
  if type(sg) == 'table' then
    if (sg.n or 0) > 0 then auto[#auto + 1] = {'gather', string.format('%d gatherers added (%d gather jobs)', sg.n,
                                                                     sg.open or 0)}
    elseif sg.why then put('gather', 'gather: ' .. sg.why) end
  end
  if not ws_any(f, {'workshop:Kitchen'}) then put('kitchen', 'no kitchen')
  elseif M.cook_n(inv) <= 0 then put('cook', 'no ' .. M.cook_why(inv, f))
  elseif not M.labor_holder(K, 'COOK') then put('cook', 'nobody holds the COOK labor') end
  if not st.fishzone then
    local z = st.fishz
    local why = type(z) == 'table' and type(z.why) == 'string' and z.why ~= 'painted' and z.why or nil
    put('fish_zone', why or 'no fishing zone')
  end
  if hunters_spec(c) and (st.hunters or 0) == 0 then
    local h = st.hunt or {}
    if (inv.w_xbow or 0) + (inv.w_bow or 0) == 0 then put('hunt', 'hunt: no crossbow')
    elseif st.no_ammo or (inv.bolts_free or 0) == 0 then put('hunt', 'hunt: no bolts')
    elseif h.why == 'mode' then put('hunt', 'hunt: not in ' .. tostring(K.mode())) end
  end
  local fs = st.food or {}
  if (fs.need or 0) > (fs.tiles or 0) then
    put('farms', st.farm_lost and string.format('farms %d/%d tiles; %s lost (build_lost): cancel it, place elsewhere',
                                                fs.tiles or 0, fs.need or 0, tostring(st.farm_lost):sub(1, 12))
                 or string.format('farms %d/%d tiles', fs.tiles or 0, fs.need or 0))
  end
  local ca = K.census.a
  if type(ca) == 'table' and (math.tointeger(ca.n) or 0) > 0 and not ws_any(f, (c.slaughter or {}).ws) then
    put('butcher', "no butcher's shop")
  end
  return out, auto
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
  K.log('warn', 'food %d days but %d citizens hungry and no prepared meal: raw plants and seeds are not cooked (%d cook ' ..
        'ingredients, kitchen %s, COOK labor %s)', fd, n, M.cook_n(inv), ws_any(M.facts_now(K, r), {'workshop:Kitchen'}) and
        'built' or 'missing', M.labor_holder(K, 'COOK') and 'held' or 'on nobody')
end

-- the decision text: numbers, blockers (each names its fix), what the kernel does itself (BUG-038: `auto: ...`, never
-- cut), the player's other options (DECISION_NEEDED q <= 200 bytes); opts = every option, the blockers' first (d.opts)
M.FOOD_OPTS = {fishery = 'fishery', fish_zone = 'fishing zone', kitchen = 'kitchen', hunt = 'bolts'}
M.FOOD_MORE = {'trade.want food', 'butcher', 'gather', 'popcap.lower'}
function M.food_q(fd, r, inv, bl, auto)
  local parts, opts, au = {}, {}, {}
  for _, b in ipairs(bl) do
    parts[#parts + 1] = b[2]:sub(1, 72)
    if M.FOOD_OPTS[b[1]] then opts[#opts + 1] = M.FOOD_OPTS[b[1]] end
  end
  for _, o in ipairs(M.FOOD_MORE) do opts[#opts + 1] = o end
  for _, a in ipairs(auto or {}) do au[#au + 1] = a[2]:sub(1, 44) end
  local ap = #au > 0 and ('; auto: ' .. table.concat(au, ', ')) or ''
  local q = string.format('food %d d (%d cit, %s%d meals)', fd, r and r.cit or 0,
                          (st.hungry_n or 0) > 0 and (st.hungry_n .. ' hungry, ') or '', inv.meals or 0) ..
            (#parts > 0 and (': ' .. table.concat(parts, '; ')) or '')
  local tail = '. Also: ' .. table.concat(M.FOOD_MORE, ', ')
  if #q + #ap + #tail > 200 then q = q:sub(1, math.max(30, 197 - #ap - #tail)) .. '...' end
  return (q .. ap .. tail):sub(1, 200), opts
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

function T.plan(K, c, r)
  r.cands, r.planned, r.targets, r.route = {}, {}, {}, {}
  for _, key in ipairs({'bone', 'shell'}) do r.targets[key] = target(K, c, r, key) end
  r.gear = gear_pre(K, c, r, 0)
  r.targets.leather = target(K, c, r, 'leather') + (phase_ok(K, c.leather.from_phase) and r.gear.leather or 0)
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
                {2.9, M.plan_picks},
                {urgent.bars and 1 or 3, plan_metal}, {urgent.bars and 1.1 or 3.1, plan_steel}, {3.2, plan_gear},
                {3.25, M.metal_plan}, {urgent.glass and 1.2 or 3.3, M.glass_plan}, {5, function() plan_containers(K, c, r, 'bins') end}}
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
    for _, lib in ipairs((K.plan.orders or {}).import or {}) do addlib(lib) end
    local season = type(K.plan.seasons) == 'table' and K.plan.seasons[K.now().season + 1]
    for _, lib in ipairs(season and season.orders and season.orders.import or {}) do addlib(lib) end
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
    end
  end
  if next(jam) then oq.ctx.jam = jam end
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
          sws = 0, slab = 0, wsn = {}, stand = {}}
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
        if rec.told ~= 1 and oq.told < (oc.report_per_day or 3) then
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
function M.slab_pass(K, c, r)
  local sc, OF = c.slabs, M.OF
  local jt = df.job_type.EngraveSlab
  if type(sc) ~= 'table' or jt == nil then return end
  local p, now = r.p, r.now
  local cs = df.job_type.ConstructSlab
  local eng, cons = {}, 0
  for _, o in ipairs(orders_all()) do
    local n = math.tointeger(o.amount_left) or 0
    if n > 0 then
      if o.job_type == jt then eng[#eng + 1] = o.id
      elseif cs ~= nil and o.job_type == cs then cons = cons + n end
    end
  end
  table.sort(eng)
  local sl = OF.slabs(sc.scan_max)
  local care = (K.view() or {}).care
  local ghosts = math.tointeger(type(care) == 'table' and care.ghosts or 0) or 0
  local sb = {blank = sl.blank, busy = sl.busy, held = sl.held, memorial = sl.memorial, engrave = #eng, cons = cons,
              ghosts = ghosts, removed = 0, ordered = 0}
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
    K.log('warn', 'EngraveSlab: %d orders, %d unengraved slabs (%d in jobs, %d held), %d ghosts: orders %s removed, %d kept ' ..
          '(at most %d)', #eng, sl.blank, sl.busy, sl.held, ghosts, list, #eng - #removed, sc.max_orders or 3)
    local T0 = K.now()
    local why = sl.blank == 0 and 'no unengraved slab' or 'more orders than unengraved slabs'
    if CAD.due(p.slab_ann, T0, {}, {why}, {ticks = CAD.TICKS, wall_s = CAD.WALL_S}) then
      p.slab_ann = CAD.mark(T0, {}, {why})
      K.emit('ORDER_STUCK', 'B', string.format('%d EngraveSlab orders removed (%s: %d unengraved slabs, %d ghosts): %s',
                                               #removed, why, sl.blank, ghosts, list):sub(1, 200),
             {order = removed[1], job = 'EngraveSlab', why = ('slab: ' .. why):sub(1, 60), n = #removed, dropped = 1})
    end
  elseif #drop == 0 then
    p.slab_ann = CAD.quiet(p.slab_ann)
  end
  -- ConstructSlab first
  local n, want = OF.restock(sl.blank, cons, ghosts, #eng - #removed, sc.restock_cap)
  sb.want = want
  if n > 0 then
    local f = r.f or {}
    local free = stone_free(c, r)
    if not f['workshop:Masons'] then sb.why = 'no Masons'
    elseif free < n then sb.why = string.format('%d free boulders for %d slabs', free, n)
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
  K.persist.touch('m.economy')
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
          rec = {left = left, since = r.now}
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
  for key in pairs(p.ostale) do if not sq.seen[key] then p.ostale[key] = nil end end
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
        local mc2 = e.mc
        if e.mc == 'wood' and wj[e.job] and (r.f or {})['workshop:Masons'] and stone_free(c, r) >= e.left + 10 then
          mc2 = 'rock'
        end
        local spec = M.OF.simple_spec(o, e.job, mc2)
        local ok_mat = spec and ((mc2 == 'rock' and stone_free(c, r) >= e.left) or
                                 (mc2 == 'wood' and M.wood_left(c, r, def) >= e.left))
        if ok_mat then
          spec.tag = 'dfllm:redo_' .. tostring(e.id)
          r.cmds = r.cmds + 1
          local ok = K.act.workorder(spec)
          if ok and K.act.order_remove(e.id) then
            act, dropped = 'again' .. (mc2 ~= e.mc and ' in stone' or ''), 1
            p.ostale[e.key] = nil
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

-- the items on one footprint: counted and queued (no write here)
local function site_items(K, jb, j, items)
  local s = {forb = 0, other = 0, corpse = 0, held = 0}
  local held = held_set(K, jb)
  for _, e in ipairs(items) do
    local it = df.item.find(int(e[1]) or -1)
    local f = it and it.flags
    if f and not (f.in_job or f.in_building or f.trader or f.removed or f.garbage_collect or f.construction) then
      if CORPSE_T[tname(it) or ''] or f.dead_dwarf then s.corpse = s.corpse + 1
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
local function need_class(nd)
  if nd.t >= 0 then
    local n = df.item_type[nd.t]
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
    end
    rec.line = string.format('%s suspended by DF (not buildingplan, not suspendmanager): %s', head,
                             #bits > 0 and table.concat(bits, '; ') or 'no cause readable')
  end
  return rec
end

-- one usable loose item of a class: {free = not forbidden, take = forbidden and fit to unforbid}
local function mat_item(K, jb, it, nd)
  local f = it.flags
  for _, k in ipairs(MAT_BUSY) do if f[k] then return nil end end
  if nd.mt >= 0 and (it.mat_type ~= nd.mt or (nd.mi >= 0 and it.mat_index ~= nd.mi)) then return nil end
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
          local key = string.format('%s:%d:%d', label, nd.mt, nd.mi)
          local q = by[key]
          if not q then
            q = {key = key, label = label, vecs = vecs, mt = nd.mt, mi = nd.mi, n = 0, free = 0, forb = 0, jobs = {}}
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
    if it and it.flags.forbid then
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
    r.fills = farm_fills(K, (c.farms or M.DEFAULTS.farms).per_day or 16, nil, M.food_low(c, r))
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

-- food below the pre-alarm line (or a famine): the slots take the edible crops first, autofarm steps aside
function M.food_low(c, r)
  return ((r.days or {}).food_d or 9999) < ((c.food or {}).pre_days or 30) or (r.p and r.p.famine ~= nil) or false
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
    sn.fills = farm_fills(K, fc.now_max or 24, K.now().season, M.food_low(c, r))
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
function T.forbid(K, c, r)
  if not HUNT_MODES[K.mode()] then return true end
  local fc, dfl = c.forbid or M.DEFAULTS.forbid, M.DEFAULTS.forbid
  if not r.fx then
    r.fx, r.fx_n, r.fx_why = {}, 0, {}
    -- FR-76: a fort whose stock was forbidden in bulk (a reclaimed one: 3026 of 3058 drinks) is not a player's choice
    local inv = K.census.i or {}
    local nf = (inv.drink_forb or 0) + (inv.food_forb or 0)
    local bmin = math.tointeger(fc.burst_min) or dfl.burst_min
    r.burst = bmin > 0 and nf >= bmin and nf or nil
    for _, e in ipairs(st.fix or {}) do
      if e.why ~= 'food' or r.p.starve or r.burst then r.fx[#r.fx + 1] = e end
    end
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
  local per_call = r.burst and M.BURST_SLICE or 1               -- FR-76: item flags are cheap, a burst takes many a frame
  local did = 0
  while #r.fx > 0 and r.fx_n < lim do
    local e = table.remove(r.fx, 1)
    local it = df.item.find(e.id)
    local f = it and it.flags
    if f and f.forbid and not (f.trader or f.in_building or f.garbage_collect or f.removed) then
      local x, y, z = dfhack.items.getPosition(it)
      if x and known_tile(K, x, y, z) and not far(K, x, y, z) then
        r.cmds = r.cmds + 1
        did = did + 1
        if K.act.item_flag(e.id, 'forbid', false) then
          r.fx_n = r.fx_n + 1
          r.fx_why[e.why] = (r.fx_why[e.why] or 0) + 1
        end
        if #r.fx > 0 and r.fx_n < lim and did >= per_call then return false end
      end
    end
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
function M.pile_center(K, spec, jc, cur, pos)
  for _, p in ipairs(type(jc) == 'table' and jc[(spec.jobs or '') .. '_pts'] or {}) do
    if not far(K, p[1], p[2], p[3]) then return {p[1], p[2], p[3]} end
  end
  for _, u in ipairs(cur or {}) do
    local ok, x, y, z = pcall(function() return u.pos.x, u.pos.y, u.pos.z end)
    x, y, z = ok and math.tointeger(x), ok and math.tointeger(y), ok and math.tointeger(z)
    if x and y and z then return {x, y, z} end
  end
  return pos and not far(K, pos[1], pos[2], pos[3]) and {pos[1], pos[2], pos[3]} or nil
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
    return string.format('dfllm-tools placed at %d,%d,%d (%dx%d)', at[1], at[2], at[3], rec.w or 3, rec.h or 2):sub(1, 80)
  elseif rec.state == 'exists' then return 'dfllm-tools stands'
  end
  return (tostring(rec.state) .. ': ' .. tostring(rec.why or '?')):sub(1, 80)
end

-- the nearest w x h block of revealed plain floor to the centre q.at on its level (the citizens' walk group, off the attack
-- path, no building, no pending designation): its top-left tile, or nil and why; at most `pile_reads` tile reads
function M.pile_site(K, tc, q)
  local w, h = tc.pile_w or 3, tc.pile_h or 2
  local R, budget = tc.pile_r or 12, tc.pile_reads or 300
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
  return nil, string.format('no %dx%d plain floor within %d tiles of %d,%d,%d', w, h, R, cx, cy, cz)
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
  if rec.t and r.now - rec.t < (tc.pile_every or 28) * DAY then return true end
  local site, why = M.pile_site(K, tc, q)
  r.cmds = r.cmds + 1
  local out = {t = r.now}
  if site then
    local ok, n = K.act.tool_pile(site, tc.pile_w or 3, tc.pile_h or 2)
    if ok then
      out.state, out.at, out.w, out.h, out.spec = 'placed', json.array(site), tc.pile_w or 3, tc.pile_h or 2, q.spec
      M.pile_ask_again(q.spec)
      K.log('info', 'tool pile: dfllm-tools %dx%d at %d,%d,%d for the %ss lying loose (%s lack them)', out.w, out.h, site[1],
            site[2], site[3], q.kind, q.spec)
    else
      out.state, out.why = 'refused', tostring(n):sub(1, 60)
      K.log('warn', 'tool pile: dfllm-tools at %d,%d,%d refused: %s', site[1], site[2], site[3], tostring(n))
    end
  else
    out.state, out.why = 'nosite', tostring(why):sub(1, 60)
    K.log('warn', 'tool pile: no site: %s', tostring(why))
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
      for _, d in ipairs({{key = 'gatherers', labor = 'HERBALIST', skill = 'HERBALISM', n = sc.gatherers or 0},
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
  K.log('warn', 'starvation: %d hungry, %d cannot reach food; %d shrubs marked for gathering, %d helpers added',
        #sv.hungry, #cut, sv.marked, sv.added)
  if r.now - (math.tointeger(p.starve.woke) or -1e12) >= (sc.report_days or 2) * DAY then
    p.starve.woke = r.now
    local who = #cut > 0 and ('cannot reach food: ' .. table.concat(names, ', ') .. (#cut > #names and (' +' .. (#cut - #names)) or ''))
                or ((st.food_pos and #st.food_pos > 0) and 'all can reach food' or 'no reachable food')
    K.emit('DECISION_NEEDED', 'A', string.format('starvation: %d hungry, food %d days, %d cannot reach food', #sv.hungry,
                                                 fd, #cut),
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
              'scan', 'slabs', 'slotnow', 'ocheck', 'slaughter', 'plan', 'prune', 'tools', 'cover', 'starve', 'forbid', 'toolpile',
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
    elseif h.why == 'mode' then parts[#parts + 1] = 'hunt: not in ' .. tostring(K.mode())
    else parts[#parts + 1] = 'hunt' end
    parts[#parts + 1] = 'butcher'
    parts[#parts + 1] = 'trade.want leather'
    return table.concat(parts, ', ')
  elseif key == 'bars' then
    if (inv.ore or 0) > 0 then
      return ws_any(f, (c.metal or {}).smelter) and string.format('smelt %d ore', inv.ore)
             or string.format('%d ore, no smelter', inv.ore)
    end
    return 'no ore: explore dig (plan), trade.want bar:iron'
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

---------------------------------------------------------------- module
function M.init(K)
  st = {census = nil, run = nil, rate = {}, cancels = {}, looped = {}, backoff = {}, bars_by = {}, ores = {},
        seeds = {}, f = {}}
  orec, wdef, adef = {}, {}, {}
  rcache, pinfo, pidx, ecache, plugins = {}, {}, nil, {}, {}
  skip_mask, mask_check, mask_bad = make_skip_mask(), M.MASK_CHECK, nil
  M.every = {ticks = EVERY}
  pstate(K)
  local ok, err = pcall(kitchen, K, M.conf(K), nil)
  if not ok then K.log('warn', 'kitchen exclusion: %s', tostring(err)) end
end

function M.step(K, budget, ctx)
  local c = M.conf(K)
  if not (ctx and ctx.cont) or not (st.census or st.run) then
    st.census, st.run = {acc = new_acc(c), ci = 1, idx = 0, errs = 0, start = K.now().tick}, nil
    st.census.acc.far = function(it)
      local x, y, z = dfhack.items.getPosition(it)
      if not x then return false end
      local ok, far = K.call('snapshot', 'far', x, y, z)
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
    r.labor = {starving = o.starving, idle = math.max(0, math.min(100, o.idle))}
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
    if st.rock then r.stock.rock, r.stock.rock_need = math.max(0, st.rock.free or 0), math.max(0, st.rock.need or 0) end
    if st.picks then r.stock.picks, r.stock.pick_want = st.picks.have, st.picks.want end
    -- Run 11: metal short for the soldiers (M.metal_plan: plan check's metal route gate) and the metal items marked for
    -- melting (the invaders' gear in the melt pile)
    if st.metal then r.stock.mshort = st.metal.short and 1 or 0 end
    r.stock.melt = math.max(0, math.tointeger(inv.melt) or 0)
    -- BUG-042: why the stills do not brew while drink is below the target ('no validated brew order: manager office
    -- 18631 has no chair')
    if st.dwhy then r.stock.dwhy = tostring(st.dwhy):sub(1, 80) end
    -- FR-76: drink and food units the census counts as forbidden (a reclaimed fort's stock: the status says so)
    if (math.tointeger(inv.drink_forb) or 0) > 0 then r.stock.dforb = math.tointeger(inv.drink_forb) end
    if (math.tointeger(inv.food_forb) or 0) > 0 then r.stock.fforb = math.tointeger(inv.food_forb) end
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
  return r
end

---------------------------------------------------------------- inbox verbs
local FREQ = {OneTime = true, Daily = true, Monthly = true, Seasonally = true, Yearly = true}

-- order.add {job, amount, item_subtype?, material?, material_category?, reaction?, frequency?} (FR-39): one
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
  local okj, jg = K.call('snapshot', 'groups', open_p, true)
  cg = okc and type(cg) == 'table' and cg or {}
  jg = okj and type(jg) == 'table' and jg or {}
  local home = {}
  for _, g in ipairs(cg) do if math.type(g) == 'integer' and g > 0 then home[g] = true end end
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
  local noreach, idle_nl = 0, 0
  if n_open + n_far > 0 then
    for k in ipairs(idle) do
      local g = math.tointeger(cg[idle_at[k]]) or -1
      if g > 0 and (by_grp[g] or 0) + (by_grp.any or 0) == 0 then
        if (by_nl[g] or 0) + (by_nl.any or 0) > 0 then idle_nl = idle_nl + 1 else noreach = noreach + 1 end
      end
    end
  end
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
  local data = {adults = adults, idle = #idle, idle_noreach = noreach, idle_nolabor = idle_nl,
                nolabor = json.array(nl_list), idle_units = names, jobs = total,
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
  local rq, rd = runner_queue(K)
  data.runner = rd
  local paren = string.format('%d without reachable work', noreach)
  if #nl_list > 0 then
    local ds = {}
    for i = 1, math.min(2, #nl_list) do
      ds[i] = string.format('%s %d need %s', nl_list[i].job, nl_list[i].n, nl_list[i].labor)
    end
    paren = (noreach > 0 and (paren .. ', ') or '') ..
            string.format('%d with no labor holder for the open jobs: %s', idle_nl, table.concat(ds, ', '))
  end
  return true, string.format('%d of %d adults without a job (%s), %d unclaimed jobs, %d unreachable',
                             #idle, adults, paren, n_open, n_far) .. (rq and ('; ' .. rq) or ''), data
end

return M
