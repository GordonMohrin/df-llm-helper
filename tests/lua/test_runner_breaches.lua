-- BUG-130 (Run 9 site96, Run 14 replay y707 site90: "y707s0b1 (fortcore) blocked: breach:damp", parked for good and
-- never re-sited): every breach stop is remembered with its tile, kind, project and template (m.runner dz, newest kept)
-- and mirrored into the fort manifest as `breaches`, so the fortcore ranking (bp.sites) and `plan propose` keep the next
-- fortcore away from the damp area. A breach record of an older kernel (m.runner br) is taken over at boot.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world(opts)
  W.load(runner)
  return W
end

T.test('a damp stop of the fortcore lands in manifest.breaches with its tile, kind, project and template', function()
  local W = fresh{tag = 'br_damp'}
  H.place(W, 'y707s0b1', H.dig_doc(5))
  H.runs(W, 1)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'Damp stone located', pos = {x = 12, y = 14, z = 100}})
  W.frame(1)
  T.eq(H.proj(W, 'y707s0b1').blocked, 'breach:damp')
  T.eq(W.K.manifest().breaches, {{pos = {12, 14, 100}, why = 'damp', proj = 'y707s0b1', tpl = 'fortcore'}})
  T.eq(#W.K.persist.get('m.runner').dz, 1)
  -- survives a reload; one entry per project
  local W2 = H.world{tag = 'br_damp2', persist = H.reloaded(W)}
  W2.load(runner)
  T.eq(#W2.K.manifest().breaches, 1)
end)

T.test('an older kernel breach record (m.runner br) is taken over into manifest.breaches at boot', function()
  local W = fresh{tag = 'br_old'}
  H.place(W, 'c1', H.dig_doc(3))
  H.runs(W, 1)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'Damp stone located', pos = {x = 11, y = 11, z = 100}})
  W.frame(1)
  local persist = H.reloaded(W)
  if type(persist.manifest) == 'table' then persist.manifest.breaches = nil end     -- written before BUG-130
  persist['m.runner'].dz = nil
  local W2 = H.world{tag = 'br_old2', persist = persist}
  W2.load(runner)
  T.eq(W2.K.manifest().breaches, {{pos = {11, 11, 100}, why = 'damp', proj = 'c1', tpl = 'fortcore'}})
end)

T.done()
