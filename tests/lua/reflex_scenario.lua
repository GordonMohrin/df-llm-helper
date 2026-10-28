-- Scenario for tests/test_reflex_files.py: the REAL kernel (kern.lua + act.lua: door sheet forbid, lever pull jobs,
-- civ alert, FPS cap, popup dismissal) with sense, threat, siege, gate, reflex and arbiter on k_mock's fake DF
-- (tests/lua/siege_world.lua), on a fort WITHOUT a manifest (Run 9): the arrival popup, the army revealed (SIEGE,
-- INTRUDER), an ack, the army dies, RECOVERY, PEACE + SIEGE_END, then an unacked DEATHS_3PLUS (ack timeout ->
-- LOCKDOWN). Python validates every file and runs `dfllm wait` / `status` on the result.
--   python tools/luahost.py --path tests/lua tests/lua/reflex_scenario.lua <outdir>
local H = require('kern_world')
local S = require('siege_world')
local json = require('dfllm.util.json')
local kmock = require('dfllm.util.k_mock')
local kern = require('dfllm.kern')

local outdir = assert(arg[1], 'usage: reflex_scenario.lua <outdir>')
local Z = S.Z
local units = S.fort_units()
for _, u in ipairs(S.army(6, 51, 0)) do u.hidden = true; units[#units + 1] = u end
local W = H.world{dfpath = (outdir:gsub('\\', '/')), units = units, ms_per_frame = 50}
S.install(W)                                          -- bridges and linked levers exist; no manifest is persisted
df.building_type.Door = 23
local function door(id, x, y)
  local b = W.add_building{id = id, _kind = 'door', x1 = x, y1 = y, x2 = x, y2 = y, z = Z, centerx = x, centery = y,
                           door_flags = {forbidden = false}}
  b.getType = function() return df.building_type.Door end
  df.global.world.buildings.other.DOOR:insert('#', b)
end
door(501, 51, 8)
door(502, 60, 70)
W.tiles = {}
for x = 40, 70 do W.tiles[x .. ',7,' .. Z] = {des = {outside = true}} end

local snap = {name = 'snapshot', every = {ticks = 100}}
function snap.tile() return {c = '.', dig = '', bld = ''} end
function snap.far() return false end
snap.outside_near = require('dfllm.snapshot').outside_near
local care = {name = 'care', every = {ticks = 1200}}
local mods = {}
for _, n in ipairs({'sense', 'threat', 'siege', 'gate', 'reflex', 'arbiter'}) do
  package.loaded['dfllm.' .. n] = nil
  mods[#mods + 1] = require('dfllm.' .. n)
end
mods[#mods + 1] = S.military()
mods[#mods + 1] = snap
mods[#mods + 1] = care
local ok, msg = H.boot(W, {modules = mods})
assert(ok, msg)
local K = kern.K()
local function run(n, at) S.run(W, n, {at = at, frame = function(dt) H.frame(W, dt) end}) end
local function expect(mode) assert(K.mode() == mode, 'expected ' .. mode .. ', got ' .. K.mode()) end

-- 1. the arrival popup (DF 53 halts on it with pause_state false): lockdown before anyone is seen
run(200)
df.global.world.status.popups:insert('#', {text = 'A vile force of darkness has arrived!'})
run(300)
assert(#df.global.world.status.popups == 0, 'threat popup dismissed after the reflexes')
assert(math.floor(df.global.enabler.fps) == 30 and W.ts_fps == -1, 'clock held')
assert(W.buildings[501].door_flags.forbidden == true and W.buildings[502].door_flags.forbidden == false, 'doors')
-- 2. the army is revealed: SIEGE, INTRUDER (it stands on the citizens' walkable group)
run(300, {{50, function() for i = 201, 206 do W.unit(i)._m.hidden = false end end}})
expect('SIEGE')
run(600)
assert(S.bstate(W, 'O1') == 'up' and S.bstate(W, 'B1') == 'up' and S.bstate(W, 'B2') == 'up', 'all linked bridges up')
H.inbox(W, 'a1', 'ack', {}, 'cli')
run(20)
-- 3. the army dies: RECOVERY, the lockdown ends, PEACE + SIEGE_END, the bridges come down (D-14 down)
for i = 201, 206 do W.kill(i) end
run(2400 + 8400 + 1000)
expect('PEACE')
assert(S.bstate(W, 'O1') == 'down', 'lowered again in PEACE')
assert(math.floor(df.global.enabler.fps) == 250 and W.ts_fps == 500, 'clock free')
-- 4. three deaths in a day, nobody acks: after ack_timeout_s the kernel holds the clock itself (LOCKDOWN). BUG-108: at
-- threat 0 that is the old rule only with reflex.inner empty (by default an inner cause only wakes the player)
do
  K.cfg.reflex = {v = 2, inner = {}}
  local prev = W.ms_per_frame
  local st = care
  st.step = function(KK)
    if not st.done then st.done = true; KK.emit('DEATHS_3PLUS', 'A', '3 citizens died today', {n = 3, ids = {1, 2, 3}}) end
  end
  W.ms_per_frame = 500
  run(1300 + 9 * 150)
  W.ms_per_frame = prev
end
assert(math.floor(df.global.enabler.fps) == 30, 'ack timeout default: clock held')
kern.stop('scenario end')
print('scenario done')
