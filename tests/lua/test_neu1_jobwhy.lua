-- NEU1 P8 (docs/v2/NEU1-jobfrage.md): "why is this job not running" read off the game (lua/dfllm/jobwhy.lua), the
-- inspect verb (economy `inspect what=why`) and the stall events that carry its cause (brew_watch, fish_watch).
-- Brew and fish stalls were "fixed" several times on guesses (BUG-716 'slower than the catch', BUG-767 'DF did not
-- assign it (path or burrow?)'); these worlds give each real blocker once and check that it, and only it, is named.
-- The fake fields used here follow DF 53 (names checked against hack/dfhack.dll strings, shapes against the DFHack scripts
-- under hack/scripts and this repo's own readers): workshop_profile permitted_workers / min_level / max_level /
-- max_general_orders / blocked_labors, burrow flags.limit_workshops, job.job_items as a job_item_vector struct with its
-- list in `.elements` (BUG-817: the first fakes used a flat vector, a shape the game does not have), job.items
-- (job_item_idx), job_item item_type / vector_id / flags1.empty / flags1.unrotten / has_material_reaction_product,
-- manager_order status.validated / workshop_id / item_conditions, job.order_id.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200
local BREWING, PROCESSFISH = 60, 61
local BREWER, CLEAN_FISH = 6, 7

-- o: n citizens (default 4), brewers = ids holding Brewing, groups = {[x] = walk group} by unit x (default 1), plants, barrels
local function world(o)
  o = o or {}
  local units, ids = {}, {}
  for i = 1, o.n or 4 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}}; ids[i] = i end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  df.unit_labor = {BREWER = BREWER, [BREWER] = 'BREWER', CLEAN_FISH = CLEAN_FISH, [CLEAN_FISH] = 'CLEAN_FISH'}
  df.job_skill.BREWING, df.job_skill[BREWING] = BREWING, 'BREWING'
  df.job_skill.PROCESSFISH, df.job_skill[PROCESSFISH] = PROCESSFISH, 'PROCESSFISH'
  df.job_skill.attrs = {[BREWING] = {labor = BREWER}, [PROCESSFISH] = {labor = CLEAN_FISH}}
  if df.job_type.PrepareRawFish == nil then df.job_type.PrepareRawFish = 80; df.job_type[80] = 'PrepareRawFish' end
  if df.job_type.Drink == nil then df.job_type.Drink = 81; df.job_type[81] = 'Drink' end
  df.job_type.attrs = setmetatable({[df.job_type.PrepareRawFish] = {labor = -1, skill = PROCESSFISH}},
                                   {__index = function() return {labor = -1, skill = -1} end})
  df.items_other_id = kmock.enum({'IN_PLAY', 'PLANT', 'BARREL', 'FISH_RAW', 'FOOD_STORAGE'})
  rawset(df.global.world.items.other, 'FOOD_STORAGE', kmock.vec{})
  df.global.world.raws.reactions = {reactions = kmock.vec{
    {code = 'BREW_DRINK_FROM_PLANT', skill = BREWING,
     building = {type = kmock.vec{df.building_type.Workshop}, subtype = kmock.vec{df.workshop_type.Still}}}}}
  dfhack.job.getWorker = function(j) return j._worker end
  dfhack.job.isSuitableItem = function() return true end
  dfhack.job.isSuitableMaterial = function() return true end
  dfhack.units.isJobAvailable = function(u) return u._m.avail ~= false end
  dfhack.units.getNominalSkill = function(u, id) return (u._m.skills or {})[id] or 0 end
  local groups = o.groups or {}
  -- snapshot's walk groups (the map reads are snapshot's): group by x, 1 by default
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, plot_under = function() return true end,
          groups = function(_K, pts)
            local out = {}
            for i, p in ipairs(pts) do out[i] = groups[p.x or p[1]] or 1 end
            return out
          end})
  for i = 1, o.n or 4 do
    local u = W.unit(i)
    u.job, u.mood = {current_job = nil}, -1
    u.status.labors = {}
    u.burrows = kmock.vec{}
  end
  for _, id in ipairs(o.brewers or {1}) do W.unit(id).status.labors[BREWER] = true end
  W.set_census('u', F.census_u(ids))
  F.mat(W, 419, 1, {token = 'PLANT:WHEAT:STRUCTURAL', products = {'DRINK_MAT'}})
  F.mat(W, 419, 2, {token = 'PLANT:ROCK:STRUCTURAL'})
  return W
