-- claude/zugaenge: computes all entrances into the fort from outside (pathfinding), output 'ZUGANG x y z n fuehrt_zum_Kern umgeht_Fallen'. ~10 s runtime (main thread)!
-- Accesses into the fort: entry points from outside (outside=true) into walkable interior rooms, grouped, with trap coverage
-- Usage: claude/zugaenge [cx cy cz [zmin zmax]]  core point (default config.FORT_REFS[1]) and z range (default
-- config.Z_MIN..Z_MAX); the run-3/4 values (core 100,101,130, z 100..136) were hard-coded (BUG-419).
-- Enclave filter (ported from the live copy, BUG-420): connected walkable outside areas smaller than config.PERIMETER_MINCOMP tiles
-- (walled sky terraces, light wells) are not 'outside' and do not start the search.
-- Fair play: undiscovered tiles count as not walkable (nothing is read from them).
-- Used for: defence planning (where can enemies get in, which entrances bypass the traps); optional script.
-- Needs config keys: FORT_REFS (or FORT_X/FORT_Y/SURFACE_Z), Z_MIN/Z_MAX (from SURFACE_Z/Z_DOWN/Z_UP), PERIMETER_MINCOMP.
local cfg = reqscript('claude/config')
local args = { ... }
local function iarg(i) local v = tonumber(args[i]) return v and math.tointeger(v) or nil end
local M = df.global.world.map
local XM, YM = M.x_count, M.y_count
local ZMIN, ZMAX = iarg(4) or cfg.Z_MIN, iarg(5) or cfg.Z_MAX
local SH = df.tiletype_shape
local walkshape = {}
for _,n in ipairs{'FLOOR','BOULDER','PEBBLES','BROOK_TOP','SHRUB','SAPLING','RAMP','STAIR_UP','STAIR_DOWN','STAIR_UPDOWN','TWIG','BROOK_BED','TRUNK_BRANCH'} do walkshape[SH[n]] = true end
local function info(x,y,z)
  if x<0 or y<0 or x>=XM or y>=YM then return nil end
  local b=dfhack.maps.getTileBlock(x,y,z) if not b then return nil end
  local d=b.designation[x%16][y%16]
  if d.hidden then return nil end
  local tt=b.tiletype[x%16][y%16]
  local sh=df.tiletype.attrs[tt].shape
  return sh, d.outside, d.flow_size>0
end
local function walk(x,y,z)
  local sh,out,wet=info(x,y,z)
  return sh and walkshape[sh] and not wet, out
end
-- Traps
local trap = {}
for _,b in ipairs(df.global.world.buildings.all) do
  if b:getType()==df.building_type.Trap then trap[b.x1..','..b.y1..','..b.z]=true end
