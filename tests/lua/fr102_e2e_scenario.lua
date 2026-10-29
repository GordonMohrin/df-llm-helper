-- FR-102/103 (G15) end to end in the kernel mock: the documents bp.emit writes (arg[1], a JSON file from
-- tests/test_fr102_103_rooms.py) go through bp.place and the real runner: suites and grand_temple stage 1 then their
-- beauty stage 2 at site `same`, the deep core's three stages. Not a test_*.lua: it needs the emitted documents.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')
local json = require('dfllm.util.json')
local f = assert(io.open(arg[1], 'rb'))
local D = json.decode(f:read('a'))
f:close()

local function fresh(tag)
  local W = H.world{tag = tag}
  W.load(runner)
  W.load{name = 'readiness', every = {ticks = 33600}, level = function() return 1 end}
  return W
end

local function drive(W, id)
  for _ = 1, 12 do H.runs(W, 1); H.dig(W); H.build(W) end
  H.runs(W, 3)
  return H.proj(W, id)
end

local function count(W, c)
  local n = 0
  for _, t in pairs(W.map) do if t.c == c then n = n + 1 end end
  return n
end

for _, tpl in ipairs({'suites', 'grand_temple'}) do
  T.test(tpl .. ': stage 1 builds, the beauty stage at `same` smooths and engraves, both finish', function()
    local W = fresh('e2e' .. tpl)
    H.RESULT.e = 'S'                                 -- an engraved wall stays smooth (the mock's miners)
    local r = H.place(W, 'a1', D[tpl][1])
    T.ok(r.ok, r.msg)
    T.eq(drive(W, 'a1').done, 1, tpl .. ' stage 1')
    T.eq(count(W, 'S'), 0)
    r = H.place(W, 'a2', D[tpl][2], {tpl = tpl, site = 'same'})
    T.ok(r.ok, r.msg)
    T.eq(drive(W, 'a2').done, 1, tpl .. ' stage 2')
    T.ok(count(W, 'S') > 0, 'walls smoothed')
    local s, e = 0, 0
    for _, c in ipairs(H.qf_calls(W, 'dig')) do
      H.cells(c, function(_, _, _, key)
        if key == 's' then s = s + 1 elseif key == 'e' then e = e + 1 end
      end)
    end
    T.ok(s > 0 and e > 0, 'smooth and engrave calls: ' .. s .. '/' .. e)
    H.RESULT.e = nil
  end)
end

T.test('deepcore: dig, furnish, move run one after the other at `same`', function()
  local W = fresh('e2edeep')
  for k = 1, 3 do
    local r = H.place(W, 'd' .. k, D.deepcore[k], k > 1 and {tpl = 'deepcore', site = 'same'} or nil)
    T.ok(r.ok, r.msg)
    T.eq(drive(W, 'd' .. k).done, 1, 'deep stage ' .. k)
  end
  local m = W.K.manifest()
  T.eq(#m.workshops, 6, 'the six deep workshops')
  T.eq(#m.zones.Z4, 3, 'vestibule, shaft, deep level join the core')
  local modes = {}
  for _, a in ipairs(W.applied) do modes[a.mode] = (modes[a.mode] or 0) + 1 end
  T.eq(modes.place, 1, 'the deep stockpiles')
  T.eq(modes.zone, 1, 'dormitory and dining zone')
  T.ok((modes.burrow or 0) >= 2, 'Kern+ over the shaft and the deep rooms')
end)

T.done()
