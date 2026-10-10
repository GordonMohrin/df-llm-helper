-- dfllm JSON: compact, deterministic, locale-proof, UTF-8 safe. Pure Lua 5.3, no DFHack.
--   encode(v) -> string     numbers are written as integers only (floats rounded half away
--                           from zero, NaN/inf -> null); object keys sorted; invalid UTF-8
--                           bytes -> U+FFFD; raises on functions/userdata/cycles/depth>64.
--   decode(s) -> value      raises 'json: <msg> at byte N'; null in objects drops the key,
--                           null in arrays -> json.null; integral numbers -> Lua integers.
--   try_decode(s) -> value | nil, err
--   null, array(t), object(t), is_array(t)
-- Empty plain table encodes as [] ; use json.object{} for an empty object (CONTRACTS §2.3).
local M = {}

local ARRAY = {__name = 'json.array'}
local OBJECT = {__name = 'json.object'}
M.null = setmetatable({}, {__name = 'json.null', __tostring = function() return 'null' end})

function M.array(t) return setmetatable(t or {}, ARRAY) end
function M.object(t) return setmetatable(t or {}, OBJECT) end
function M.is_array(t) return getmetatable(t) == ARRAY end

local byte, char, fmt, concat = string.byte, string.char, string.format, table.concat
local tointeger, mtype, floor = math.tointeger, math.type, math.floor
local HUGE = math.huge

