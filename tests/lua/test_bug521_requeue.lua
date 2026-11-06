-- BUG-521 (Run 16d i4 Trumpetrealms y389: TIMELINE RESET, the fortcore st3 retrofit placed in the discarded timeline was gone from the
-- loaded save): at the first step after a boot that found the clock jumped back, the bp.place commands of the discarded timeline
-- (commands.log after the older save's tick, result ok, not cancelled) whose project the save lacks are placed again and PROJECTS_REQUEUED
-- says which; a project the loaded save has, a cancelled one, a refused one and the part shared by both timelines are left alone.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local WALL = os.time()
local function line(ts, tick, id, verb, args, res)
  return string.format('%d\t%d\tinbox:%s:cli\tverb:%s\t%s\t%s\n', ts, tick, id, verb, args, res or 'ok')
end

local function setup(tag, cmds, extra)
  local W = H.world({tag = tag})
  for _, id in ipairs({'shared1', 'lost1', 'lost2', 'lost3', 'have1', 'bad1'}) do H.put(W, id, H.doc{x = 10, tpl = 'bedrooms'}) end
  H.put(W, 'bad1', {v = 2, tpl = 'bedrooms'})          -- a bp file the verb refuses (no stages)
  H.write(W.sd .. '/commands.log', cmds)
  W.K.reset = {kind = 'clock', n_alt = 100, tick_alt = 5000, tick_neu = 1000}
  W.load(runner)
  if extra then extra(W) end
  H.settle(W); W.frame(1); H.settle(W)
  return W
end

local OLD, NEW = WALL - 600, WALL - 300
local LOG = line(OLD, 800, 'shared1', 'bp.place', '{"site":"S1","tpl":"bedrooms"}')            -- both timelines have it
  .. line(NEW, 1500, 'lost1', 'bp.place', '{"site":"S1","tpl":"bedrooms","prio":2}')           -- only the discarded one
  .. line(NEW, 1600, 'lost2', 'bp.place', '{"site":"S1","tpl":"bedrooms"}')
  .. line(NEW, 1700, 'lost2', 'bp.cancel', '{"proj":"lost2"}')                                  -- the player cancelled it
  .. line(NEW, 1800, 'lost3', 'bp.place', '{"site":"S1","tpl":"bedrooms"}', 'fail refused')    -- never queued
  .. line(NEW, 1900, 'have1', 'bp.place', '{"site":"S1","tpl":"bedrooms"}')                    -- the loaded save has it
  .. line(NEW, 2000, 'bad1', 'bp.place', '{"site":"S1","tpl":"bedrooms"}')                     -- its bp file is unusable now
  .. line(WALL + 5, 1000, 'zzz', 'bp.place', '{"site":"S1","tpl":"bedrooms"}')                  -- this boot's own line, ignored

T.test('BUG-521: the projects placed in the discarded timeline are queued again, in order, and PROJECTS_REQUEUED names them', function()
  local W = setup('req1', LOG, function(W)              -- the loaded save has have1 already
    H.place(W, 'have1', H.doc{x = 30, tpl = 'bedrooms'}, {tpl = 'bedrooms', site = 'S1'})
  end)
  local ev = W.find_events('PROJECTS_REQUEUED')
  T.eq(#ev, 1)
  T.eq({ev[1].cls, ev[1].d.ids, ev[1].d.n}, {'B', {'lost1'}, 1})
  T.ok(H.proj(W, 'lost1') and H.proj(W, 'have1'), 'queued, and the one the save has stays single')
  local cnt = 0
  for _, P in ipairs(W.K.persist.get('projects').list) do if P.id == 'have1' then cnt = cnt + 1 end end
  T.eq(cnt, 1)
  T.eq(H.proj(W, 'lost1').prio, 2, 'with its prio')
  T.eq(H.proj(W, 'shared1'), nil, 'a line both timelines share is not touched')
  T.eq(H.proj(W, 'lost2'), nil, 'cancelled after it was placed: not queued')
  T.eq(H.proj(W, 'lost3'), nil, 'a refused command: not queued')
  T.eq({ev[1].d.tick_alt, ev[1].d.tick_neu}, {5000, 1000})
  T.ok(ev[1].d.failed and ev[1].d.failed[1]:find('^bad1: '), 'the unusable bp file is named with the reason')
  T.ok(ev[1].msg:find('timeline reset', 1, true) and ev[1].msg:find('queued again', 1, true), ev[1].msg)
end)

T.test('BUG-521: a project the loaded save has is not placed twice; no reset, no re-queue; once per boot', function()
  local W = setup('req2', LOG, function(W) end)
  local n = #W.find_events('PROJECTS_REQUEUED')
  H.settle(W); W.frame(1); H.settle(W)
  T.eq(#W.find_events('PROJECTS_REQUEUED'), n, 'once')
  local W2 = H.world({tag = 'req3'})
  for _, id in ipairs({'lost1'}) do H.put(W2, id, H.doc{x = 10, tpl = 'bedrooms'}) end
  H.write(W2.sd .. '/commands.log', LOG)
  W2.load(runner)
  H.settle(W2); W2.frame(1); H.settle(W2)
  T.eq(#W2.find_events('PROJECTS_REQUEUED'), 0, 'K.reset is nil: a normal boot re-queues nothing')
  T.eq(H.proj(W2, 'lost1'), nil)
end)

T.test('BUG-521: at most requeue_max, the rest is counted', function()
  local lines = ''
  for i = 1, 4 do
    local id = 'p' .. i
    lines = lines .. line(NEW, 1100 + i, id, 'bp.place', '{"site":"S1","tpl":"bedrooms"}')
  end
  local old = runner.CFG.requeue_max
  runner.CFG.requeue_max = 2
  local W = H.world({tag = 'req4'})
  for i = 1, 4 do H.put(W, 'p' .. i, H.doc{x = 10 * i, tpl = 'bedrooms'}) end
  H.write(W.sd .. '/commands.log', lines)
  W.K.reset = {kind = 'clock', n_alt = 1, tick_alt = 5000, tick_neu = 1000}
  W.load(runner)
  H.settle(W); W.frame(1); H.settle(W)
  runner.CFG.requeue_max = old
  local ev = W.find_events('PROJECTS_REQUEUED')
  T.eq({#ev, ev[1].d.n, ev[1].d.skipped}, {1, 2, 2})
  T.eq({ev[1].d.ids}, {{'p1', 'p2'}})
end)

T.done()
