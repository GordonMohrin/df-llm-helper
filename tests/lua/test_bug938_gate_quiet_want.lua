-- BUG-938 (test debt of round 19b, BUG-928 verifier): the quiet-want branch of gate.lua check_fail. A want `peace_gates` / `window_end` that is left over in an ALERT /
-- RECOVERY (no lockdown) carries the age of the PEACE it came from: past its deadline and not raised ('down' / 'moving') the bridge is `failed` and has its kpi.fails entry,
-- but no GATE_FAIL (class A); a raised bridge is never failed. The state is read directly (the gate's own st / rt upvalues). No behaviour of gate.lua is changed.
local T = require('testlib')
local S = require('siege_world')
local B = require('b1_world')
local Z = S.Z
local G

local function upvalue(fn, name)
  local i = 1
  while true do
    local n, v = debug.getupvalue(fn, i)
    if not n then return nil end
    if n == name then return v end
    i = i + 1
  end
end

local function b1_fails(W)
  local r = {}
  for _, e in ipairs(W.find_events('GATE_FAIL')) do if e.d.bridge == 'B1' then r[#r + 1] = e end end
  return r
end
local function kfails(W)
  local fl = {}
  for _, f in ipairs(G.kpi(W.K).fails or {}) do if f:sub(1, 3) == 'B1:' then fl[#fl + 1] = f end end
  return fl
end

local function up_world()
  local W = B.build{mode = 'PEACE', lock = nil, base = false, closed = {B1 = true}, cfg = {decisions = {['D-14'] = 'up'}, reflex = {v = 2, gate = {peace_clear = 0, peace_clear_r = 2}}}, actors = {}, army = {}}
  B.run(W, 1500)
  G = package.loaded['dfllm.gate']
  local st, rt = upvalue(G.not_up, 'st'), upvalue(G.not_up, 'rt')
  T.eq({st.br.B1.want, st.br.B1.why, st.br.B1.failed, rt.B1.last}, {'up', 'peace_gates', false, 'up'}, 'the PEACE want: B1 up, peace_gates')
  return W, st, rt
end

-- B1 is lowered from outside (the player's lever) while the want left over from PEACE stands in the ALERT; its PEACE deadline passes with the bridge not up
for _, mode in ipairs({'ALERT', 'RECOVERY'}) do
  T.test('BUG-938: the quiet-want branch of check_fail in ' .. mode .. ': a lowered B1 past its PEACE deadline is failed with its kpi.fails entry and NO GATE_FAIL', function()
    local W, st, rt = up_world()
    if mode == 'RECOVERY' then                          -- PEACE > RECOVERY is no transition: the way is a siege that ends
      W.K.set_mode('ALERT', 'test: alert first'); B.run(W, 50); W.K.set_mode('SIEGE', 'test: siege'); B.run(W, 50)
      W.K.set_mode('RECOVERY', 'test: the siege is over'); B.run(W, 50)
      W.bridges.B1.gate_flags.closed = true; B.run(W, 50)
      st.br.B1.want, st.br.B1.why, st.br.B1.deadline = 'up', 'peace_gates', W.K.now().tick - 100   -- the leftover quiet want (by hand: SIEGE / RECOVERY rewrite it)
      st.br.B1.failed = false
    else
      W.K.set_mode(mode, 'test: leftover quiet want')
      B.run(W, 100)
    end
    T.eq(st.br.B1.why, 'peace_gates', 'the want is carried over')
    T.eq(st.br.B1.failed, false)
    W.bridges.B1.gate_flags.closed = false
    local seen, first = nil, nil
    for _ = 1, 160 do
      B.run(W, 10)
      if st.br.B1.failed and not first then first = rt.B1.last end
      if first then break end
    end
    T.ok(first ~= nil, 'check_fail marked it failed')
    T.ok(first == 'down' or first == 'moving', 'while it was not up: ' .. tostring(first))
    T.eq(st.br.B1.failed, true)
    local kf = kfails(W)
    T.eq(#kf, 1, 'the kpi.fails entry stays (siege failed_bridge, drill reports read it): ' .. table.concat(kf, ','))
    T.ok(kf[1]:find('^B1:%a'), kf[1])
    T.eq(#b1_fails(W), 0, 'no GATE_FAIL (class A) for a leftover PEACE age')
    B.run(W, 600)
    T.eq(#b1_fails(W), 0, 'still none')
    T.eq(#kfails(W), 1, 'one entry, not one per look')
    T.eq(#W.crushed, 0)
  end)
end

T.test('BUG-938: a raised B1 in an ALERT with a stale PEACE deadline stays failed = false (r.last up returns first)', function()
  local W, st, rt = up_world()
  W.K.set_mode('ALERT', 'test: a lone plant eater')
  B.run(W, 100)
  st.br.B1.deadline = W.K.now().tick - 5000            -- the age of the PEACE the want came from
  B.run(W, 800)
  T.eq({st.br.B1.want, st.br.B1.why}, {'up', 'peace_gates'})
  T.eq(rt.B1.last, 'up')
  T.eq(st.br.B1.failed, false, 'a raised bridge is never failed')
  T.eq(#kfails(W), 0)
  T.eq(#b1_fails(W), 0)
  local nb
  for _, x in ipairs(G.not_up(W.K) or {}) do if x.bridge == 'B1' then nb = x end end
  T.eq(nb, nil, 'not in not_up')
end)

T.done()
