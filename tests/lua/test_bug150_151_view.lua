-- BUG-150 (live tests i1 and i2, 2026-10-28): view replies carried the raw CP437 unit name ('Kumil Cogn?ng'), viewlib read
-- getReadableName without dfhack.df2utf. BUG-151 (live test i1): after the player ended a follow by moving the camera, a
-- bare view said "no saved player position (no view has moved the camera yet)" although views had moved it.
local T = require('testlib')
local H = require('kern_world')
local kern = require('dfllm.kern')
local arbiter = require('dfllm.arbiter')
arbiter.PROFILE.overlays = true

local W, K

local function stub_snapshot()
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.find_units() return {}, 0 end
  return snap
end

local function world()
  W = H.world{tag = 'view151', ms_per_frame = 100, units = {
    {id = 7, citizen = true, name = 'Kumil Cogn\x81ng, Administrator', pos = {50, 60, 10}}}}
  df.global.window_x, df.global.window_y, df.global.window_z = 100, 200, 5
  dfhack.gui = dfhack.gui or {}
  dfhack.gui.revealInDwarfmodeMap = function(pos)
    df.global.window_x, df.global.window_y, df.global.window_z = pos.x - 30, pos.y - 20, pos.z
  end
  local ok, msg = H.boot(W, {modules = {arbiter, stub_snapshot()}})
  assert(ok, msg)
  K = kern.K()
end

local function view(id, args)
  H.inbox(W, id, 'view', args, 'llm')
  H.run(W, 5, {paused = true})
  return H.outbox(W, id)
end

T.test('BUG-150: the unit name in a view reply is converted from CP437 (dfhack.df2utf)', function()
  world()
  local df2utf = dfhack.df2utf
  dfhack.df2utf = function(s) return (tostring(s):gsub('\x81', '\xc3\xbc')) end      -- CP437 0x81 = u-umlaut
  local r = view('u1', {target = 7})
  dfhack.df2utf = df2utf
  T.ok(r.ok, r.msg)
  T.eq(r.msg, 'camera on Kumil Cogn\xc3\xbcng, Administrator (7) at 50,60 z10')
  kern.stop()
end)

T.test('BUG-151: after the player ended a follow, a bare view says the camera is his (not "no saved position")', function()
  world()
  T.ok(view('f1', {target = 7, follow = true}).ok)
  H.run(W, 20, {paused = true})
  df.global.window_x = df.global.window_x + 15                         -- the player scrolls: the follow ends
  H.run(W, 30, {paused = true})
  local r = view('f2', {})
  T.ok(r.ok, r.msg)
  T.ok(r.msg:find('the player has moved the camera since the last view: it is his, nothing to restore', 1, true), r.msg)
  r = view('f3', {})                                                   -- told once; then there is nothing saved
  T.ok(not r.ok and r.msg:find('no saved player position', 1, true), r.msg)
  -- a new view series starts clean
  T.ok(view('f4', {target = 7}).ok)
  r = view('f5', {})
  T.ok(r.ok and r.msg:find('camera back at', 1, true), r.msg)
  kern.stop()
end)

T.done()
