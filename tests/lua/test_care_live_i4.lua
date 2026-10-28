-- Live test i4 (region2-site90 Trussroads y717-y719, 2026-10-28): BUG-153 the labor names of DF 53.16, BUG-154 a stalled
-- project paused by care first says so, BUG-156 the P1 mood features in a plan-less fort, BUG-158 the free tombs the
-- coffin provisioner counts and `inspect tombs` shows. Every test here fails on main (dec5132).
local T = require('testlib')
local F = require('wp8_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

---------------------------------------------------------------- BUG-153: df.unit_labor names of DF 53.16
-- df-structures 53.16 (df.unit_labor; live i4: 18 DIAGNOSE, 19 SURGERY, 20 BONE_SETTING, 21 SUTURING, 22 DRESSING_WOUNDS)
local LABORS = {}
for n in ([[MINE HAUL_STONE HAUL_WOOD HAUL_BODY HAUL_FOOD HAUL_REFUSE HAUL_ITEM HAUL_FURNITURE HAUL_ANIMALS CLEAN CUTWOOD
  CARPENTER DETAIL MASON ARCHITECT ANIMALTRAIN ANIMALCARE DIAGNOSE SURGERY BONE_SETTING SUTURING DRESSING_WOUNDS
  FEED_WATER_CIVILIANS RECOVER_WOUNDED BUTCHER TRAPPER DISSECT_VERMIN LEATHER TANNER BREWER ALCHEMIST SOAP_MAKER WEAVER
  CLOTHESMAKER MILLER PROCESS_PLANT MAKE_CHEESE MILK COOK PLANT HERBALIST FISH CLEAN_FISH DISSECT_FISH HUNT SMELT
  FORGE_WEAPON FORGE_ARMOR FORGE_FURNITURE METAL_CRAFT CUT_GEM ENCRUST_GEM WOOD_CRAFT STONE_CRAFT BONE_CARVE GLASSMAKER
  EXTRACT_STRAND SIEGECRAFT SIEGEOPERATE BOWYER MECHANIC POTASH_MAKING LYE_MAKING DYER BURN_WOOD OPERATE_PUMP SHEARER
  SPINNER POTTERY GLAZING PRESSING BEEKEEPING WAX_WORKING HANDLE_VEHICLES HAUL_TRADE PULL_LEVER REMOVE_CONSTRUCTION
  HAUL_WATER GELD BUILD_ROAD BUILD_CONSTRUCTION PAPERMAKING BOOKBINDING]]):gmatch('%S+') do LABORS[n] = true end

T.test('BUG-153: every labor name the kernel looks up in df.unit_labor exists in DF 53.16 (SUTURING, not SUTURE; the ' ..
       'slab engraver is DETAIL, there is no ENGRAVER labor)', function()
  local bad = {}
  local function chk(where, n) if not LABORS[n] then bad[#bad + 1] = where .. ':' .. tostring(n) end end
  local OL, W = fresh('orderlib'), fresh('water')
  for k, n in pairs(OL.WS_LABOR) do chk('orderlib.WS_LABOR.' .. k, n) end
  for k, n in pairs(OL.JOB_LABOR) do chk('orderlib.JOB_LABOR.' .. k, n) end
  for _, m in ipairs(W.MEDIC) do chk('water.MEDIC.' .. m[1], m[2][1]) end
  for k, n in pairs(W.MEDIC_LABOR) do chk('water.MEDIC_LABOR.' .. k, n) end
  for _, n in ipairs(fresh('care').MEDIC) do chk('care.MEDIC', n) end
  for _, n in ipairs(fresh('act').MEDIC_LABORS) do chk('act.MEDIC_LABORS', n) end
  local E = fresh('economy')
  for _, n in ipairs(E.MEDIC) do chk('economy.MEDIC', n) end
  for k, n in pairs(E.JOB_LABOR) do chk('economy.JOB_LABOR.' .. k, n) end
  for _, c in ipairs(E.COVER) do chk('economy.COVER.' .. c.key, c.labor) end
  table.sort(bad)
  T.eq(bad, {})
  T.eq(OL.labors('EngraveSlab', 'any', OL.workshops('EngraveSlab', 'any')), {'DETAIL'})
end)

---------------------------------------------------------------- BUG-156: P1 mood features in a plan-less fort
local function econ_world(opts)
  local units, ids = {}, {}
  for i = 1, opts.cit do units[i] = {id = i, citizen = true}; ids[i] = i end
  local persist = opts.plan and {plan = {v = 2, plan = {v = 2, year = 700, phase_target = 'P1'}, loaded = 1}} or nil
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, persist = persist}
  for i = 1, opts.cit do W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = opts.phase} end})
  F.workshop(W, 'Carpenters'); F.workshop(W, 'Masons')
  local E = fresh('economy')
  W.load(E)
  for _ = 1, 40 do W.run(1) end
  return W, E
end

