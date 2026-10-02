local px,py=tonumber(({...})[1]),tonumber(({...})[2])
local g=df.global.gps
g.mouse_x=px//g.tile_pixel_x g.mouse_y=py//g.tile_pixel_y g.precise_mouse_x=px g.precise_mouse_y=py
require('gui').simulateInput(dfhack.gui.getCurViewscreen(),{_MOUSE_L=true,_MOUSE_L_DOWN=true})
