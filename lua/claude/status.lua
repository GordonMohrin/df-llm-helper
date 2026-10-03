-- claude/status - compact fortress situation report as JSON.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local cits = util.citizens()

-- Mood & work
local mood = { miserable = 0, unhappy = 0, content = 0, happy = 0 }
local adults, children, idle = 0, 0, 0
local jobs = {}
for _, u in ipairs(cits) do
  local c = dfhack.units.getStressCategory(u)
  if c <= 0 then mood.miserable = mood.miserable + 1
  elseif c <= 2 then mood.unhappy = mood.unhappy + 1
  elseif c <= 4 then mood.content = mood.content + 1
  else mood.happy = mood.happy + 1 end

  if dfhack.units.isChild(u) or dfhack.units.isBaby(u) then
    children = children + 1
  else
    adults = adults + 1
    local j = u.job.current_job
    if j then
      local name = df.job_type[j.job_type] or tostring(j.job_type)
      jobs[name] = (jobs[name] or 0) + 1
    else
      idle = idle + 1
    end
  end
end
local top_jobs = {}
for name, n in pairs(jobs) do top_jobs[#top_jobs + 1] = { job = name, n = n } end
table.sort(top_jobs, function(a, b) return a.n > b.n end)
while #top_jobs > 8 do table.remove(top_jobs) end

-- Open jobs (including suspended)
local open_jobs, suspended = 0, 0
local link = df.global.world.jobs.list.next
while link do
  local j = link.item
  if j then
    open_jobs = open_jobs + 1
    if j.flags.suspend then suspended = suspended + 1 end
  end
  link = link.next
end

-- Stocks
local T = df.item_type
local edible = { [T.FOOD] = true, [T.MEAT] = true, [T.FISH] = true, [T.CHEESE] = true,
                 [T.EGG] = true, [T.PLANT] = true, [T.PLANT_GROWTH] = true }
local stock = { food = 0, drink = 0, seeds = 0, wood = 0, boulders = 0, bars = 0,
                cloth = 0, barrels = 0, bins = 0, beds = 0 }
for _, item in ipairs(df.global.world.items.other.IN_PLAY) do
  local f = item.flags
  if not (f.rotten or f.dump or f.forbid or f.construction or f.trader or f.garbage_collect
          or f.in_building) then
    local ty, n = item:getType(), item:getStackSize()
    if edible[ty] then stock.food = stock.food + n
    elseif ty == T.DRINK then stock.drink = stock.drink + n
    elseif ty == T.SEEDS then stock.seeds = stock.seeds + n
    elseif ty == T.WOOD then stock.wood = stock.wood + n
    elseif ty == T.BOULDER then stock.boulders = stock.boulders + n
    elseif ty == T.BAR then stock.bars = stock.bars + n
    elseif ty == T.CLOTH then stock.cloth = stock.cloth + n
    elseif ty == T.BARREL then stock.barrels = stock.barrels + 1
    elseif ty == T.BIN then stock.bins = stock.bins + 1
    elseif ty == T.BED then stock.beds = stock.beds + 1 end
  end
end

-- Threats (visible only)
local hostiles = {}
for _, u in ipairs(df.global.world.units.active) do
  if dfhack.units.isActive(u) and not dfhack.units.isDead(u) and dfhack.units.isDanger(u)
     and not dfhack.units.isCitizen(u) and not util.unit_hidden(u)
     and not (u.flags1.caged or u.flags1.chained) and not (dfhack.units.getContainer and dfhack.units.getContainer(u)) then   -- BUG-423: prisoner in a cage
    local name = dfhack.units.getReadableName(u)
    hostiles[name] = (hostiles[name] or 0) + 1
  end
end
local threat_list = {}
for name, n in pairs(hostiles) do threat_list[#threat_list + 1] = { name = name, n = n } end

-- Orientation: center of mass of the dwarves
local zc, sx, sy = {}, {}, {}
for _, u in ipairs(cits) do
  local p = u.pos
  if p.x >= 0 then
    zc[p.z] = (zc[p.z] or 0) + 1
    sx[p.z] = (sx[p.z] or 0) + p.x
    sy[p.z] = (sy[p.z] or 0) + p.y
  end
end
local main_z, best = nil, -1
for z, n in pairs(zc) do if n > best then best, main_z = n, z end end
local center = main_z and { x = sx[main_z] // zc[main_z], y = sy[main_z] // zc[main_z], z = main_z } or nil

local mx, my, mz = dfhack.maps.getTileSize()
local pop = #cits
local function days(total, per_season)
  return pop > 0 and math.floor(total * 84 / (pop * per_season)) or -1
end

local alerts = {}
local food_days, drink_days = days(stock.food, 2), days(stock.drink, 5)
if food_days >= 0 and food_days < 20 then alerts[#alerts + 1] = 'Essen knapp (' .. food_days .. ' Tage)' end
if drink_days >= 0 and drink_days < 20 then alerts[#alerts + 1] = 'Getraenke knapp (' .. drink_days .. ' Tage)' end
if #threat_list > 0 then alerts[#alerts + 1] = 'Feinde auf der Karte' end
if mood.miserable > 0 then alerts[#alerts + 1] = mood.miserable .. ' Zwerg(e) todungluecklich' end
if adults > 0 and idle / adults >= 0.3 then alerts[#alerts + 1] = idle .. ' von ' .. adults .. ' Zwergen untaetig' end
if suspended > 0 then alerts[#alerts + 1] = suspended .. ' Jobs gesperrt (suspended)' end

local wealth = 0
pcall(function() wealth = df.global.plotinfo.tasks.wealth.total end)

util.emit({
  fort = util.fort_name(),
  date = util.game_date(),
  paused = df.global.pause_state,
  population = { total = pop, adults = adults, children = children, idle = idle },
  mood = mood,
  top_jobs = top_jobs,
  jobs = { open = open_jobs, suspended = suspended },
  stock = stock,
  food_days = food_days,
  drink_days = drink_days,
  threats = threat_list,
  wealth = wealth,
  center = center,
  map_size = { x = mx, y = my, z = mz },
  alerts = alerts,
})
