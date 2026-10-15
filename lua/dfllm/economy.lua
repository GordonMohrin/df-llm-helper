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
--     unforbidden, and DECISION_NEEDED starvation names the citizens who cannot reach food.
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local OL = require('dfllm.orderlib')
local CAD = require('dfllm.util.cadence')   -- BUG-008: when a standing class-A condition is announced again

local M = {name = 'economy', every = {ticks = 1200}, on = {}, verbs = {}, inspect = {},
           reports = {MIGRANT_ARRIVAL = true, MIGRANT_ARRIVAL_NAMED = true, D_MIGRANTS_ARRIVAL = true,
                      CANCEL_JOB = true}}
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
  tools = {shrink_days = 3,
           key_labors = {'MASON', 'CARPENTER', 'BREWER', 'PLANT', 'COOK', 'MECHANIC', 'DIAGNOSE', 'SMELT',
                         'FORGE_WEAPON', 'FORGE_ARMOR'},
           details = {{name = 'Miners', skill = 'MINING', melee = {'MINING'}, min = 2, max = 6, max_pop = 20,
                       tiles_per = 40},
                      {name = 'Woodcutters', skill = 'WOODCUTTING', melee = {'AXE'}, wood = {60, 150}, n = {2, 1, 0}},
                      -- live L3: 9 of 10 strange moods failed with 0 bone, shell and leather in the fort; one
                      -- hunter in PEACE from mood_from_phase while one of them is short (two for an open need)
                      {name = 'Hunters', skill = 'CROSSBOW', ranged = {'CROSSBOW', 'BOW'}, famine = 2, mood = 1,
                       need = 2, ammo_min = 1, mood_keys = {'bone', 'shell', 'leather'}},
                      -- live L5: one fisher per `per` citizens (at most `max`) while food is below food.want_days
                      -- and a fishing zone exists (zones are the runner's or the LLM's); outside PEACE/RECOVERY none
                      {name = 'Fisherdwarves', skill = 'FISH', fish = true, per = 15, max = 3}}},
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
  supply = {
    {tag = 'dfllm:drink', key = 'drink_d', per_job = 5, max_jobs = 30,
     spec = {job = 'CustomReaction', reaction = 'BREW_DRINK_FROM_PLANT', frequency = 'OneTime',
             item_conditions = {{condition = 'AtLeast', flags = {'unrotten'}, item_type = 'PLANT', reaction_product = 'DRINK_MAT', value = 2},
                                {condition = 'AtLeast', flags = {'empty', 'food_storage'}, value = 1}}}},
    {tag = 'dfllm:food', key = 'food_d', per_job = 4, max_jobs = 20,
     spec = {job = 'PrepareMeal', meal_ingredients = 2, frequency = 'OneTime',
             item_conditions = {{condition = 'AtLeast', flags = {'unrotten', 'cookable'}, value = 10}}}},
  },
  -- live L4: floors economy's own consumers keep (wood: the furniture fallback took 70 of 82 logs in L3); care's
  -- forbidden mood reserve counts against them (economy keeps max(0, floor - held) of the free items)
  reserve = {wood = 20, rock = 0, bone = 0, shell = 0, leather = 0, cloth = 0, thread = 0, bars = 0, gems = 0,
             fuel = 0},
  wood = {chop_min = 60, chop_max = 150, margin = 20, band = 90, cap = 400, step = 10},
  -- live L1b: brewing stalled without empty barrels; then dfllm:barrel made 34 barrels (logs 183 -> 66). Below the
  -- drink target the cap is max_total, below nofloor_days of drink barrels may use the wood floor
  -- live L6: while drink is short and fewer than min_empty barrels are empty, the cap grows up to grow_total
  barrels = {tag = 'dfllm:barrel', min_empty = 4, drink_pct = 150, cit_pct = 50, min_total = 8, max_total = 30,
             grow_total = 80, nofloor_days = 30, max_jobs = 4, ws = {'workshop:Carpenters'},
             spec = {job = 'MakeBarrel', material_category = {'wood'}}},
  bins = {tag = 'dfllm:bin', min_empty = 1, cit_pct = 25, min_total = 4, max_total = 20, max_jobs = 2,
          ws = {'workshop:Carpenters'}, spec = {job = 'ConstructBin', material_category = {'wood'}}},
  leather = {from_phase = 'P1', tag = 'dfllm:tan', after_days = 2, max_jobs = 10, ws = {'workshop:Tanners'},
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
  metal = {from_phase = 'P2', max_jobs = 10, ores_per_day = 2, smelter = {'furnace:Smelter', 'furnace:MagmaSmelter'},
           charcoal = {tag = 'dfllm:charcoal', buffer = 4, cap = 40, ws = {'furnace:WoodFurnace'}},
           bronze = {tag = 'dfllm:bronze', ore = 'BRONZE_MAKING', bars = 'BRONZE_MAKING2', max_jobs = 5},
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
  -- dfllm order is not entered again for backoff_days
  orders = {stuck_days = 3, needs_drop = 10, backoff_days = 10, report_per_day = 3},
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
  farms = {per_day = 16},
  forbid = {per_day = 30},
  -- FR-25: below `days` food days with citizens over `hunger` (DF's "hungry" is 50000)
  starve = {days = 0, hunger = 50000, plants_max = 200, plants_per_slice = 400, report_days = 2, gatherers = 4,
            planters = 4, plants = {'GRASS_WHEAT_CAVE', 'MUSHROOM_HELMET_PLUMP', 'POD_SWEET', 'BUSH_QUARRY',
                                    'MUSHROOM_CUP_DIMPLE'},
            details = {planters = {'Planters'}, gatherers = {'Plant gatherers', 'Gatherers', 'Herbalists'}}},
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
              'badseen', 'jres'}
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
              'SEEDS', 'WEAPON', 'ARMOR', 'HELM', 'PANTS', 'GLOVES', 'SHOES', 'SHIELD', 'QUIVER'}
local SKIP = {'trader', 'garbage_collect', 'removed', 'dump', 'hostile', 'in_building', 'construction', 'rotten'}
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
local FIX_MAX = 200
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

local function classify(it, a, cat)
  local f = it.flags
  for _, k in ipairs(SKIP) do if f[k] then return end end
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
  elseif f.forbid then return end
  -- live L7 (Paddletribes): 117 of 137 "edible" fruit lay in cut-off caves; the fort read 101 food days while 35 of
  -- 42 dwarves starved. Food and drink on another walkable group than the citizens' feed nobody.
  if (cat == 'DRINK' or a.food_set[cat]) and not f.in_inventory and a.far and a.far(it) then
    a.unreach = (a.unreach or 0) + n
    return
  end
  if cat == 'DRINK' then a.drink = a.drink + n
  elseif a.food_set[cat] then
    -- food = what a dwarf can eat now: meals and raw-edible items. Cook-only items (egg yolks, raw fish,
    -- flour) feed nobody without a kitchen job (live L1: 34 yolks reported as 250 food days while a
    -- dwarf starved), so they count as `cookable`.
    if cat ~= 'FOOD' then
      local mf = mat_flags(it)
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
  elseif cat == 'SMALLGEM' or cat == 'ROUGH' then a.gems = a.gems + n
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
    if not f.spider_web then
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
    if k == 'pick' then
      a.w_pick = a.w_pick + 1
      if not holder(it) then a.w_pick_free = a.w_pick_free + 1 end   -- FR-40: nobody carries it (a bin may)
    elseif k == 'axe' then
      a.w_axe = a.w_axe + 1
      if not holder(it) then a.w_axe_free = a.w_axe_free + 1 end
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
              'g_quiver', 'g_metal', 'fish_raw', 'food_nocook', 'seeds_ok', 'seeds_forb', 'w_pick_free', 'w_axe_free'}
