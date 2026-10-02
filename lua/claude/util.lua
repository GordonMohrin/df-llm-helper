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

local function to_utf8(t)
  for k, v in pairs(t) do
    local ty = type(v)
    if ty == 'string' then t[k] = dfhack.df2utf(v)
    elseif ty == 'table' then to_utf8(v) end
  end
end

function emit(t)
  to_utf8(t)
  print(json.encode(t))
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
