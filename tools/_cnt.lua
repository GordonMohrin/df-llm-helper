local t,j,b=0,0,0 for _,it in ipairs(df.global.world.items.other.BOULDER) do t=t+1 if it.flags.in_job then j=j+1 end if it.flags.in_building then b=b+1 end end
local dig=0 for _,bl in ipairs(df.global.world.map.map_blocks) do for x=0,15 do for y=0,15 do if bl.designation[x][y].dig~=0 and bl.map_pos.z<114 then dig=dig+1 end end end end
print(df.global.cur_year_tick,'boulders',t,'injob',j,'inbuilding',b,'dig<114',dig,'slabs',#df.global.world.items.other.SLAB,'coffins',#df.global.world.items.other.COFFIN,'blocks',#df.global.world.items.other.BLOCKS)
