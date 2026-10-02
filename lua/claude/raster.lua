-- claude/raster start|stop|status|next|reset [n]
-- Persistent refill logic for raster exploration / dig program (ore agent, erkundung): check every 1500 ticks; if fewer than
-- MIN_OFFEN open dig orders exist, the next strips of the stages from lua/claude/stages.lua are designated INCREMENTALLY (max. BUDGET new tiles per check, in strips of <= STRIP_TILES tiles)
-- (wall tiles only, only z >= config.dig_min_z(), only strips adjacent to already reachable terrain).
-- Stages are NO LONGER designated as a block (freeze risk; orchestrator 01.10.): the queue stays at MIN_OFFEN..MIN_OFFEN+BUDGET.
-- Progress (cursor = up to which entry of the sorted stage list is released, first = first unfinished entry) in dfhack.persistent.
local util = reqscript('claude/util')
if not util.require_fort() then return end
local repeatUtil = require('repeat-util')
local st = reqscript('claude/stages')
local cfg = reqscript('claude/config')
local bh = reqscript('claude/bauhelp')
local KEY, KEY2, INTERVAL = 'claude-raster', 'claude-raster2', 1500
local MIN_OFFEN = 300   -- dig queue target: below it, more strips are set (orchestrator 01.10.: 300..600 open jobs)
local BUDGET = 250      -- max. newly designated tiles per check
local STRIP_TILES = 120 -- strip size
-- MIN_Z: aquifer limit from claude/config (dig_min_z: DIG_MIN_Z or highest known aquifer level + 1); recomputed on every call
local mz_cache
local function MIN_Z()
  local t = df.global.cur_year_tick
  if not mz_cache or math.abs(t - mz_cache.t) > 600 then mz_cache = { t = t, z = cfg.dig_min_z(cfg.aquifer_seen()) } end
  return mz_cache.z
end

