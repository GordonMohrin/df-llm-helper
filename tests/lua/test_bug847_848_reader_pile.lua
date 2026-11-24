-- NEU5 (BUG-847, BUG-848): the cancel reader and the stockpile barrel limit. Live (main 4081ef70, i4 Girderroots): the tally stayed empty for ~25 game days while
-- gamelog.txt held 110x "<name>, <profession> cancels Brew drink from plant: Needs empty food storage item." and 109x "... Brew drink from fruit: Needs
-- unrotten fermentable leaf or fruit." in its last 400 lines; `sp.max_barrels` was unreadable ("max_barrels=?"). Offline, against the fake world and a fixture file.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200
local BREWER, CARPENTER = 6, 7

local function world(o)
  o = o or {}
  local units, ids = {}, {}
  for i = 1, o.n or 6 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}}; ids[i] = i end
  local base = F.cfg()
  if o.diag then base.economy.diag = o.diag end
  local W = F.world{cfg = {baseline = base}, units = units}
  if df.job_type.Dig == nil then df.job_type.Dig = 990; df.job_type[990] = 'Dig' end
  if df.job_type.MakeBarrel == nil then df.job_type.MakeBarrel = 991; df.job_type[991] = 'MakeBarrel' end
  df.unit_labor = {BREWER = BREWER, [BREWER] = 'BREWER', CARPENTER = CARPENTER, [CARPENTER] = 'CARPENTER'}
  df.job_skill = df.job_skill or {}
  df.items_other_id = kmock.enum({'IN_PLAY', 'PLANT', 'PLANT_GROWTH', 'BARREL', 'FISH_RAW', 'FOOD_STORAGE', 'WOOD'})
  for _, v in ipairs({'PLANT', 'PLANT_GROWTH', 'BARREL', 'WOOD', 'FOOD_STORAGE'}) do rawset(df.global.world.items.other, v, rawget(df.global.world.items.other, v) or kmock.vec{}) end
  df.job_type.attrs = setmetatable({}, {__index = function() return {labor = -1, skill = -1} end})
  df.global.world.raws.reactions = {reactions = kmock.vec{
    {code = 'BREW_DRINK_FROM_PLANT', skill = 60, building = {type = kmock.vec{df.building_type.Workshop}, subtype = kmock.vec{df.workshop_type.Still}}}}}
  dfhack.job.getWorker = function(j) return j._worker end
  dfhack.job.isSuitableItem = function() return true end
  dfhack.job.isSuitableMaterial = function() return true end
  dfhack.units.isJobAvailable = function(u) return u._m.avail ~= false end
  dfhack.units.getNominalSkill = function() return 0 end
  dfhack.units.isChild = function() return false end
  dfhack.units.isBaby = function() return false end
  for i = 1, o.n or 6 do
    local u = W.unit(i)
    u.job, u.mood = {current_job = nil}, -1
    u.status.labors = {}
    u.military = {squad_id = -1}
    u.burrows = kmock.vec{}
    u.flags1 = {}
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  for _, id in ipairs(o.brewers or {1, 2}) do W.unit(id).status.labors[BREWER] = true end
  W.set_census('u', F.census_u(ids))
  F.item(W, 'DRINK', {stack_size = 20000})
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, plot_under = function() return true end,
          groups = function(_, pts) local g = {}; for i, p in ipairs(pts) do g[i] = p[1] >= 500 and 2 or 1 end; return g end,
          hidden = function(_, pts) local g = {}; for i, p in ipairs(pts) do g[i] = p[2] >= 900 end; return g end})
  W.load(fresh('economy'))
  local b = F.workshop(W, 'Still')
  b.x1, b.y1, b.x2, b.y2, b.z, b.centerx, b.centery = 20, 20, 22, 22, 100, 21, 21
  b.getBuildStage = function() return 1 end
  b.getMaxBuildStage = function() return 1 end
  b.jobs = kmock.vec{}
  b.flags = {}
  b.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  local ord = F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = o.left or 5, amount_total = o.left or 5,
                          mat_type = -1, mat_index = -1, workshop_id = o.pinned or -1, status = {validated = true, active = true}, frequency = 0,
                          item_conditions = kmock.vec{{compare_type = 'AtLeast', compare_val = 1, item_type = -1, flags1 = {empty = true}, flags3 = {food_storage = true}}}})
  return W, b, ord
end

local function raw(W, key)
  return W.inbox('inspect', {what = 'raw', key = key})