end
local function key(x,y,z) return x..','..y..','..z end
local function neighbors(x,y,z)
  local res={}
  local sh=info(x,y,z)
  for dx=-1,1 do for dy=-1,1 do if dx~=0 or dy~=0 then
    if walk(x+dx,y+dy,z) then res[#res+1]={x+dx,y+dy,z} end
  end end end
  if sh==SH.STAIR_UP or sh==SH.STAIR_UPDOWN then
    local s2=info(x,y,z+1) if s2==SH.STAIR_DOWN or s2==SH.STAIR_UPDOWN then res[#res+1]={x,y,z+1} end
  end
  if sh==SH.STAIR_DOWN or sh==SH.STAIR_UPDOWN then
    local s2=info(x,y,z-1) if s2==SH.STAIR_UP or s2==SH.STAIR_UPDOWN then res[#res+1]={x,y,z-1} end
  end
  if sh==SH.RAMP then
    for dx=-1,1 do for dy=-1,1 do if walk(x+dx,y+dy,z+1) then res[#res+1]={x+dx,y+dy,z+1} end end end
  end
  -- from above onto ramp
  for dx=-1,1 do for dy=-1,1 do
    local s2=info(x+dx,y+dy,z-1)
    if s2==SH.RAMP and (dx~=0 or dy~=0 or true) then res[#res+1]={x+dx,y+dy,z-1} end
  end end
  return res
end
-- Multi-source BFS: all walkable outside tiles (outside) as start; entry = first interior tile
local seen, entries = {}, {}
local queue, qi = {}, 1
local MINCOMP = tonumber(cfg.PERIMETER_MINCOMP) or 0
do
  local outs, cid, comp = {}, {}, 0
  for z=ZMIN,ZMAX do for x=0,XM-1 do for y=0,YM-1 do
    local w,out = walk(x,y,z)
    if w and out then outs[key(x,y,z)]={x,y,z} end
  end end end
  -- connected outside components; only those with >= MINCOMP tiles seed the search (enclave filter)
  for k,c in pairs(outs) do
    if not cid[k] then
      comp = comp + 1
      local st, members, sp = {c}, {}, 1
      cid[k]=comp
      while sp<=#st do
        local cur=st[sp] sp=sp+1 members[#members+1]=cur
        for _,n in ipairs(neighbors(cur[1],cur[2],cur[3])) do
          local k2=key(n[1],n[2],n[3])
          if outs[k2] and not cid[k2] then cid[k2]=comp st[#st+1]=n end
        end
      end
      if #members >= MINCOMP then
        for _,m in ipairs(members) do seen[key(m[1],m[2],m[3])]=true queue[#queue+1]=m end
      end
    end
  end
end
local innen = {}
while qi<=#queue do
  local c=queue[qi] qi=qi+1
  local ci=select(2,walk(c[1],c[2],c[3]))
  for _,n in ipairs(neighbors(c[1],c[2],c[3])) do
    local k=key(n[1],n[2],n[3])
    if not seen[k] then
      local w,out=walk(n[1],n[2],n[3])
      if w then
        seen[k]=true
        if out then queue[#queue+1]=n
        else
          if ci then entries[#entries+1]={n[1],n[2],n[3]} end   -- transition from outside to inside
          innen[k]=true queue[#queue+1]=n
        end
      end
    end
  end
end
-- Clusters of entry points (26-neighborhood)
local used, clusters = {}, {}
local epos = {}
for _,e in ipairs(entries) do epos[key(e[1],e[2],e[3])]=e end
for k,e in pairs(epos) do
  if not used[k] then
    local cl={} local st={e} used[k]=true
    while #st>0 do
      local c=table.remove(st) cl[#cl+1]=c
      for dx=-2,2 do for dy=-2,2 do for dz=-1,1 do
        local k2=key(c[1]+dx,c[2]+dy,c[3]+dz)
        if epos[k2] and not used[k2] then used[k2]=true st[#st+1]=epos[k2] end
      end end end
    end
    clusters[#clusters+1]=cl
  end
end
-- Reachability of the core without trap tiles, from cluster
local REF = (cfg.FORT_REFS or {})[1] or { cfg.FORT_X, cfg.FORT_Y, cfg.SURFACE_Z }
local CORE = { iarg(1) or REF[1], iarg(2) or REF[2], iarg(3) or REF[3] }
local function reach_core(cl)
  local s2, q2, i2 = {}, {}, 1
  for _,c in ipairs(cl) do local k=key(c[1],c[2],c[3]) if not trap[k] then s2[k]=true q2[#q2+1]=c end end
  while i2<=#q2 do
    local c=q2[i2] i2=i2+1
    if c[1]==CORE[1] and c[2]==CORE[2] and c[3]==CORE[3] then return true end
    for _,n in ipairs(neighbors(c[1],c[2],c[3])) do
      local k=key(n[1],n[2],n[3])
      if not s2[k] and not trap[k] then
        local w,out=walk(n[1],n[2],n[3])
        if w and not out then s2[k]=true q2[#q2+1]=n end
      end
    end
  end
  return false
end
local out={}
for i,cl in ipairs(clusters) do
  local sx,sy,sz,minz,maxz=0,0,0,999,-999
  for _,c in ipairs(cl) do sx=sx+c[1] sy=sy+c[2] if c[3]<minz then minz=c[3] end if c[3]>maxz then maxz=c[3] end end
  local n=#cl
  -- only meaningful if the entry point leads to the core: check with traps
  local core_plain = (function()
    local s2,q2,i2={},{},1
    for _,c in ipairs(cl) do s2[key(c[1],c[2],c[3])]=true q2[#q2+1]=c end
    while i2<=#q2 do local c=q2[i2] i2=i2+1
      if c[1]==CORE[1] and c[2]==CORE[2] and c[3]==CORE[3] then return true end
      for _,nn in ipairs(neighbors(c[1],c[2],c[3])) do local k=key(nn[1],nn[2],nn[3])
        if not s2[k] then local w,o=walk(nn[1],nn[2],nn[3]) if w and not o then s2[k]=true q2[#q2+1]=nn end end end end
    return false end)()
  out[#out+1]={x=sx//n,y=sy//n,z=minz..'-'..maxz,n=n,kern=core_plain,ohne_fallen=core_plain and reach_core(cl)}
end
table.sort(out,function(a,b) return (a.kern and 1 or 0)>(b.kern and 1 or 0) end)
print("Einstiegscluster gesamt",#clusters)
for _,o in ipairs(out) do
  print(string.format("ZUGANG %d %d %s %d %s %s",o.x,o.y,o.z,o.n,tostring(o.kern),tostring(o.ohne_fallen)))
end
local tn=0 for _ in pairs(trap) do tn=tn+1 end print("Fallenkacheln",tn)
