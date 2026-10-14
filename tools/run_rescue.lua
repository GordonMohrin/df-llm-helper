-- Fast rescue pass (every ~10 s real time; the game runs at 300-500 ticks/s, so the 3-minute watcher round is too slow for thirst):
--  * citizens flagged for health care who are thirsty/hungry get released (no forced rest, no diagnosis) so they drink and eat themselves
--  * threat popups are logged and dismissed (the game halts on them while pause_state stays false)
--  * death incidents of loose dwarf corpses are marked discovered
local freed = 0
for _, u in ipairs(dfhack.units.getCitizens(true)) do
  local h = u.health
  if h and (h.flags.should_not_move or h.flags.rq_diagnosis) and (u.counters2.thirst_timer > 20000 or u.counters2.hunger_timer > 35000) then
    h.flags.should_not_move = false
    h.flags.rq_diagnosis = false
    local j = u.job.current_job
    if j and df.job_type[j.job_type] == 'Rest' then pcall(function() dfhack.job.removeJob(j) end) end
    freed = freed + 1
  end
end
local p = df.global.world.status.popups
local n = 0
while #p > 0 and n < 10 do
  local text = dfhack.df2utf(p[0].text or '')
  if text:find('Strike the earth') then break end
  print('popup=' .. text:sub(1, 100))
  p:erase(0); n = n + 1
end
local disc = 0
for _, i in ipairs(df.global.world.items.other.CORPSE) do
  local r = df.creature_raw.find(i.race)
  if r and r.creature_id == 'DWARF' then
    local u = df.unit.find(i.unit_id)
    if u and u.counters.death_id >= 0 then
      local ic = df.incident.find(u.counters.death_id)
      if ic and not ic.flags.discovered then ic.flags.discovered = true; disc = disc + 1 end
    end
  end
end
if n + disc > 0 or freed >= 6 then print('rescue released=' .. freed .. ' popups=' .. n .. ' discovered=' .. disc) end
