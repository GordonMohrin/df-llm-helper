-- BUG-876 (Run 17 i1 Diedplank: drink stock 0, no group holds drink: seal.job_stray returned at once, nothing was cancelled, MISSING never
-- sounded): with no drink anywhere the citizens' main group is the one to measure against. (Fort of test_bug751_752_strays.)
-- BUG-751 (Run 16c i3 Doorwings y388-y391: seven citizens died of thirst on the walkable tops of the unfinished bedroom block, a HuntVermin
-- job led them there, CUTOFF 'cause not found'): (1) CUTOFF names the wall top and the drop, and the cut citizen's job; a trip job excuses
-- a citizen for two days only; (2) the errand of a citizen on a group with drink and food whose target lies on a group without is
-- cancelled (act.cancel_stray_job), the others stay; (3) seal.separator names the tile for STRANDED.
-- BUG-752 (Run 16d i4 Pagedsculpture y386/y391: citizens 'missing in the unit list', then found dead): MISSING (A) for a citizen off the
-- map or cut off for days, once per episode, with the last position and the job.
local T = require('testlib')
local SW = require('seal_world')

local function seal()
  package.loaded['dfllm.seal'] = nil
  return require('dfllm.seal')
end
local function evs(W, t) return W.find_events(t) end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l end end
end

-- room A x2-8 y2-8 (drink, food), corridor y5, room B x12-18 y2-8; z6 above the wall at y9-10 x12-14: a walkable top (its own group),
-- one level over the floor of room B at y8
local Z = 5
local HUNT = 301
local function fort(opts)
  opts = opts or {}
  local W = SW.new{}
  df.job_type.HuntVermin, df.job_type[HUNT] = HUNT, 'HuntVermin'
  SW.fill(W, Z, 0, 0, 20, 12, '#')
  SW.fill(W, Z, 2, 2, 8, 8, '.')
  SW.fill(W, Z, 12, 2, 18, 8, '.')
  SW.fill(W, Z, 9, 5, 11, 5, '.')
  if not opts.rock then SW.fill(W, Z, 12, 9, 14, 10, 'C') end        -- a constructed wall (else natural rock) under the top
  SW.fill(W, Z + 1, 12, 9, 14, 10, '.')
  SW.draw(W, Z, {'bb'}, 3, 3)
  SW.regroup(W)
  local list = {{1, 4, 4, Z}, {2, 5, 5, Z}, {3, 14, 4, Z}, {4, 15, 5, Z}, {5, 16, 6, Z}}
  if opts.top then list[#list + 1] = {6, 13, 9, Z + 1} end
  SW.citizens(W, list)
  if not opts.nodrink then SW.item(W, 'DRINK', 6, 6, Z, 10) end
  SW.item(W, 'PLANT', 7, 7, Z, 20)
  SW.item(W, 'SEEDS', 16, 7, Z, 5)
  W.cancelled = {}
  W.act_result('cancel_stray_job', function(id)
    local u = W.unit(id)
    local j = u.job and u.job.current_job
    if not j then return true, 'no job' end
    W.cancelled[#W.cancelled + 1] = id
    u.job = {current_job = nil}
    return true, 'HuntVermin'
  end)
  if opts.setup then opts.setup(W) end
  local M = seal()
  W.load(M)
  return W, M
end

T.test('BUG-876: with no drink on any walk group an errand to a group off the main group is cancelled, an errand in the fort stays', function()
  local W = fort{nodrink = true, setup = function(W)
    W.unit(1).job = {current_job = {id = 71, job_type = HUNT, pos = {x = 13, y = 9, z = Z + 1}}}   -- the wall top
    W.unit(2).job = {current_job = {id = 72, job_type = HUNT, pos = {x = 14, y = 5, z = Z}}}        -- room B
  end}
  W.run(900, {skip = 9})
  T.eq(W.cancelled, {1}, 'old code: {} (nd == 0 returned before anything ran)')
  T.ok(W.unit(2).job.current_job ~= nil, 'the errand inside stays')
end)

T.test('BUG-876: the same fort WITH drink behaves as before (control)', function()
  local W = fort{setup = function(W)
    W.unit(1).job = {current_job = {id = 71, job_type = HUNT, pos = {x = 13, y = 9, z = Z + 1}}}
  end}
  W.run(900, {skip = 9})
  T.eq(W.cancelled, {1})
end)

T.done()
