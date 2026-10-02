--@ module = true
-- claude/bauhelp - shared helpers (scope wirtschaft/bau, 30.09.2026 Y88): reachability, wood only if reachable, dig job cleanup.
-- Module (no command): reqscript('claude/bauhelp').
-- Background (Y88 measurement): (1) 359 of 416 dig jobs were DUPLICATE jobs on the same tile (DF turns the designation into a job immediately and
-- deletes it; raster.reapply designated again every round -> new job); miners walked to duplicates and aborted with 'Dig: Inappropriate dig square'
-- (753 aborts in 4000 game log lines). (2) Wood in the cavern (shaft D sealed) counted as stock -> 'Make charcoal/bed: Needs logs'
-- (1120 + 283 aborts).

-- 'reachable from the fort' = on foot from one of the reference points config.FORT_REFS (run 4: no fixed coordinates anymore)
function reach(x, y, z)
  local cfg = reqscript('claude/config')
  for _, r in ipairs(cfg.FORT_REFS) do
    local ok, v = pcall(dfhack.maps.canWalkBetween, xyz2pos(r[1], r[2], r[3]), xyz2pos(x, y, z))
    if ok and v then return true end
  end
  return false
end

-- Item (wood etc.) lies on a tile reachable from the fort (not in the sealed cavern)
function item_reachable(it)
  local x, y, z = dfhack.items.getPosition(it)
  if not x then return false end
  return reach(x, y, z)
end

-- does the tile have a reachable orthogonal neighbor (precondition for a miner to dig it)
function dig_reachable(x, y, z)
  for _, o in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
    if reach(x + o[1], y + o[2], z) then return true end
  end
  -- Stairs/channels are also reached from above/below
  return reach(x, y, z) or reach(x, y, z + 1) or reach(x, y, z - 1)
end

local function digjob(jt)
  local JT = df.job_type
  return jt == JT.Dig or jt == JT.CarveUpwardStaircase or jt == JT.CarveDownwardStaircase or jt == JT.CarveUpDownStaircase
    or jt == JT.CarveRamp or jt == JT.DigChannel
end

-- Set of all tiles that already have a dig job ('x,y,z' -> count)
function dig_job_positions()
  local set = {}
  local l = df.global.world.jobs.list.next
  while l do
    local j = l.item
    if j and digjob(j.job_type) then
      local k = j.pos.x .. ',' .. j.pos.y .. ',' .. j.pos.z
      set[k] = (set[k] or 0) + 1
    end
    l = l.next
  end
  return set
end

-- Remove duplicate dig jobs (same tile, same type, without worker); keeps one per tile. Returns the number of removed jobs.
function dedupe_dig_jobs()
  local seen, kill = {}, {}
  local l = df.global.world.jobs.list.next
  while l do
    local j = l.item
    if j and digjob(j.job_type) then
      local k = j.job_type .. ':' .. j.pos.x .. ',' .. j.pos.y .. ',' .. j.pos.z
      if dfhack.job.getWorker(j) then seen[k] = true
      elseif seen[k] then kill[#kill + 1] = j
      else seen[k] = true end
    end
    l = l.next
  end
  local n = 0
  for _, j in ipairs(kill) do if pcall(dfhack.job.removeJob, j) then n = n + 1 end end
  return n
end
