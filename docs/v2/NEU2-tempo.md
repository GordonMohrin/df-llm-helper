# Neuausrichtung 2: tempo (BUG-826, 2026-11-24)

Owner request (Gordon, 24.11.): by default, when nothing special is going on, every game runs at maximum game frames and few
graphics frames, and timestream is used as much as possible. Offline, live-untested.

## What changes

| Knob (`config/reflex.json`) | Before | Now | Bounds (invalid = default) |
|---|---|---|---|
| `clock.gfps` (enabler.gfps) | 30 (constant `M.PROFILE.gfps`) | **10** | int 1..100 |
| `clock.peace_fps` (quiet PEACE timestream target) | 500 (`M.MODE_FPS.PEACE`) | **1000** | int 100..1000 |
| `deadman.min_s` | none | **45** | int 0..3600 |

Unchanged on purpose: ALERT 250 with cap 100, RECOVERY 250, SIEGE/BREACH/DRILL timestream off with cap `siege_cap` 30, the clock
lockdown (timestream off, siege cap), `trade_cap` 100, the supply brake and P0 brake (150), `tempo.lower`, popups. Quiet PEACE is
the only mode that reads `peace_fps`; anything that lowers the clock in PEACE (brake, lockdown, trade, inbox tempo) still wins
because it is applied after the mode value in `desired()`.

## The FPS cap is not raised

DF's own cap (`enabler.fps`, init FPS_CAP 250 on most instances, 60 on one) is captured at boot. The arbiter only ever lowers it
(brake, mode caps, trade clamp, tempo.lower) and puts the original back; "only the brake writes the cap" stays. In PEACE the
desired cap is `nil` (free), so `desired()` does not switch timestream off for being above the cap (that rule only applies when a
lowering cap exists). Evidence that timestream runs above the vanilla cap: live an 18-dwarf fort reached ~475 ticks/s with cap 250
(timestream runs several ticks per frame). So raising the cap is not needed for a higher target, and it was left alone; a
lowered cap in force (siege 30, alert 100, trade 100, brake 150) always keeps timestream off or below it, as before. Risk: if
timestream clips at some internal rate we have not seen, PEACE simply runs at that rate; nothing breaks.

A large fort is CPU bound (44 dwarfs ~270 ticks/s): there neither a 500 nor a 1000 target matters, the gain is in small forts and
in the 20 saved renders per second (gfps 30 to 10).

## Graphics frames

`clock_cfg(K).gfps` is written at boot (originals first in `restore.json`, restored on unload). While trade holds the clock
(`trade.clock()`), gfps rises to `M.TRADE_GFPS` 30 (never below the configured value) and falls back after: the trade UI clicks
wait `CLICK_MS` 100 and `STABLE_MS` 200, which need a render every <= 34 ms (at gfps 10 a frame is 100 ms). The crash heal treats
the configured gfps and 30 as "ours" (a live value that is neither is the player's and is left alone).

## Dead-man: real time is the primary bound

`deadman` pauses the game when no live session heartbeat (`session.json` `wall`) is younger than `timeout_s` (180 real seconds,
primary bound) or when the game ran more than `max_ticks` (24000 ticks = 20 game days) since the heartbeat changed. At 1000
ticks/s 24000 ticks are 24 real seconds, shorter than a player thinks between commands. Rule now: the tick bound fires only when
**also** the heartbeat is at least `min_s` (45) real seconds old (`age >= min_s`). `wait` writes the heartbeat every 10 s, so a
live session never reaches 45 s; `timeout_s` and `missing`/`future` are untouched and not delayed by `min_s`.

Worst case of unattended game time (dead session, check every `check_s` 5 s, so the pause comes at most 50 s resp. 185 s after the
last heartbeat):

| Rate | Before (max 24000, no min) | Now (min_s 45) |
|---|---|---|
| 270 ticks/s (44 dwarfs) | 24000 ticks = 20 days | 24000 ticks = 20 days (reached after 89 s, age >= 45) |
| 475 ticks/s (18 dwarfs) | 24000 = 20 days | 24000 = 20 days (after 51 s) |
| 1000 ticks/s (theoretical top) | 24000 = 20 days | at most 50 s * 1000 = **50,000 ticks = 41.7 days** |

So the real-world worst case stays 20 to 21 game days; only a fort that really reaches 1000 ticks/s can run up to about 42 days
unattended. With `max_ticks` 0 (no game-time bound) the wall bound alone allows 185 s * rate = 154 days at 1000 ticks/s (as it did
at 500 ticks/s: 77 days). Trade-off: a higher `min_s` means more game days pass unattended at high speed; set `min_s` 0 to get the
old pure tick bound back.

## Status

`state.clock` gains `gfps` (the live graphics frame rate set by the arbiter, 0 = profile not applied) and `pt` (the configured
quiet-PEACE target); `ts` is the timestream target actually driven (-1 when D-11 leaves timestream alone). The status clock line:

- quiet PEACE: `clock: free (cap 250, timestream 1000, gfps 10)`
- lowered: `clock: held 30 t/s, reason siege, gfps 10`
- trade: `clock: held 100 t/s, reason trade, gfps 30`

## Live-Erwartung

1. `python -m dfpilot status` of a quiet PEACE fort: `timestream 1000` and `gfps 10` in the clock line; at a caravan `gfps 30`; in SIEGE/ALERT the old held cap with `gfps 10`.
2. Small forts (about 20 dwarfs) show clearly more than the earlier ~475 ticks/s; forts of 40+ dwarfs stay near their CPU limit (about 270). Nothing is faster in SIEGE, BREACH, ALERT, DRILL or while the brake holds.
3. No `DEADMAN_PAUSE` `why: ticks` while the session is alive; a dead session still pauses within about 185 real seconds (about 50 s for the tick bound).
4. kern.log: no `fps cap` raise ever; caravan trades still complete (no `ui_timeout` at gfps 10, the trade clamp runs gfps 30).

## Tests

`tests/lua/test_bug826_tempo.lua`, `tests/lua/test_neu1_deadman.lua` (min_s), `tests/lua/test_kern_arbiter.lua` (values moved), `tests/test_bug826_tempo.py`.
