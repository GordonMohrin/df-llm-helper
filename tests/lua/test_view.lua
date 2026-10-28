-- FR-88 (Run 14 note 95): the verb `view` (the camera) through the arbiter and act.view_to / view_window, and FR-87's popup
-- watch (a popup that vanished without the kernel's dismiss). The tile reader and the name search are stand-ins for snapshot.
local T = require('testlib')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local kern = require('dfllm.kern')
local arbiter = require('dfllm.arbiter')
local V = require('dfllm.viewlib')
arbiter.PROFILE.overlays = true

local W, K, hidden_tiles, cam_calls

local function stub_snapshot()
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile(_, x, y, z)
    if hidden_tiles[x .. ',' .. y .. ',' .. z] or z < 0 or z > 30 then return nil end
    return {c = '.', dig = '', bld = ''}
  end
  function snap.find_units(_, query, max)
    local out, total = {}, 0
    for _, u in ipairs(df.global.world.units.active) do
      local name = dfhack.units.getReadableName(u)
      if not dfhack.units.isDead(u) and not dfhack.units.isHidden(u) and name:lower():find(query:lower(), 1, true) then
        total = total + 1
        if #out < max then out[#out + 1] = {id = u.id, name = name, x = u.pos.x, y = u.pos.y, z = u.pos.z} end
      end
    end
    return out, total
  end
  return snap
end

local function world(opts)
  opts = opts or {}
  hidden_tiles, cam_calls = {}, {}
  W = H.world{tag = opts.tag or 'view', ms_per_frame = 100, units = opts.units or {
    {id = 7, citizen = true, name = 'Oddom Letmoscog, Miner', pos = {50, 60, 10}},
    {id = 8, citizen = true, name = 'Oddom Zulban, Mason', pos = {52, 60, 10}},
    {id = 9, citizen = true, name = 'Urist Cilob, Farmer', pos = {20, 20, 12}},
    {id = 10, name = 'Goblin Ambusher', pos = {70, 70, 10}, hidden = true},
    {id = 11, citizen = true, name = 'Dead Dwarf', pos = {30, 30, 10}, dead = true},
    {id = 12, citizen = true, name = 'Offmap Dwarf', pos = {31, 30, 10}, offmap = true},
    {id = 13, name = 'Goblin Thief', pos = {77, 67, 12}}}}
  df.global.window_x, df.global.window_y, df.global.window_z = 100, 200, 5
  dfhack.gui = dfhack.gui or {}
  dfhack.gui.revealInDwarfmodeMap = function(pos, center)
    cam_calls[#cam_calls + 1] = {pos.x, pos.y, pos.z, center}
    df.global.window_x, df.global.window_y, df.global.window_z = pos.x - 30, pos.y - 20, pos.z
  end
  local ok, msg = H.boot(W, {modules = {arbiter, stub_snapshot()}})
  assert(ok, msg)
  K = kern.K()
  return W
end

local function view(id, args, by)
  H.inbox(W, id, 'view', args, by or 'llm')
  H.run(W, 5, {paused = true})
  return H.outbox(W, id)
end

local function frames(n) H.run(W, n, {paused = true}); K.flush(); H.frame(W, 0) end
-- logs and events reach the files with a delay of a few seconds of kernel time
local function settle() H.run(W, 60, {paused = true}); K.flush(); H.frame(W, 0) end

T.test('FR-88: a unit id centres the camera like a click on a report; the reply names the unit and the tile', function()
  world()
  local r = view('v1', {target = 7, why = 'the miner'})
  T.ok(r.ok, r.msg)
  T.eq(r.msg, 'camera on Oddom Letmoscog, Miner (7) at 50,60 z10')
  T.eq(cam_calls, {{50, 60, 10, true}})
  T.eq(r.data.pos, {50, 60, 10})
  T.eq({df.global.window_x, df.global.window_y, df.global.window_z}, {20, 40, 10})
  kern.stop()
end)

T.test('FR-88: the other targets: x,y,z as a list and as text, a building, a project, a part of a name', function()
  world()
  T.eq(view('p1', {target = {40, 41, 9}}).msg, 'camera on 40,41 z9')
  T.eq(view('p2', {target = '41, 42, 9'}).msg, 'camera on 41,42 z9')
  W.buildings[55] = {id = 55, centerx = 60, centery = 61, z = 8}
  T.eq(view('b1', {target = 'bld:55'}).msg, 'camera on building 55 at 60,61 z8')
  H.write(W.sd .. '/bp/y9s0b0.json', '{"id":"y9s0b0","tpl":"hospital","anchor":[33,34,11]}')
  T.eq(view('j1', {target = 'y9s0b0'}).msg, 'camera on y9s0b0 at 33,34 z11')
  local r = view('n1', {target = 'urist'})
  T.ok(r.ok and r.msg:find('Urist Cilob, Farmer (9) at 20,20 z12', 1, true), r.msg)
  r = view('n2', {target = 'oddom'})
  T.ok(not r.ok and r.msg:find('2 units match "oddom": 7 Oddom Letmoscog, Miner; 8 Oddom Zulban, Mason; give the id', 1, true), r.msg)
  r = view('n3', {target = 'nobody'})
  T.ok(not r.ok and r.msg:find('no visible living unit with "nobody" in its name', 1, true), r.msg)
  r = view('b2', {target = 'bld:99'})
  T.ok(not r.ok and r.msg:find('no building 99', 1, true), r.msg)
  kern.stop()
end)

T.test('FR-88 fair play: only tiles and units the player has seen, nothing under the map, nothing dead or off the map', function()
  world()
  hidden_tiles['40,41,9'] = true
  local r = view('h1', {target = {40, 41, 9}})
  T.ok(not r.ok and r.msg:find('is not revealed or off the map: the camera goes only where the player has seen', 1, true), r.msg)
  T.ok(not view('h2', {target = {40, 41, -1}}).ok, 'under the map')
  r = view('h3', {target = 10})
  T.ok(not r.ok and r.msg:find('unit 10 is hidden', 1, true), r.msg)
  r = view('h4', {target = 11})
  T.ok(not r.ok and r.msg:find('unit 11 is dead', 1, true), r.msg)
  r = view('h5', {target = 12})
  T.ok(not r.ok and r.msg:find('unit 12 is not on the map', 1, true), r.msg)
  hidden_tiles['50,60,10'] = true
  r = view('h6', {target = 7})
  T.ok(not r.ok and r.msg:find('unit 7: tile 50,60,10 is not revealed', 1, true), r.msg)
  T.eq(cam_calls, {}, 'no camera move for any refusal')
  r = view('h7', {target = {1, 2}})
  T.ok(not r.ok and r.msg:find('three integers', 1, true), r.msg)
  kern.stop()
end)

T.test('FR-88: in a fight the camera is the player\'s: refused unless the command is by=gordon', function()
  world()
  for _, mode in ipairs({'SIEGE', 'ALERT'}) do
    world{tag = 'fight' .. mode}
    K.set_mode(mode, 'test')
    local r = view('f' .. mode, {target = 13})
    T.ok(not r.ok and r.msg:find(mode .. ' is a fight: the camera is the player\'s', 1, true), r.msg)
  end
  T.eq(cam_calls, {})
  world()
  K.set_mode('SIEGE', 'test')
  K.set_mode('BREACH', 'test')
  T.ok(not view('fb', {target = 13}).ok, 'BREACH too')
  local r = view('fg', {target = 13}, 'gordon')
  T.ok(r.ok, r.msg)
  T.eq(cam_calls, {{77, 67, 12, true}})
  world()
  T.ok(view('fp', {target = 13}).ok)
  kern.stop()
end)

T.test('FR-88: follow re-centres when the unit walks, ends at the ttl and keeps the player\'s old position for view', function()
  world()
  local r = view('w1', {target = 7, follow = true, ttl_s = 20})
  T.ok(r.ok and r.msg:find('following for 20 s (until the player moves the camera)', 1, true), r.msg)
  T.eq({r.data.follow, r.data.ttl_s}, {true, 20})
  frames(40)
  T.eq(#cam_calls, 1, 'the unit stood still: no further centring')
  W.move(7, 52, 60, 10)                                   -- two tiles: below the re-centre distance
  frames(40)
  T.eq(#cam_calls, 1)
  W.move(7, 57, 60, 10)
  frames(40)
  T.eq(cam_calls[2], {57, 60, 10, true})
  W.move(7, 57, 60, 11)                                   -- another level follows at once
  frames(40)
  T.eq(cam_calls[3], {57, 60, 11, true})
  frames(300)                                             -- 30 s of mock time: the 20 s ttl is over
  W.move(7, 70, 60, 11)
  frames(40)
  T.eq(#cam_calls, 3, 'the follow ended at its ttl')
  settle()
  T.ok(H.read(W.sd .. '/kern.log'):find('view: follow of Oddom Letmoscog, Miner ended: ttl', 1, true))
  -- a bare view puts the camera back where the player had it before the first view (window 100,200 z5)
  r = view('w2', {})
  T.ok(r.ok and r.msg == 'camera back at 100,200 z5', r.msg)
  T.eq({df.global.window_x, df.global.window_y, df.global.window_z}, {100, 200, 5})
  r = view('w3', {})
  T.ok(not r.ok and r.msg:find('no saved player position', 1, true), r.msg)
  kern.stop()
end)

T.test('FR-88: the follow ends at once when the player moves the camera, and then nothing is given back', function()
  world()
  T.ok(view('m1', {target = 7, follow = true}).ok)
  frames(20)
  df.global.window_x = df.global.window_x + 15            -- the player scrolls
  W.move(7, 60, 60, 10)
  frames(30)
  T.eq(#cam_calls, 1, 'the camera stays where the player put it')
  settle()
  T.ok(H.read(W.sd .. '/kern.log'):find('ended: the player moved the camera', 1, true))
  local r = view('m2', {})                                -- BUG-151: it says the camera is his
  T.ok(r.ok and r.msg:find('it is his, nothing to restore', 1, true), r.msg)
  -- without a follow: the player moved the camera after a plain view; the bare view leaves it alone
  T.ok(view('m3', {target = 8}).ok)
  df.global.window_y = df.global.window_y + 20
  r = view('m4', {})
  T.ok(r.ok and r.msg:find('it is his, nothing to restore', 1, true), r.msg)
  T.eq(#cam_calls, 2)
  kern.stop()
end)

T.test('FR-88: a follow ends when the unit goes, hides, or a fight starts (not for by=gordon)', function()
  world()
  T.ok(view('e1', {target = 7, follow = true}).ok)
  W.kill(7)
  frames(30)
  settle()
  T.ok(H.read(W.sd .. '/kern.log'):find('ended: the unit is gone or hidden', 1, true))
  T.ok(view('e2', {target = 8, follow = true}).ok)
  K.set_mode('SIEGE', 'test')
  frames(30)
  settle()
  T.ok(H.read(W.sd .. '/kern.log'):find('ended: SIEGE', 1, true))
  T.ok(view('e3', {target = 8, follow = true}, 'gordon').ok)
  W.move(8, 70, 60, 10)
  frames(30)
  T.eq(cam_calls[#cam_calls], {70, 60, 10, true}, 'by=gordon follows through a fight')
  kern.stop()
end)

T.test('FR-88: follow needs a unit, the ttl is clamped by view.max_ttl_s, view.on false refuses', function()
  world()
  local r = view('c1', {target = {5, 5, 5}, follow = true})
  T.ok(r.ok and r.msg:find('follow needs a unit: centred once', 1, true), r.msg)
  r = view('c2', {target = 7, follow = true, ttl_s = 3600})
  T.eq(r.data.ttl_s, 900)
  r = view('c3', {target = 7, follow = true})
  T.eq(r.data.ttl_s, 300)
  K.cfg.baseline = K.cfg.baseline or {}
  K.cfg.baseline.view = {on = true, default_ttl_s = 60, max_ttl_s = 120}
  T.eq(view('c4', {target = 7, follow = true}).data.ttl_s, 60)
  T.eq(view('c5', {target = 7, follow = true, ttl_s = 500}).data.ttl_s, 120)
  K.cfg.baseline.view = {on = false}
  r = view('c6', {target = 7})
  T.ok(not r.ok and r.msg:find('switched off (config view.on)', 1, true), r.msg)
  K.cfg.baseline.view = {on = 'yes', default_ttl_s = 0, max_ttl_s = 99999}
  T.ok(view('c7', {target = 7}).ok, 'bad values keep the defaults')
  kern.stop()
end)

T.test('FR-88: a camera that cannot be read still centres; a DF without window_x cannot be given back', function()
  world()
  df.global.window_x, df.global.window_y, df.global.window_z = nil, nil, nil
  local r = view('d1', {target = 7})
  T.ok(r.ok, r.msg)
  r = view('d2', {})
  T.ok(not r.ok and r.msg:find('no saved player position', 1, true), r.msg)
  kern.stop()
end)

---------------------------------------------------------------- FR-87: a popup that vanished
local function gone_events()
  local n = {}
  for _, e in ipairs(H.events(W)) do if e.type == 'POPUP_GONE' then n[#n + 1] = e end end
  return n
end

T.test('FR-87: a popup that leaves without the kernel\'s dismiss is logged once (POPUP_GONE, class C); its own dismiss is not', function()
  world{tag = 'gone'}
  local popups = df.global.world.status.popups
  popups:insert('#', {text = 'Oddom Letmoscog has been cursed by Ok! He transforms.'})
  df.global.pause_state = true
  frames(8)
  T.eq(#popups, 1, 'unknown text: the kernel leaves it for the player')
  popups:erase(0)                                          -- somebody else deletes it
  frames(8)
  settle()
  local ev = gone_events()
  T.eq(#ev, 1)
  T.eq({ev[1].cls, ev[1].d.n, ev[1].d.text}, {'C', 1, 'Oddom Letmoscog has been cursed by Ok! He transforms.'})
  T.ok(H.read(W.sd .. '/kern.log'):find('popup vanished without a kernel dismiss (1): "Oddom Letmoscog has been cursed', 1, true))
  -- the same text again within the log period: no second line
  popups:insert('#', {text = 'Oddom Letmoscog has been cursed by Ok! He transforms.'})
  frames(8)
  popups:erase(0)
  frames(8)
  settle()
  T.eq(#gone_events(), 1, 'cadence: once per text and period')
  -- a whitelisted popup the kernel dismisses itself is not "gone"
  df.global.pause_state = false
  popups:insert('#', {text = 'Some migrants have arrived.'})
  df.global.pause_state = true
  frames(10)
  settle()
  T.eq(#popups, 0)
  T.eq(#gone_events(), 1, 'the kernel\'s own dismiss counts as its own')
  kern.stop()
end)

T.test('FR-88: config/baseline.json "view" mirrors viewlib.CFG (the defaults the kernel keeps for a bad value)', function()
  local F = require('wp8_world')
  T.eq(F.read_json('config/baseline.json').view, V.CFG)
end)

T.done()