end
local function text(r) return table.concat((r.data and r.data.lines) or {}, '\n') end

local CW = require('dfllm.cancelwhy')
local BREWWHY = 'Needs empty food storage item'
local function feed(econ, K, n, tick, why, job)
  for _ = 1, n do
    econ.on.REPORT(K, {type = 'CANCEL_JOB', tick = tick, text = 'Urist McBrew cancels ' .. (job or 'Brew drink from plant') .. ': ' .. (why or BREWWHY) .. '.'})
  end
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l.msg end end
end


local GL = require('dfllm.gamelog')
local OL = require('dfllm.orderlib')
local DAYT = 1200
local function tmpfile(tag)
  local dir = (os.getenv('TEMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests/test_bug847-' .. tag
  luahost.mkdir_recursive(dir)
  os.remove(dir .. '/gamelog.txt')
  return dir, dir .. '/gamelog.txt'
end
local function put(path, s, mode)
  local f = assert(io.open(path, mode or 'ab'))
  f:write(s)
  f:close()
end
-- the two live sentences, with CP437 names (bytes >= 128)
local PLANT = 'Iden Al\134th\148m, Woodcrafter cancels Brew drink from plant: Needs empty food storage item.\n'
local FRUIT = 'Domas M\148rulothsin, militia captain cancels Brew drink from fruit: Needs unrotten fermentable leaf or fruit.\n'

T.test('BUG-847 cause: orderlib.cancel_parts reads both live sentences incl. CP437 names: the wording was never the problem', function()
  local j, why = OL.cancel_parts(PLANT)
  T.eq({j, why}, {'Brew drink from plant', 'Needs empty food storage item'})
  j, why = OL.cancel_parts(FRUIT)
  T.eq({j, why}, {'Brew drink from fruit', 'Needs unrotten fermentable leaf or fruit'})
  T.eq({GL.parse(PLANT)}, {'Brew drink from plant', 'Needs empty food storage item'})
  T.eq(GL.parse('Urist cancels Dump item: Item is forbidden. (x3)'), 'Dump item')
  T.eq(GL.parse('The Dwarven caravan has arrived.'), nil)
  local k, w = GL.parse('X cancels Br\200w: N\200eds it.')
  T.eq({k, w}, {'Br?w', 'N?eds it'}, 'non-ASCII bytes of the job text are cut to ?')
end)

T.test('BUG-847 gamelog: first look starts at the END, then only the new complete lines, with the cancel lines picked out', function()
  local _, path = tmpfile('inc')
  put(path, 'old line\n' .. PLANT, 'wb')
  local s = GL.new(path)
  T.eq(#GL.poll(s, {}), 0, 'the old lines are not today')
  T.eq(s.state, 'ok')
  put(path, PLANT .. 'a boring line\n' .. FRUIT .. 'half a lin')
  local r = GL.poll(s, {})
  T.eq(#r, 2)
  T.eq({r[1][1], r[1][2], r[2][1]}, {'Brew drink from plant', 'Needs empty food storage item', 'Brew drink from fruit'})
  T.eq(#GL.poll(s, {}), 0, 'the half line waits')
  put(path, 'e cancels Drink: Well dry.\n')
  r = GL.poll(s, {})
  T.eq({#r, r[1][1], r[1][2]}, {1, 'Drink', 'Well dry'}, 'completed on the next look')
  T.eq(s.cancels, 3)
end)

T.test('BUG-847 gamelog: bounded bytes per look, a long backlog is skipped, never the whole file', function()
  local _, path = tmpfile('bound')
  put(path, '', 'wb')
  local s = GL.new(path)
  GL.poll(s, {})
  put(path, string.rep(PLANT, 100))
  local r = GL.poll(s, {max = #PLANT * 10 + 5})                      -- 10 whole lines fit
  T.eq(#r, 10)
  local n = #r
  for _ = 1, 20 do n = n + #GL.poll(s, {max = #PLANT * 10 + 5}) end
  T.eq(n, 100, 'the rest follows look by look')
  put(path, string.rep(PLANT, 100))
  r = GL.poll(s, {backlog = 500})                                    -- far behind (a long pause): skipped, counted
  T.eq(#r, 0)
  T.ok(s.skipped >= #PLANT * 100, 'skipped ' .. s.skipped)
  put(path, PLANT)
  T.eq(#GL.poll(s, {backlog = 500}), 1, 'and reads on from the end')
end)

T.test('BUG-847 gamelog: truncation, replacement (rotation) and the new-game marker', function()
  local _, path = tmpfile('rot')
  put(path, 'first head of the old game\n' .. string.rep('x\n', 50), 'wb')
  local s = GL.new(path)
  GL.poll(s, {})
  put(path, 'another head line\n' .. PLANT, 'wb')                    -- the file was replaced: smaller and another head
  local r = GL.poll(s, {})
  T.eq({#r, s.resets}, {1, 1}, 'read from the start of the new file')
  put(path, PLANT .. PLANT .. PLANT, 'wb')                           -- truncated and rewritten
  GL.poll(s, {})
  T.ok(s.resets >= 2, 'resets ' .. s.resets)
  put(path, PLANT .. '*** STARTING NEW GAME ***\n' .. FRUIT)
  r = GL.poll(s, {})
  T.eq({#r, r[1] and r[1][1], s.restarts}, {1, 'Brew drink from fruit', 1}, 'lines before the marker belong to the older game')
  os.remove(path)
  r = GL.poll(s, {})
  T.eq({#r, s.state}, {0, 'missing'})
  put(path, FRUIT, 'wb')
  T.eq(#GL.poll(s, {}), 1, 'the file is back (a reset): its lines count')
end)

T.test('BUG-847 gamelog: the offset persists as hex (no raw bytes in the state) and resumes', function()
  local _, path = tmpfile('res')
  put(path, 'Caf\233 line\n' .. PLANT, 'wb')
  local s = GL.new(path)
  GL.poll(s, {})
  local saved = GL.save(s)
  T.ok(type(saved.sig) == 'string' and not saved.sig:find('[^0-9a-f]'), T.show(saved))
  put(path, FRUIT)
  local s2 = GL.new(path)
  GL.resume(s2, saved)
  local r = GL.poll(s2, {})
  T.eq({#r, r[1] and r[1][1]}, {1, 'Brew drink from fruit'}, 'the reload continues where it stood')
  local s3 = GL.new(path)
  GL.resume(s3, {off = 5, sig = 'zz'})
  T.eq(s3.off, nil, 'a bad saved state is ignored')
end)

local function gworld(tag, o)
  o = o or {}
  local W, b, ord = world(o)
  local dir, path = tmpfile(tag)
  W.K.cfg.paths.df = dir
  put(path, 'start\n', 'wb')
  return W, path, ord
end

T.test('BUG-847 economy: the gamelog is the tally source, the reports are then not counted twice, the health line says so', function()
  local W, path = gworld('econ')
  local econ = require('dfllm.economy')
  local now = W.K.now().tick
  local h = econ.cw_health(W.K, nil, now)
  T.ok(h.text:find('DF cancel lines seen in window: 0 (source report; gamelog reader not started', 1, true), h.text)
  econ.gl_poll(W.K)                                                  -- first look: from the end
  for _ = 1, 110 do put(path, PLANT) end
  for _ = 1, 109 do put(path, FRUIT) end
  T.eq(econ.gl_poll(W.K), 219)
  h = econ.cw_health(W.K, nil, now)
  T.ok(h.n == 219 and h.source == 'gamelog' and h.text:find('DF cancel lines seen in window: 219 (source gamelog', 1, true), h.text)
  local e = econ.df_reason(W.K, {'brew '})
  T.ok(e.why == BREWWHY and e.n == 110, T.show(e))
  T.ok(econ.cx_gate(W.K, nil, now) == 110, 'the cure gate opens on the gamelog lines')
  feed(econ, W.K, 7, now)                                            -- the same cancels also arrive as reports: counted once
  T.eq(econ.cw_health(W.K, nil, now).n, 219)
  T.ok(econ.cw_health(W.K, nil, now + 4 * DAYT).source == 'report', 'no new gamelog line for 3 days: the reports count again')
  local l = econ.stall_log(W.K, 'brew', 'brew')
  T.ok(l and l:find('DF cancel lines seen in window: 219 (source gamelog', 1, true), tostring(l))
end)

T.test('BUG-847 economy: no gamelog file -> source report and a loud one-time kern.log line; the report path fills the tally; why shows the health', function()
  local W = gworld('nofile')
  os.remove(W.K.cfg.paths.df .. '/gamelog.txt')
  local econ = require('dfllm.economy')
  econ.gl_poll(W.K)
  local l = logged(W, 'gamelog reader')
  T.ok(l and l:find('falls back to the eventful reports', 1, true), tostring(l))
  econ.gl_poll(W.K)
  local n = 0
  for _, x in ipairs(W.logs) do if tostring(x.msg):find('gamelog reader', 1, true) then n = n + 1 end end
  T.eq(n, 1, 'one line, not one per look')
  local h = econ.cw_health(W.K, nil, W.K.now().tick)
  T.ok(h.text:find('(source report; gamelog missing', 1, true), h.text)
  local W2, _, ord = gworld('nofile2', {left = 6})
  os.remove(W2.K.cfg.paths.df .. '/gamelog.txt')
  local econ2 = require('dfllm.economy')
  econ2.gl_poll(W2.K)
  local r = econ2.jw_ask(W2.K, nil, 'order:' .. ord.id)
  T.ok(r.dfh and r.dfh:find('DF cancel lines seen in window: 0 (source report', 1, true), 'why carries the health: ' .. tostring(r.dfh))
  T.ok(require('dfllm.jobwhy').line(r):find('DF cancel lines seen in window: 0', 1, true), 'and the line says it')
  feed(econ2, W2.K, 12, W2.K.now().tick)
  local e = econ2.df_reason(W2.K, {'brew '})
  T.ok(e and e.n == 12, 'the fallback source fills the tally')
end)

T.test('BUG-847 economy: the offset is persisted, switch economy.cancel.gamelog off keeps the report path only', function()
  local W, path = gworld('persist')
  local econ = require('dfllm.economy')
  econ.gl_poll(W.K)
  put(path, PLANT .. PLANT)
  econ.gl_poll(W.K)
  local p = W.K.persist.get('m.economy')
  T.ok(type(p.gl) == 'table' and math.tointeger(p.gl.off) and p.gl.off > 0 and type(p.gl.sig) == 'string', T.show(p.gl))
  local c = W.K.cfg.baseline.economy
  c.cancel.gamelog = false
  put(path, PLANT)
  T.eq(econ.gl_poll(W.K, c), 0)
  T.ok(econ.cw_health(W.K, c, W.K.now().tick).text:find('gamelog reader off', 1, true))
end)

T.test('item 4: why brew shows the DF reason first in the line', function()
  local W = world{left = 6}
  local econ = require('dfllm.economy')
  feed(econ, W.K, 30, W.K.now().tick)
  local r = econ.jw_ask(W.K, nil, 'brew')
  T.ok(r, 'brew answers')
  local line = require('dfllm.jobwhy').line(r)
  T.ok(line:sub(1, 25) == 'DF cancelled brew drink f', line:sub(1, 80))
  local rr = W.inbox('inspect', {what = 'why', key = 'brew'})
  T.ok(rr.ok and rr.msg:sub(1, 6) == 'DF can', T.show(rr.msg))
end)

-- BUG-848 -------------------------------------------------------------------------------------------------------------------------------
local PL = require('dfllm.pilelib')

T.test('BUG-848 pilelib: DFHack 53 keeps the limit in storage.max_barrels; the flat name is the second candidate; none = nil and says what was tried', function()
  local a = {storage = {max_barrels = -1, max_bins = 3}}
  T.eq({PL.get(a)}, {-1, 'storage.max_barrels'})
  T.eq({PL.set(a, 4)}, {true, 'storage.max_barrels'})
  T.eq(a.storage.max_barrels, 4)
  local b = {max_barrels = 7}
  T.eq({PL.get(b)}, {7, 'max_barrels'})
  T.eq({PL.set(b, 2)}, {true, 'max_barrels'})
  local c = {}
  T.eq({PL.get(c)}, {nil, nil})
  local ok, why = PL.set(c, 3)
  T.ok(ok == false and why:find('storage.max_barrels, max_barrels', 1, true), tostring(why))
  local d = setmetatable({}, {__index = function(_, k) error('no field ' .. k) end})      -- a DF struct raises on an unknown field
  T.eq({PL.get(d)}, {nil, nil})
  local pr = PL.probe({a, b, c})
  T.eq({pr.n, pr.ok, pr.cand}, {3, 2, 'storage.max_barrels'})
end)

local function piles()
  local mk = function(id, name, x1, max, flat)
    local sp = {id = id, name = name, x1 = x1, y1 = 0, x2 = x1 + 2, y2 = 2, z = 5, stockpile_number = id - 40,
                settings = {flags = {food = true}, food = {drink_plant = kmock.vec{false}, drink_animal = kmock.vec{false}}},
                links = {give_to_pile = kmock.vec{}, take_from_pile = kmock.vec{}}}
    if flat then sp.max_barrels = max else sp.storage = {max_barrels = max, max_bins = -1, max_wheelbarrows = 0} end
    return sp
  end
  local sp = {mk(41, 'dfllm-stock', 0, -1), mk(42, 'old flat', 10, -1, true)}
  df.global.world.buildings.other.STOCKPILE = kmock.vec(sp)
  df.building.find = function(id) for _, s in ipairs(sp) do if s.id == id then return s end end end
  rawset(df.global.world.items.other, 'BARREL', kmock.vec{{pos = {x = 1, y = 1, z = 5}}, {pos = {x = 11, y = 1, z = 5}}, {pos = {x = 12, y = 1, z = 5}}})
  return sp
end
local function api()
  local actlib = require('dfllm.act')
  return actlib.new{who = function() return 'economy' end, allowlist = function() return actlib.BUILTIN_ALLOWLIST end, log_cmd = function() end, fail = function() end}
end

T.test('BUG-848 act.pile_barrels works on storage.max_barrels (DFHack 53) and on the flat field, and restores through the same field', function()
  world{}
  local sp = piles()
  local a = api()
  local ok, res = a.pile_barrels('freeze', {})
  T.ok(ok and #res == 2, T.show(res))
  T.eq({sp[1].storage.max_barrels, sp[2].max_barrels}, {1, 2})
  a.pile_barrels('restore', {['41'] = -1, ['42'] = -1})
  T.eq({sp[1].storage.max_barrels, sp[2].max_barrels}, {-1, -1})
  sp[1].storage, sp[2].max_barrels = nil, nil                        -- no field at all: false with the candidates named
  ok, res = a.pile_barrels('freeze', {})
  T.ok(ok == false and tostring(res):find('no barrel limit field on 2 food stockpiles (tried storage.max_barrels, max_barrels)', 1, true), T.show(res))
end)

T.test('BUG-848 economy: a pile whose limit cannot be read logs ONE loud error line and the stall line says so', function()
  local W = world{left = 30}
  local sp = piles()
  sp[1].storage, sp[2].max_barrels = nil, nil
  local econ = require('dfllm.economy')
  local p = W.K.persist.get('m.economy')
  W.K.act.pile_barrels = api().pile_barrels
  econ.cx_freeze(W.K, p, false, W.K.now().tick)
  econ.cx_freeze(W.K, p, false, W.K.now().tick)
  local n, lvl = 0, nil
  for _, x in ipairs(W.logs) do
    if tostring(x.msg):find('cannot be read or set', 1, true) then n, lvl = n + 1, x.level end
  end
  T.eq(n, 1, 'one line per load')
  T.eq(lvl, 'error')
  local l = econ.stall_log(W.K, 'brew', 'brew')
  T.ok(l and l:find('pile limit field UNREADABLE on 2 piles (tried storage.max_barrels, max_barrels)', 1, true), tostring(l))
end)

T.test('BUG-848 raw dumps: pile:<id> dumps a stockpile, ws:<id> takes a stockpile id, why ws:<id> says what it is', function()
  local W = world{}
  piles()
  local r = raw(W, 'pile:41')
  T.ok(r.ok, T.show(r))
  local t = text(r)
  T.ok(t:find('pile 41 dfllm-stock', 1, true) and t:find('barrel limit -1 (field storage.max_barrels', 1, true), t)
  T.ok(t:find('storage max_barrels=-1', 1, true) and t:find('link give_to_pile', 1, true) and t:find('barrels lying in the pile: 1', 1, true), t)
  T.ok(text(raw(W, 'pile:42')):find('(field max_barrels', 1, true))
  local r3 = raw(W, 'ws:41')
  T.ok(r3.ok and text(r3):find('pile 41', 1, true), 'ws:<id> accepts a stockpile id: ' .. T.show(r3.msg))
  local r4 = raw(W, 'pile:99')
  T.ok(r4.ok == false and tostring(r4.msg):find('no stockpile 99', 1, true), T.show(r4))
  local q = W.inbox('inspect', {what = 'why', key = 'ws:41'})
  T.ok(q.ok == false and tostring(q.msg):find('is a stockpile, not a workshop', 1, true), T.show(q.msg))
end)

T.done()