local function new_acc(c)
  local fs = {}
  for _, k in ipairs(c.food_cats or {}) do fs[k] = true end
  local nocook = {}
  for _, e in ipairs(c.kitchen or {}) do
    if e.what == 'Cook' and e.item == 'PLANT' and type(e.plant) == 'string' then nocook[e.plant] = true end
  end
  local a = {kinds = {}, food_set = fs, bars_by = {}, ores = {}, seeds = {}, nocook = nocook, fix = {}, fix_seen = {},
             reach = {}, food_pos = {}}
  for _, k in ipairs(ZERO) do a[k] = 0 end
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

-- open orders: our tags still live (amount left), the inputs they still hold (meta.uses x left) and the wood
-- any other open order still needs (material category wood, MakeCharcoal)
local function scan_orders(p)
  local own = {}
  for tag, id in pairs(p.orders) do own[id] = tag end
  local s = {live = {}, used = {}}
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

---------------------------------------------------------------- needs, reserves, floors (hook API)
local KEYS = {wood = true, rock = true, bone = true, shell = true, leather = true, cloth = true, thread = true,
              bars = true, gems = true, fuel = true, hides = true}
local ALIAS = {logs = 'wood', log = 'wood', boulders = 'rock', boulder = 'rock', stone = 'rock', rough = 'gems',
               glass = 'gems', gem = 'gems', bar = 'bars', skin = 'hides'}
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
  local w = care_hook(K, 'mood_wants')
  if type(w) == 'table' then
    for k, v in pairs(w) do
      local key, n
      if type(k) == 'number' and type(v) == 'table' then key, n = key_of(v.cls or v.class or v.key), count_of(v.n or 1)
      else key, n = key_of(k), count_of(v) end
      if KEYS[key] and n and n > 0 then wants[key] = (wants[key] or 0) + n end
    end
  end
  for key in pairs(KEYS) do
    local m = r.p.needs[key]
    if wants[key] then
      if type(m) ~= 'table' then m = json.object{}; r.p.needs[key] = m end
      local prev = m.care
      m.care = {n = wants[key], untl = r.now + 2 * DAY}
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

