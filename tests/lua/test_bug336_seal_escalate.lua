-- BUG-336 (Run 15b Earthboat y384-y387, i3): seal y384s1b0, the refuge hatch 55,82,133, stood 'BLOCKED:stalled 0%' for 911
-- days ('job 205434 not suspended, no builder has taken it'); SEAL_STUCK came, the re-place (BUG-274) ran once, then nothing:
-- BUG-328 would now set it aside as well. 5 trolls walked down the open stair into Tiefe+, 92 -> 1. A stuck seal without
-- progress for seal_first.esc_days asks the player (DECISION_NEEDED seal_stalled) with the piece, the cause and the
-- commands, again every esc_days while it stays so; the refuge's seal is never set aside. Every test fails on b35af6d.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local SX, SY, Z = 114, 73, 143
local CFG0 = {}
local S_AT                      -- the tile the fake seal.refuge_alt was asked for
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function row(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end
end
local function asks(W)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'seal_stalled' then r[#r + 1] = e end end
  return r
end

-- o.refuge: a fake seal whose refuge stair column is the piece's x,y
local function world(o)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = o.tag, map_size = {16, 16, 160},
                    cfg = {baseline = {v = 2, runner = {seal_first = {esc_days = 5}, queue = {idle_days = 5}}}}}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, SX, SY, Z, SX, SY)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  if o.refuge then
    W.load({name = 'seal', every = {ticks = 100000},
            refuge_stair = function(K) return {state = 'ok', pos = {SX, SY, Z}, man = {SX, SY, Z}} end,
            refuge_alt = o.alt and function(K, at) S_AT = at; return o.alt end or nil})
  end
  W.load(runner)
  W.state()
  return W
end

local function seal_doc(key)
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = SX .. ',' .. SY .. ',' .. Z .. ' floor'},
          anchor = {SX, SY, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {SX, SY, Z}, cells = {{0, 0, 0, key}}}}}},
          manifest = {v = 2}, materials = {[key == 'H' and 'hatch' or 'door'] = 1}}
end

T.test('BUG-336: a perimeter seal door nobody builds: after esc_days DECISION_NEEDED seal_stalled names the piece and ' ..
       'the wall command (old: SEAL_STUCK once, then silence), again after another esc_days, never on every run', function()
  local W = world{tag = 'b336p'}
  H.place(W, 'sl', seal_doc('d'))
  local runs = 0
  while #asks(W) == 0 and runs < 40 do H.runs(W, 1); runs = runs + 1 end
  local a = asks(W)
  T.eq(#a, 1, 'asked after ' .. runs .. ' runs')
  T.ok(#W.find_events('SEAL_STUCK') >= 1, 'SEAL_STUCK came first')
  T.eq(a[1].cls, 'A')
  T.ok(a[1].d.n >= 5, T.show(a[1].d))
  T.eq(a[1].d.mat, 'door 114,73,143')
  T.ok(a[1].d.q:find('^seal sl: door 114,73,143 open %d+ d'), a[1].d.q)
  T.ok(a[1].d.q:find('the way in stays open', 1, true), a[1].d.q)
  T.eq(a[1].d.proj, 'sl')
  -- review: the command the CLI schema takes (bp.place needs site; old: '{"tpl":"seal","at":...}' -> $.args.site: missing)
  T.eq(a[1].d.cmd, [[dfllm cmd bp.cancel '{"proj":"sl"}' then dfllm cmd bp.place ]] ..
                   [['{"tpl":"seal","site":"S1","p":{"at":"114,73,143 floor","close":"wall"}}']])
  T.ok(a[1].d.how:find('wall the tile', 1, true), a[1].d.how)
  H.runs(W, 4)
  T.eq(#asks(W), 1, 'not again within esc_days')
  H.runs(W, 8)
  T.eq(#asks(W), 2, 'again after another esc_days')
  H.build(W)
  H.runs(W, 6)                                         -- set aside by then: measured every meas_every
  T.eq(H.proj(W, 'sl').done, 1)
end)

T.test('BUG-336: the refuge hatch nobody builds: never set aside (old: set aside after idle_days, BUG-328), the question ' ..
       'says the refuge is not the civilians\' burrow in a fight; review: never bp.place at=refuge on the same head again',
       function()
  local W = world{tag = 'b336r', refuge = true}
  H.place(W, 'rf', seal_doc('H'))
  for _ = 1, 24 do H.runs(W, 1) end
  T.ok(not ((row(W, 'rf') or {})[4] or ''):find('^set aside'), T.show(row(W, 'rf')))
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do T.eq(e.d.idle, nil, 'no set-aside PROJECT_BLOCKED') end
  local a = asks(W)
  T.ok(#a >= 1, 'asked')
  T.eq(a[1].d.mat, 'hatch 114,73,143')
  T.ok(a[1].d.q:find("the refuge is NOT the civilians' burrow in a fight until it stands", 1, true), a[1].d.q)
  T.eq(a[1].d.cmd, nil, 'no bp.place on the same head')
  T.ok(a[1].d.how:find('placing it again at the same head does not help', 1, true), a[1].d.how)
end)

T.test('BUG-336 review: the refuge hatch stalled where the map now shows another head (BUG-313 moved it up a walled-in ' ..
       'shaft): the question names that tile and the schema-valid bp.place at=refuge', function()
  local W = world{tag = 'b336m', refuge = true, alt = {head = {SX, SY, Z + 2}, moved = true, boxed = true}}
  H.place(W, 'rf', seal_doc('H'))
  local runs = 0
  while #asks(W) == 0 and runs < 40 do H.runs(W, 1); runs = runs + 1 end
  local a = asks(W)
  T.ok(#a >= 1, 'asked')
  T.eq(S_AT, {SX, SY, Z}, 'refuge_alt gets the stalled piece')
  T.ok(a[1].d.how:find('place it at the head the map shows now (114,73,145)', 1, true), a[1].d.how)
  T.eq(a[1].d.cmd, [[dfllm cmd bp.cancel '{"proj":"rf"}' then dfllm cmd bp.place ]] ..
                   [['{"tpl":"seal","site":"S1","p":{"at":"refuge"}}']])
end)

T.test('BUG-336 review: the refuge hatch stalled on the head the map shows (no other tile): the doors round the stair ' ..
       'foot on the refuge floor, one bp.place with their tiles; boxed names the cause', function()
  local W = world{tag = 'b336f', refuge = true,
                  alt = {head = {SX, SY, Z}, boxed = true, foot = {'115,73,141 floor', '114,74,141 floor'}}}
  H.place(W, 'rf', seal_doc('H'))
  local runs = 0
  while #asks(W) == 0 and runs < 40 do H.runs(W, 1); runs = runs + 1 end
  local a = asks(W)
  T.ok(#a >= 1, 'asked')
  T.ok(a[1].d.how:find('build it by hand in DF (no tile beside it to build from), or cancel it and put doors round ' ..
                       'the stair foot', 1, true), a[1].d.how)
  T.eq(a[1].d.cmd, [[dfllm cmd bp.cancel '{"proj":"rf"}' then dfllm cmd bp.place ]] ..
                   [['{"tpl":"seal","site":"S1","p":{"at":"115,73,141 floor;114,74,141 floor"}}']])
end)

T.done()
