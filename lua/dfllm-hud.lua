-- dfllm-hud: a permanent on-screen display of how busy the dwarves are (Gordon, 11.10.2026).
-- A DFHack overlay widget (overlay rescan; enable with `overlay enable dfllm-hud.hud`, move it with
-- gui/overlay). Read only: citizens' current job type, once per second. Two lines:
--   Auslastung 66%  (33 von 50 arbeiten)
--   Leerlauf 17: 5 Bedarf (schlafen, essen, trinken), 12 frei
-- "frei" = no job at all, "Bedarf" = a basic need job. Children are left out.
--@module = true
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local NEED = {}
for _, n in ipairs({'Sleep', 'Eat', 'DrinkItem', 'Rest', 'CleanSelf', 'GetProvisions', 'Pray', 'Worship'}) do
  if df.job_type[n] then NEED[df.job_type[n]] = true end
end

local stat = {total = 0, busy = 0, need = 0, free = 0}

-- citizens by id from the kernel's census (the kernel owns unit iteration); package.path gets lua/ once
local function census_ids()
  local me = dfhack.findScript('dfllm-hud')
  if me then
    local entry = me:gsub('[/\\]dfllm%-hud%.lua$', '') .. '/?.lua'
    if not package.path:find(entry, 1, true) then package.path = entry .. ';' .. package.path end
  end
  local ok, kern = pcall(require, 'dfllm.kern')
  local K = ok and kern.K and kern.K() or nil
  local cu = K and K.census and K.census.u
  return type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or nil
end

local function measure()
  local ids = census_ids()
  if not ids then stat.total, stat.busy, stat.need, stat.free = 0, 0, 0, 0; return end
  local total, busy, need, free = 0, 0, 0, 0
  local ok = pcall(function()
    for _, id in ipairs(ids) do
      local u = df.unit.find(id)
      if u and dfhack.units.isAdult(u) and not dfhack.units.isDead(u) then
        total = total + 1
        local j = u.job.current_job
        if not j then free = free + 1
        elseif NEED[j.job_type] then need = need + 1
        else busy = busy + 1 end
      end
    end
  end)
  if ok then stat.total, stat.busy, stat.need, stat.free = total, busy, need, free end
end

local function pct() return stat.total > 0 and (stat.busy * 100) // stat.total or 0 end

local function pen(p)
  if p >= 70 then return COLOR_LIGHTGREEN elseif p >= 40 then return COLOR_YELLOW end
  return COLOR_LIGHTRED
end

HudOverlay = defclass(HudOverlay, overlay.OverlayWidget)
HudOverlay.ATTRS {
  desc = 'Shows how busy the dwarves are, permanently (df-llm-helper).',
  default_pos = {x = -36, y = 3},
  default_enabled = true,
  viewscreens = 'dwarfmode',
  overlay_onupdate_max_freq_seconds = 1,
  frame = {w = 34, h = 2},
}

function HudOverlay:init()
  self:addviews {
    widgets.Label {
      frame = {t = 0, l = 0},
      text = {
        {text = 'Auslastung ', pen = COLOR_GREY},
        {text = function() return string.format('%d%%', pct()) end, pen = function() return pen(pct()) end},
        {text = function() return string.format('  (%d von %d)', stat.busy, stat.total) end, pen = COLOR_GREY},
        NEWLINE,
        {text = function()
          return string.format('Leerlauf %d: %d Bedarf, %d frei', stat.need + stat.free, stat.need, stat.free)
        end, pen = COLOR_GREY},
      },
    },
  }
end

function HudOverlay:overlay_onupdate() measure() end

OVERLAY_WIDGETS = {hud = HudOverlay}

if dfhack_flags.module then return end

local en = overlay.isOverlayEnabled('dfllm-hud.hud')
print('dfllm-hud: overlay ' .. (en and 'enabled' or 'disabled')
      .. '; toggle with `overlay enable|disable dfllm-hud.hud`, move it with gui/overlay')