-- cooking keeps food (live L5: gathered fruit and butchered meat rot; meals keep): meals_per_dwarf prepared meals
-- per citizen, and the job cap of the food order grows with the fort
local function meal_jobs(c, r, e)
  local fc = c.food
  if e.key ~= 'food_d' or type(fc) ~= 'table' then return 0, e.max_jobs or 20 end
  local cit, inv = r.cit or 0, r.inv
  local want = cit * (fc.meals_per_dwarf or 0) - (inv.meals or 0)
  -- what a cook may use: raw-edible food that is no meal and not on the cook ban (plump helmets), cook-only items
  local ingredients = (inv.food or 0) - (inv.meals or 0) - (inv.food_nocook or 0) + (inv.cookable or 0)
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
  -- live L6 (Laborkings): 30 barrels, all full of food and drink, drink below the target: max_total stopped the
  -- stills. While drink is short and the empty barrels are missing, the cap grows past max_total (up to grow_total)
  if short and empty_miss > 0 and b.grow_total then
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
  local ok, _, per = K.call('military', 'targets')
  if ok and type(per) == 'table' then
    for key, v in pairs(per) do
      local n = math.tointeger(v) or 0
      if key == 'C' then xb = xb + n else melee = melee + n end
    end
  end
  local who = {all = melee + xb, melee = melee, xbow = xb, ranged = xb + hunt}
  local res = {n = melee + xb, melee = melee, xbow = xb, hunt = hunt, cats = {}, leather = 0, metal_jobs = 0}
  -- metal pieces the bars at hand could make (any preferred metal), shared by the slots in order
  local bars = 0
  for _, m in ipairs(g.metals or {}) do bars = bars + (st.bars_by['INORGANIC:' .. m] or 0) end
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
    end
  end
  return res
end

local function hunters_spec(c)
  for _, d in ipairs((c.tools or {}).details or {}) do if d.name == 'Hunters' then return d end end
end

