-- NEU14 BUG-896 (Run 17d i4 Girderroots y448-y460: 'why ConstructCoffin: boulder x1: 0 match, 0 free' beside 'why items:BOULDER: no exclusion (free as DF sees it): 53' and ORDER_STUCK
-- '26 free boulders': nothing said which of the 53 are hard non-economic stone, the only ones a mason's filter takes; `why items:DOOR` was no key players knew):
-- `why items:BOULDER --raw` names the material of every sample and says whether a mason's filter (flags2 non_economic, flags3 hard) takes it, with the counts 'N free, of them M hard
-- non-economic'; the mason job's input text and ORDER_STUCK's stale reason say '0 of 53 free boulders are hard non-economic stone'; `items:door` / `items:DOOR` and the other
-- furniture vectors are keys.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200

local function world(setup)
  local units, ids = {}, {}
  for i = 1, 4 do units[i] = {id = i, citizen = true}; ids[i] = i end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  W.set_census('u', F.census_u(ids))
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.', shape = 'FLOOR', mat = 'STONE'} end,
          groups = function(_, pts) local g = {}; for i = 1, #pts do g[i] = 1 end; return g end,
          hidden = function(_, pts) local g = {}; for i = 1, #pts do g[i] = false end; return g end,
          far = function() return false end})
  F.mat(W, 0, 7, {token = 'INORGANIC:GRANITE', flags = {ITEMS_HARD = true}})
  F.mat(W, 0, 9, {token = 'INORGANIC:MAGNETITE', flags = {ITEMS_HARD = true}})
  F.mat(W, 0, 11, {token = 'INORGANIC:CHALK', flags = {}})
  df.global.plotinfo.economic_stone = {[9] = 1}
  setup(W)
  W.load(fresh('economy'))
  return W
end
local function dump(W, key)
  local r = W.inbox('inspect', {what = 'raw', key = key})
  T.ok(r.ok, T.show(r))
  return table.concat((r.data and r.data.lines) or {}, '\n')
end

T.test('BUG-896: items:BOULDER names each sample\'s material and the mason filter verdict; the counts say N free, of them M hard non-economic', function()
  local W = world(function(W)
    for _ = 1, 3 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7, _pos = {5, 5, 1}}) end          -- granite: hard, not economic
    for _ = 1, 2 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 9, _pos = {6, 5, 1}}) end          -- magnetite: hard, economic
    for _ = 1, 4 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 11, _pos = {7, 5, 1}}) end         -- chalk: soft
    F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7, _pos = {8, 5, 1}, flags = {forbid = true}})
  end)
  local t = dump(W, 'items:BOULDER')
  T.ok(t:find('boulders: 9 free, of them 3 hard non-economic', 1, true), t)
  T.ok(t:find('GRANITE x3 (hard)', 1, true) and t:find('MAGNETITE x2 (hard, economic)', 1, true) and t:find('CHALK x4 (soft)', 1, true), t)
  T.ok(t:find('mat=GRANITE hard=true economic=false mason_filter=pass', 1, true), t)
  T.ok(t:find('mat=MAGNETITE hard=true economic=true mason_filter=fail', 1, true), t)
  T.ok(t:find('no exclusion (free as DF sees it): 9', 1, true), t)
  local t2 = dump(W, 'items:boulder')
  T.ok(t2:find('boulders: 9 free, of them 3 hard non-economic', 1, true), 'the lower case key too')
end)

