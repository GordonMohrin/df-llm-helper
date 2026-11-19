-- BUG-780: see the body
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
  SW.item(W, 'DRINK', 6, 6, Z, 10)
  SW.item(W, 'PLANT', 7, 7, Z, 20)
  SW.item(W, 'SEEDS', 16, 7, Z, 5)
  W.cancelled, W.labors = {}, {}
  W.act_result('labor_set', function(id, which, on) W.labors[#W.labors + 1] = {id, which, on}; return true, 'disabled' end)
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


-- BUG-780 (Run 16c i3 Lancemoment y380: the militia captain 26415 took a HuntVermin job and walked 90 tiles into the cavern level, died of thirst):
-- seal cancels the hunt of a squad member at once, and a vermin hunt that leads far from the citizens inside; a hunt near the fort stays.
local function squad(W, id) W.unit(id).military = {squad_id = 5} end

T.test('BUG-780: the hunt of a squad member is cancelled wherever it leads, a civilian hunt inside stays', function()
  local W = fort{setup = function(W)
    squad(W, 1)
    W.unit(1).job = {current_job = {id = 71, job_type = HUNT, pos = {x = 14, y = 5, z = Z}}}   -- room B: near
    W.unit(2).job = {current_job = {id = 72, job_type = HUNT, pos = {x = 15, y = 5, z = Z}}}   -- a civilian, near
  end}
  W.run(900, {skip = 9})
  T.eq(W.cancelled, {1})
  T.ok(W.unit(2).job.current_job ~= nil, 'the civilian hunt in the fort stays')
  T.ok(logged(W, 'a squad member does not hunt'), 'kern.log names it')
  T.eq(W.labors, {{1, 'hunt', false}}, 'his Hunting labor goes off, else the next hunt starts at once')
  W.unit(1).job = {current_job = {id = 75, job_type = HUNT, pos = {x = 14, y = 5, z = Z}}}   -- a new hunt the same day
  W.run(900, {skip = 9})
  T.eq(W.cancelled, {1, 1}, 'cancelled again at the next look, not a day later')
end)

T.test('BUG-780: a squad member on another job (no hunt) is left alone, his labors too', function()
  local W = fort{setup = function(W)
    squad(W, 2)
    W.unit(2).job = {current_job = {id = 81, job_type = df.job_type.Dig or 1, pos = {x = 100, y = 5, z = Z}}}
  end}
  W.run(900, {skip = 9})
  T.ok(W.unit(2).job.current_job ~= nil, 'no hunt, no cancel')
  T.eq(W.labors, {})
end)

T.test('BUG-780: a vermin hunt 90 tiles from the citizens inside is cancelled', function()
  local W = fort{setup = function(W)
    W.unit(3).job = {current_job = {id = 73, job_type = HUNT, pos = {x = 100, y = 5, z = Z}}}
    W.unit(4).job = {current_job = {id = 74, job_type = HUNT, pos = {x = 14, y = 5, z = Z - 12}}}   -- twelve levels down
  end}
  W.run(900, {skip = 9})
  T.eq(#W.cancelled, 2)
  T.ok(logged(W, 'the vermin hunt leads'), 'kern.log names it')
end)

T.done()
