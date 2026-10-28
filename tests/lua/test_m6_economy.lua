-- Package M6 (Run 14 notes 75, 80, 83, 92): economy.mood_shops (BUG-117), the cloth floor (BUG-117).
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local function econ_world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, opts.cit or 8 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = opts.cfg or F.cfg()}, units = units}
  local ids = {}
  for i = 1, opts.cit or 8 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = opts.phase} end})
  if opts.setup then opts.setup(W) end
  local E = fresh('economy')
  W.load(E)
  settle(W)                                                      -- the runner's state reaches K.view()
  return W, E
end

local function sorted(l) table.sort(l); return l end

T.test('BUG-117: economy.mood_shops lists the moodable types no built workshop covers; a magma forge / magma glass furnace stand ' ..
       'for the plain ones; nil before mood_from_phase', function()
  local W, E = econ_world{phase = 'P1', setup = function(W)
    F.workshop(W, 'Carpenters'); F.workshop(W, 'Masons'); F.workshop(W, 'Craftsdwarfs')
    F.workshop(W, 'MagmaForge')                                 -- a mood claims it like the forge
    F.workshop(W, 'Loom'); F.workshop(W, 'Farmers')             -- a farmer's shop is no mood shop
    F.workshop(W, 'MagmaGlassFurnace', true)
    local half = F.workshop(W, 'Jewelers')
    half.getBuildStage = function() return 1 end                 -- still being built: not a shop yet
    half.getMaxBuildStage = function() return 3 end
  end}
  local ms = E.mood_shops(W.K)
  T.eq(sorted(ms.missing), {'Bowyers', 'Clothiers', 'Jewelers', 'Leatherworks', 'Mechanics', 'Tanners'})
  T.eq(ms.queued, {})
  local W0, E0 = econ_world{phase = 'P0'}
  T.eq(E0.mood_shops(W0.K), nil, 'before mood_from_phase the plan builds the shops itself')
  local W1, E1 = econ_world{phase = nil}
  T.eq(E1.mood_shops(W1.K), nil, 'no phase known: no answer')
end)

T.test('BUG-117: a pending workshops project that lists a missing type is named in queued', function()
  local W, E = econ_world{phase = 'P2', setup = function(W)
    for _, t in ipairs({'Carpenters', 'Masons', 'Craftsdwarfs', 'Jewelers', 'MetalsmithsForge', 'Bowyers', 'Clothiers',
                        'Leatherworks', 'Loom', 'Mechanics'}) do F.workshop(W, t) end
    F.workshop(W, 'GlassFurnace', true)
  end}
  local pd = W.K.persist.get('projects') or {v = 2, list = {}}
  pd.list[#pd.list + 1] = {id = 'c1a147c261d9', tpl = 'workshops', site = 'S1', class = 'infra', prio = 1, stage = 1, chunk = 0,
                           pct = 40, blocked = '', since = 0, created = 0, done = 0}
  W.K.persist.set('projects', pd)
  W.K.persist.set('bp.c1a147c261d9', {v = 2, tpl = 'workshops', manifest = {v = 2, workshops = {{type = 'Tanners', pos = {1, 1, 1}}}}})
  local ms = E.mood_shops(W.K)
  T.eq(ms.missing, {'Tanners'})
  T.eq({ms.queued.Tanners.id, ms.queued.Tanners.pct}, {'c1a147c261d9', 40})
end)

T.test('BUG-117: the 12 moodable types of economy, runner and the blueprint library agree', function()
  local E, R = fresh('economy'), fresh('runner')
  T.eq(E.MOOD_SHOPS, R.MOODABLE)
end)

T.done()
