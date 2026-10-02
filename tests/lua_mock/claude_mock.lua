-- Generic DFHack mock for the companion scripts in lua/claude/ (the pilot_* scripts use dfhack_mock.lua / grid_mock.lua).
-- Usage: lua5.4 tests/lua_mock/claude_mock.lua <script.lua> [args...]
--   reqscript('claude/<name>') loads <dir of script, or MOCK_SCRIPT_DIR>/<name>.lua as a module (dfhack_flags.module = true, own environment).
--   `df` auto-vivifies: unknown fields are empty, callable tables (calling one returns nil), so scripts load without
--   a game. MOCK_SETUP = path to a Lua file run after the base setup (defines units, screen text, globals ...).
--   MOCK_AFTER = Lua file run after the script (prints state for assertions).
--   MOCK_DECIMAL_COMMA=1 emulates a German LC_NUMERIC in the json encoder (floats printed as 250,0 like the live game).
--   dfhack.df2utf converts CP437 -> UTF-8 like the real one (incl. control characters -> glyphs, e.g. \n -> U+25D9).
local SCRIPT_DIR = os.getenv('MOCK_SCRIPT_DIR') or (arg[1] or ''):match('^(.*)/[^/]*$') or '.'

------------------------------------------------------------------ auto-vivifying proxy for df
local auto_mt = {}
local function auto() return setmetatable({}, auto_mt) end
auto_mt.__index = function(t, k)
  if type(k) == 'number' then return nil end   -- empty vectors (ipairs/loops terminate)
  local v = auto(); rawset(t, k, v); return v
end
auto_mt.__call = function() return nil end
auto_mt.__len = function() return 0 end

------------------------------------------------------------------ CP437 -> UTF-8
local HIGH = {
  'Ç', 'ü', 'é', 'â', 'ä', 'à', 'å', 'ç', 'ê', 'ë', 'è', 'ï', 'î', 'ì', 'Ä', 'Å',
  'É', 'æ', 'Æ', 'ô', 'ö', 'ò', 'û', 'ù', 'ÿ', 'Ö', 'Ü', '¢', '£', '¥', '₧', 'ƒ',
  'á', 'í', 'ó', 'ú', 'ñ', 'Ñ', 'ª', 'º', '¿', '⌐', '¬', '½', '¼', '¡', '«', '»',
  '░', '▒', '▓', '│', '┤', '╡', '╢', '╖', '╕', '╣', '║', '╗', '╝', '╜', '╛', '┐',
  '└', '┴', '┬', '├', '─', '┼', '╞', '╟', '╚', '╔', '╩', '╦', '╠', '═', '╬', '╧',
  '╨', '╤', '╥', '╙', '╘', '╒', '╓', '╫', '╪', '┘', '┌', '█', '▄', '▌', '▐', '▀',
  'α', 'ß', 'Γ', 'π', 'Σ', 'σ', 'µ', 'τ', 'Φ', 'Θ', 'Ω', 'δ', '∞', 'φ', 'ε', '∩',
  '≡', '±', '≥', '≤', '⌠', '⌡', '÷', '≈', '°', '∙', '·', '√', 'ⁿ', '²', '■', '\u{A0}',
}
local CTRL = { [9] = '○', [10] = '◙', [13] = '♪' }
local function df2utf(s)
  return (s:gsub('[%z\1-\31\128-\255]', function(c)
    local b = c:byte()
    if b >= 128 then return HIGH[b - 127] end
    return CTRL[b] or '☺'
  end))
end
local REV = {}
for i, u in ipairs(HIGH) do REV[u] = string.char(i + 127) end
local function utf2df(s) return (s:gsub(utf8.charpattern, function(c) return REV[c] or c end)) end

------------------------------------------------------------------ json (emulates the DFHack encoder incl. locale defect)
local DEC_COMMA = os.getenv('MOCK_DECIMAL_COMMA') == '1'
local function encode(v)
  local t = type(v)
  if t == 'nil' then return 'null' end
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then
    if math.type(v) == 'integer' then return tostring(v) end
    local s = string.format('%.14g', v)
    if not s:find('[%.eEn]') then s = s .. '.0' end
    if DEC_COMMA then s = s:gsub('%.', ',') end
    return s
  end
  if t == 'string' then
    return '"' .. v:gsub('[%c"\\]', function(c)
      local m = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\t'] = '\\t', ['\r'] = '\\r' }
      return m[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
  end
  if t == 'table' then
    if #v > 0 or next(v) == nil then
      local parts = {}
      for _, x in ipairs(v) do parts[#parts + 1] = encode(x) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      local val = v[k]
      if val == nil then val = v[tonumber(k)] end
      parts[#parts + 1] = encode(k) .. ':' .. encode(val)
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return '"<' .. t .. '>"'
end
package.loaded['json'] = { encode = encode, decode = function() return nil end }
-- any other DFHack library module (gui, utils, dfhack.workshops ...) is an auto-vivifying stub
local real_require = require
function require(name)
  if package.loaded[name] then return package.loaded[name] end
  local ok, m = pcall(real_require, name)
  if ok then return m end
  package.loaded[name] = auto()
  return package.loaded[name]
end
xyz2pos = function(x, y, z) return { x = x, y = y, z = z } end
copyall = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
package.loaded['repeat-util'] = { scheduled = {}, isScheduled = function() return false end,
                                  scheduleEvery = function() end, cancel = function() end }

------------------------------------------------------------------ df / dfhack
df = auto()
df.game_mode = { DWARF = 0, ADVENTURE = 1 }
df.global.gamemode = 0
df.global.cur_year = 118
df.global.cur_year_tick = 31871
MOCK_SCREEN = { 'abc def abc', '', 'xyz' }   -- rows of screen text (setup may replace)
dfhack = auto()
dfhack.isMapLoaded = function() return true end
dfhack.getDFPath = function() return os.getenv('MOCK_HOME') or '.' end
dfhack.df2utf = df2utf
dfhack.utf2df = utf2df
dfhack.timeout = function() return nil end
dfhack.screen.getWindowSize = function()
  local w = 0
  for _, r in ipairs(MOCK_SCREEN) do w = math.max(w, #r) end
  return w, #MOCK_SCREEN
end
dfhack.screen.readTile = function(x, y)
  local r = MOCK_SCREEN[y + 1] or ''
  local c = r:byte(x + 1)
  return { ch = c or 32 }
end
dfhack.gui.getCurFocus = function() return { 'dwarfmode/Default' } end
dfhack.units.getReadableName = function(u) return u._name or '?' end
CR_OK = 0

------------------------------------------------------------------ reqscript
local loaded = {}
local function load_script(path, module, ...)
  local env = setmetatable({ dfhack_flags = { module = module } }, { __index = _G })
  local chunk = assert(loadfile(path, 't', env))
  chunk(...)
  return env
end
function reqscript(name)
  if loaded[name] then return loaded[name] end
  local short = name:gsub('^claude/', '')
  local env = load_script(SCRIPT_DIR .. '/' .. short .. '.lua', true)
  loaded[name] = env
  return env
end
dfhack.script_environment = reqscript

local setup = os.getenv('MOCK_SETUP')
if setup then dofile(setup) end

local args = {}
for i = 2, #arg do args[#args + 1] = arg[i] end
load_script(arg[1], false, table.unpack(args))
-- MOCK_AFTER = Lua file run after the script (prints state for assertions)
local after = os.getenv('MOCK_AFTER')
if after then dofile(after) end