-- hunters wanted: famine (PEACE or RECOVERY only), else (PEACE, from mood_from_phase or an open need, not paused
-- for want of game) one while leather, bone or shell is short of its target, `need` while one of them has an open
-- need. Hunters roam outside the walls: in ALERT, SIEGE, BREACH or a DRILL ("nobody outside at T+1,200") they are
-- wanted nowhere, and tools() takes them off the detail at once (reason 'mode'), not after shrink_days.
local HUNT_MODES = {PEACE = true, RECOVERY = true}
local function hunt_want(K, c, r)
  local spec = hunters_spec(c)
  if not spec then return 0, 'none' end
  local mode = K.mode()
  if not HUNT_MODES[mode] then return 0, 'mode' end
  if r.p.famine then return spec.famine or 0, 'famine' end
  if mode ~= 'PEACE' then return 0, 'mode' end
  local short, needed = false, false
  for _, key in ipairs(spec.mood_keys or {}) do
    local tgt = r.targets[key] or target(K, c, r, key)
    if have(r, key) < tgt then short = true end
    if need_n(r.p, key, r.now) > have(r, key) then needed = true end
  end
  if not short then return 0, 'stock' end
  -- an open mood need still unmet hunts through the "no game" pause (a failed mood ends in a death)
  if needed then return spec.need or spec.mood or 1, 'need' end
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
  if not r.p.famine and d >= (fc.want_days or 90) then return 0, 'stock' end
  local per = math.max(1, spec.per or 15)
  return clamp(((r.cit or 0) + per - 1) // per, 1, spec.max or 3), r.p.famine and 'famine' or 'food'
end

local function plan_leather(K, c, r)
  local L = c.leather
  local want = target(K, c, r, 'leather') + (phase_ok(K, L.from_phase) and r.gear.leather or 0)
  r.targets.leather = want
  if have(r, 'leather') >= want or open(r, L.tag) then return end
  if (r.inv.hides or 0) > 0 and (r.p.hides_days or 0) >= (L.after_days or 2) and ws_any(r.f, L.ws) then
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
  local wanted = have(r, 'bars') < bars_want or r.gear.metal_jobs > 0
  if not wanted then return end
  if not phase_ok(K, Mt.from_phase) and need_n(r.p, 'bars', r.now) == 0 and r.gear.metal_jobs == 0 then return end
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
  local material = (r.inv.ore or 0) + (r.inv.bars or 0) > 0
  if ch and material and not magma and not open(r, ch.tag) and ws_any(r.f, ch.ws) then
    -- fuel for: the ore still to smelt, the forge jobs the bars (and ore, ~4 bars each) could feed, the fuel
    -- the open orders hold, plus a buffer
    local jobs = math.max(smelt_jobs, math.min(r.inv.ore or 0, Mt.max_jobs or 10)) +
                 math.min(r.gear.metal_jobs, (r.inv.bars or 0) + (r.inv.ore or 0) * 4)
    local want = math.min(ch.cap or 40, jobs + (r.s.used.fuel or 0) + (ch.buffer or 4))
    local n = math.min(want - (r.inv.fuel or 0), left(c, r, 'wood'), Mt.max_jobs or 10)
    add(r, {tag = ch.tag, spec = wood_spec(c, r, {job = 'MakeCharcoal', material_category = {}}), n = n,
            uses = {wood = 1}, why = 'fuel'})
  end
  -- no ore and no usable bars: exploration (a dig is not economy's to designate) and the LLM once a year
  local ex = Mt.explore
  if ex and (r.inv.ore or 0) == 0 and (r.gear.metal_short or have(r, 'bars') < bars_want) and
     left(c, r, 'bars') == 0 and phase_ok(K, Mt.from_phase) then
    r.route.bars = 'explore'
    local e = r.p.explore
    if r.now - (math.tointeger(e.req) or -1e12) >= (ex.request_every or 100800) then
      e.req = r.now
      K.emit('PROJECT_REQUEST', 'B', 'exploration dig for ore (no ore, no bars: soldiers and moods need metal)',
             {tpl = ex.tpl or 'explore', n = 1, why = 'ore'})
    end
    if r.now - (math.tointeger(e.dec) or -1e12) >= (ex.decide_every or 403200) then
      e.dec = r.now
      K.emit('DECISION_NEEDED', 'A', string.format('metal: no ore, %d bars; %d forge jobs and %d bars for moods wanted',
                                                   r.inv.bars or 0, r.gear.metal_jobs, bars_want),
             {id = 'metal', q = 'no ore or bars: exploration dig into revealed stone (digexp pattern), or trade.want bar:iron/bar:copper?'})
    end
  end
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
  if floor ~= st.stale then
    K.log('info', 'labor: %d of %d starving postings are stale (oldest %s, %s ticks)', floor, n, tostring(job or '?'),
          age and fmt(age) or '?')
  end
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
local function idle_rule(K, c, p, inv, rock)
  local rule = decision(K, 'D-03')
  if st.idle == nil then return false end
  if st.idle > c.idle.pct then p.idle_days = (p.idle_days or 0) + 1 else p.idle_days = 0 end
  local need = rule == 'immediate' and 1 or c.idle.days
  if rule == 'off' or p.idle_days < need or K.mode() ~= 'PEACE' then return false end
  local b = backlog_pick(K, c, p, inv, rock)
  if not b then
    K.log('info', 'idle %d%% for %d days, useful backlog empty: no action', st.idle, p.idle_days)
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
  if OL.needs(why) then
    oid = find_order_named(key)
    if oid then needs_cancel(K, c, oid, job, why) end
  end
  if n < (c.cancel_loop or 5) or st.looped[key] then return end
  st.looped[key] = true
  oid = oid or find_order_named(key)
  K.emit('CANCEL_LOOP', 'B', string.format('%s cancelled %d times today', job, n), {order = oid or -1, job = job, n = n})
  if st.rechecked ~= day then           -- orders.txt: recheck stops cancellation spam of stale conditions
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
M.POSITIONS = {{code = 'MANAGER', skills = {'ORGANIZATION'}},
               {code = 'BOOKKEEPER', skills = {'RECORD_KEEPING'}},
               {code = 'BROKER', skills = {'APPRAISAL', 'NEGOTIATION', 'JUDGING_INTENT'}}}

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
    elseif code then vac[code] = true end
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

function M.appoint_vacant(K)
  local ok, vac, held = pcall(positions)
  if not ok then return 0 end
  local cu = K.census.u
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' then return 0 end
  local n = 0
  for _, pos in ipairs(M.POSITIONS) do
    if vac[pos.code] then
      local best, bscore
      for _, id in ipairs(cu.ids) do
        local u = df.unit.find(id)
        if u and dfhack.units.isAdult(u) and u.military.squad_id < 0 then
          local score = skill_score(u, pos.skills) * 10 - (held[u.hist_figure_id] and 1000 or 0)
          if not bscore or score > bscore then best, bscore = u, score end
        end
      end
      if best then
        local aok = K.act.appoint(pos.code, best.id)
        if aok then
          held[best.hist_figure_id] = true
          n = n + 1
          K.log('info', '%s appointed: unit %d (%s)', pos.code, best.id, dfhack.df2utf(dfhack.units.getReadableName(best)))
        end
      end
    end
  end
  return n
end

-- Manager orders that never get validated (live L1: the MANAGER position has required_office 1, so above
-- a population threshold the manager validates only from an office with a chair; DF posts no
-- ManageWorkOrders job otherwise). After 3 days with orders, a manager and nothing validated: wake the LLM.
local function validation_watch(K, p)
  -- live L6: a new manager (the old one died or left) stood without an office; the office check runs every
  -- day for whoever is manager now, not only when no order was validated
  local now = K.now().tick
  if K.act.manager_office and now - (p.office_t or -DAY) >= DAY then
    p.office_t = now
    local okc, res = K.act.manager_office()
    if okc and res == 'assigned' then K.log('warn', 'manager had no office: free Office zone assigned') end
  end
  local ok, total, valid = pcall(function()
    local t, v = 0, 0
    for _, o in ipairs(orders_all()) do t = t + 1; if o.status.validated then v = v + 1 end end
    return t, v
  end)
  -- live L6: one hand-validated order kept the watch quiet while 117 of 118 waited; below 10% validated counts
  if not ok or total == 0 or valid * 10 >= total then p.unval = nil; return end
  local vac = select(2, pcall(positions))
  if type(vac) ~= 'table' or vac.MANAGER then p.unval = nil; return end   -- no manager yet: appoint first
  p.unval = p.unval or {since = now, woke = 0}
  if now - p.unval.since >= 3 * DAY and now - (p.unval.woke or 0) >= 7 * DAY then
    p.unval.woke = now
    K.emit('DECISION_NEEDED', 'A', string.format('%d manager orders, none validated for 3 days', total),
           {id = 'manager_office', q = 'manager validates no orders: office zone with a chair for the manager?'})
  end
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

---------------------------------------------------------------- tool work details (live L1b)
-- economy is the sole writer of the builtin Miners / Woodcutters / Hunters memberships (act.work_detail, the
-- work details screen) while labormanager is not in modern mode; modern manages them itself. Members are
-- adult citizens; a soldier, a member of an earlier tool detail or a unit that left the fort is removed at
-- once. New members: no noble (militia posts excepted), no moody or insane dwarf, no sole holder of a key
-- labor, nobody from another tool detail; the best skill joins first. Shrinking waits shrink_days and drops
-- the lowest skill first (among equals those it would not pick).
local DIG_JOBS = {Dig = true, CarveUpwardStaircase = true, CarveDownwardStaircase = true,
                  CarveUpDownStaircase = true, CarveRamp = true, DigChannel = true}
local MILITIA = {MILITIA_CAPTAIN = true, MILITIA_COMMANDER = true}
local TOOL_KEY = {MINING = 'w_pick', AXE = 'w_axe', CROSSBOW = 'w_xbow', BOW = 'w_bow'}

-- designation jobs waiting in the job list (also digging nobody planned through the runner)
local function dig_jobs()
  local n = 0
  pcall(function()
    local link, i = df.global.world.jobs.list.next, 0
    while link and i < 5000 do
      local j = link.item
      if j and DIG_JOBS[df.job_type[j.job_type] or ''] then n = n + 1 end
      link, i = link.next, i + 1
    end
  end)
  return n
end

-- weapons usable as the detail's tool (picks, axes, crossbows and bows not carried by soldiers), from the census
local function tool_count(spec, inv)
  local n = 0
  for _, s in ipairs(spec.melee or {}) do n = n + (inv[TOOL_KEY[s] or ''] or 0) end
  for _, s in ipairs(spec.ranged or {}) do n = n + (inv[TOOL_KEY[s] or ''] or 0) end
  return n
end

local function tool_target(K, spec, cit, inv, r)
  if spec.tiles_per then
    local ok, rb = K.call('runner', 'dig_backlog')
    local backlog = math.max(ok and math.tointeger(rb) or 0, dig_jobs())
    local cap = cit >= (spec.max_pop or 0) and spec.max or spec.min
    local want = (backlog + spec.tiles_per - 1) // spec.tiles_per
    return math.max(spec.min, math.min(cap, want)), backlog
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
  if hunters == 0 or r.p.famine then p.hunt = nil; return end
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
  local member = {}                          -- unit id -> name of its first tool detail
  for _, spec in ipairs(tc.details or {}) do
    local wd = wds[spec.name]
    if wd then for _, id in ipairs(wd.assigned_units) do member[id] = member[id] or spec.name end end
  end
  local function soft_ok(u)                  -- may be picked
    return not noble(u) and not sole[u.id] and not ((u.mood or -1) >= 0)
  end
  p.tools = json.object(type(p.tools) == 'table' and p.tools or {})
  local now, changes, taken = K.now().tick, 0, {}
  local function set(spec, id, on, why, tgt)
    local ok = K.act.work_detail(spec.name, id, on)
    if ok then
      changes = changes + 1
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
      local tgt, basis = tool_target(K, spec, #cu.ids, inv, r)
      if tgt > 0 and (spec.melee or spec.ranged) then tgt = math.min(tgt, tool_count(spec, inv)) end
      local sid = df.job_skill[spec.skill]
      local function skill(u) return sid and dfhack.units.getNominalSkill(u, sid, true) or 0 end
      local keep = {}
      for _, id in ipairs(wd.assigned_units) do keep[#keep + 1] = id end
      local cur = {}
      for _, id in ipairs(keep) do
        local u = cit[id]
        if not u or not dfhack.units.isAdult(u) or u.military.squad_id >= 0 or taken[id] then
          set(spec, id, false, taken[id] and ('in ' .. taken[id]) or 'not eligible', tgt)
        else cur[#cur + 1] = u end
      end
      local ps = p.tools[spec.name] or {}
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
          end
        end
      elseif #cur > tgt then
        ps.low = ps.low or now
        -- hunters outside the walls while the fort leaves PEACE: off the detail now (siege reflex, drills)
        local at_once = r ~= nil and ((spec.ranged ~= nil and r.hunt_why == 'mode') or
                                      (spec.fish ~= nil and r.fish_why == 'mode'))
        if at_once or now - ps.low >= (tc.shrink_days or 3) * DAY then
          table.sort(cur, function(a, b)               -- the best skill stays (live L1b: shrinking by
            local sa, sb = skill(a), skill(b)          -- eligibility first dropped the fort's only trained
            if sa ~= sb then return sa > sb end        -- miner, the bookkeeper)
            local oa, ob = soft_ok(a), soft_ok(b)
            if oa ~= ob then return oa end
            return a.id < b.id
          end)
          local why = at_once and ('mode ' .. tostring(K.mode())) or string.format('basis %d', basis)
          while #cur > tgt do
            local u = table.remove(cur)
            if not set(spec, u.id, false, why, tgt) then cur[#cur + 1] = u; break end
          end
          ps.low = nil
        end
      else
        ps.low = nil
      end
      p.tools[spec.name] = json.object(ps)
      for _, u in ipairs(cur) do taken[u.id] = spec.name end
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
    K.emit('DECISION_NEEDED', 'A', string.format('famine: %d food days, %d drink days', fd, dd),
           {id = 'famine', q = string.format('food %d d (%d eatable, %d cookable, %d raw fish%s), drink %d d: gather, farm, cook, trade?',
                                             fd, inv.food or 0, inv.cookable or 0, inv.fish_raw or 0,
                                             ((inv.fish_raw or 0) > 0 and not (r and r.f and r.f['workshop:Fishery']))
                                               and ': build a fishery' or '', dd):sub(1, 200)})
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

-- the famine pre-alarm: below pre_days (and not yet a famine) a weekly class-A wake with what the fort has
local function food_pre(K, c, p, days, inv)
  local fc = c.food
  local fd = days.food_d
  local pre, lim = type(fc) == 'table' and (fc.pre_days or 0) or 0, c.famine_days or 10
  if fd >= pre then
    if p.food_pre then p.food_pre = nil; K.log('info', 'food pre-alarm over: %d food days', fd) end
    return
  end
  if fd < lim then return end                       -- the famine wake (famine_days) speaks now
  local now = K.now().tick
  if type(p.food_pre) ~= 'table' then
    p.food_pre = {since = now, woke = 0}
    K.log('warn', 'food pre-alarm: %d food days (< %d)', fd, pre)
  end
  if p.food_pre.woke ~= 0 and now - p.food_pre.woke < 7 * DAY then return end
  p.food_pre.woke = now
  local f = st.food or {}
  K.emit('DECISION_NEEDED', 'A', string.format('food low: %d food days (pre-alarm, famine below %d)', fd, lim),
         {id = 'food_low', q = string.format('food %d d: farms %d/%d tiles%s, fishing zone %s, %d raw fish, %d cookable: ' ..
                                             'farms, gather/fishing zones, butcher, trade?', fd, f.tiles or 0,
                                             f.need or 0, f.falling and ' (falling)' or '', st.fishzone and 'yes' or 'no',
                                             inv.fish_raw or 0, inv.cookable or 0):sub(1, 200)})
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
  local ctx = {f = r.f or {}, holders = {}}
  function ctx.is_metal(mi)
    local f = mat_flags({mat_type = 0, mat_index = mi})
    return f ~= nil and f.IS_METAL == true
  end
  function ctx.has(key)
    if key == 'cook' then
      return (inv.food or 0) - (inv.meals or 0) - (inv.food_nocook or 0) + (inv.cookable or 0) > 0
    elseif key == 'fish_raw' then return (inv.fish_raw or 0) > 0 end
    local n = key == 'rock' and stone_free(c, r) or stock_of(r, key)
    if n <= 0 then return false end
    return type(reach) ~= 'table' or reach[key] == true
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
  local mc = OL.mat_class(o, ctx.is_metal)
  local ws, labors
  if job == 'CustomReaction' then ws, labors = reaction_needs(o.reaction_name)
  else
    ws = OL.workshops(job, mc)
    labors = OL.labors(job, mc, ws)
  end
  local why = {}
  if ws and not ws_any(ctx.f, ws) then why[#why + 1] = 'no ' .. (ws[1]:match(':(.+)$') or ws[1]) end
  if job ~= 'CustomReaction' then
    local tok = (mc == 'metal' or job == 'SmeltOre') and (o.mat_index or -1) >= 0 and mat_token(0, o.mat_index) or nil
    local key = OL.input(job, mc, tok)
    if key and not ctx.has(key) then why[#why + 1] = 'no ' .. key end
  end
  if labors and not ctx.labor_ok(labors) then why[#why + 1] = 'no worker ' .. table.concat(labors, '/') end
  if #why == 0 then return nil, job end
  return table.concat(why, ', '), job
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
function M.slot_crop(crops, under, s, seeds)
  local function fits(inf) return inf and inf.under == under and inf.seasons[s + 1] == true end
  for _, pid in ipairs(crops) do
    local inf = plant_info(pid)
    if fits(inf) and (seeds[inf.id] or 0) > 0 then return pid end
  end
  local best, bn
  for id, n in pairs(seeds) do
    local pid = plant_index(id)
    local inf = pid and plant_info(pid)
    if fits(inf) and inf.crop and n > 0 and (not bn or n > bn or (n == bn and pid < best)) then best, bn = pid, n end
  end
  if best then return best end
  for _, pid in ipairs(crops) do if fits(plant_info(pid)) then return pid end end
end

-- {plot id, season, crop} for every empty slot of the built farm plots; st.farm counts plots and empty slots
local function farm_fills(max)
  local fills, plots, empty = {}, 0, 0
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.FARM_PLOT) do
      if built(b) then
        plots = plots + 1
        local crops, under = {}, nil
        for s = 0, 3 do
          local pid = b.plant_id[s]
          if pid and pid >= 0 then
            crops[#crops + 1] = pid
            local inf = plant_info(pid)
            if inf and under == nil then under = inf.under end
          end
        end
        for s = 0, 3 do
          local pid = b.plant_id[s]
          if not pid or pid < 0 then
            empty = empty + 1
            local crop = under ~= nil and #fills < max and M.slot_crop(crops, under, s, st.seeds or {}) or nil
            if crop then fills[#fills + 1] = {id = b.id, s = s, crop = crop} end
          end
        end
      end
    end
  end)
  st.farm = {plots = plots, empty = empty}
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

local function unit_name(id)
  local u = df.unit.find(id)
  local ok, n = pcall(function() return dfhack.df2utf(dfhack.units.getReadableName(u)) end)
  return ok and type(n) == 'string' and n or ('unit ' .. tostring(id))
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
  validation_watch(K, r.p)
  alarm_check(K, c, r.p, r.days)
  famine(K, c, r.p, r.days, r.inv, r)
  food_pre(K, c, r.p, r.days, r.inv)
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

function T.plan(K, c, r)
  r.cands, r.planned, r.targets, r.route = {}, {}, {}, {}
  for _, key in ipairs({'bone', 'shell'}) do r.targets[key] = target(K, c, r, key) end
  r.gear = gear_pre(K, c, r, 0)
  r.targets.leather = target(K, c, r, 'leather') + (phase_ok(K, c.leather.from_phase) and r.gear.leather or 0)
  r.hunt, r.hunt_why = hunt_want(K, c, r)
  r.fish, r.fish_why = fish_want(K, c, r)
  r.gear = gear_pre(K, c, r, r.hunt)
  -- priority: needs (moods) first, then drink and food, then soldiers, then stock
  local urgent = {leather = need_n(r.p, 'leather', r.now) > 0, cloth = need_n(r.p, 'cloth', r.now) +
                  need_n(r.p, 'thread', r.now) > 0, bars = need_n(r.p, 'bars', r.now) > 0}
  local list = {{1.5, plan_supply}, {2, function() plan_containers(K, c, r, 'barrels') end},
                {urgent.leather and 1 or 4, plan_leather}, {urgent.cloth and 1 or 3.5, plan_cloth},
                {urgent.bars and 1 or 3, plan_metal}, {3.2, plan_gear},
                {5, function() plan_containers(K, c, r, 'bins') end}}
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
  if type(Cc) ~= 'table' then return true end
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
  if type(fc) ~= 'table' or not r.day then return true end
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
    st.orders = {n = n, bad = st.bad, stuck = st.orders and st.orders.stuck or 0}
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
    oq = {ids = ids, i = 1, ctx = order_ctx(K, c, r), seen = {}, stuck = 0, told = 0}
    r.oq = oq
  end
  local last = math.min(#oq.ids, oq.i + ORDER_SLICE - 1)
  for k = oq.i, last do
    local o = order_by_id(oq.ids[k])
    local why, job
    if o and (o.amount_left or 0) > 0 then why, job = M.order_reasons(o, oq.ctx) end
    if why then
      local key = tostring(o.id)
      oq.seen[key] = true
      local rec = p.ostuck[key]
      if type(rec) ~= 'table' then rec = {since = r.now}; p.ostuck[key] = rec end
      rec.why, rec.job = why:sub(1, 80), tostring(job):sub(1, 40)
      local days = (r.now - (math.tointeger(rec.since) or r.now)) // DAY
      if days >= (oc.stuck_days or 3) then
        oq.stuck = oq.stuck + 1
        if rec.told ~= 1 and oq.told < (oc.report_per_day or 3) then
          rec.told, oq.told = 1, oq.told + 1
          K.emit('ORDER_STUCK', 'B', string.format('order %d %s cannot run for %d days: %s', o.id, rec.job, days, rec.why),
                 {order = o.id, job = rec.job, why = rec.why, days = days, dropped = 0})
        end
      end
    end
  end
  oq.i = last + 1
  r.cmds = r.cmds + 1                            -- a slice of its own (orders, labor holders)
  if oq.i <= #oq.ids then return false end
  for key in pairs(p.ostuck) do if not oq.seen[key] then p.ostuck[key] = nil end end
  st.orders = {n = #oq.ids, bad = st.bad or 0, stuck = oq.stuck}
  return true
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
    r.fills = farm_fills((c.farms or M.DEFAULTS.farms).per_day or 16)
    if K.census.i and st.farm then K.census.i.farm_plots, K.census.i.farm_empty = st.farm.plots, st.farm.empty end
    r.filled = 0
  end
  local f = table.remove(r.fills, 1)
  if not f then
    if r.filled > 0 then K.log('info', 'farm plots: %d empty season slots filled', r.filled) end
    return true
  end
  r.cmds = r.cmds + 1
  if K.act.farm_crop(f.id, f.s, f.crop) then r.filled = r.filled + 1 end
  return #r.fills == 0 and r.filled == 0
end

-- FR-23/FR-50 (daily, PEACE/RECOVERY): forbidden containers of drink/food/seeds and forbidden seeds on revealed,
-- reachable tiles are unforbidden; in a starvation forbidden food too (FR-25)
function T.forbid(K, c, r)
  if not HUNT_MODES[K.mode()] then return true end
  if not r.fx then
    r.fx, r.fx_n, r.fx_why = {}, 0, {}
    for _, e in ipairs(st.fix or {}) do
      if e.why ~= 'food' or r.p.starve then r.fx[#r.fx + 1] = e end
    end
  end
  local lim = (c.forbid or M.DEFAULTS.forbid).per_day or 30
  while #r.fx > 0 and r.fx_n < lim do
    local e = table.remove(r.fx, 1)
    local it = df.item.find(e.id)
    local f = it and it.flags
    if f and f.forbid and not (f.trader or f.in_building or f.garbage_collect or f.removed) then
      local x, y, z = dfhack.items.getPosition(it)
      if x and known_tile(K, x, y, z) and not far(K, x, y, z) then
        r.cmds = r.cmds + 1
        if K.act.item_flag(e.id, 'forbid', false) then
          r.fx_n = r.fx_n + 1
          r.fx_why[e.why] = (r.fx_why[e.why] or 0) + 1
        end
        if #r.fx > 0 and r.fx_n < lim then return false end
      end
    end
  end
  if r.fx_n > 0 then K.log('info', 'unforbidden: %s', why_line(r.fx_why, 4)) end
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
    st.out = {drink_d = r.days.drink_d, food_d = r.days.food_d, meals = r.inv.meal_kinds,
              starving = st.starving or 0, idle = st.idle or 0}
  end
  K.persist.touch('m.economy')
end

local FULL = {'guard', 'days', 'kitchen', 'appoint', 'food', 'watch', 'cmdq', 'engine', 'labor_fix', 'scan', 'ocheck',
              'slaughter', 'plan', 'prune', 'tools', 'starve', 'forbid', 'jobs', 'jsite', 'jmat', 'jfree', 'jresume',
              'jcheck', 'jmove', 'pb', 'orders', 'wood', 'chop', 'crops',
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
  elseif key == 'bars' then
    if (inv.ore or 0) > 0 then return true, 'smelt' end
    return false, 'no ore: exploration dig or trade'
  end
  return false, 'no route: mining/trade'
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
    r.labor = {starving = o.starving, idle = math.max(0, math.min(100, o.idle))}
  end
  local od = st.orders
  if od then r.orders = {n = od.n or 0, bad = od.bad or 0, stuck = od.stuck or 0} end   -- FR-01/FR-39
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
          e.why, e.days = rec.why, (now - (math.tointeger(rec.since) or now)) // DAY
          rank = math.min(rank, 1)
        end
        local cr = p.ocancel[key]
        if type(cr) == 'table' then e.cancels, e.cancel_why, rank = cr.n, cr.why, math.min(rank, 2) end
        all[#all + 1] = {rank, e}
      end
    end
  end
  table.sort(all, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2].id < b[2].id end)
  local list, bytes = {}, 0
  for _, x in ipairs(all) do
    local ok, enc = pcall(json.encode, x[2])
    bytes = bytes + (ok and #enc or 200) + 1
    if bytes > INSPECT_BYTES then break end
    list[#list + 1] = x[2]
  end
  local od = st.orders or {}
  return true, string.format('%d open orders, %d stuck, %d unsafe', n, od.stuck or 0, od.bad or 0),
         {n = n, stuck = od.stuck or 0, bad = od.bad or 0, list = json.array(list), more = n - #list}
end

-- inspect what=workload (FR-40): adults without a job, unclaimed jobs by type, top cancel reasons, free tools,
-- suspended construction jobs and the starvation report
M.inspect.workload = function(K, args)
  local cu = K.census.u or {}
  local sold = {}
  for _, id in ipairs(cu.soldier_ids or {}) do sold[id] = true end
  local idle, adults = {}, 0
  for _, id in ipairs(cu.ids or {}) do
    local u = not sold[id] and df.unit.find(id)
    if u and dfhack.units.isAdult(u) then
      adults = adults + 1
      if u.job == nil or u.job.current_job == nil then idle[#idle + 1] = id end
    end
  end
  local open, sus, total = {}, 0, 0
  pcall(function()
    local link, i = df.global.world.jobs.list.next, 0
    while link and i < 50000 do
      local j = link.item
      if j then
        total = total + 1
        if j.flags.suspend then sus = sus + 1
        else
          local okw, w = pcall(dfhack.job.getWorker, j)
          if okw and w == nil then
            local tn = df.job_type[j.job_type] or '?'
            open[tn] = (open[tn] or 0) + 1
          end
        end
      end
      link, i = link.next, i + 1
    end
  end)
  local why = {}
  for k, v in pairs(st.why_prev or {}) do why[k] = v end
  for k, v in pairs(st.why or {}) do why[k] = (why[k] or 0) + v end
  local unclaimed = {}
  for _, e in ipairs(top(open, 12)) do unclaimed[#unclaimed + 1] = {job = e.why, n = e.n} end
  local inv = K.census.i or {}
  local names = {}
  for i = 1, math.min(10, #idle) do names[i] = {id = idle[i], name = unit_name(idle[i]):sub(1, 40)} end
  local sj = st.jobs
  local jobs = sj and {suspended = sj.suspended, released = sj.released, kept = sj.kept, planned = sj.planned,
                       why = top(sj.why, 5), resuspended = sj.resuspended or 0, forbidden = sj.forbidden or 0,
                       other = sj.other or 0, unforbidden = sj.unforbidden or 0, missing = json.array(sj.missing or {}),
                       blocked = json.array(sj.blocked or {}), depot_move = st.depot_move} or json.object{}
  local sv = st.starve
  local data = {adults = adults, idle = #idle, idle_units = names, jobs = total, suspended = sus,
                unclaimed = unclaimed, cancels = top(why, 8),
                tools = {pick = inv.w_pick or 0, pick_free = inv.w_pick_free or 0, axe = inv.w_axe or 0,
                         axe_free = inv.w_axe_free or 0},
                construction = jobs,
                starve = sv and {hungry = sv.hungry, cut = #sv.cut, cut_units = {table.unpack(sv.cut, 1, math.min(10, #sv.cut))},
                                 marked = sv.marked, added = sv.added, unreach = sv.unreach} or json.object{}}
  return true, string.format('%d of %d adults without a job, %d unclaimed jobs', #idle, adults,
                             (function() local n = 0; for _, v in pairs(open) do n = n + v end; return n end)()), data
end

return M
