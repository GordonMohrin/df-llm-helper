local word=({...})[1]
local w,h=dfhack.screen.getWindowSize()
for y=0,h-1 do
  local row=''
  for x=0,w-1 do local p=dfhack.screen.readTile(x,y) local c=p and p.ch or 0 row=row..((c>=32 and c<127) and string.char(c) or ' ') end
  local s=row:find(word,1,true)
  if s then
    local g=df.global.gps local cx=s-1+#word//2
    g.mouse_x=cx g.mouse_y=y g.precise_mouse_x=cx*12+6 g.precise_mouse_y=y*18+9
    require('gui').simulateInput(dfhack.gui.getCurViewscreen(),{_MOUSE_L=true,_MOUSE_L_DOWN=true})
    print('clicked',word,cx,y) return
  end
end
print('not found',word)
