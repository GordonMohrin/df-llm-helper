-- BUG-727 (Run 16b i2 Whirledrampart y425: a Fey mood needed glass_green, 'Make raw glass: no sand', `trade.want add=["glass"]` was
-- 'ignored (no item type): glass'; 7 citizens died of failed moods): glass and rough gems are trade tokens, a raw-glass slot the fort's
-- glass chain cannot fill (no sand, no furnace) gets the early mood decision with trade.want glass.
local T = require('testlib')
local F = require('wp8_world')
local CW = require('care_world')
local kmock = require('dfllm.util.k_mock')
local R = require('dfllm.reserve')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function filter(t, spec)
  local f = {_t = t, mat_type = -1, mat_index = -1, quantity = 1, flags1 = {}, flags2 = {}, flags3 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end

local function item(W, cat, id, mi, flags, pos)
  local it = F.item(W, cat, {id = id, mat_type = 0, mat_index = mi, flags = flags or {}, _pos = pos or {10, 10, 5}})
  it.getSubtype = function() return -1 end
  it.getMaterial = function(self) return self.mat_type end
  it.getMaterialIndex = function(self) return self.mat_index end
  return it
end

local function moody(W, id, kind, filters)
  local u = W.unit(id)
  for _, f in ipairs(filters) do f.item_type = f._t and df.item_type[f._t] or -1 end
  u.mood = df.mood_type[kind]
  u.job.current_job = CW.mood_job(W, 900 + id, F.workshop(W, 'Craftsdwarfs'), filters, {})
  return u
end


local L = require('dfllm.trade').lib

T.test('BUG-727 trade: glass is a token (raw or cut glass by its description), rough gems stay `rough`', function()
  local tk = L.token('glass')
  T.ok(tk ~= nil and tk.types.ROUGH and tk.types.SMALLGEM and tk.word == 'glass', 'glass is a kind')
  T.eq(tk.cap, 6)
  T.ok(L.valid('glass'))
  T.ok(L.match(tk, {type = 'ROUGH', mat = 'glass_green', desc = 'green glass'}), 'raw green glass')
  T.ok(L.match(tk, {type = 'SMALLGEM', mat = 'glass_crystal', desc = 'cut crystal glass'}), 'cut crystal glass')
  T.ok(not L.match(tk, {type = 'ROUGH', mat = 'inorganic:amethyst', desc = 'rough amethyst'}), 'a rough gem is no glass')
  T.ok(not L.match(tk, {type = 'BAR', mat = 'inorganic:iron', desc = 'iron bars'}), 'no bar')
  T.ok(L.token('rough') and L.token('rough').types.ROUGH, 'rough gems have their token')
end)

T.test('BUG-727 reserve: the buy token of a raw glass need is glass, of a rough gem rough, of a cut gem gem', function()
  T.eq(R.token({cls = 'glass', tname = 'ROUGH'}), 'glass')
  T.eq(R.token({cls = 'gems', tname = 'ROUGH'}), 'rough')
  T.eq(R.token({cls = 'gems', tname = 'SMALLGEM'}), 'gem')
end)

T.test('BUG-727 care: a raw glass slot with no sand gets an early mood decision naming it and trade.want glass; the chain at work does not',
       function()
  local function run(stuck)
    local W = CW.world{census_i = {gems = 0, gems_cut = 0}, setup = function(W)
      moody(W, 1, 'Fey', {filter('ROUGH', {mat_type = 3})})
      W.unit(1).counters2 = {thirst_timer = 1000, hunger_timer = 0}
      W.load({name = 'economy', every = {ticks = 1200}, mood_hint = function() return nil end,
              glass_stuck = function() return stuck, stuck and 'no sand revealed: raw glass cannot be made here' or nil end})
    end}
    W.run(6)
    local ds = {}
    for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'mood_deadline' and e.d.early == 1 then ds[#ds + 1] = e end end
    return ds
  end
  local ds = run(true)
  T.eq(#ds, 1, 'one early decision at the first report')
  T.ok(ds[1].d.q:find('raw glass: no sand revealed', 1, true), ds[1].d.q)
  local joined = table.concat(ds[1].d.cmds, ' ')
  T.ok(joined:find('trade.want', 1, true) and joined:find('"glass"', 1, true), joined)
  for _, c in ipairs(ds[1].d.cmds) do T.ok(#c < 200, c) end
  T.eq(#run(false), 0, 'sand and a furnace: economy makes it, no early decision')
end)

T.done()
