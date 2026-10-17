-- K.persist: contract keys (CONTRACTS §10) over dfhack.persistent site data (Lua API.txt:750-762).
-- get() returns the cached decoded table; set()/touch() mark keys dirty; kern calls flush()
-- at most every 10 s, on mode change and before unload. Site data lives in memory until DF saves.
-- FR-62: a key whose last encoding was at least env.big.bytes long is written at most every env.big.ms
-- (unless flush(true)); env.charge(key, ms) receives each write's cost on env.clock (kern books it to
-- the key's owner).
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')

local P = {}
local MISSING = setmetatable({}, {__name = 'persist.missing'})

-- env = {who = fn() -> module name or nil, violation = fn(msg), log = fn(level, msg),
--        optional: on_flush(key, v), clock() -> ms, charge(key, ms), now_ms() -> ms, big = {bytes, ms}}
function P.new(env)
  local cache, dirty = {}, {}
  local size, written = {}, {}     -- last encoded length and write time per key (big keys wait)
  local noted = {}                 -- BUG-033: keys whose size was logged (once a boot, >= 64 KB)
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

  local function due(key, all, now)
    if all or not env.big or not now then return true end
    local sz = size[key]
    return sz == nil or sz < env.big.bytes or written[key] == nil or now - written[key] >= env.big.ms
  end

  -- write dirty keys (all = every one, else big keys only every env.big.ms); returns the number written
  function store.flush(all)
    local n = 0
    local now = env.now_ms and env.now_ms()
    local clock = env.clock
    for key in pairs(dirty) do
      if due(key, all, now) then
        local t0 = clock and clock()
        local dk, v = C.persist_key(key), cache[key]
        dirty[key] = nil
        local ok, err = pcall(function()
          if v == MISSING then dfhack.persistent.deleteSiteData(dk); size[key] = nil
          else
            local enc = json.encode(v)
            dfhack.persistent.saveSiteDataString(dk, enc)
            size[key] = #enc
            if #enc >= 65536 and not noted[key] then     -- BUG-033: a record that big costs its owner each write
              noted[key] = true
              env.log('info', string.format('persist %s: %d KB encoded (its owner pays each write%s)', key, #enc // 1024,
                                            env.big and string.format(', at most every %d s', env.big.ms // 1000) or ''))
            end
          end
        end)
        written[key] = now
        if ok then
          n = n + 1
          if env.on_flush and v ~= MISSING then pcall(env.on_flush, key, v) end
        else env.log('error', 'persist flush ' .. key .. ': ' .. tostring(err)) end
        if t0 and env.charge then pcall(env.charge, key, clock() - t0) end
      end
    end
    return n
  end

  function store.dirty() return next(dirty) ~= nil end

  -- BUG-033: the last encoded size (bytes) of every key written this boot (inspect persist)
  function store.sizes()
    local r = {}
    for k, n in pairs(size) do r[k] = n end
    return r
  end

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
