-- FR-78 (Run 14 note 65): the verb zone.place: a civzone (pen, pit, pond, sand, clay, fishing, meeting) in a box through
-- quickfort's zone mode. zonelib (the cell text, the refusals), act.zone_place (the zone appears, the pond setting), the
-- verb on a kernel with a runner and a tile reader.
local T = require('testlib')
local H = require('kern_world')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
local actlib = require('dfllm.act')
local Z = require('dfllm.zonelib')

local function mk(who)
  local env = {lines = {}, fails = {}}
  env.api = actlib.new{
    who = function() return who end,
    allowlist = function() return actlib.BUILTIN_ALLOWLIST end,
    log_cmd = function(origin, what, args, result) env.lines[#env.lines + 1] = {origin, what, args, result} end,
    fail = function(fn, err, module) env.fails[#env.fails + 1] = {fn, err, module} end,
  }
  return env
end

---------------------------------------------------------------- the blueprint text
T.test('FR-78: the cell text per type: quickfort zone keys, the pit has no pond property, a pond has, the name goes in', function()
  local box = {x0 = 10, y0 = 20, x1 = 13, y1 = 22, z = 5}
  local want = {pen = 'n(4x3)', pit = 'p(4x3)', pond = 'p{pond=true}(4x3)', sand = 's(4x3)', clay = 'c(4x3)',
                fishing = 'f(4x3)', meeting = 'm(4x3)', dump = 'd(4x3)'}
  for _, ty in ipairs(Z.ORDER) do
    local cell, pos = Z.cell(ty, box)
    T.eq(cell, want[ty], ty)
    T.eq(pos, {10, 20, 5})
  end
  T.eq((Z.cell('pond', box, 'ward-pond')), 'p{pond=true name=ward-pond}(4x3)')
  T.eq((Z.cell('pen', box, 'pasture')), 'n{name=pasture}(4x3)')
  T.eq(#Z.ORDER, 8)
  T.ok(#Z.cell('pond', {x0 = 0, y0 = 0, x1 = 19, y1 = 19, z = 0}, string.rep('n', 24)) <= 64, 'a cell stays under the 64 characters')
end)

T.test('FR-78: spec refusals: type, bbox shape and order, one level, size, name', function()
  local function bad(args) local s, why = Z.spec(args, 400); T.eq(s, nil); return why end
  T.ok(bad({type = 'garden', bbox = {1, 1, 1, 2, 2, 1}}):find('type must be one of pen, pit, pond, sand, clay, fishing, meeting, dump', 1, true))
  T.ok(bad({type = 'pen'}):find('bbox must be', 1, true))
  T.ok(bad({type = 'pen', bbox = {1, 1, 1, 2, 2}}):find('bbox must be', 1, true))
  T.ok(bad({type = 'pen', bbox = {1, 1, 1, 2, 2, 'x'}}):find('six integers', 1, true))
  T.ok(bad({type = 'pen', bbox = {5, 1, 1, 2, 2, 1}}):find('ordered', 1, true))
  T.ok(bad({type = 'pen', bbox = {1, 1, 1, 2, 2, 2}}):find('one level per zone', 1, true))
  T.ok(bad({type = 'pen', bbox = {0, 0, 1, 20, 20, 1}}):find('441 tiles: a zone holds at most 400', 1, true))
  T.ok(bad({type = 'pen', bbox = {1, 1, 1, 2, 2, 1}, name = 'two words'}):find('name must be', 1, true))
  T.ok(bad({type = 'pen', bbox = {1, 1, 1, 2, 2, 1}, name = 7}):find('name must be', 1, true))
  local s = Z.spec({type = 'pit', bbox = {3, 4, 9, 5, 6, 9}, name = 'p1'}, 400)
  T.eq({s.type, s.name, s.box}, {'pit', 'p1', {x0 = 3, y0 = 4, x1 = 5, y1 = 6, z = 9}})
  T.eq((Z.spec({type = 'pen', bbox = {0, 0, 1, 19, 19, 1}}, 400)).box.x1, 19, '20x20 = 400 tiles is the limit')
end)

T.test('FR-78: tiles: hidden or off-map, rock, open air, water (fishing only) refuse the box', function()
  local map = {}
  local function tile(x, y, z) return map[x .. ',' .. y .. ',' .. z] or {c = '.'} end
  local box = {x0 = 1, y0 = 1, x1 = 2, y1 = 2, z = 3}
  T.eq(Z.tiles_ok('pen', box, tile), nil)
  map['2,1,3'] = false
  T.ok(Z.tiles_ok('pen', box, function(x, y, z) local t = map[x .. ',' .. y .. ',' .. z]; if t == false then return nil end return t or {c = '.'} end)
       :find('tile 2,1,3 is not revealed or off the map', 1, true))
  map['2,1,3'] = nil
  map['1,2,3'] = {c = '#'}
  T.eq(Z.tiles_ok('pen', box, tile), 'tile 1,2,3 is rock or a wall')
  map['1,2,3'] = {c = '_'}
  T.eq(Z.tiles_ok('sand', box, tile), 'tile 1,2,3 is open air')
  map['1,2,3'] = {c = '~'}
  T.eq(Z.tiles_ok('pit', box, tile), 'tile 1,2,3 is water: only a fishing zone covers water')
  T.eq(Z.tiles_ok('fishing', box, tile), nil)
  map['1,2,3'] = {c = 'r'}
  T.eq(Z.tiles_ok('pen', box, tile), nil, 'a ramp is a floor')
end)

T.test('FR-78: conflicts: the same type, locations, room zones for animals, pit/pond against pen/meeting', function()
  local function zone(id, tname, over)
    local z = {id = id, tname = tname, loc = -1, name = '', x0 = 10, y0 = 10, x1 = 14, y1 = 14, z = 5}
    for k, v in pairs(over or {}) do z[k] = v end
    return z
  end
  local box = {x0 = 12, y0 = 12, x1 = 16, y1 = 16, z = 5}
  local function c(ty, zones, b) return Z.conflict(ty, b or box, zones) end
  T.eq(c('pen', {}), nil)
  T.eq(c('pen', {zone(1, 'Pen')}), 'overlaps zone 1 (Pen) at 10-14,10-14 z5, which has the same type')
  T.ok(c('pit', {zone(2, 'Pond')}):find('has the same type', 1, true), 'a pit over a pond/pit zone')
  T.ok(c('pond', {zone(3, 'Barracks', {name = 'Armory'})}):find('overlaps zone 3 (Barracks "Armory")', 1, true))
  T.ok(c('pen', {zone(3, 'Barracks')}):find('is a room zone', 1, true), 'the note-65 case: a pen beside/over the barracks')
  T.ok(c('pit', {zone(4, 'Bedroom')}):find('is a room zone', 1, true))
  T.eq(c('sand', {zone(4, 'Bedroom')}), nil, 'sand over a bedroom is no conflict of ours')
  T.ok(c('sand', {zone(5, 'MeetingHall', {loc = 6})}):find('is a location', 1, true), 'a hospital/temple/tavern is a location')
  T.ok(c('pen', {zone(6, 'Pond')}):find('is a pit/pond zone', 1, true))
  T.ok(c('pit', {zone(7, 'Pen')}):find('is a Pen zone', 1, true))
  T.ok(c('pond', {zone(8, 'MeetingHall')}):find('is a MeetingHall zone', 1, true))
  T.ok(c('meeting', {zone(9, 'Pen')}):find('is a Pen zone', 1, true))
  T.ok(c('meeting', {zone(9, 'MeetingHall')}):find('has the same type', 1, true))
  T.eq(c('fishing', {zone(10, 'Pen')}), nil)
  T.eq(c('pen', {zone(11, 'Pen')}, {x0 = 15, y0 = 15, x1 = 18, y1 = 18, z = 5}), nil, 'a box clear of the zone')
  T.eq(c('pen', {zone(11, 'Pen', {z = 6})}), nil, 'another level')
  -- an irregular zone: the rectangles meet, no tile does
  T.eq(c('pen', {zone(12, 'Pen', {has = function(x, y) return x == 10 and y == 10 end})}), nil)
  T.ok(c('pen', {zone(12, 'Pen', {has = function(x, y) return x == 13 and y == 13 end})}))
end)

---------------------------------------------------------------- act.zone_place
T.test('FR-78 act.zone_place: one quickfort zone cell at the corner; the new zones come back; a pit is not kept filled', function()
  local W = H.world{tag = 'zp'}
  local zones = kmock.vec{}
  df.global.world.buildings.other.ACTIVITY_ZONE = zones
  local calls, nextid = {}, 100
  local created = true
  W.scripts['quickfort'] = {apply_blueprint = function(p)
    calls[#calls + 1] = p
    if created then
      nextid = nextid + 1
      zones:insert('#', {id = nextid, zone_settings = {pond = {flag = {keep_filled = true}}}})   -- the game's default
    end
    return {zone_designated = {label = 'Zones designated', value = created and 1 or 0}}
  end}
  local env = mk('runner')
  local ok, res = env.api.zone_place({cell = 'p(4x3)', pos = {10, 20, 5}, pond = false})
  T.ok(ok)
  T.eq({res.ids, res.pond}, {{101}, false})
  T.eq(zones[0].zone_settings.pond.flag.keep_filled, false, 'the pit setting was written')
  T.eq({calls[1].mode, calls[1].command, calls[1].pos}, {'zone', 'run', {x = 10, y = 20, z = 5}})
  T.eq(calls[1].data[0][0][0], 'p(4x3)')
  ok, res = env.api.zone_place({cell = 'p{pond=true}(2x2)', pos = {1, 2, 3}, pond = true})
  T.eq({ok, res.ids, res.pond}, {true, {102}, true})
  ok, res = env.api.zone_place({cell = 'n(4x3)', pos = {10, 20, 5}})
  T.eq({ok, res.ids, res.pond}, {true, {103}, nil}, 'a pen: no pond setting')
  T.eq(zones[2].zone_settings.pond.flag.keep_filled, true, 'untouched')
  created = false
  T.eq({env.api.zone_place({cell = 'n(4x3)', pos = {10, 20, 5}})}, {false, 'quickfort designated no zone there'})
  T.eq({env.api.zone_place({cell = '', pos = {10, 20, 5}})}, {false, 'spec.cell required (<= 64 characters)'})
  T.eq({env.api.zone_place({cell = 'n(1x1)', pos = {10, 20}})}, {false, 'spec.pos must be {x,y,z}'})
  T.eq((mk('economy').api.zone_place({cell = 'n(1x1)', pos = {1, 2, 3}})), false, 'runner only')
end)

---------------------------------------------------------------- the verb
local function zworld(opts)
  opts = opts or {}
  local W = F.world{cfg = {baseline = F.cfg()}, units = {{id = 1, citizen = true}}}
  W.tiles = opts.tiles or {}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile(K, x, y, z)
    local t = W.tiles[x .. ',' .. y .. ',' .. z]
    if t == false then return nil end
    return t or {c = '.', dig = '', bld = ''}
  end
  local runner = {name = 'runner', every = {ticks = 600}, verbs = {}}
  runner.verbs['zone.place'] = function(K, args, cmd) return Z.verb(K, args, cmd) end
  W.created = {}
  W.act_result('zone_place', function(spec)
    W.created[#W.created + 1] = spec
    return true, {ids = {500 + #W.created}, pond = spec.pond}
  end)
  W.load(snap)
  W.load(runner)
  return W
end

T.test('FR-78: zone.place draws the zone: the cell, the corner, the zone id back; the pit carries its setting', function()
  local W = zworld()
  local r = W.inbox('zone.place', {type = 'pen', bbox = {10, 20, 5, 13, 22, 5}, name = 'taming'})
  T.ok(r.ok, r.msg)
  T.eq(r.data.zone, 501)
  T.eq({r.data.type, r.data.bbox, r.data.cell}, {'pen', {10, 20, 5, 13, 22, 5}, 'n{name=taming}(4x3)'})
  T.eq(r.msg, 'pen zone 501 at 10,20-13,22 z5')
  T.eq({W.created[1].cell, W.created[1].pos, W.created[1].pond, W.created[1].ztype}, {'n{name=taming}(4x3)', {10, 20, 5}, nil, 'Pen'})
  r = W.inbox('zone.place', {type = 'pit', bbox = {30, 30, 5, 31, 31, 5}})
  T.ok(r.ok, r.msg)
  T.eq({W.created[2].cell, W.created[2].pond}, {'p(2x2)', false})
  r = W.inbox('zone.place', {type = 'pond', bbox = {40, 30, 5, 41, 31, 5}})
  T.eq({W.created[3].cell, W.created[3].pond, r.data.pond}, {'p{pond=true}(2x2)', true, true})
  T.eq(#W.commands, 0, 'no command: only the act')
end)

T.test('FR-78: zone.place refusals: modes, hidden/rock/water tiles, size, conflicting zones, no tile reader, config', function()
  local W = zworld{tiles = {['11,21,5'] = false, ['50,50,5'] = {c = '#'}, ['60,60,5'] = {c = '~'}}}
  local function refused(args, needle)
    local r = W.inbox('zone.place', args)
    T.ok(not r.ok, 'expected a refusal: ' .. tostring(r.msg))
    T.ok(r.msg:find(needle, 1, true), r.msg)
  end
  refused({type = 'pen', bbox = {10, 20, 5, 13, 22, 5}}, 'tile 11,21,5 is not revealed or off the map')
  refused({type = 'pen', bbox = {49, 49, 5, 50, 50, 5}}, 'tile 50,50,5 is rock or a wall')
  refused({type = 'meeting', bbox = {60, 60, 5, 60, 60, 5}}, 'is water: only a fishing zone covers water')
  T.ok(W.inbox('zone.place', {type = 'fishing', bbox = {60, 60, 5, 60, 60, 5}}).ok, 'a fishing zone covers water')
  refused({type = 'pen', bbox = {0, 0, 5, 30, 30, 5}}, '961 tiles: a zone holds at most 400')
  refused({type = 'pen', bbox = {0, 0, 5, 1, 1, 6}}, 'one level per zone')
  -- the note-65 case: a pen over the barracks zone, a pit over a pen
  F.building(W, 'ACTIVITY_ZONE', {id = 23421, type = 'Barracks', x1 = 100, y1 = 100, x2 = 110, y2 = 105, z = 7, location_id = -1,
                                  name = 'Waffenkammer'})
  F.building(W, 'ACTIVITY_ZONE', {id = 23430, type = 'Pen', x1 = 120, y1 = 100, x2 = 125, y2 = 105, z = 7, location_id = -1})
  F.building(W, 'ACTIVITY_ZONE', {id = 23440, type = 'MeetingHall', x1 = 130, y1 = 100, x2 = 135, y2 = 105, z = 7, location_id = 8})
  df.civzone_type = df.civzone_type or {}
  for _, n in ipairs({'Barracks', 'Pen', 'MeetingHall'}) do df.civzone_type[n] = n; df.civzone_type[n:lower()] = nil end
  refused({type = 'pen', bbox = {105, 102, 7, 112, 106, 7}}, 'overlaps zone 23421 (Barracks "Waffenkammer") at 100-110,100-105 z7, which is a room zone')
  refused({type = 'pit', bbox = {123, 103, 7, 124, 104, 7}}, 'zone 23430 (Pen)')
  refused({type = 'sand', bbox = {133, 103, 7, 134, 104, 7}}, 'is a location')
  T.ok(W.inbox('zone.place', {type = 'pen', bbox = {112, 100, 7, 118, 105, 7}}).ok, 'beside the barracks is fine')
  -- fights and bad arguments
  W.set_mode('SIEGE')
  refused({type = 'pen', bbox = {200, 200, 5, 201, 201, 5}}, 'zone.place not allowed in SIEGE')
  W.set_mode('PEACE')
  refused({type = 'garden', bbox = {200, 200, 5, 201, 201, 5}}, 'type must be one of')
  -- config zones.max_tiles
  local cfg = F.cfg()
  cfg.zones = {max_tiles = 4}
  W.K.cfg.baseline = cfg
  refused({type = 'pen', bbox = {200, 200, 5, 202, 201, 5}}, '6 tiles: a zone holds at most 4')
  cfg.zones = {max_tiles = 'many'}
  T.ok(W.inbox('zone.place', {type = 'pen', bbox = {200, 200, 5, 202, 201, 5}}).ok, 'a bad value keeps the default 400')
end)

T.test('FR-78: no tile reader: nothing is drawn on tiles nobody read', function()
  local W = F.world{cfg = {baseline = F.cfg()}, units = {{id = 1, citizen = true}}}
  local runner = {name = 'runner', every = {ticks = 600}, verbs = {}}
  runner.verbs['zone.place'] = function(K, args, cmd) return Z.verb(K, args, cmd) end
  W.load(runner)
  W.mods.snapshot = nil                                    -- (the world may carry a default one)
  local r = W.inbox('zone.place', {type = 'pen', bbox = {1, 1, 1, 2, 2, 1}})
  T.ok(not r.ok and r.msg:find('no tile reader', 1, true), r.msg)
  T.eq(#W.find_acts('zone_place'), 0)
end)

T.done()
