# BUG-672 Four woolly mammoths at the well hold BREACH, the PREDATOR lockdown and the 30 t/s clock for 380 days
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16b i2 Whirledrampart y414-y431 (`runs/run-16b/FR-BUGS.md` "Mammut-BREACH >370 d"; runtime `r16b7-whirledrampart-site98/events.jsonl:439-499`, `state.a.json`): `CENOZOIC_MAMMOTH_WOOLLY` 29104-29106 (555,000-709,000 cm3) at the well 121,134,136 inside Kern+, never an attack in 380 days
Module: `lua/dfllm/reflex.lua` (`pv_kind`, `pv_step`, `pv_mark`, `far_scan`, `quiet_block`, `far_now`, `M.pv_ids`), `lua/dfllm/seal.lua` (`groups`), `config/reflex.json`

## Actual
- BREACH (`hostile inside Kern+`), the PREDATOR lockdown (`clock 30 t/s, alert`), every project `BLOCKED:frozen`, `alert burrow Kern+ -> none` over and over, `lockdown_long` (limit 10 d) offering a sortie nobody could send: 380 days of a fort at a sixteenth of its speed because of animals that only drink.
- `alarm.by`: `hw "large predator"`, `hl 0`: every size rule (`confine.harmless_size` 20000) calls them dangerous.

## Root cause
`sense.lua:792` (`entry.pr = 1` for `big_wild`, BUG-439: a big wild beast on a roofed tile is a danger BEFORE it kills) is the right default for a mammoth that walks into a room with dwarves, but nothing ever takes it back: `threat.lua` `assess` counts it as `inside`, `siege.lua:1041`/`1048` (`a.inside > 0`) keeps the BREACH, `reflex.lua` `confine_picture` / `lone_picture` / `harmless` call it dangerous by size, the lone-intruder clock (BUG-112) needs `lone_max` 2 of them and a harmless size, `lockdown_long` offers a sortie only. The census already marks a plant eater (`hb`, BUG-554) and a killer (`kl`, BUG-421); no module used the time a plant eater has stood in the fort without a kill.

## Fix
- `reflex.pv_kind` / `pv_step` (each fresh census): a unit with `hb == 1` and no `kl` is timed (`st.pv[id] = {k = 'p', t}`; a gap in the census longer than `PV_GAP` 2,400 ticks starts it again). After `confine.passive_days` (3, 0 = off) game days `pv_mark` puts it on the cleared list (`far.ids`, `far.hl`, `far.ig`, new `far.pv`): threat subtracts it from `inside` (BUG-112 `far_in`), so BREACH goes by its quiet clock, the lockdown by `hold_quiet_days`, the ack default never re-applies for it. HOSTILE_RELEASED (B, why `passive`) says it once.
- Unlike a BUG-065 harmless intruder it is NOT counted again when another hostile comes into sight (`far_scan` leaves `pvset` alone, `rc_note` skips it): a real siege beside a mammoth is a siege of its own. It counts again the moment `pv_holds` fails: it killed (sense drops `hb`, marks `kl`), or changed.
- `quiet_block` / `far_now`: an invader cleared as unreachable (BUG-673) does not hold the lockdown's quiet clock.
- `seal.groups`: the cleared units are no hostile group, so the BREACH made by them alone can fall back to SIEGE (`reflex.pv_ids`).
- Config `confine.passive_days` (0-365, 3); `fairplay.CONFINE_LIM`.

## Tests
`tests/lua/test_bug672_676_lockdown.lua`: four mammoths inside Kern+ (BREACH, lockdown at 30 t/s, held until the days are over, one HOSTILE_RELEASED, BREACH ends, PEACE, LOCKDOWN_END, clock free, list persisted); a killer mark brings one back at once (BREACH again), a goblin newcomer does not bring the others back; `passive_days 0` keeps the old rule; the siege traffic tests (see BUG-673).

## Live check
A mammoth inside Kern+: PREDATOR + BREACH as before; 3 game days later `HOSTILE_RELEASED passive` in the digest, the mode leaves BREACH after the 2,400-tick quiet clock, `status` clock back to 250. One that kills a citizen: PREDATOR/BREACH again at the next census.
Open: "never attacked" is the absence of a kill (BUG-421's killer mark, 30 days), not a read of the unit's job or wounds; 3 days is a judgement from one fort; the other raw `census.h.inside` readers (gate `breach_safe`, the inner hold) still see a cleared animal and stay at their conservative rule; the `seal.groups` change has no test of its own (that function needs a full audit state).
