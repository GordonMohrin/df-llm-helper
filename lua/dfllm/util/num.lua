-- dfllm.util.num (BUG-143, live test i3: "has held the BREACH for 1,0 days", "cleared after 10,0 days"): DF/DFHack runs
-- with LC_NUMERIC set to the player's locale (German_Germany.utf8 on Gordon's machine), and Lua's string.format('%.1f'),
-- tostring(float) and float .. string take that locale's decimal comma. The kernel never formats a decimal with them:
-- M.dec formats with integer math and always writes '.'. os.setlocale is not an option (process-wide, it would change
-- DF itself). tests/test_live_siege_i3.py pins that no kernel file uses a %.Nf/%g/%e format.
local M = {}

local POW = {[0] = 1, 10, 100, 1000, 10000}

-- x rounded to n decimals (0..4, default 1), half away from zero, with a '.' whatever the locale: dec(4.75) = '4.8',
-- dec(-0.04) = '0.0', dec(3, 2) = '3.00'; a non-number is tostring'ed, nan/inf read 'nan'/'inf'/'-inf'
function M.dec(x, n)
  n = math.tointeger(n) or 1
  if n < 0 then n = 0 elseif n > 4 then n = 4 end
  if type(x) ~= 'number' then return tostring(x) end
  if x ~= x then return 'nan' end
  if x == math.huge then return 'inf' end
  if x == -math.huge then return '-inf' end
  local p = POW[n]
  local m = math.floor(math.abs(x) * p + 0.5)
  local mi = math.tointeger(m)
  if not mi then return string.format('%.0f', x) end      -- beyond 2^63: no decimal point, so no locale comma
  local sign = (x < 0 and mi > 0) and '-' or ''
  if n == 0 then return sign .. string.format('%d', mi) end
  return string.format('%s%d.%0' .. n .. 'd', sign, mi // p, mi % p)
end

return M
