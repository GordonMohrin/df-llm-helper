local repeatUtil=require('repeat-util')
local a=({...})
if a[1]=='stop' then repeatUtil.cancel('mousehold') print('stopped') return end
local px,py=tonumber(a[1]),tonumber(a[2])
repeatUtil.scheduleEvery('mousehold',1,'frames',function()
  local g=df.global.gps
  g.mouse_x=px//g.tile_pixel_x g.mouse_y=py//g.tile_pixel_y g.precise_mouse_x=px g.precise_mouse_y=py
end)
print('holding',px,py)