end

local function still(W, o)
  o = o or {}
  local b = F.workshop(W, 'Still')
  b.x1, b.y1, b.x2, b.y2, b.z = 20, 20, 22, 22, 100
  b.centerx, b.centery = 21, 21
  b.profile = o.profile or {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  b.jobs = kmock.vec{}
  return b
end

local BREW_ITEMS = function()                   -- DF 53: job.job_items is a job_item_vector struct, the list in .elements
  return {elements = kmock.vec{
    {item_type = df.item_type.PLANT, item_subtype = -1, mat_type = -1, mat_index = -1, quantity = 1, vector_id = -1,
     flags1 = {unrotten = true}, has_material_reaction_product = 'DRINK_MAT', reaction_class = ''},
    {item_type = -1, item_subtype = -1, mat_type = -1, mat_index = -1, quantity = 1, vector_id = df.items_other_id.FOOD_STORAGE,
     flags1 = {empty = true}, has_material_reaction_product = '', reaction_class = ''}}}
end

local function brew_job(W, b, o)
  o = o or {}
  local j = {id = 700 + #b.jobs, job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT',
             mat_type = -1, mat_index = -1, flags = {suspend = o.susp == true}, _worker = o.worker, _holder = b,
             order_id = o.order or -1, job_items = BREW_ITEMS(), items = kmock.vec{}}
  b.jobs:insert('#', j)
  return j
end

local function plant(W, o)
  o = o or {}
  return F.item(W, 'PLANT', {mat_type = 419, mat_index = o.mi or 1, flags = o.flags or {}, _pos = o.pos or {12, 12, 100},
                             getSubtype = function() return -1 end, getMaterial = function(it) return it.mat_type end,
                             getMaterialIndex = function(it) return it.mat_index end})
end
local function barrel(W, o)
  o = o or {}
  local it = F.item(W, 'BARREL', {flags = o.flags or {}, _pos = {13, 13, 100}, _contents = o.full and {{id = 1}} or {},
                                  getSubtype = function() return -1 end, getMaterial = function() return 420 end,
                                  getMaterialIndex = function() return 0 end})
  df.global.world.items.other.FOOD_STORAGE:insert('#', it)
  return it
end

local JW = fresh('jobwhy')
local function ask(W, key, ctx) return JW.find(W.K, key, ctx or {}) end

T.test('NEU1 P8: an untaken brew job whose only brewers stand in burrows without the Still is named burrow, not "path or burrow?"', function()
  local W = world{brewers = {1, 2, 3, 4}}
  local b = still(W)
  brew_job(W, b)
  plant(W); barrel(W)
  local bx = W.burrow('Farm', {0, 0, 100, 15, 15, 100})
  W.unit(1).burrows = kmock.vec{bx.id}
  for _, id in ipairs({2, 3, 4}) do W.unit(id).job = {current_job = {id = 9, job_type = df.job_type.Drink}} end
  local r = ask(W, 'ws:' .. b.id)
  T.eq(r.cause, 'busy', 'three of four holders are busy, one kept out: busy (they come free)')
  T.ok(r.text:find('1 kept out by burrows', 1, true), 'the text names the burrow too: ' .. r.text)
  W.unit(2).burrows = kmock.vec{bx.id}
  W.unit(2).job = {current_job = nil}
  r = ask(W, 'ws:' .. b.id)
  T.eq(r.cause, 'burrow', 'half the holders kept out by burrows outranks the busy ones: ' .. r.text)
  T.ok(r.text:find('2 busy', 1, true), r.text)
  for _, id in ipairs({3, 4}) do W.unit(id).status.labors[BREWER] = nil end
  r = ask(W, 'brew')
  T.eq(r.cause, 'burrow', r.text)
  T.ok(r.text:find('2 BREWER holders: 2 kept out by burrows', 1, true), r.text)
  T.eq(r.workers.by.burrow, 2)
end)

T.test('NEU1 P8: the civ alert and a workshop-limiting burrow keep holders out; a free holder in another walk group is far', function()
  local W = world{brewers = {1}}
  local b = still(W)
  brew_job(W, b)
  plant(W); barrel(W)
  local hide = W.burrow('Hide', {0, 0, 100, 15, 15, 100})
  df.global.plotinfo.alerts = {civ_alert_idx = 1, list = kmock.vec{{burrows = kmock.vec{}}, {burrows = kmock.vec{hide.id}}}}
  T.eq(ask(W, 'brew').cause, 'burrow', 'the civ alert holds the brewer in Hide')
  df.global.plotinfo.alerts.civ_alert_idx = 0
  local lim = W.burrow('Brewery', {19, 19, 100, 23, 23, 100})
  lim.flags = {limit_workshops = true}
  local r = ask(W, 'brew')
  T.eq(r.cause, 'burrow', 'the Still lies in a workshop-limiting burrow he is no member of')
  T.ok(r.text:find('workshop-limiting burrow', 1, true), r.text)
  W.unit(1).burrows = kmock.vec{lim.id}
  T.eq(ask(W, 'brew').cause, 'input_burrow', 'a member works there, but the plant lies outside his burrow')
  lim.flags.limit_workshops = false
  W.unit(1).burrows = kmock.vec{}
  local W3 = world{brewers = {1}, groups = {[11] = 5}}
  local b3 = still(W3)
  brew_job(W3, b3)
  plant(W3); barrel(W3)
  local r3 = ask(W3, 'brew')
  T.eq(r3.cause, 'far', r3.text)
  W3.mods.snapshot.M.groups = function() error('no map') end
  T.eq(ask(W3, 'brew').cause, 'unknown', 'fail closed: no walk groups, no far verdict')
end)

T.test('NEU1 P8: nobody holds the labor, the profile shuts the holders out, a mood, or the brewer is not looking for work', function()
  local W = world{brewers = {}}
  local b = still(W)
  brew_job(W, b)
  plant(W); barrel(W)
  local r = ask(W, 'brew')
  T.eq(r.cause, 'no_labor')
  T.ok(r.text:find('nobody holds the BREWER labor', 1, true), r.text)
  W.unit(2).status.labors[BREWER] = true
  b.profile.permitted_workers = kmock.vec{4}
  r = ask(W, 'brew')
  T.eq(r.cause, 'profile', r.text)
  T.ok(r.text:find('not on the permitted list', 1, true), r.text)
  b.profile.permitted_workers = kmock.vec{}
  b.profile.min_level = 5
  W.unit(2)._m.skills = {[BREWING] = 2}
  T.eq(ask(W, 'brew').cause, 'profile', 'skill 2 below the window 5-3000')
  b.profile.min_level = 0
  W.unit(2).mood = 1
  T.eq(ask(W, 'brew').cause, 'mood')
  W.unit(2).mood = -1
  W.unit(2)._m.avail = false
  T.eq(ask(W, 'brew').cause, 'busy', 'not looking for work counts with the busy')
end)

T.test('NEU1 P8: a free brewer reaches the Still: the missing inputs are named (no plant, forbidden plants, no empty barrel, no DRINK_MAT)', function()
  local W = world{brewers = {1}}
  local b = still(W)
  brew_job(W, b)
  barrel(W)
  local r = ask(W, 'brew')
  T.eq(r.cause, 'no_input', r.text)
  T.ok(r.text:find('plant (DRINK_MAT) x1: 0 match', 1, true), r.text)
  local p = plant(W, {flags = {forbid = true}})
  r = ask(W, 'brew')
  T.eq(r.cause, 'input_forbidden', r.text)
  p.flags.forbid = false
  p.flags.rotten = true
  -- NEU16 BUG-915: items of the type exist but none fits: 'scan unverified', never no_input from the scan alone
  r = ask(W, 'brew')
  T.eq(r.cause, 'scan_unreliable', 'a rotten plant does not count (flags1.unrotten), but the scan is no proof: ' .. r.text)
  T.ok(r.text:find('scan unverified (1 items of that type exist', 1, true), r.text)
  T.ok(not r.text:find('0 match', 1, true), r.text)
  p.flags.rotten = false
  p.mat_index = 2
  T.eq(ask(W, 'brew').cause, 'scan_unreliable', 'a plant without the DRINK_MAT product does not count: unverified')
  p.mat_index = 1
  T.eq(ask(W, 'brew').cause, 'unknown', 'plant and barrel free: nothing named')
  df.global.world.items.other.FOOD_STORAGE[0]._contents = {{id = 1}}
  r = ask(W, 'brew')
  T.eq(r.cause, 'no_container', r.text)
  T.ok(r.text:find('empty food_storage', 1, true), r.text)
  df.global.world.items.other.FOOD_STORAGE[0]._contents = {}
  df.global.world.items.other.FOOD_STORAGE[0].flags.in_job = true
  T.eq(ask(W, 'brew').cause, 'input_claimed')
  local W2 = world{brewers = {1}, groups = {[12] = 4}}
  local b2 = still(W2)
  brew_job(W2, b2)
  plant(W2); barrel(W2)
  T.eq(ask(W2, 'brew').cause, 'input_far', 'the only plant lies on another walk group')
end)

T.test('NEU1 P8: a brewer held to a burrow with the Still in it, the only free plant outside it: input_burrow', function()
  local W = world{brewers = {1}}
  local b = still(W)
  brew_job(W, b)
  plant(W, {pos = {40, 40, 100}})
  barrel(W)
  df.global.world.items.other.FOOD_STORAGE[0]._pos = {21, 22, 100}
  local bw = W.burrow('Brewery', {10, 10, 100, 25, 25, 100})
  W.unit(1).burrows = kmock.vec{bw.id}
  local r = ask(W, 'brew')
  T.eq(r.cause, 'input_burrow', r.text)
  T.ok(r.text:find('0 inside the free holders burrows', 1, true), r.text)
  T.eq(JW.data(r).inputs[1]._pts, nil, 'positions stay inside')
  W.unit(1).burrows = kmock.vec{}
  T.eq(ask(W, 'brew').cause, 'unknown', 'a brewer who may go anywhere fetches it')
end)

T.test('NEU1 P8: a worked job is working; a suspended job is said so; an item the job already holds is not asked again', function()
  local W = world{brewers = {1}}
  local b = still(W)
  local j = brew_job(W, b, {worker = W.unit(1)})
  T.eq(ask(W, 'job:' .. j.id).cause, 'working')
  j._worker = nil
  j.flags.suspend = true
  T.eq(ask(W, 'job:' .. j.id).cause, 'suspended')
  j.flags.suspend = false
  plant(W)
  j.items = kmock.vec{{job_item_idx = 1}}        -- the barrel is fetched
  T.eq(ask(W, 'job:' .. j.id).cause, 'unknown', 'only the plant was asked and it lies free')
end)

T.test('NEU1 P8: an order: unvalidated (no manager / his first cause), pinned, no workshop, closed profile, full shops, conditions, its job', function()
  local W = world{brewers = {1}}
  local o = F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = 5, amount_total = 5,
                        mat_type = -1, mat_index = -1, workshop_id = -1, item_conditions = kmock.vec{}, status = {validated = false}})
  local key = 'order:' .. o.id
  T.eq(ask(W, key, {manager = function() return {causes = {'no MANAGER post is open'}} end}).cause, 'no_manager')
  local r = ask(W, key, {manager = function() return {unit = 5, causes = {'office 12 has no chair'}} end})
  T.eq(r.cause, 'not_validated')
  T.ok(r.text:find('office 12 has no chair', 1, true), r.text)
  o.status.validated = true
  T.eq(ask(W, key).cause, 'no_workshop')
  T.ok(ask(W, key).text:find('workshop:Still', 1, true))
  o.workshop_id = 999
  T.eq(ask(W, key).cause, 'pinned')
  o.workshop_id = -1
  local b = still(W)
  b.profile.max_general_orders = 0
  T.eq(ask(W, key).cause, 'profile_orders')
  b.profile.max_general_orders = 10
  for _ = 1, 10 do brew_job(W, b, {worker = W.unit(2)}) end
  T.eq(ask(W, key).cause, 'shop_full')
  b.jobs = kmock.vec{}
  o.item_conditions = kmock.vec{{}, {}}
  T.eq(ask(W, key).cause, 'conditions')
  o.item_conditions = kmock.vec{}
  T.eq(ask(W, key).cause, 'unknown')
  brew_job(W, b, {order = o.id})
  barrel(W)
  r = ask(W, key)
  T.eq(r.cause, 'no_input', 'the order\'s own job lacks its plant')
  T.eq(r.sub.kind, 'job')
  o.amount_left = 0
  T.eq(ask(W, key).cause, 'done')
