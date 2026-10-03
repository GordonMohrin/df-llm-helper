-- claude/pilot_forbid status | fix <class,class,...> [--max <n>] [--apply]      (df-llm-helper FEATURE-003, LIVE-UNTESTED)
-- status: READ ONLY. Own forbidden items (not trader/foreign/hostile, not built in, not removed) by class
--         container (barrel/bin/bag/bucket/flask, a tool holding items) / drink / food / material (blocks, logs, bars,
--         boulders) / other, the drinks and food blocked by a forbidden container around them, the claimed (in_job)
--         and dump-marked own items for comparison, and a cause hint per forbidden item:
--           dump_zone    lies on a garbage dump zone (DF forbids what it carried onto a dump zone)
--           own_dead     corpse/part of the fort's race (standing order forbid_own_dead_items)
--           other_dead   corpse/part of another race (standing order forbid_other_dead_items: siege kill zone)
--           used_ammo    ammunition (standing order forbid_used_ammo)
--           foreign_made made by another race (siege loot, enemy gear)
--           area         many forbidden items in one 16x16 map block (a mass 'forbid' designation or a script)
--           unknown      none of the above
--         plus the densest map blocks (where to look), the standing orders forbid_* and the number of forbidden own
--         items on hidden tiles (never listed by position: fog of war).
--         BUG-125 / Run 5: 1043 own items forbidden, 'cancels Drink: Forbidden area', > 10 dwarves died of thirst.
-- fix:    clears the forbid flag (the item menu's forbid toggle, a normal player action) on own forbidden items of the
--         given classes (drink, food, container, material; 'other' = siege loot is refused: the standing order
--         protects haulers during sieges). Skipped: items on hidden tiles, items lying on a dump zone, items of
--         traders/foreign/hostile. At most --max (default 2000, never above 5000) per call. Without --apply: dry run.
--         Every changed id is appended to <home>/tools/out/forbid-fix.log. No item is moved, created or removed.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local a = { ... }
local cmd = a[1] or 'status'
local IT = df.item_type

local function safe(f, d) local ok, v = pcall(f) if ok and v ~= nil then return v end return d end
local function tname(it) return IT[it:getType()] or '?' end
local function inc(t, k, n) t[k] = (t[k] or 0) + (n or 1) end

local CONT = { BARREL = true, BIN = true, BOX = true, BUCKET = true, FLASK = true }
local MAT = { BLOCKS = true, WOOD = true, BAR = true, BOULDER = true }
local FOOD = { FOOD = true, MEAT = true, FISH = true, FISH_RAW = true, PLANT = true, PLANT_GROWTH = true, EGG = true,
               CHEESE = true, GLOB = true }
local CORPSE_T = { CORPSE = true, CORPSEPIECE = true, REMAINS = true }
local CLASSES = { 'container', 'drink', 'food', 'material', 'other' }
local FIXABLE = { container = true, drink = true, food = true, material = true }
local CLUSTER_MIN = 20
local FORT_RACE = safe(function() return df.global.plotinfo.race_id end, -1)

-- own = belongs to the fort's stock (trader/foreign/hostile goods are never counted nor touched)
local function own(it)
  local f = it.flags
  return not (f.removed or f.trader or f.foreign or f.hostile or f.construction or f.in_building or f.garbage_collect)
end

local function class_of(it, t)
  if t == 'DRINK' then return 'drink' end
  if FOOD[t] and not it.flags.rotten then return 'food' end
  if CONT[t] then return 'container' end
  if t == 'TOOL' and safe(function() return #dfhack.items.getContainedItems(it) > 0 end, false) then return 'container' end
  if MAT[t] then return 'material' end
  return 'other'
end

local function forbidden_container(it)
  local c, d = safe(function() return dfhack.items.getContainer(it) end, nil), 0
  while c and d < 5 do
    if c.flags.forbid then return true end
    c, d = safe(function() return dfhack.items.getContainer(c) end, nil), d + 1
  end
  return false
end

-- position of the item itself or of the outermost container (a drink in a barrel has no own position)
local function pos_of(it)
  local ok, x, y, z = pcall(dfhack.items.getPosition, it)
  if ok and x and x >= 0 then return x, y, z end
  return nil
end

local function hidden(x, y, z)
  local fl = safe(function() return dfhack.maps.getTileFlags(x, y, z) end, nil)
  return (not fl) or fl.hidden == true
end

local dump_zones = {}
for _, b in ipairs(df.global.world.buildings.all) do
  if safe(function() return b:getType() == df.building_type.Civzone and df.civzone_type[b.type] == 'Dump' end, false) then
    dump_zones[#dump_zones + 1] = b
  end
end
local function dump_zone_at(x, y, z)
  for _, b in ipairs(dump_zones) do
    if z == b.z and x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return b.id end
  end
  return nil
end

local function standing()
  local out = {}
  for _, k in ipairs({ 'forbid_other_dead_items', 'forbid_own_dead_items', 'forbid_used_ammo', 'forbid_other_nohunt',
                       'forbid_own_dead' }) do
    local v = safe(function() return df.global['standing_orders_' .. k] end, nil)
    if v == nil then v = safe(function() return df.global.plotinfo['standing_orders_' .. k] end, nil) end
    if v ~= nil then out[k] = (v == true or v == 1) end
  end
  return out
end

-- the cause that does not need the neighbours (the 'area' cause is decided after the scan)
local function direct_cause(it, t, x, y, z, st)
  if x and dump_zone_at(x, y, z) then return 'dump_zone' end
  if CORPSE_T[t] then
    local race = safe(function() return it.race end, -1)
    if race == FORT_RACE then return 'own_dead' end
    return 'other_dead'
  end
  if t == 'AMMO' and st.forbid_used_ammo then return 'used_ammo' end
  local mr = safe(function() return it.maker_race end, -1)
  if mr >= 0 and FORT_RACE >= 0 and mr ~= FORT_RACE then return 'foreign_made' end
  return nil
end

local function block_key(x, y, z) return z .. ':' .. (x // 16) .. ':' .. (y // 16) end

if cmd == 'status' then
  local st = standing()
  local out = { ok = true, total = 0, hidden = 0, standing = st,
                classes = { container = 0, drink = 0, food = 0, material = 0, other = 0 },
                drink = { total = 0, blocked = 0, in_forbidden_container = 0 },
                food = { total = 0, blocked = 0, in_forbidden_container = 0 },
                flags = { in_job = 0, dump = 0 },
                causes = { dump_zone = 0, own_dead = 0, other_dead = 0, used_ammo = 0, foreign_made = 0, area = 0,
                           unknown = 0 },
                by_class_cause = {}, clusters = {} }
  for _, c in ipairs(CLASSES) do out.by_class_cause[c] = {} end
  local pending, blocks = {}, {}
  for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
    if own(it) then
      local f = it.flags
      local t = tname(it)
      local n = safe(function() return it:getStackSize() end, 1)
      if f.in_job then out.flags.in_job = out.flags.in_job + 1 end
      if f.dump then out.flags.dump = out.flags.dump + 1 end
      local cls = class_of(it, t)
      local edible = cls == 'drink' or cls == 'food'
      local in_forb = edible and not f.forbid and forbidden_container(it)
      if edible then
        local c = out[cls]
        c.total = c.total + n
        if f.forbid or in_forb then c.blocked = c.blocked + n end
        if in_forb then c.in_forbidden_container = c.in_forbidden_container + n end
      end
      if f.forbid then
        local x, y, z = pos_of(it)
        if x and hidden(x, y, z) then
          out.hidden = out.hidden + 1                       -- fog of war: not counted by class, no position
        else
          out.total = out.total + 1
          out.classes[cls] = out.classes[cls] + 1
          local cause = direct_cause(it, t, x, y, z, st)
          local e = { cls = cls, cause = cause }
          if x then
            local k = block_key(x, y, z)
            local b = blocks[k]
            if not b then
              b = { z = z, x1 = x, y1 = y, x2 = x, y2 = y, n = 0, classes = {} }
              blocks[k] = b
            end
            b.n = b.n + 1
            b.x1, b.y1, b.x2, b.y2 = math.min(b.x1, x), math.min(b.y1, y), math.max(b.x2, x), math.max(b.y2, y)
            inc(b.classes, cls)
            e.block = k
            if not b.pile then
              local bl = safe(function() return dfhack.buildings.findAtTile(xyz2pos(x, y, z)) end, nil)
              if bl and safe(function() return bl:getType() == df.building_type.Stockpile end, false) then b.pile = bl.id end
            end
            if not b.zone then b.zone = dump_zone_at(x, y, z) end
          end
          pending[#pending + 1] = e
        end
      end
    end
  end
  for _, e in ipairs(pending) do
    local cause = e.cause
    if not cause then
      cause = (e.block and blocks[e.block].n >= CLUSTER_MIN) and 'area' or 'unknown'
    end
    out.causes[cause] = out.causes[cause] + 1
    inc(out.by_class_cause[e.cls], cause)
  end
  local list = {}
  for _, b in pairs(blocks) do list[#list + 1] = b end
  table.sort(list, function(p, q) return p.n > q.n end)
  for i = 1, math.min(5, #list) do out.clusters[i] = list[i] end
  util.emit(out)
elseif cmd == 'fix' then
  local classes, apply, max = {}, false, 2000
  local refused = {}
  local i = 2
  while i <= #a do
    if a[i] == '--apply' then apply = true
    elseif a[i] == '--max' then max = tonumber(a[i + 1]) or max; i = i + 1
    elseif a[i] ~= '--dry' then
      for c in tostring(a[i]):gmatch('[%w_]+') do
        if FIXABLE[c] then classes[c] = true else refused[#refused + 1] = c end
      end
    end
    i = i + 1
  end
  max = math.max(1, math.min(5000, max))
  local out = { ok = true, applied = apply, candidates = 0, changed = 0, max = max, ids = {}, refused_classes = refused,
                by_class = {}, skipped = { hidden = 0, dump_zone = 0, class = 0, cap = 0 } }
  if next(classes) == nil then
    out.ok, out.reason = false, 'no fixable class given (drink, food, container, material)'
    util.emit(out)
    return
  end
  local changed = {}
  for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
    if it.flags.forbid and own(it) then
      local cls = class_of(it, tname(it))
      local x, y, z = pos_of(it)
      if not classes[cls] then out.skipped.class = out.skipped.class + 1
      elseif x and hidden(x, y, z) then out.skipped.hidden = out.skipped.hidden + 1
      elseif x and dump_zone_at(x, y, z) then out.skipped.dump_zone = out.skipped.dump_zone + 1
      elseif out.candidates >= max then out.skipped.cap = out.skipped.cap + 1
      else
        out.candidates = out.candidates + 1
        inc(out.by_class, cls)
        local id = safe(function() return it.id end, -1)
        if #out.ids < 200 then out.ids[#out.ids + 1] = id end
        if apply then
          it.flags.forbid = false                 -- the item menu's forbid toggle on an own item
          changed[#changed + 1] = id
        end
      end
    end
  end
  if apply then
    out.changed = #changed
    if #changed > 0 then
      local d = safe(function() return util.game_date().text end, '?')
      local line = 'unforbid ' .. d .. ' n=' .. #changed .. ' ids=' .. table.concat(changed, ',')
      safe(function() util.append_log(util.home() .. '/tools/out/forbid-fix.log', line) return true end, false)
      out.log = 'tools/out/forbid-fix.log'
    end
  end
  util.emit(out)
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_forbid status | fix <drink,food,container,material> [--max <n>] [--apply]' })
end
