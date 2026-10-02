local w,h=dfhack.screen.getWindowSize()
print('focus',table.concat(dfhack.gui.getCurFocus(true),'|'),w,h)
for y=0,h-1 do
  local row=''
  for x=0,w-1 do
    local p=dfhack.screen.readTile(x,y)
    local c=p and p.ch or 0
    row=row..((c>=32 and c<127) and string.char(c) or (c==0 and ' ' or '?'))
  end
  if row:match('%S') then
    local t=row:gsub('%s+$','')
    if #t>0 then print(string.format('%3d %s',y,t)) end
  end
end