end)

T.test('NEU1 P8: keys: a bare id is an order, then a workshop, then a job; unknown keys and kinds are refused; a kind with nothing open says so', function()
  local W = world{brewers = {1}}
  local b = still(W)
  local j = brew_job(W, b)
  local r = ask(W, tostring(b.id))
  T.eq({r.kind, r.guess}, {'shop', 'shop'})
  r = ask(W, tostring(j.id))
  T.eq({r.kind, r.guess}, {'job', 'job'})
  T.eq(select(2, ask(W, 'ws:4242')), 'no workshop or furnace 4242')
  T.eq(select(2, ask(W, 'bogus')), 'unknown kind bogus')
  T.eq(ask(W, 'fish').cause, 'none_open')
  T.eq(ask(W, 'ConstructBed').cause, 'none_open', 'a job type name is a kind')
  T.ok(JW.line(r):find('^job %d+ BREW_DRINK_FROM_PLANT at 21,21,100: '), JW.line(r))
  T.eq(JW.data(r).kind, 'job')
end)

T.test('NEU1 P8 BUG-817: job_items unreadable (absent, erroring, a struct without its list): the cause stays unknown, no free-input claim', function()
  local W = world{brewers = {1}}
  local b = still(W)
  local j = brew_job(W, b)
  T.eq(ask(W, 'job:' .. j.id).cause, 'no_input', 'the .elements list is read: no plant, no barrel')
  T.eq(#JW.job_items(j), 2)
  for _, case in ipairs({'absent', 'erroring', 'struct'}) do
    if case == 'absent' then j.job_items = nil
    elseif case == 'erroring' then j.job_items = setmetatable({}, {__index = function() error('no field') end})
    else j.job_items = setmetatable({flags = {}}, {__index = function(_, k) error('Cannot read field job_item_vector.' .. tostring(k)) end}) end
    T.eq(JW.job_items(j), nil, case .. ': no list')
    local r = ask(W, 'job:' .. j.id)
    T.eq(r.cause, 'unknown', case .. ': ' .. r.text)
    T.ok(r.text:find('its inputs not read', 1, true), r.text)
    T.ok(not r.text:find('lie free', 1, true), case .. ': no claim on unread inputs: ' .. r.text)
    T.eq(r.inputs, nil)
  end
  j.job_items = kmock.vec{}                        -- an old build: the vector itself (act.lua reads it so too)
  T.eq(#JW.job_items(j), 0)
end)

-- economy: the inspect verb and the stall watches
local function econ_world(o)
  local W = world(o)
  F.item(W, 'DRINK', {stack_size = 20000})
  W.load(fresh('economy'))
  return W
end

T.test('NEU1 P8: inspect what=why answers through economy (msg = the line, data = the record)', function()
  local W = econ_world{brewers = {}}
  local b = still(W)
  brew_job(W, b)
  local econ = require('dfllm.economy')
  local ok, msg, data = econ.inspect.why(W.K, {key = 'brew'})
  T.ok(ok, msg)
  T.ok(msg:find('no_labor: nobody holds the BREWER labor', 1, true), msg)
  T.eq(data.cause, 'no_labor')
  local ok2, msg2 = econ.inspect.why(W.K, {key = 'job:99999'})
  T.eq({ok2, msg2}, {false, 'no job 99999'})
end)

local function brew_stall(W, n, cfg)
  local econ = require('dfllm.economy')
  local p = W.K.persist.get('m.economy')
  p.orders = p.orders or {}
  local c = cfg or W.K.cfg.baseline.economy
  for i = 1, n do
    econ.brew_watch(W.K, c, {day = true, now = (100 + i) * DAYT, p = p, inv = {brew_p = 50, barrels_empty = 3}, days = {drink_d = 40}, cit = 4})
  end
  local out = {}
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do if tostring(e.msg):find('brewing stalled', 1, true) then out[#out + 1] = e end end
  return out
end

T.test('NEU1 P8: a brew stall whose old cause was the guess "path or burrow?" carries the real cause; switch off = the old text', function()
  local function make()
    local W = econ_world{brewers = {1, 2}}
    local b = still(W)
    brew_job(W, b)
    plant(W); barrel(W)
    F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = 5, amount_total = 5,
                mat_type = -1, mat_index = -1, workshop_id = -1, item_conditions = kmock.vec{}, status = {validated = true}})
    local bx = W.burrow('Farm', {0, 0, 100, 15, 15, 100})
    for _, id in ipairs({1, 2}) do W.unit(id).burrows = kmock.vec{bx.id} end
    return W
  end
  local W = make()
  local ev = brew_stall(W, 8)
  T.eq(#ev, 1)
  T.eq(ev[1].d.cause, 'burrow')
  T.ok(ev[1].msg:find('burrow: 2 BREWER holders: 2 kept out by burrows', 1, true), ev[1].msg)
  T.ok(not ev[1].msg:find('path or burrow?', 1, true), 'the guess is gone')
  local found = false
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('jobwhy brew: job', 1, true) then found = true end end
  T.ok(found, 'kern.log carries the whole query line')
  local W2 = make()
  local c = {}
  for k, v in pairs(W2.K.cfg.baseline.economy) do c[k] = v end
  c.jobwhy = {stall = false, items_max = 4000}
  local ev2 = brew_stall(W2, 8, c)
  T.eq(#ev2, 1)
  T.eq(ev2[1].d.cause, nil, 'switched off: no cause')
  T.ok(ev2[1].msg:find('nobody works; idle brewers', 1, true), ev2[1].msg)
end)

T.test('NEU1 P8: a fish stall with a holder carries the real cause instead of "the fishery is slower than the catch"', function()
  local W = econ_world{brewers = {}}
  local fy = F.workshop(W, 'Fishery')
  fy.x1, fy.y1, fy.x2, fy.y2, fy.z = 30, 30, 32, 32, 100
  fy.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  fy.jobs = kmock.vec{{id = 801, job_type = df.job_type.PrepareRawFish, mat_type = -1, mat_index = -1, flags = {}, _holder = fy,
                       job_items = {elements = kmock.vec{}}, items = kmock.vec{}}}
  W.unit(2).status.labors[CLEAN_FISH] = true
  W.unit(2)._m.avail = false
  local econ = require('dfllm.economy')
  local p = W.K.persist.get('m.economy')
  p.orders = p.orders or {}
  local o = F.order(W, {job_type = df.job_type.PrepareRawFish, amount_left = 4, amount_total = 4, mat_type = -1, mat_index = -1,
                        workshop_id = -1, item_conditions = kmock.vec{}, status = {validated = true}})
  p.orders['dfllm:fish'] = o.id
  p.fishw = {base = 120, d = 9, day = 100}
  econ.fish_watch(W.K, W.K.cfg.baseline.economy, {day = true, now = 101 * DAYT, p = p, inv = {fish_raw = 120}, f = {['workshop:Fishery'] = true}})
  local ev = {}
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do if tostring(e.msg):find('raw fish not cleaned', 1, true) then ev[#ev + 1] = e end end
  T.eq(#ev, 1)
  T.eq(ev[1].d.cause, 'busy')
  T.ok(ev[1].d.why:find('fish stall: busy: 1 CLEAN_FISH holder: 1 not looking for work', 1, true), ev[1].d.why)
  T.ok(not ev[1].msg:find('slower than the catch', 1, true), ev[1].msg)
end)

T.test('NEU1 P8 BUG-818: a "nojob" brew stall (the guess "DF counts items its own way") carries the order-level cause read before the cure', function()
  local W = econ_world{brewers = {1}}
  still(W)
  plant(W); barrel(W)
  W.act_result('order_remove', function(id)
    local all = df.global.world.manager_orders.all
    for i = #all - 1, 0, -1 do if all[i].id == id then all:erase(i); return true, 'removed' end end
    return false, 'no order'
  end)
  local o = F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = 5, amount_total = 5,
                        mat_type = -1, mat_index = -1, workshop_id = -1, item_conditions = kmock.vec{{}, {}}, status = {validated = true}})
  local p = W.K.persist.get('m.economy')
  p.orders = p.orders or {}
  p.orders['dfllm:drink'] = o.id
  local ev = brew_stall(W, 8)
  T.eq(#ev, 1)
  T.ok(ev[1].msg:find('the manager gave no Still a job', 1, true), 'the old cause is nojob: ' .. ev[1].msg)
  local cured = false
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('1 brew order taken down', 1, true) then cured = true end end
  T.ok(cured, 'the cure still runs')
  T.eq(ev[1].d.cause, 'conditions', 'the query saw the order before it was taken down (not none_open)')
  T.eq(#df.global.world.manager_orders.all, 0, 'the order is gone after the cure')
  local found = false
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('jobwhy brew: order ' .. o.id, 1, true) then found = true end end
  T.ok(found, 'kern.log carries the order-level query line')
end)

-- NEU16 BUG-915 (BUG-836 / 868 / 896: '0 match' for every job item with an item_type): the scan walks the vector of the item's TYPE, not the one job_item.vector_id decodes
-- to (items_other_id vs job_item_vector_id are not proven the same enum); a typed scan that finds none although items of the type exist says 'scan unverified'
local function wood_job(W, b, ji)
  local j = {id = 880, job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', mat_type = -1, mat_index = -1, flags = {},
             _holder = b, order_id = -1, items = kmock.vec{}, job_items = {elements = kmock.vec{ji}}}
  b.jobs:insert('#', j)
  return j
end
local function wood(W, n, o)
  o = o or {}
  for _ = 1, n do
    F.item(W, 'WOOD', {mat_type = 420, flags = o.flags or {}, _pos = o.pos or {12, 12, 100}, getSubtype = function() return -1 end,
                       getMaterial = function() return 420 end, getMaterialIndex = function() return 0 end})
  end
end
T.test('NEU16 BUG-915: a WOOD job item whose vector_id decodes to ANOTHER vector (FISH_RAW) still scans the WOOD vector: 5 free logs match; the mismatch is printed', function()
  local W = world{brewers = {1}}
  local b = still(W)
  wood_job(W, b, {item_type = df.item_type.WOOD, item_subtype = -1, mat_type = -1, mat_index = -1, quantity = 1, vector_id = df.items_other_id.FISH_RAW,
                  flags1 = {}, has_material_reaction_product = '', reaction_class = ''})
  wood(W, 5)
  local r = ask(W, 'job:880')
  local e = r.inputs[1]
  T.eq({e.match, e.free, e.vec, e.vec_mismatch}, {5, 5, 'type', 'FISH_RAW'}, require('testlib').show(e))
  T.ok(not e.unverified)
  T.ok(r.cause ~= 'no_input' and r.cause ~= 'scan_unreliable', 'logs lie free: ' .. tostring(r.cause) .. ' / ' .. r.text)
end)

T.test('NEU16 BUG-915: items of the type exist but none fits the filter: "scan unverified (N items of that type exist, K near)", cause scan_unreliable, never no_input / "0 match"', function()
  local W = world{brewers = {1}, groups = {[200] = 7}}
  local b = still(W)
  wood_job(W, b, {item_type = df.item_type.WOOD, item_subtype = -1, mat_type = 999, mat_index = -1, quantity = 1, vector_id = 18,
                  flags1 = {}, has_material_reaction_product = '', reaction_class = ''})
  wood(W, 4)
  wood(W, 3, {pos = {200, 5, 100}})                                  -- another walk group
  local r = ask(W, 'job:880')
  local e = r.inputs[1]
  T.ok(e.unverified, 'unverified')
  T.eq({e.ntype, e.tnear}, {7, 4})
  T.eq(r.cause, 'scan_unreliable', r.text)
  T.ok(r.text:find('scan unverified (7 items of that type exist, 4 near)', 1, true), r.text)
  T.ok(not r.text:find('0 match', 1, true) and not r.text:find('none:', 1, true), r.text)
  -- DF's own reason leads: with a cancel on record the cause becomes df_reason with its words first
  local r2 = JW.find(W.K, 'job:880', {df = function() return {why = 'Needs logs', n = 5, days = 7, last = 1, text = 'DF cancelled Make wooden barrel 5x in 7 d: Needs logs'} end})
  T.eq(r2.cause, 'df_reason')
  T.ok(r2.text:find('DF cancelled Make wooden barrel 5x in 7 d: Needs logs |', 1, true), r2.text)
end)

T.test('NEU16 BUG-915: no item of the type exists at all: the old "0 match" and no_input stay (a proof, not a scan artifact)', function()
  local W = world{brewers = {1}}
  local b = still(W)
  wood_job(W, b, {item_type = df.item_type.WOOD, item_subtype = -1, mat_type = -1, mat_index = -1, quantity = 1, vector_id = 18,
                  flags1 = {}, has_material_reaction_product = '', reaction_class = ''})
  local r = ask(W, 'job:880')
  T.eq(r.cause, 'no_input', r.text)
  T.ok(r.text:find('wood x1: 0 match', 1, true), r.text)
end)

T.test('NEU1 P8: the fish stall asks before the labor cure: the cause is the state before the cure sets the labor', function()
  local W = econ_world{brewers = {}}
  local fy = F.workshop(W, 'Fishery')
  fy.x1, fy.y1, fy.x2, fy.y2, fy.z = 30, 30, 32, 32, 100
  fy.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  fy.jobs = kmock.vec{{id = 802, job_type = df.job_type.PrepareRawFish, mat_type = -1, mat_index = -1, flags = {}, _holder = fy,
                       job_items = {elements = kmock.vec{}}, items = kmock.vec{}}}
  local econ = require('dfllm.economy')
  local set, old = {}, econ.fish_labor
  econ.fish_labor = function() W.unit(1).status.labors[CLEAN_FISH] = true; set[#set + 1] = 1; return 'set', 1 end
  local p = W.K.persist.get('m.economy')
  p.orders = p.orders or {}
  p.fishw = {base = 120, d = 9, day = 100}
  econ.fish_watch(W.K, W.K.cfg.baseline.economy, {day = true, now = 101 * DAYT, p = p, inv = {fish_raw = 120}, f = {['workshop:Fishery'] = true}})
  econ.fish_labor = old
  local ev = {}
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do if tostring(e.msg):find('raw fish not cleaned', 1, true) then ev[#ev + 1] = e end end
  T.eq(#ev, 1)
  T.eq(#set, 1, 'the labor cure ran')
  T.eq(ev[1].d.cause, 'no_labor', 'the cause is the state before the cure')
end)

T.done()