T.test('BUG-896: items:door and items:DOOR are keys (also the other furniture vectors); a vector DF does not have is refused', function()
  local W = world(function(W)
    for _ = 1, 2 do F.item(W, 'DOOR', {mat_type = 0, mat_index = 7, _pos = {5, 5, 1}}) end
    F.item(W, 'DOOR', {mat_type = 0, mat_index = 7, _pos = {6, 5, 1}, flags = {forbid = true}})
    F.item(W, 'BED', {mat_type = 0, mat_index = 7, _pos = {6, 5, 1}})
  end)
  W.set_census('i', {doors = 2})
  for _, k in ipairs({'items:DOOR', 'items:door', 'items:doors'}) do
    local t = dump(W, k)
    T.ok(t:find('items door (vector DOOR): 3 records', 1, true), k .. ': ' .. t)
    T.ok(t:find('no exclusion (free as DF sees it): 2', 1, true) and t:find('forbid=1', 1, true), t)
    T.ok(t:find('census says: doors=2', 1, true), t)
  end
  T.ok(dump(W, 'items:bed'):find('items bed (vector BED): 1 records', 1, true))
  local r = W.inbox('inspect', {what = 'raw', key = 'items:NOSUCHTHING'})
  T.ok(not r.ok, 'no such vector')
end)

T.test('BUG-896: a mason job\'s input text says "0 of 53 free boulders are hard non-economic stone"; a plain input keeps its text', function()
  local JW = require('dfllm.jobwhy')
  local e = {what = 'boulder', need = 1, match = 0, free = 0, forbid = 0, claimed = 0, far = 0, btot = 53, bfilter = true}
  T.eq(JW.input_text(e), 'boulder x1: 0 match, 0 free, 0 of 53 free boulders are hard non-economic stone')
  local e2 = {what = 'boulder', need = 1, match = 3, free = 2, forbid = 0, claimed = 0, far = 1, btot = 53}
  T.ok(JW.input_text(e2):find('3 of 53 free boulders are taken by this job', 1, true), JW.input_text(e2))
  local e3 = {what = 'wood', need = 1, match = 0, free = 0, forbid = 0, claimed = 0, far = 0}
  T.eq(JW.input_text(e3), 'wood x1: 0 match, 0 free')
end)

T.test('BUG-896: J.inputs counts the free boulders of the vector (not forbidden, not in a job) beside the matches of the mason filter', function()
  local W = world(function(W)
    for i = 1, 5 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 11, _pos = {5 + i, 5, 1}}) end
    F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7, _pos = {5, 6, 1}, flags = {forbid = true}})
    F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7, _pos = {5, 7, 1}, flags = {in_job = true}})
  end)
  df.items_other_id = kmock.enum({'IN_PLAY', 'BOULDER'})
  dfhack.job.isSuitableItem = function() return true end
  dfhack.job.isSuitableMaterial = function() return false end
  local JW = require('dfllm.jobwhy')
  local ji = {item_type = df.item_type.BOULDER, quantity = 1, mat_type = -1, mat_index = -1, vector_id = -1, flags1 = {}, flags2 = {non_economic = true}, flags3 = {hard = true}}
  local job = {job_items = {elements = kmock.vec{ji}}, items = kmock.vec{}}
  local ins = JW.inputs(W.K, job, nil, nil)
  T.eq({ins[1].btot, ins[1].match, ins[1].bfilter}, {5, 0, true})
  T.ok(JW.input_text(ins[1]):find('0 of 5 free boulders are hard non-economic stone', 1, true), JW.input_text(ins[1]))
end)

T.test('BUG-896: the stale-order reason of a rock order says how many of the free boulders are hard non-economic stone, not "26 free boulders"', function()
  local W = world(function() end)
  local econ = fresh('economy')
  local c = econ.conf(W.K)
  local p = W.K.persist.get('m.economy') or {}
  local r = {now = 300 * DAYT, p = p, inv = {rock = 53, rock_nouse = 53, boulders = 60}, f = {}, held = {}, planned = {}, cmds = 0, s = {used = {}, live = {}}}
  local txt = econ.stale_reason(c, r, {ctx = {}}, {id = 1}, 'ConstructCoffin', 'rock', 5)
  T.ok(txt:find('0 of 53 free boulders are hard non-economic stone', 1, true), txt)
  r.inv = {rock = 53, rock_nouse = 27, boulders = 60}
  local txt2 = econ.stale_reason(c, r, {ctx = {}}, {id = 1}, 'ConstructCoffin', 'rock', 5)
  T.ok(txt2:find('26 of 53 free boulders are hard non-economic stone', 1, true), txt2)
end)

T.done()
