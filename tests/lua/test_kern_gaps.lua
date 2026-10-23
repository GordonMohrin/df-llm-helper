-- BUG-070 (Run 13 y456/y483: 24-27 s freezes at the year change and at saves, 13 gaps > 3 s): every frame gap gets one cause
-- (our module and its task, a DF save, unknown), perf.csv/inspect perf/PERF_DEGRADED carry it, and heavy background work waits
-- in a quiet window after a new year or a save gap. BUG-071 (status showed only the clock line): pop/stock/labor keep their
-- last known values with their age instead of vanishing, across a reboot too, and a >4 KB document sheds other keys first.
local T = require('testlib')
local H = require('kern_world')
local json = require('dfllm.util.json')
local kern = require('dfllm.kern')
local perf = require('dfllm.perf')

local function log(W) return H.read(W.sd .. '/kern.log') or '' end

T.test('BUG-070: a gap across the year change is a DF save (yearly autosave), not unknown', function()
  local W = H.world{tag = 'gap_year', ytick = 403200 - 20}
  H.boot(W, {modules = {perf}})
  H.run(W, 5)
  H.frame(W, 30, 25000)                                -- the year changes inside a 25 s freeze
  H.run(W, 5)
  H.inbox(W, 'p1', 'inspect', {what = 'perf'})
  H.run(W, 80)
  local d = H.outbox(W, 'p1').data
  kern.stop()
  T.ok(log(W):find('frame gap 25000 ms (blame save) (new year: the yearly autosave)', 1, true), log(W))
  T.eq(d.gaps[1].cause, 'save')
  T.eq(d.gaps[1].ms, 25000)
  local pd = H.find(H.events(W), 'PERF_DEGRADED')
  T.eq(#pd, 1)
  T.eq({pd[1].d.why, pd[1].d.cause}, {'freeze', 'save'})
  T.ok(pd[1].msg:find('(DF save)', 1, true), pd[1].msg)
end)

T.test('BUG-070: a renamed save folder across the gap is a DF save; no evidence stays external', function()
  local W = H.world{tag = 'gap_name'}
  local name = 'region1'
  dfhack.getSavePath = function() return W.dir .. '/save/' .. name end
  H.boot(W, {modules = {perf}})
  H.run(W, 5)
  name = 'autosave 2'
  H.frame(W, 1, 12000)
  H.run(W, 5)
  H.frame(W, 1, 9000)                                  -- the name is known now: nothing explains this one
  H.run(W, 5)
  kern.stop()
  local l = log(W)
  T.ok(l:find('frame gap 12000 ms (blame save) (save folder region1 > autosave 2)', 1, true), l)
  T.ok(l:find('frame gap 9000 ms (blame external)', 1, true), l)
end)

T.test('BUG-070: our own slow frame is blamed on the module and the task it said it was doing', function()
  local W = H.world{tag = 'gap_task'}
  local slow = {name = 'economy', every = {ticks = 1000}, doing = function() return 'daily run: quickfort place' end}
  function slow.step() W.ms = W.ms + 4000 end
  H.boot(W, {modules = {slow}, strict = false})
  H.run(W, 5)
  kern.stop()
  T.ok(log(W):find('(blame economy) in daily run: quickfort place', 1, true), log(W))
end)

T.test('BUG-070: perf.csv splits the gaps by cause (gap:<cause> ms, gapn:<cause> count)', function()
  local W = H.world{tag = 'gap_csv', ytick = 403200 - 20}
  perf.ROW_MS = 3000
  H.boot(W, {modules = {perf}})
  H.run(W, 5)
  H.frame(W, 30, 25000)
  H.frame(W, 1, 4000)
  H.run(W, 400)
  perf.ROW_MS = 30000
  kern.stop()
  local mods = ''
  for i, l in ipairs(H.lines(W.sd .. '/perf.csv')) do
    if i > 1 and l:find('gap:', 1, true) then
      mods = mods .. '|' .. l:match('^[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,(.*)$')
    end
  end
  T.ok(#mods > 0, 'a row with the gap fields')
  T.ok(mods:find('gap:save=25000;gapn:save=1', 1, true), mods)
  T.ok(mods:find('gap:external=4000;gapn:external=1', 1, true), mods)
end)

T.test('BUG-070: after a new year heavy background work waits (K.busy), the timed persist flush too, then it goes on', function()
  local W = H.world{tag = 'quiet', ytick = 403200 - 1500, ms_per_frame = 1000}
  local busy_at, n = {}, 0
  local r = {name = 'runner', every = {ticks = 100}}
  function r.step(K)
    n = n + 1
    busy_at[#busy_at + 1] = {tick = K.now().tick, by = (K.busy())}
    K.persist.set('m.runner', {n = n})
  end
  H.boot(W, {modules = {r}})
  local rec = function() local raw = W.persist_raw['dfllm.m.runner']; return raw and json.decode(raw).n or 0 end
  H.run(W, 1400, {skip = 100})                          -- 14 frames of 1 s: still the old year
  local before = rec()
  T.ok(before > 0)
  H.run(W, 300, {skip = 100})                           -- the new year is here: quiet for 60 s
  local year_n = #busy_at
  local saw_busy = false
  for _, b in ipairs(busy_at) do if b.by == 'save' then saw_busy = true end end
  T.ok(saw_busy, 'K.busy() says save after the year change')
  local mid = rec()
  H.run(W, 3000, {skip = 100})                          -- 30 more s: still inside the window
  T.eq(rec(), mid, 'no timed persist flush inside the quiet window')
  H.run(W, 4000, {skip = 100})                          -- past 60 s
  T.ok(rec() > mid, 'flushed after the window')
  T.eq(select(1, kern.K().busy()), nil, 'quiet is over')
  kern.stop()
end)

T.test('BUG-070: the periodic selftest waits out the quiet window too', function()
  local selftest = require('dfllm.selftest')
  local W = H.world{tag = 'quiet_selftest', ytick = 403200 - 5000, ms_per_frame = 1000}
  local n, orig = 0, selftest.run
  selftest.run = function(...) n = n + 1; return orig(...) end
  H.boot(W, {modules = {selftest}})
  H.run(W, 10 * 1000, {skip = 1000})                    -- first run at once; the year changes about frame 5
  T.eq(n, 1)
  H.run(W, 60 * 1000, {skip = 1000})                    -- due again at 61 s: inside the window (to 65 s)
  T.eq(n, 1, 'skipped inside the quiet window')
  H.run(W, 60 * 1000, {skip = 1000})
  T.ok(n >= 2, 'runs again after it: ' .. n)
  selftest.run = orig
  kern.stop()
end)

T.test('BUG-070: only PEACE waits for a save: in a fight nothing is held back, the window does not even open', function()
  local W = H.world{tag = 'quiet_fight', ytick = 403200 - 100, ms_per_frame = 1000}
  H.boot(W, {modules = {H.counter('test_a', {ticks = 100})}})
  H.run(W, 300, {skip = 100})                           -- the year changes in PEACE: the window is open (control)
  T.eq(select(1, kern.K().busy()), 'save')
  kern.K().set_mode('SIEGE', 'test')
  T.eq(select(1, kern.K().busy()), nil, 'a siege starts: nothing waits any more')
  kern.stop()
  local W2 = H.world{tag = 'quiet_fight2', ytick = 403200 - 100, ms_per_frame = 1000}
  H.boot(W2, {modules = {H.counter('test_a', {ticks = 100})}})
  kern.K().set_mode('SIEGE', 'test')
  H.run(W2, 400, {skip = 100})                          -- the year changes in a siege
  T.eq(select(1, kern.K().busy()), nil)
  kern.K().set_mode('RECOVERY', 'test')
  H.frame(W2, 1, 25000)                                 -- a save gap in RECOVERY: no window either
  T.eq(select(1, kern.K().busy()), nil)
  kern.stop()
end)

T.test('BUG-070: perf.quiet_s 0 in config/baseline.json switches the window off', function()
  for _, off in ipairs({false, true}) do
    local W = H.world{tag = 'quiet0' .. tostring(off), ytick = 403200 - 100, ms_per_frame = 1000}
    if off then
      luahost.mkdir_recursive(W.dir .. '/config')
      H.write(W.dir .. '/config/baseline.json', '{"v":2,"perf":{"quiet_s":0}}')
    end
    H.boot(W, {modules = {H.counter('test_a', {ticks = 100})}})
    H.run(W, 400, {skip = 100})
    T.eq(select(1, kern.K().busy()), (not off) and 'save' or nil, off and 'switched off' or 'default: open')
    kern.stop()
  end
end)

---------------------------------------------------------------- BUG-071
local function pop_mod(show)
  return {name = 'sense', every = {ticks = 10}, state = function()
    if show.pop then return {pop = {cit = 7, adults = 5, soldiers = 1}} end
  end}
end
local function econ_mod(show)
  return {name = 'economy', every = {ticks = 10}, state = function()
    if show.stock then return {stock = {drink_d = 200, food_d = 90, meals = 12}, labor = {starving = 0, idle = 40}} end
  end}
end

T.test('BUG-071: a module that publishes nothing any more keeps its last values, with their age in stale', function()
  local W = H.world{tag = 'carry', ms_per_frame = 500}
  local show = {pop = true, stock = true}
  H.boot(W, {modules = {pop_mod(show), econ_mod(show)}})
  H.run(W, 100, {skip = 10})
  local s = H.state(W)
  T.eq(s.pop, {cit = 7, adults = 5, soldiers = 1})
  T.eq(s.stale, nil)
  show.pop, show.stock = false, false
  H.run(W, 600, {skip = 10})
  s = H.state(W)
  T.eq(s.pop, {cit = 7, adults = 5, soldiers = 1}, 'pop stays')
  T.eq(s.stock, {drink_d = 200, food_d = 90, meals = 12}, 'stock stays')
  T.eq(s.labor, {starving = 0, idle = 40})
  T.ok(s.stale.pop >= 500 and s.stale.stock >= 500 and s.stale.labor >= 500, json.encode(s.stale))
  show.pop = true
  H.run(W, 100, {skip = 10})
  s = H.state(W)
  T.eq(s.stale.pop, nil, 'fresh again')
  T.ok(s.stale.stock ~= nil)
  kern.stop()
end)

T.test('BUG-071: the last known values survive a reboot until the module publishes (economy: first daily run)', function()
  local W = H.world{tag = 'carry_boot', ms_per_frame = 500}
  local show = {pop = true, stock = true}
  H.boot(W, {modules = {pop_mod(show), econ_mod(show)}})
  H.run(W, 100, {skip = 10})
  kern.stop()
  local raw = json.decode(W.persist_raw['dfllm.kern'])
  T.eq(raw.carry.stock.v.drink_d, 200)
  show.pop, show.stock = false, false                   -- after the reboot economy has run no daily pass yet
  H.boot(W, {modules = {pop_mod(show), econ_mod(show)}})
  local s = H.state(W)
  T.eq(s.stock, {drink_d = 200, food_d = 90, meals = 12})
  T.eq(s.pop.cit, 7)
  T.ok(s.stale.stock >= 0)
  kern.stop()
end)

T.test('BUG-071: carry_days 0 turns the carrying off', function()
  for _, off in ipairs({false, true}) do
    local W = H.world{tag = 'carry_off' .. tostring(off), ms_per_frame = 500}
    if off then
      luahost.mkdir_recursive(W.dir .. '/config')
      H.write(W.dir .. '/config/baseline.json', '{"v":2,"perf":{"carry_days":0}}')
    end
    local show = {pop = true, stock = true}
    H.boot(W, {modules = {pop_mod(show), econ_mod(show)}})
    H.run(W, 50, {skip = 10})
    show.pop, show.stock = false, false
    H.run(W, 100, {skip = 10})
    local s = H.state(W)
    if off then T.eq({s.pop, s.stock, s.stale}, {nil, nil, nil}, 'carry_days 0: nothing carried')
    else T.eq(s.pop.cit, 7, 'default: carried') end
    kern.stop()
  end
end)

T.test('BUG-071: a document over 4 KB sheds proj, care, ready, bridges, threat before labor, stock and pop', function()
  local W = H.world{tag = 'shrink', ms_per_frame = 500}
  local show = {pop = true, stock = true}
  local gate = {name = 'gate', every = {ticks = 10}, state = function()
    local b = {}
    for i = 1, 400 do b[string.format('B%04d', i)] = 'down' end
    return {bridges = b}
  end}
  H.boot(W, {modules = {pop_mod(show), econ_mod(show), gate}, strict = false})
  H.run(W, 100, {skip = 10})
  local raw = H.read(W.sd .. '/state.a.json')
  local s = H.state(W)
  T.ok(#H.read(W.sd .. '/state.a.json') <= 4096 and #H.read(W.sd .. '/state.b.json') <= 4096)
  T.eq(s.bridges, nil)
  T.eq(s.pop.cit, 7)
  T.eq(s.stock.drink_d, 200)
  T.eq(s.labor.idle, 40)
  local n = 0
  for _ in log(W):gmatch('state > 4 KB: dropped bridges') do n = n + 1 end
  T.eq(n, 1, 'named once, not every 2 s')
  kern.stop()
end)

T.done()
