-- Test world for lua/dfllm/runner.lua (WP7): k_mock + a fake map (256 x 256 x 128), a fake quickfort
-- (W.act_result) that designates/builds on that map, a fake snapshot module (tile) and dwarf
-- simulators (dig, build).
--   local H = require('runner_world')
--   local W = H.world{tag = 'x'}; W.load(require('dfllm.runner')); H.place(W, 'c1', H.doc())
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

local H = {}
local SCRIPT = (arg and arg[0] or 'lua'):match('([^/\\]+)%.lua$') or 'lua'
H.RESULT = {d = '.', h = '_', u = '<', j = '>', i = 'X', r = 'r', s = 'S', F = 'F'}

local function wipe(dir)
  for _, n in ipairs(luahost.listdir(dir)) do
    local p = dir .. '/' .. n
    if luahost.isdir(p) then wipe(p) else os.remove(p) end
  end
end

function H.tmpdir(tag)
  local base = (os.getenv('TEMP') or os.getenv('TMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests'
  local d = string.format('%s/%s-%s', base, SCRIPT, tag or 't')
  luahost.mkdir_recursive(d)
  wipe(d)
  return d
end

function H.write(path, s)
  local f = assert(io.open(path, 'wb'))
  f:write(s)
  f:close()
end

-- every cell of a quickfort call: fn(x, y, z, key, w, h, text) in absolute coordinates
function H.cells(p, fn)
  local px, py, pz = 0, 0, 0
  if p.pos then px, py, pz = p.pos.x or p.pos[1], p.pos.y or p.pos[2], p.pos.z or p.pos[3] end
  local list = {}
  for dz, g in pairs(p.data) do
    for dy, row in pairs(g) do
      for dx, text in pairs(row) do list[#list + 1] = {px + dx, py + dy, pz + dz, text} end
    end
  end
  table.sort(list, function(a, b)
    if a[3] ~= b[3] then return a[3] < b[3] end
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
  for _, c in ipairs(list) do
    local text = c[4]
    local w, h = text:match('%((%-?[0-9]+)x(%-?[0-9]+)%)')
    fn(c[1], c[2], c[3], text:match('^[^{(:/]*'), tonumber(w) or 1, tonumber(h) or 1, text)
  end
end

local MINE = {d = true, h = true, u = true, j = true, i = true, r = true}
local function on_map(x, y, z) return dfhack.maps.isValidTilePos(x, y, z) end
local function on_edge(x, y, z)
  return not (on_map(x - 1, y, z) and on_map(x + 1, y, z) and on_map(x, y - 1, z) and on_map(x, y + 1, z))
end

-- quickfort's designation rules that matter here (dig.lua:171-180 do_mine, :288-297 do_smooth,
-- :309-314 do_fortification): mine keys designate hidden tiles but never the map edge; smoothing needs
-- a visible hard wall (W.soil marks soil), a fortification a smooth wall
local function diggable(W, t, key, x, y, z)
  if MINE[key] then return not on_edge(x, y, z) and (t.hidden or t.c == '#' or t.c == 'S') end
  if t.hidden then return false end
  if key == 's' then return t.c == '#' and not W.soil[x .. ',' .. y .. ',' .. z] end
  if key == 'F' then return t.c == 'S' end
  return t.c == '#' or t.c == 'S'
end

local function building(W, x, y, z, key)
  local id = df.global.building_next_id
  df.global.building_next_id = id + 1
  local cons = key:sub(1, 1) == 'C'
  W.add_building{id = id, _t = cons and df.building_type.Construction or df.building_type.Bed, _st = 0,
                 _pos = {x, y, z}, _key = key,
                 getType = function(self) return self._t end,
                 getBuildStage = function(self) return self._st end,
                 getMaxBuildStage = function() return 1 end}
  W.bld_at[x .. ',' .. y .. ',' .. z] = id
end

-- manager orders as act.quickfort returns them once it runs orders.create_orders: one array entry per
-- material = its quantity (orders.lua:162-165); W.orders_unfixed = apply_blueprint alone (no entries)
local function fake_orders(W, p)
  W.orders[#W.orders + 1] = p
  local st = {invalid_keys = 0}
  if W.orders_unfixed then return st end
  local per, keys = {}, {}
  H.cells(p, function(_, _, _, key)
    if not per[key] then per[key] = 0; keys[#keys + 1] = key end
    per[key] = per[key] + 1
  end)
  table.sort(keys)
  for i, k in ipairs(keys) do st[i] = per[k] end
  return st
end

-- the fake quickfort.apply_blueprint behind act.quickfort; returns ok, stats (act.lua:402-407 shape)
-- W.qf_fail fails every call, W.qf_fail_cmd only calls with that command
function H.fake_qf(W, p)
  W.qf[#W.qf + 1] = {mode = p.mode, command = p.command or 'run', dry = p.dry_run == true, frame = W.frame_n,
                     pos = p.pos, data = p.data, priority = p.priority}
  local cmd = p.command or 'run'
  if W.qf_fail or W.qf_fail_cmd == cmd then return false, 'quickfort failed' end
  local st = {invalid_keys = 0, out_of_bounds = 0}
  if p.mode == 'dig' then
    st.dig_designated, st.dig_invalid_tiles = 0, 0
    H.cells(p, function(x, y, z, key, w, h)
      for yy = 0, h - 1 do
        for xx = 0, w - 1 do
          local tx, ty = x + xx, y + yy
          local t = W.tile(tx, ty, z)
          if not on_map(tx, ty, z) then
            st.out_of_bounds = st.out_of_bounds + 1
          elseif cmd == 'undo' then
            if t.dig ~= '' then t.dig = ''; st.dig_designated = st.dig_designated + 1 end
          elseif diggable(W, t, key, tx, ty, z) then
            st.dig_designated = st.dig_designated + 1
            if not p.dry_run and cmd == 'run' then t.dig = key end
          else
            st.dig_invalid_tiles = st.dig_invalid_tiles + 1
          end
        end
      end
    end)
  elseif p.mode == 'build' then
    st.build_designated, st.build_unsuitable = 0, 0
    if cmd == 'orders' then return true, fake_orders(W, p) end
    H.cells(p, function(x, y, z, key, w, h)
      local tiles = key:sub(1, 1) == 'C' and w * h or 1
      for i = 0, tiles - 1 do
        local tx, ty = x + i % w, y + i // w
        local k = tx .. ',' .. ty .. ',' .. z
        if cmd == 'undo' then
          local id = W.bld_at[k]
          if id then W.buildings[id] = nil; W.bld_at[k] = nil; W.undone = W.undone + 1 end
        elseif W.unsuitable[k] or W.bld_at[k] or W.tile(tx, ty, z).c ~= '.' then
          st.build_unsuitable = st.build_unsuitable + 1
        elseif not p.dry_run then
          building(W, tx, ty, z, key)
          st.build_designated = st.build_designated + 1
        end
      end
    end)
  else
    W.applied[#W.applied + 1] = {mode = p.mode, command = cmd}
  end
  return true, st
end

-- opts: tag, year, ytick, mode, plan, phases, census, persist, snapshot (false = no module), cfg, strict
function H.world(opts)
  opts = opts or {}
  local dir = opts.dfpath or H.tmpdir(opts.tag)
  local W = kmock.new{dfpath = dir, save = 'region1', year = opts.year or 3, ytick = opts.ytick or 0,
                      mode = opts.mode, plan = opts.plan, phases = opts.phases, census = opts.census,
                      persist = opts.persist, strict = opts.strict, cfg = opts.cfg, marker = opts.marker}
  W.dir, W.sd = dir, dir .. '/dfllm-runtime/region1'
  luahost.mkdir_recursive(W.sd .. '/bp')
  W.map_size = opts.map_size or {16, 16, 128}     -- blocks: 256 x 256 x 128 tiles (k_mock isValidTilePos)
  W.map, W.unsuitable, W.bld_at, W.qf, W.orders, W.applied, W.undone = {}, {}, {}, {}, {}, {}, 0
  W.soil = {}
  df.global.building_next_id = opts.next_id or 1
  df.building_type = kmock.enum{'Chair', 'Bed', 'Table', 'Door', 'Construction', 'Trap', 'Workshop'}
  function W.tile(x, y, z)
    local k = x .. ',' .. y .. ',' .. z
    local t = W.map[k]
    if not t then t = {c = '#', dig = ''}; W.map[k] = t end
    return t
  end
  W.act_result('quickfort', function(p) return H.fake_qf(W, p) end)
  if opts.snapshot ~= false then
    W.snap = W.load{name = 'snapshot', every = {ticks = 100}, calls = 0,
                    tile = function(K, x, y, z)
                      W.snap.calls = W.snap.calls + 1
                      if W.snap_fail then error('snapshot broken') end
                      if not on_map(x, y, z) then return nil end
                      local t = W.tile(x, y, z)
                      if t.hidden then return nil end
                      return {c = t.c, dig = t.dig, bld = W.bld_at[x .. ',' .. y .. ',' .. z] and 'Bed' or ''}
                    end}
  end
  return W
end

-- miners: dig up to n designated tiles (sorted, deterministic)
function H.dig(W, n)
  local keys = {}
  for k, t in pairs(W.map) do if t.dig ~= '' then keys[#keys + 1] = k end end
  table.sort(keys)
  for i = 1, math.min(n or #keys, #keys) do
    local t = W.map[keys[i]]
    t.c, t.dig, t.hidden = H.RESULT[t.dig] or '.', '', nil
  end
  return math.min(n or #keys, #keys)
end

-- builders: finish every placed building (constructions turn into 'C' tiles and vanish as buildings)
function H.build(W)
  for id, b in pairs(W.buildings) do
    if b._t == df.building_type.Construction then
      W.buildings[id] = nil
      W.bld_at[table.concat(b._pos, ',')] = nil
      W.tile(b._pos[1], b._pos[2], b._pos[3]).c = 'C'
    else
      b._st = 1
    end
  end
end

-- floor tiles under a bbox (pre-dug ground for build-only docs)
function H.floor(W, x0, y0, z, x1, y1)
  for y = y0, y1 do for x = x0, x1 do W.tile(x, y, z).c = '.' end end
end

-- a small project: dig 2 chunks (2 rows of 5), build (2 beds, 1 wall), zone, burrow
function H.doc(o)
  o = o or {}
  local x, y, z = o.x or 10, o.y or 10, o.z or 100
  local pre = o.prefix or ''
  return {v = 2, tpl = o.tpl or 'bedrooms', site = 'S1', class = o.class or 'living', params = o.params or {n = 2},
          anchor = {x, y, z}, rot = 0,
          stages = {
            {label = pre .. 'dig', mode = 'dig', orders = 0, defense = 0,
             chunks = {{pos = {x, y, z}, cells = {{0, 0, 0, 'd(5x1)'}}}, {pos = {x, y + 1, z}, cells = {{0, 0, 0, 'd(5x1)'}}}}},
            {label = pre .. 'build', mode = 'build', orders = 1, defense = o.defense or 0,
             chunks = {{pos = {x, y, z}, cells = {{0, 0, 0, 'b'}, {4, 0, 0, 'b'}, {2, 1, 0, 'Cw'}}}}},
            {label = pre .. 'zone', mode = 'zone', orders = 0, defense = 0,
             chunks = {{pos = {x, y, z}, cells = {{0, 0, 0, 'b(5x2)'}}}}},
            {label = pre .. 'burrow', mode = 'burrow', orders = 0, defense = 0,
             chunks = {{pos = {x, y, z}, cells = {{0, 0, 0, 'a{name=Kern+ create=true}(5x2)'}}}}},
          },
          manifest = o.manifest or {v = 2, rooms = {{id = 'r' .. x, tpl = o.tpl or 'bedrooms', use = 'used',
                                                     bbox = {x, y, z, x + 4, y + 1, z}, tier = 500}}},
          materials = {bed = 2}}
end

-- a dig-only project of n chunks (one row of 5 tiles each, rows y, y+1, ...)
function H.dig_doc(n, o)
  o = o or {}
  local x, y, z = o.x or 10, o.y or 10, o.z or 100
  local chunks = {}
  for i = 0, n - 1 do chunks[#chunks + 1] = {pos = {x, y + i, z}, cells = {{0, 0, 0, (o.key or 'd') .. '(5x1)'}}} end
  return {v = 2, tpl = o.tpl or 'fortcore', site = 'S1', class = o.class or 'infra', params = o.params or {stage = 1},
          anchor = {x, y, z}, rot = 0,
          stages = {{label = o.label or 's1.dig', mode = 'dig', orders = 0, defense = 0, chunks = chunks}},
          manifest = o.manifest or {v = 2}, materials = {}}
end

function H.put(W, id, d)
  d.id = id
  H.write(W.sd .. '/bp/' .. id .. '.json', json.encode(d))
end

function H.place(W, id, d, args)
  H.put(W, id, d)
  return W.inbox('bp.place', args or {tpl = d.tpl, site = 'S1'}, {id = id})
end

function H.proj(W, id)
  local pd = W.K.persist.get('projects')
  for _, P in ipairs(pd and pd.list or {}) do if P.id == id then return P end end
end

function H.qf_calls(W, mode, command)
  local r = {}
  for _, c in ipairs(W.qf) do
    if (mode == nil or c.mode == mode) and (command == nil or c.command == command) and not c.dry then r[#r + 1] = c end
  end
  return r
end

-- run until the runner has no continuation pending (at most `max` frames)
function H.settle(W, max)
  for _ = 1, max or 200 do
    local e = W.mods.runner
    if not (e and e.cont) then return end
    W.frame(1)
  end
  error('runner did not settle')
end

-- n runner runs: advance to the next due tick, then settle
function H.runs(W, n, every)
  for _ = 1, n or 1 do
    W.run(every or 600, {skip = 9})
    H.settle(W)
  end
end

-- persist round trip: the raw site strings decoded again, keyed by contract key (a fresh load)
function H.reloaded(W)
  local out = {}
  for dk, s in pairs(W.persist_raw) do
    local key = dk == 'dfllm' and 'marker' or dk:gsub('^dfllm%.', '')
    out[key] = json.decode(s)
  end
  return out
end

return H
