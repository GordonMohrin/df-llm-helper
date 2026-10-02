--@ module = true
-- Shared helpers for the claude/* scripts: JSON output, date, visibility.

local json = require('json')

-- Base folder for flags/logs/state (shared with df-llm-helper): environment variable DF_LLM_HELPER_HOME,
-- otherwise <Dwarf Fortress>/df-llm-helper-runtime. Below it: tools/ (flags, events.log, out/), state/, metrics.csv.
function home()
  local h = os.getenv('DF_LLM_HELPER_HOME') or os.getenv('DFPILOT_HOME')
  if h and h ~= '' then return (h:gsub('[/\\]+$', '')) end
  return dfhack.getDFPath() .. '/df-llm-helper-runtime'
end

-- DF strings are CP437; only runs of bytes >= 0x80 need converting. Pure ASCII stays as is, so control characters
-- (\n, \t) are not turned into CP437 picture glyphs (BUG-417). A string that already is valid UTF-8 with multi-byte
-- characters (a caller converted it with df2utf itself) is left alone instead of being encoded twice (BUG-401).
function to_utf8(s)
  if type(s) ~= 'string' or not s:find('[\128-\255]') then return s end
  if utf8.len(s) then return s end
  return (s:gsub('[\128-\255]+', dfhack.df2utf))
end

-- Cut a string to at most n bytes. CP437 strings (1 byte per character) are cut as bytes; a valid UTF-8 string is
-- cut at a character boundary so no multi-byte character is split (invalid UTF-8 in the JSON, BUG-401).
function cut(s, n)
  if type(s) ~= 'string' or #s <= n then return s end
  local c = n
  if s:find('[\128-\255]') and utf8.len(s) then
    while c > 0 do
      local b = s:byte(c + 1)
      if b < 0x80 or b >= 0xC0 then break end   -- the byte after the cut starts a character
      c = c - 1
    end
  end
  return s:sub(1, c)
end

-- Locale-independent number text: DF runs with the Windows locale, Lua/sprintf would print 250,0 (BUG-400).
local function num_text(v)
  if v ~= v or v == math.huge or v == -math.huge then return 'null' end
  local s = string.format('%.10g', v):gsub(',', '.')
  if not s:find('[%.eE]') then s = s .. '.0' end
  return s
end

-- Deep copy for the encoder: strings converted, non-integer numbers replaced by placeholders that are swapped for
-- locale-independent number text after encoding (the caller's table is not modified).
local function prepare(v, nums, seen)
  local ty = type(v)
  if ty == 'string' then return to_utf8(v) end
  if ty == 'number' then
    if math.type(v) == 'integer' then return v end
    nums[#nums + 1] = num_text(v)
    return '#~NUM' .. #nums .. '~#'
  end
  if ty ~= 'table' then return v end
  if seen[v] then return '<cycle>' end
  seen[v] = true
  local out = {}
  for k, x in pairs(v) do out[to_utf8(k)] = prepare(x, nums, seen) end
  seen[v] = nil
  local mt = getmetatable(v)
  if type(mt) == 'table' then setmetatable(out, mt) end
  return out
end

-- JSON text of a table with UTF-8 strings and dot decimals.
function encode(t)
  local nums = {}
  local s = json.encode(prepare(t, nums, {}))
  if #nums > 0 then
    s = s:gsub('"#~NUM(%d+)~#"', function(i) return nums[tonumber(i)] end)
  end
  return s
end

function emit(t)
  print(encode(t))
end

-- Append one line to a log file; when the file is larger than max_bytes (default 1 MB) it is renamed to <path>.1
-- (one generation kept) so tools/out/*.log cannot grow without bound (BUG-416/BUG-422). Never raises.
function append_log(path, line, max_bytes)
  pcall(function()
    local f = io.open(path, 'a')
    if not f then return end
    local size = f:seek('end') or 0
    if size > (max_bytes or 1000000) then
      f:close()
      os.remove(path .. '.1')
      os.rename(path, path .. '.1')
      f = io.open(path, 'a')
      if not f then return end
    end
    f:write(line, '\n')
    f:close()
  end)
end

function fort_loaded()
  return dfhack.isMapLoaded() and df.global.gamemode == df.game_mode.DWARF
end

-- Returns false (and reports the error) if no fortress is loaded.
function require_fort()
  if fort_loaded() then return true end
  emit({ error = 'keine Festung geladen' })
  return false
end

MONTHS = { 'Granite', 'Slate', 'Felsite', 'Hematite', 'Malachite', 'Galena',
           'Limestone', 'Sandstone', 'Timber', 'Moonstone', 'Opal', 'Obsidian' }
SEASONS = { 'Spring', 'Summer', 'Autumn', 'Winter' }

TICKS_PER_DAY = 1200
TICKS_PER_MONTH = 33600

function game_date()
  local tick = df.global.cur_year_tick
  local midx = tick // TICKS_PER_MONTH
  return {
    year = df.global.cur_year,
    year_tick = tick,
    month = MONTHS[midx + 1],
    day = (tick % TICKS_PER_MONTH) // TICKS_PER_DAY + 1,
    season = SEASONS[midx // 3 + 1],
    text = string.format('%d. %s, Jahr %d', (tick % TICKS_PER_MONTH) // TICKS_PER_DAY + 1,
                         MONTHS[midx + 1], df.global.cur_year),
  }
end

-- Fog of war: we do not reveal undiscovered tiles (fair play).
function is_hidden(x, y, z)
  local blk = dfhack.maps.getTileBlock(x, y, z)
  if not blk then return true end
  return blk.designation[x % 16][y % 16].hidden
end

function unit_hidden(u)
  return is_hidden(u.pos.x, u.pos.y, u.pos.z)
end

function citizens()
  return dfhack.units.getCitizens(true)
end

function fort_name()
  local ok, name = pcall(function()
    return dfhack.translation.translateName(df.global.world.world_data.active_site[0].name, true)
  end)
  return ok and name or nil
end

if dfhack_flags and dfhack_flags.module then
  return
end
