-- K.persist: contract keys (CONTRACTS §10) over dfhack.persistent site data (Lua API.txt:750-762).
-- get() returns the cached decoded table; set()/touch() mark keys dirty; kern calls flush()
-- at most every 10 s, on mode change and before unload. Site data lives in memory until DF saves.
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')

local P = {}
local MISSING = setmetatable({}, {__name = 'persist.missing'})

-- env = {who = fn() -> module name or nil, violation = fn(msg), log = fn(level, msg)}
function P.new(env)
  local cache, dirty = {}, {}
  local store = {}
  local api = {}

  local function owner_ok(key)
    local who = env.who()
    if who == nil or who == 'kern' then return true end
    local e = C.PERSIST[key]
    if e then return e.owner == who end
    if key:match('^bp%.') then return who == 'runner' end
    return key:match('^m%.(.+)$') == who
  end

  local function dkey(key)
    if type(key) ~= 'string' then return nil end
    return C.persist_key(key)
  end

  function api.get(key)
    local dk = dkey(key)
    if not dk then env.violation('unknown persist key ' .. tostring(key)); return nil end
    local v = cache[key]
    if v == nil then
      v = MISSING
      local raw = dfhack.persistent.getSiteDataString(dk)
      if raw then
        local dec, err = json.try_decode(raw)
        if type(dec) == 'table' and dec ~= json.null then v = dec
        else env.log('error', 'persist ' .. key .. ' unreadable: ' .. tostring(err)) end
      end
      cache[key] = v
    end
    if v == MISSING then return nil end
    return v
  end

  function api.set(key, v)
    if not dkey(key) then return env.violation('unknown persist key ' .. tostring(key)) end
    if not owner_ok(key) then return env.violation(tostring(env.who()) .. ' may not write persist ' .. key) end
    if v ~= nil and type(v) ~= 'table' then return env.violation('persist ' .. key .. ' must be a table') end
    cache[key] = (v == nil) and MISSING or v
    dirty[key] = true
  end

  function api.touch(key)
    if not dkey(key) then return env.violation('unknown persist key ' .. tostring(key)) end
    if not owner_ok(key) then return env.violation(tostring(env.who()) .. ' may not write persist ' .. key) end
    if cache[key] ~= nil and cache[key] ~= MISSING then dirty[key] = true end
  end

  -- write dirty keys; returns the number written
  function store.flush()
    local n = 0
    for key in pairs(dirty) do
      local dk, v = C.persist_key(key), cache[key]
      dirty[key] = nil
      local ok, err = pcall(function()
        if v == MISSING then dfhack.persistent.deleteSiteData(dk)
        else dfhack.persistent.saveSiteDataString(dk, json.encode(v)) end
      end)
      if ok then n = n + 1 else env.log('error', 'persist flush ' .. key .. ': ' .. tostring(err)) end
    end
    return n
  end

  function store.dirty() return next(dirty) ~= nil end

  -- cached keys that hold a value (for inspect)
  function store.keys()
    local r = {}
    for k, v in pairs(cache) do if v ~= MISSING then r[#r + 1] = k end end
    table.sort(r)
    return r
  end

  return api, store
end

return P
