-- Workaround FR-22: link built levers to built bridges (same job the kernel's act.link_lever creates).
-- usage: dfhack-run lua -f tools/run_link.lua  (pairs are read from the table below)
local pairs_to_link = {
  {lx=57, ly=61, bx=64, by=63},
  {lx=58, ly=61, bx=72, by=63},
  {lx=59, ly=61, bx=68, by=67},
  {lx=60, ly=61, bx=60, by=67},
}
local Z = 117
local function bld_at(x, y, ty)
  for _, b in ipairs(df.global.world.buildings.all) do
    if b:getType() == ty and b.z == Z and x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return b end
  end
end
local function free_mech(n, used)
  local out = {}
  for _, i in ipairs(df.global.world.items.other.TRAPPARTS) do
    if #out >= n then break end
    if not used[i.id] and not i.flags.in_job and not i.flags.forbid then
      out[#out + 1] = i
    end
  end
  return out
end
local used = {}
for _, p in ipairs(pairs_to_link) do
  local lever = bld_at(p.lx, p.ly, df.building_type.Trap)
  local bridge = bld_at(p.bx, p.by, df.building_type.Bridge)
  if not lever or not bridge then print('missing', p.lx, p.ly); goto continue end
  do
    local already = false
    for _, t in ipairs(lever.linked_mechanisms) do end
    for _, ref in ipairs(lever.general_refs) do
      if ref:getType() == df.general_ref_type.BUILDING_TRIGGERTARGET and ref.building_id == bridge.id then already = true end
    end
    local pending = false
    for _, j in ipairs(lever.jobs) do if j.job_type == df.job_type.LinkBuildingToTrigger then pending = true end end
    if already then print('linked already', p.lx, p.ly)
    elseif pending then print('link job pending', p.lx, p.ly)
    else
      local mech = free_mech(2, used)
      if #mech < 2 then print('need 2 free mechanisms'); goto continue end
      used[mech[1].id] = true; used[mech[2].id] = true
      local at = xyz2pos(lever.centerx, lever.centery, lever.z)
      local job = df.job:new()
      job.job_type = df.job_type.LinkBuildingToTrigger
      job.pos = at
      if not dfhack.job.attachJobItem(job, mech[1], df.job_role_type.LinkToTrigger, -1, -1)
         or not dfhack.job.attachJobItem(job, mech[2], df.job_role_type.LinkToTarget, -1, -1) then
        job:delete(); print('attach failed'); goto continue
      end
      dfhack.job.addGeneralRef(job, df.general_ref_type.BUILDING_HOLDER, lever.id)
      dfhack.job.addGeneralRef(job, df.general_ref_type.BUILDING_TRIGGERTARGET, bridge.id)
      lever.jobs:insert('#', job)
      dfhack.job.linkIntoWorld(job, true)
      print('link job queued', p.lx, p.ly, '->', p.bx, p.by)
    end
  end
  ::continue::
end
dfhack.job.checkBuildingsNow()