T.test('BUG-156: a plan-less fort of offices.mood_ws_pop citizens that stays at P0 gets the P1 mood features (mood ' ..
       'shops, cloth floor, training): live i4 y717, pop 52, PLAN NONE, phase P0 had none of them', function()
  local W, E = econ_world{cit = 24, phase = 'P0'}
  T.eq(E.planless(W.K), true)
  local ms = E.mood_shops(W.K)
  T.ok(type(ms) == 'table' and #ms.missing == 10, 'the ten missing mood shops are known')
  T.eq(E.phase_ok(W.K, 'P1'), true)
  T.eq(E.phase_ok(W.K, 'P2'), false, 'only the P1 features: metal (P2) and glass (P3) wait for the phases')
  -- a small plan-less fort and a fort with an applied plan keep the phase gate
  local W2, E2 = econ_world{cit = 8, phase = 'P0'}
  T.eq(E2.mood_shops(W2.K), nil)
  local W3, E3 = econ_world{cit = 24, phase = 'P0', plan = true}
  T.eq(E3.planless(W3.K), false)
  T.eq(E3.mood_shops(W3.K), nil, 'an applied plan builds the shops by its phases')
end)

---------------------------------------------------------------- BUG-154: a stalled project paused by care first
local H = require('runner_world')
local runner = fresh('runner')
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function care_world(water)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = 'i4', map_size = {16, 16, 160}}
  W.ctl = {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}, water = water}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = W.ctl.stock} end})
  W.load({name = 'water', every = {ticks = 1200}, state = function()
    return {water = {patients = 0, thirst_max = 0, hosp_ok = 1, refuge_ok = 1, buckets_free = 10, hosp = 1, src = {},
                     hosp_out = water.hosp_out}}
  end})
  W.load(runner)
  W.state()
  return W
end

local function why(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r[4] end end
end

T.test('BUG-154: a stalled project that care first pauses says both (live i4: `BLOCKED:stalled` hid `paused: care`)', function()
  local W = care_world{hosp_out = 1}
  runner.CFG.active = 3
  H.place(W, 'bd1', H.dig_doc(2, {tpl = 'bedrooms', class = 'living', params = {n = 4}, x = 10, label = 'dig'}))
  H.place(W, 'ws1', H.doc{tpl = 'workshops', class = 'infra', x = 30, params = {}})
  H.runs(W, 1)
  H.place(W, 'hos', H.dig_doc(2, {tpl = 'hospital', class = 'living', params = {beds = 4}, x = 70, label = 'dig'}))
  H.runs(W, 1)
  T.eq(why(W, 'ws1'), 'paused: care hos')
  H.proj(W, 'ws1').blocked = 'stalled'
  H.runs(W, 1)
  T.eq(why(W, 'ws1'), 'stalled, paused: care hos')
  T.eq(why(W, 'hos'), '', 'the hospital itself runs')
end)

---------------------------------------------------------------- BUG-158: free tombs of the provisioner and the header
T.test('BUG-158: a zone care frees that DF re-gave last run is no free tomb for the coffin provisioner; inspect tombs ' ..
       'shows the header free in prov.free and the provisioner count in prov.free_run (live i4: 0 free vs prov.free 20)',
       function()
  local CW = require('care_world')
  local function dead(W, id) W.kill(id); W.event('UNIT_DEATH', {unit = id}) end
  local W = CW.world{cit = 8, setup = function(W)
    df.civzone_type.Bedroom, df.civzone_type[20] = 20, 'Bedroom'
    df.job_type.PlaceItemInTomb, df.job_type[90] = 90, 'PlaceItemInTomb'
    CW.tomb_acts(W)
    CW.tomb(W, 30, 10, 5, {unit = 3, closed = true})            -- zone 2: unit 3 died without a body here (stale)
    CW.tomb(W, 31, 10, 5)                                       -- zone 4: free
    dead(W, 3)
  end}
  local by_id = {}
  for _, z in ipairs(df.global.world.buildings.other.ZONE_TOMB) do by_id[z.id] = z end
  W.run(2)
  T.eq(CW.tacts(W, 'free'), {{'free', 2}})
  dead(W, 4)                                                  -- DF hands the freed zone to another bodiless dead
  by_id[2].assigned_unit_id, by_id[2].zone_settings.tomb.flags.no_citizens = 4, true
  W.ms = W.ms + 600000
  CW.day(W, 1)
  local r = W.inbox('inspect', {what = 'tombs'})
  T.ok(r.ok, r.msg)
  local prov = r.data.prov
  T.ok(prov ~= nil, 'the provisioner ran')
  T.eq(prov.regive, 1, 'one of this run\'s frees is the zone DF re-gave last run')
  T.eq(prov.free_run, r.data.free - 1)
  T.eq(prov.free, r.data.free, 'prov.free is the header\'s count')
  T.ok(r.msg:find(string.format('%d free', r.data.free), 1, true), r.msg)
end)

T.done()
