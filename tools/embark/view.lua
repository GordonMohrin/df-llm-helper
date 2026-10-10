-- tools/embark/view.lua: read-only model of what the vanilla embark screens show.
-- A source supplies raw UI state. In game, embark.lua builds it from dfhack.screen.readTile,
-- dfhack.gui.getFocusStrings and a few viewscreen fields that mirror visible UI state
-- (camera, selected rectangle, points/picks left). Offline tests pass a fake source.
-- Nothing in this file writes to DF.
local V = {}

local function lower(s)  -- ASCII only; locale-proof (CONTRACTS 1.1)
  return (s:gsub('[A-Z]', function(c) return string.char(c:byte() + 32) end))
end
V.lower = lower

local function trim(s) return (s:gsub('^ +', ''):gsub(' +$', '')) end
V.trim = trim

-- CP437 code -> ASCII char: printable ASCII stays, box drawing (176-223) and NUL become
-- spaces (so frames split cells), everything else (accents, glyphs) becomes '?'.
function V.char(c)
  if not c or c == 0 or c == 32 then return ' ' end
  if c > 32 and c < 127 then return string.char(c) end
  if c >= 176 and c <= 223 then return ' ' end
  return '?'
end

function V.read_lines(w, h, ch)
  local lines = {}
  for y = 0, h - 1 do
    local buf = {}
    for x = 0, w - 1 do buf[x + 1] = V.char(ch(x, y)) end
    lines[y + 1] = table.concat(buf)
  end
  return lines
end

-- cells: runs of text separated by 2+ spaces, {x (0-based col), y (0-based row), text}
function V.cells_of(lines)
  local cells = {}
  for y, line in ipairs(lines) do
    local pos = 1
    while true do
      local s = line:find('[^ ]', pos)
      if not s then break end
      local e = line:find('  ', s, true)
      local text = line:sub(s, (e or #line + 1) - 1)
      cells[#cells + 1] = {x = s - 1, y = y - 1, text = trim(text)}
      if not e then break end
      pos = e
    end
  end
  return cells
end

-- paragraphs: cells continued on the next row at the same column (+-1) are joined,
-- so wrapped popup sentences can be matched as one string.
function V.paras_of(cells)
  local paras, open = {}, {}
  for _, c in ipairs(cells) do
    local hit
    for _, p in ipairs(open) do
      if p.last_y == c.y - 1 and math.abs(p.x - c.x) <= 1 then hit = p break end
    end
    if hit then
      hit.text = hit.text .. ' ' .. c.text
      hit.last_y = c.y
    else
      hit = {x = c.x, y = c.y, last_y = c.y, text = c.text}
      paras[#paras + 1] = hit
      open[#open + 1] = hit
    end
  end
  for _, p in ipairs(paras) do p.norm = lower(p.text):gsub(' +', ' ') end
  return paras
end

local View = {}
View.__index = View

function V.capture(src)
  local w, h = src.size()
  local v = setmetatable({w = w, h = h}, View)
  v.lines = src.lines and src.lines() or V.read_lines(w, h, src.ch)  -- lines(): offline fakes only
  v.focus = src.focus and src.focus() or {}
  v.cs = src.cs and src.cs() or nil
  v.prep = src.prep and src.prep() or nil
  return v
end

function V.from_lines(lines, extra)  -- for fixtures and tests
  local v = setmetatable({w = 0, h = #lines, lines = lines}, View)
  for _, l in ipairs(lines) do if #l > v.w then v.w = #l end end
  extra = extra or {}
  v.focus, v.cs, v.prep = extra.focus or {}, extra.cs, extra.prep
  return v
end

function View:cells()
  self._cells = self._cells or V.cells_of(self.lines)
  return self._cells
end

function View:paras()
  self._paras = self._paras or V.paras_of(self:cells())
  return self._paras
end

-- find plain text; occ = n-th match (1 = first); from_bottom searches upward.
-- returns x, y (0-based tile of the first char) or nil
function View:find(text, occ, from_bottom)
  occ = occ or 1
  local n = 0
  local y0, y1, dy = 1, #self.lines, 1
  if from_bottom then y0, y1, dy = #self.lines, 1, -1 end
  for y = y0, y1, dy do
    local init = 1
    while true do
      local s = self.lines[y]:find(text, init, true)
      if not s then break end
      n = n + 1
      if n == occ then return s - 1, y - 1 end
      init = s + 1
    end
  end
end

function View:has(text) return self:find(text) ~= nil end

function View:focus_has(sub)
  sub = lower(sub)
  for _, f in ipairs(self.focus) do
    if lower(f):find(sub, 1, true) then return true end
  end
  return false
end

-- which embark screen is shown
function View:kind()
  if self:focus_has('dwarfmode') then return 'fort' end
  if self:focus_has('setupdwarfgame') then
    for _, k in ipairs({'default', 'dwarves', 'items', 'animals', 'abort', 'objections'}) do
      if self:focus_has('setupdwarfgame/' .. k) then return 'prep_' .. k end
    end
    return 'prep'
  end
  if self:focus_has('choose_start_site') then
    local cs = self.cs or {}
    if cs.finder or self:focus_has('/sitefinder') then return 'finder' end
    if self:focus_has('/chooseciv') then return 'civ' end
    if cs.choosing_embark then return 'placing' end
    if cs.zoomed_in then return 'local' end
    return 'world'
  end
  if self:focus_has('title') then return 'title' end
  if self:focus_has('choose_game_type') then return 'game_type' end
  return 'unknown'
end

-- text dump with row numbers (blank rows skipped), like the v1 screen.lua
function View:dump()
  local out = {'focus ' .. table.concat(self.focus, '|') .. ' ' .. self.w .. 'x' .. self.h}
  for y, l in ipairs(self.lines) do
    local t = l:gsub(' +$', '')
    if #t > 0 then out[#out + 1] = string.format('%3d %s', y - 1, t) end
  end
  return table.concat(out, '\n')
end

-- inverse of dump(): fixture text -> lines (row numbers restore the layout)
function V.parse_dump(text)
  local lines, focus, maxy = {}, {}, -1
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    line = line:gsub('\r$', '')
    local f = line:match('^focus ([^ ]*)')
    local y, rest = line:match('^ *([0-9]+) (.*)$')
    if f then
      for s in f:gmatch('[^|]+') do focus[#focus + 1] = s end
    elseif y then
      y = tonumber(y)
      lines[y + 1] = rest
      if y > maxy then maxy = y end
    end
  end
  for i = 1, maxy + 1 do lines[i] = lines[i] or '' end
  return lines, focus
end

return V
