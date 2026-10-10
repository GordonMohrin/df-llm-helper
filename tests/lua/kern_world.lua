-- Test harness (WP1): the real kernel (lua/dfllm/kern.lua) on k_mock's fake df/dfhack globals,
-- with real files in a temp DF folder. Frames are driven by calling the repeat-util callback.
--   local H = require('kern_world')
--   local W = H.world{marker = true}; H.boot(W, {modules = {...}}); H.run(W, 100, {skip = 9})
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

local H = {}
local SCRIPT = (arg and arg[0] or 'lua'):match('([^/\\]+)%.lua$') or 'lua'

local function wipe(dir)   -- delete the files below dir (directories stay and are reused)
  for _, n in ipairs(luahost.listdir(dir)) do
    local p = dir .. '/' .. n
    if luahost.isdir(p) then wipe(p) else os.remove(p) end
  end
end

-- a fixed, emptied folder per test file and tag: repeated runs do not pile up temp dirs
function H.tmpdir(tag)
  local base = (os.getenv('TEMP') or os.getenv('TMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests'
  local d = string.format('%s/%s-%s', base, SCRIPT, tag or 't')
  luahost.mkdir_recursive(d)
  wipe(d)
  return d
end

function H.read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

function H.write(path, s)
  local f = assert(io.open(path, 'wb'))
  f:write(s)
  f:close()
end

-- a k_mock world plus the DF fakes the kernel files need
function H.world(opts)
  opts = opts or {}
  local kern = package.loaded['dfllm.kern']
  if kern and kern.running() then kern.stop('test reset') end
  local dir = opts.dfpath or H.tmpdir(opts.tag)
  local W = kmock.new{dfpath = dir, save = opts.save or 'region1', marker = opts.marker, year = opts.year,
                      ytick = opts.ytick, units = opts.units, persist = opts.persist, ms = opts.ms or 100000}
  W.dir = dir
  -- the kernel's cost clock (os.clock in game) follows the mock ms, so tests that advance W.ms inside
  -- a step simulate slow calls deterministically
  require('dfllm.kern').cost_clock = function() return W.ms end
  W.rt = dir .. '/dfllm-runtime'
  W.sd = W.rt .. '/' .. (opts.save or 'region1')
  W.ms_per_frame = opts.ms_per_frame or 16
  local g = df.global
  g.world.status.popups = kmock.vec{}
  g.world.manager_orders = {all = kmock.vec{}, manager_order_next_id = 1}
  df.d_init_autosave = kmock.enum{'NONE', 'SEASONAL', 'YEARLY'}
  g.d_init.feature.autosave = df.d_init_autosave.SEASONAL
  g.d_init.feature.flags = {WEATHER = true}
  _G.SC_MAP_UNLOADED = 3
  -- timestream and overlay plugins
  W.ts_fps = opts.ts_fps or 250
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.ts_fps end}
  W.ov = opts.overlays or {['hotkeys.menu'] = {enabled = true}, ['notify.panel'] = {enabled = true},
                           ['unsuspend.overlay'] = {enabled = true}, ['spare.widget'] = {enabled = false}}
  local index = {}
  for n in pairs(W.ov) do index[#index + 1] = n end
  table.sort(index)
  package.loaded['plugins.overlay'] = {
    get_state = function() return {index = index, config = W.ov} end,
    isOverlayEnabled = function(n) return W.ov[n] ~= nil and W.ov[n].enabled end,
  }
  -- commands with effects (k_mock records them in W.commands)
  local orig = dfhack.run_command_silent
  dfhack.run_command_silent = function(cmd, ...)
    local a = {...}
    local out, cr = orig(cmd, ...)
    if cmd == 'timestream' and a[1] == 'set' and a[2] == 'fps' then W.ts_fps = math.tointeger(tonumber(a[3])) end
    if cmd == 'overlay' then
      for i = 2, #a do if W.ov[a[i]] then W.ov[a[i]].enabled = (a[1] == 'enable') end end
    end
    if cmd == 'pop-control' and a[1] == 'set' and a[2] == 'max-pop' then
      g.d_init.dwarf.population_cap = math.tointeger(tonumber(a[3]))
    end
    if W.on_command then return W.on_command(cmd, a, out, cr) end
    return out, cr
  end
  return W
end

function H.kern() return require('dfllm.kern') end

function H.boot(W, opts)
  opts = opts or {}
  return H.kern().boot{repo = opts.repo or W.dir, modules = opts.modules, strict = opts.strict ~= false}
end

-- one frame: dt game ticks (0 or paused = none), ms real milliseconds
function H.frame(W, dt, ms)
  local g = df.global
  dt = dt or 1
  if dt > 0 and not g.pause_state then
    g.cur_year_tick = g.cur_year_tick + dt
    while g.cur_year_tick >= 403200 do g.cur_year_tick = g.cur_year_tick - 403200; g.cur_year = g.cur_year + 1 end
  end
  W.ms = W.ms + (ms or W.ms_per_frame)
  local r = W.repeats and W.repeats.dfllm
  assert(r, 'kernel callback not scheduled')
  r[3]()
end

-- frames of opts.skip ticks until `ticks` passed; {paused = true}: `ticks` frames without ticks
function H.run(W, ticks, opts)
  opts = opts or {}
  if opts.paused then
    for _ = 1, ticks do H.frame(W, 0, opts.ms) end
    return
  end
  local skip, done = opts.skip or 1, 0
  while done < ticks do
    local step = math.min(skip, ticks - done)
    H.frame(W, step, opts.ms)
    done = done + step
  end
end

function H.json(path)
  local s = H.read(path)
  return s and json.decode(s)
end

-- the state document a reader would pick (both slots, highest valid seq)
function H.state(W)
  local best
  for _, s in ipairs({'a', 'b'}) do
    local d = json.try_decode(H.read(W.sd .. '/state.' .. s .. '.json') or '')
    if type(d) == 'table' and (not best or d.seq > best.seq) then best = d end
  end
  return best
end

function H.events(W, file)
  local r = {}
  local s = H.read(W.sd .. '/' .. (file or 'events.jsonl')) or ''
  for line in s:gmatch('([^\n]+)\n') do r[#r + 1] = json.decode(line) end
  return r
end

function H.find(list, etype)
  local r = {}
  for _, e in ipairs(list) do if e.type == etype then r[#r + 1] = e end end
  return r
end

function H.lines(path)
  local r = {}
  for line in (H.read(path) or ''):gmatch('([^\n]+)\n') do r[#r + 1] = line end
  return r
end

H.ts = 1791676800000
function H.inbox(W, id, verb, args, by, raw)
  H.ts = H.ts + 1
  local name = string.format('%013d-%s.json', H.ts, id)
  if args == nil or (type(args) == 'table' and next(args) == nil and not json.is_array(args)) then args = json.object{} end
  local body = raw or json.encode({id = id, verb = verb, args = args, by = by or 'test'})
  H.write(W.sd .. '/inbox/' .. name, body)
  return name
end

function H.outbox(W, id) return H.json(W.sd .. '/outbox/' .. id .. '.json') end

-- a counting test module
function H.counter(name, every, extra)
  local M = {name = name, every = every, runs = {}}
  function M.step(K, budget, ctx) M.runs[#M.runs + 1] = {tick = K.now().tick, ms = K.now().ms, ctx = ctx} end
  for k, v in pairs(extra or {}) do M[k] = v end
  return M
end

return H