local function num(n) return tonumber(tostring(n):match('%d+')) or 0 end
local function names()
  local list, seen = {}, {}
  for _, s in ipairs(st.stages) do if not seen[s[1]] then seen[s[1]] = true list[#list + 1] = s[1] end end
  table.sort(list, function(a, b) return num(a) < num(b) end)
  return list
end
-- Entries sorted by stage number (stable)
local function entries()
  local list = {}
  for i, s in ipairs(st.stages) do list[#list + 1] = { num = num(s[1]), idx = i, e = s } end
  table.sort(list, function(a, b) if a.num ~= b.num then return a.num < b.num end return a.idx < b.idx end)
  local out = {}
  for _, v in ipairs(list) do out[#out + 1] = v.e end
  return out
end

local function get_done()
  local d = dfhack.persistent.getSiteData(KEY) or {}
  return d.done or 0
end
local function get_state()
  local d = dfhack.persistent.getSiteData(KEY2)
  if d and d.cursor then return { cursor = d.cursor, first = d.first or 1 } end
  -- Migration from the old stage counter: all entries up to and including the last released stage number count as set
  local ns, done = names(), get_done()
  local lastnum = (done > 0 and ns[done]) and num(ns[done]) or 0
  local c = 0
  for _, e in ipairs(entries()) do if num(e[1]) <= lastnum then c = c + 1 end end
  return { cursor = c, first = 1 }
end
local function set_state(s) dfhack.persistent.saveSiteData(KEY2, { cursor = s.cursor, first = s.first }) end

local function open_count()
  local n = 0
  local mx, my = dfhack.maps.getTileSize()
  -- Speed (30.09., SCHNELLER-run3 sec. 3): NEVER enum lookup in the inner loop, and first check only blocks with flags.designated.
  local NO = df.tile_dig_designation.No
  for z = MIN_Z(), cfg.SURFACE_Z - 1 do
    for bx = 0, mx // 16 - 1 do
      for by = 0, my // 16 - 1 do
        local b = dfhack.maps.getBlock(bx, by, z)
        if b and b.flags.designated then
          local des = b.designation
          for i = 0, 15 do for j = 0, 15 do
            -- count only designations a miner can reach (otherwise deadlock with unreachable designations)
            if des[i][j].dig ~= NO and bh.dig_reachable(b.map_pos.x + i, b.map_pos.y + j, z) then n = n + 1 end
          end end
        end
      end
    end
  end
  -- designations become dig jobs in the game (designation disappears) -> also count running dig jobs
  local JT = df.job_type
  local dig = { [JT.Dig] = true, [JT.CarveUpwardStaircase] = true, [JT.CarveDownwardStaircase] = true, [JT.CarveUpDownStaircase] = true,
    [JT.CarveRamp] = true, [JT.DigChannel] = true }
  local l = df.global.world.jobs.list.next
  while l do
    local j = l.item
    if j and dig[j.job_type] and j.pos.z >= MIN_Z() and bh.dig_reachable(j.pos.x, j.pos.y, j.pos.z) then n = n + 1 end
    l = l.next
  end
  return n
end

-- Remove invalid designations (floor/sapling/open tiles, 'Inappropriate dig square') and the associated dig jobs
local function purge()
  local ez = reqscript('claude/erzdig')
  return ez.purge(MIN_Z(), cfg.SURFACE_Z)
end

local JOBPOS = {}
local function free_tile(blk, x, y, z)
  if cfg.in_layout(x, y, z) or cfg.is_sperre(x, y, z) then return false end
  local tt = blk.tiletype[x % 16][y % 16]
  local sh = df.tiletype_shape[df.tiletype.attrs[tt].shape]
  local d = blk.designation[x % 16][y % 16]
  return sh == 'WALL' and d.dig == df.tile_dig_designation.No and not d.water_table and not st.reserved(x, y, z) and not JOBPOS[x .. ',' .. y .. ',' .. z]
end
-- Designate strip (rectangle), returns: new tiles
local function apply_rect(z, x1, y1, x2, y2)
  if z < MIN_Z() then return 0 end
  local n = 0
  for x = x1, x2 do for y = y1, y2 do
    local blk = dfhack.maps.getTileBlock(x, y, z)
    if blk and free_tile(blk, x, y, z) then
      blk.designation[x % 16][y % 16].dig = df.tile_dig_designation.Default
      blk.flags.designated = true
      n = n + 1
    end
  end end
  return n
end
local function hasfree(z, x1, y1, x2, y2)
  if z < MIN_Z() then return false end
  for x = x1, x2 do for y = y1, y2 do
    local blk = dfhack.maps.getTileBlock(x, y, z)
    if blk and free_tile(blk, x, y, z) then return true end
  end end
  return false
end

local function walk(x, y, z)
  local tt = dfhack.maps.getTileType(x, y, z)
  if not tt then return false end
  local sh = df.tiletype_shape[df.tiletype.attrs[tt].shape]
  return (sh == 'FLOOR' or sh:find('STAIR') ~= nil or sh:find('RAMP') ~= nil) and bh.reach(x, y, z)
end
-- does the strip (edge + 1 tile) border walkable, reachable terrain?
local function touches(z, x1, y1, x2, y2)
  for x = x1 - 1, x2 + 1 do
    if walk(x, y1 - 1, z) or walk(x, y2 + 1, z) then return true end
  end
  for y = y1, y2 do
    if walk(x1 - 1, y, z) or walk(x2 + 1, y, z) then return true end
  end
  return false
end

local function strips(e)
  local _, z, x1, y1, x2, y2 = table.unpack(e)
  x1, x2 = math.min(x1, x2), math.max(x1, x2)
  y1, y2 = math.min(y1, y2), math.max(y1, y2)
  local w, h = x2 - x1 + 1, y2 - y1 + 1
  local out = {}
  if w >= h then
    local rows = math.max(1, STRIP_TILES // w)
    for y = y1, y2, rows do out[#out + 1] = { z, x1, y, x2, math.min(y2, y + rows - 1) } end
  else
    local cols = math.max(1, STRIP_TILES // h)
    for x = x1, x2, cols do out[#out + 1] = { z, x, y1, math.min(x2, x + cols - 1), y2 } end
  end
  return out
end

-- One pass: designate free, connected strips of the released entries up to BUDGET tiles; if none are left, release the next entry.
local function release(budget)
  JOBPOS = bh.dig_job_positions()
  local ent = entries()
  local s = get_state()
  local total, added = 0, 0
  while total < budget do
    local got = 0
    local i = s.first
    while i <= math.min(s.cursor, #ent) do
      local anyfree = false
      for _, sp in ipairs(strips(ent[i])) do
        local z, x1, y1, x2, y2 = table.unpack(sp)
        if hasfree(z, x1, y1, x2, y2) then
          anyfree = true
          if total < budget and touches(z, x1, y1, x2, y2) then
            local n = apply_rect(z, x1, y1, x2, y2)
            total = total + n
            got = got + n
          end
        end
      end
      if not anyfree and i == s.first then s.first = i + 1 end
      i = i + 1
      if total >= budget then break end
    end
    if got == 0 then
      if s.cursor < #ent and added < 3 then s.cursor = s.cursor + 1 added = added + 1 else break end
    end
  end
  set_state(s)
  return total, s
end

-- Ore refill only rarely (no continuous scan: froze the game)
local ERZ_EVERY = 40000
local last_erz = -1e12
local function now_ticks() return df.global.cur_year * 403200 + df.global.cur_year_tick end
local function check()
  local ok, err = pcall(function()
    purge()
    local dd = bh.dedupe_dig_jobs()
    if dd > 0 then dfhack.println(('claude/raster: %d doppelte Dig-Jobs entfernt'):format(dd)) end
    local offen = open_count()
    local n, s = 0, nil
    if offen < MIN_OFFEN then
      n, s = release(BUDGET)
      if n > 0 then dfhack.println(('claude/raster: %d Kacheln nachgelegt (offen vorher %d, Cursor %d)'):format(n, offen, s.cursor)) end
    end
    if offen < MIN_OFFEN and n == 0 and now_ticks() - last_erz >= ERZ_EVERY then
      last_erz = now_ticks()
      local ez = reqscript('claude/erzdig')
      local g = ez.run('ALL', cfg.dig_min_z(cfg.aquifer_seen()), cfg.SURFACE_Z - 1, MIN_OFFEN - offen + 20, false)
      if g > 0 then dfhack.println(('claude/raster: offen %d -> %d Erz-Waende nachgesetzt'):format(offen, g)) end
    end
  end)
  if not ok then dfhack.printerr('claude/raster: ' .. tostring(err)) end
end

local a = { ... }
local cmd = a[1] or 'status'
if cmd == 'start' then
  repeatUtil.scheduleEvery(KEY, INTERVAL, 'ticks', check)
  check()
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
elseif cmd == 'next' then
  local s = get_state()
  local ent = entries()
  if s.cursor < #ent then s.cursor = s.cursor + 1 set_state(s) end
  local n = release(BUDGET)
  util.emit({ cursor = s.cursor, eintraege = #ent, kacheln = n })
  return
elseif cmd == 'reset' then
  local s = get_state()
  s.cursor = tonumber(a[2]) or 0
  s.first = 1
  set_state(s)
end
local s, ent = get_state(), entries()
util.emit({ laeuft = repeatUtil.isScheduled and repeatUtil.isScheduled(KEY) or nil, cursor = s.cursor, first = s.first, eintraege = #ent, etappen_gesamt = #names(),
  offen = open_count(), min_offen = MIN_OFFEN, budget = BUDGET, min_z = MIN_Z() })