---------------------------------------------------------------- encode
local ESC = {['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
             ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
for i = 0, 31 do
  local c = char(i)
  if not ESC[c] then ESC[c] = fmt('\\u%04x', i) end
end
ESC['\127'] = '\\u007f'

-- Replace invalid UTF-8 (overlong, surrogates, > U+10FFFF, truncated) with U+FFFD.
local function utf8_clean(s)
  if not s:find('[\128-\255]') then return s end
  local out, n, i, len = {}, 0, 1, #s
  local start = 1
  while i <= len do
    local c = byte(s, i)
    if c < 0x80 then
      i = i + 1
    else
      local need, min
      if c >= 0xC2 and c <= 0xDF then need, min = 1, 0x80
      elseif c >= 0xE0 and c <= 0xEF then need, min = 2, 0x800
      elseif c >= 0xF0 and c <= 0xF4 then need, min = 3, 0x10000
      end
      local cp, ok = 0, need ~= nil
      if ok then
        cp = c & (0x3F >> need)
        for k = 1, need do
          local cc = byte(s, i + k)
          if not cc or cc < 0x80 or cc > 0xBF then ok = false; break end
          cp = (cp << 6) | (cc & 0x3F)
        end
        ok = ok and cp >= min and cp <= 0x10FFFF and not (cp >= 0xD800 and cp <= 0xDFFF)
      end
      if ok then
        i = i + need + 1
      else
        n = n + 1; out[n] = s:sub(start, i - 1)
        n = n + 1; out[n] = '\239\191\189'
        i = i + 1
        start = i
      end
    end
  end
  if start == 1 then return s end
  n = n + 1; out[n] = s:sub(start)
  return concat(out, '', 1, n)
end
M.utf8_clean = utf8_clean

-- explicit byte classes: %c/%a depend on LC_CTYPE (CONTRACTS §2.3)
local function enc_string(s)
  return '"' .. utf8_clean(s):gsub('[\0-\31\127"\\]', ESC) .. '"'
end

local function enc_number(x)
  if mtype(x) == 'integer' then return fmt('%d', x) end
  if x ~= x or x == HUGE or x == -HUGE then return 'null' end
  local r = x >= 0 and floor(x + 0.5) or -floor(-x + 0.5)
  local i = tointeger(r)
  if i then return fmt('%d', i) end
  return fmt('%.0f', r) -- beyond 2^63: no decimal point, so no locale comma
end

local function key_string(k)
  local tk = type(k)
  if tk == 'string' then return k end
  if tk == 'number' and mtype(k) == 'integer' then return fmt('%d', k) end
  error('json: object key must be a string or integer, got ' .. (tk == 'number' and 'float' or tk), 0)
end

local enc_value

local function enc_table(t, depth, seen, buf)
  if depth > 64 then error('json: nesting deeper than 64', 0) end
  if seen[t] then error('json: cycle detected', 0) end
  seen[t] = true
  local mt = getmetatable(t)
  local n = #t
  local as_array
  if mt == ARRAY then
    as_array = true
  elseif mt == OBJECT then
    as_array = false
  else
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    as_array = (count == n) -- includes the empty table -> []
  end
  if as_array then
    buf[#buf + 1] = '['
    for i = 1, n do
      if i > 1 then buf[#buf + 1] = ',' end
      enc_value(t[i], depth + 1, seen, buf)
    end
    buf[#buf + 1] = ']'
  else
    local keys, map = {}, {}
    for k in pairs(t) do
      local ks = key_string(k)
      if map[ks] ~= nil then error('json: duplicate key ' .. ks, 0) end
      map[ks] = k
      keys[#keys + 1] = ks
    end
    table.sort(keys)
    buf[#buf + 1] = '{'
    for i, ks in ipairs(keys) do
      if i > 1 then buf[#buf + 1] = ',' end
      buf[#buf + 1] = enc_string(ks)
      buf[#buf + 1] = ':'
      enc_value(t[map[ks]], depth + 1, seen, buf)
    end
    buf[#buf + 1] = '}'
  end
  seen[t] = nil
end

function enc_value(v, depth, seen, buf)
  local tv = type(v)
  if v == nil or v == M.null then buf[#buf + 1] = 'null'
  elseif tv == 'boolean' then buf[#buf + 1] = v and 'true' or 'false'
  elseif tv == 'number' then buf[#buf + 1] = enc_number(v)
  elseif tv == 'string' then buf[#buf + 1] = enc_string(v)
  elseif tv == 'table' then enc_table(v, depth, seen, buf)
  else error('json: cannot encode ' .. tv, 0) end
end

function M.encode(v)
  local buf = {}
  enc_value(v, 0, {}, buf)
  return concat(buf)
end

---------------------------------------------------------------- decode
local function derr(msg, pos) error(fmt('json: %s at byte %d', msg, pos), 0) end

local function skip_ws(s, pos)
  return s:find('[^ \t\r\n]', pos) or #s + 1
end

local function utf8_of(cp)
  if cp < 0x80 then return char(cp) end
  if cp < 0x800 then return char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)) end
  if cp < 0x10000 then
    return char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  end
  return char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
end

local UNESC = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}

local function dec_string(s, pos) -- pos at opening quote; returns string, next pos
  local out, n, i = {}, 0, pos + 1
  while true do
    local j = s:find('[\0-\31"\\]', i)
    if not j then derr('unterminated string', pos) end
    local c = s:sub(j, j)
    if j > i then n = n + 1; out[n] = s:sub(i, j - 1) end
    if c == '"' then return concat(out, '', 1, n), j + 1 end
    if c ~= '\\' then derr('control character in string', j) end
    local e = s:sub(j + 1, j + 1)
    if e == 'u' then
      local hex = s:match('^%x%x%x%x', j + 2)
      if not hex then derr('bad \\u escape', j) end
      local cp = tonumber(hex, 16)
      local nxt = j + 6
      if cp >= 0xD800 and cp <= 0xDBFF then
        local lo = s:match('^\\u(%x%x%x%x)', nxt)
        lo = lo and tonumber(lo, 16)
        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
          cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
          nxt = nxt + 6
        else
          cp = 0xFFFD
        end
      elseif cp >= 0xDC00 and cp <= 0xDFFF then
        cp = 0xFFFD
      end
      n = n + 1; out[n] = utf8_of(cp)
      i = nxt
    else
      local u = UNESC[e]
      if not u then derr('bad escape', j) end
      n = n + 1; out[n] = u
      i = j + 2
    end
  end
end

local function dec_number(s, pos)
  local int = s:match('^-?%d+', pos)
  if not int then derr('unexpected character', pos) end
  local stop = pos + #int
  local frac = s:match('^%.%d+', stop)
  if frac then stop = stop + #frac end
  local exp = s:match('^[eE][-+]?%d+', stop)
  if exp then stop = stop + #exp end
  local tok = s:sub(pos, stop - 1)
  local v = tonumber(tok) -- Lua 5.3 retries with the locale decimal point, so '1.5' parses under ','
  if not v then derr('bad number', pos) end
  if mtype(v) == 'float' then v = tointeger(v) or v end
  return v, stop
end

local dec_value

local function dec_array(s, pos, depth)
  local t, n = setmetatable({}, ARRAY), 0
  pos = skip_ws(s, pos + 1)
  if s:sub(pos, pos) == ']' then return t, pos + 1 end
  while true do
    local v
    v, pos = dec_value(s, pos, depth + 1)
    n = n + 1
    t[n] = (v == nil) and M.null or v
    pos = skip_ws(s, pos)
    local c = s:sub(pos, pos)
    if c == ']' then return t, pos + 1 end
    if c ~= ',' then derr("expected ',' or ']'", pos) end
    pos = skip_ws(s, pos + 1)
  end
end

local function dec_object(s, pos, depth)
  local t = setmetatable({}, OBJECT)
  pos = skip_ws(s, pos + 1)
  if s:sub(pos, pos) == '}' then return t, pos + 1 end
  while true do
    if s:sub(pos, pos) ~= '"' then derr('expected string key', pos) end
    local k
    k, pos = dec_string(s, pos)
    pos = skip_ws(s, pos)
    if s:sub(pos, pos) ~= ':' then derr("expected ':'", pos) end
    local v
    v, pos = dec_value(s, skip_ws(s, pos + 1), depth + 1)
    t[k] = v -- null -> key absent
    pos = skip_ws(s, pos)
    local c = s:sub(pos, pos)
    if c == '}' then return t, pos + 1 end
    if c ~= ',' then derr("expected ',' or '}'", pos) end
    pos = skip_ws(s, pos + 1)
  end
end

function dec_value(s, pos, depth)
  if depth > 200 then derr('nesting too deep', pos) end
  pos = skip_ws(s, pos)
  local c = s:sub(pos, pos)
  if c == '{' then return dec_object(s, pos, depth)
  elseif c == '[' then return dec_array(s, pos, depth)
  elseif c == '"' then return dec_string(s, pos)
  elseif c == 't' and s:sub(pos, pos + 3) == 'true' then return true, pos + 4
  elseif c == 'f' and s:sub(pos, pos + 4) == 'false' then return false, pos + 5
  elseif c == 'n' and s:sub(pos, pos + 3) == 'null' then return nil, pos + 4
  elseif c == '' then derr('unexpected end of input', pos)
  else return dec_number(s, pos) end
end

function M.decode(s)
  if type(s) ~= 'string' then error('json: decode expects a string, got ' .. type(s), 0) end
  local pos = 1
  if s:sub(1, 3) == '\239\187\191' then pos = 4 end -- UTF-8 BOM
  local v, nxt = dec_value(s, pos, 0)
  nxt = skip_ws(s, nxt)
  if nxt <= #s then derr('trailing garbage', nxt) end
  if v == nil then return M.null end
  return v
end

function M.try_decode(s)
  local ok, v = pcall(M.decode, s)
  if ok then return v end
  return nil, v
end

return M
