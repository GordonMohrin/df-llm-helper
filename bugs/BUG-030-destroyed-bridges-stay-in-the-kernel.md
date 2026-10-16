# BUG-030 Destroyed bridges stay in the kernel; no plan B against building destroyers; stations in the kill field
Status: fixed in 486b5ce (offline, live-untested): BRIDGE_DESTROYED, a destroyed bridge is an open way, the deep defense SIEGE_DEEP (2026-10-16)
Severity: critical (Run 10 fell: pop 108 -> 0 in about 30 game days)
Found: 2026-10-16, Run 10 fort Erushthak Handlelock (region2-site97), y421 spring siege of 58 goblins and 6 trolls, kernel
main 94b9eed, the orchestrator playing (`docs/v2/POSTMORTEM-run10-siege-y421.md`)
Module: `lua/dfllm/gate.lua` (resolve/read: a missing building reads `unknown`, the want and its deadline stay),
`lua/dfllm/siege.lua` (raise hold and STRANDED over `gate.state ~= 'up'`, RECOVERY waits for 'down', SIEGE posture and
alert burrow without regard to destroyers or the army's size), `lua/dfllm/military.lua` (READY_IN stations)

## Actual
1. Trolls (caste raws: building destroyers) destroyed O1, B1 and B2. `inspect defense` no longer listed the bridges
   (`df.global.world.buildings.other.BRIDGE` was empty), but gate kept their wants: GATE_FAIL O1 `no_lever` after 3073
   ticks, and siege's raise hold kept seeing B1 and B2 as "not up": `STRANDED B1 raised although it cuts N citizens off`
   40+ times in nine days (the hold and forced texts of B1 and B2 alternated, so the cadence saw news every pass).
2. The siege had no plan B: the intake waves refused the trolls (`dz`), but the civ alert stayed on Kern+ (the main hall
   lay on the attack path once the bridges were gone) and the squads stayed at the inner station between B1 and B2.
3. Stations: `stations.melee` (130,128,122) and `stations.gallery` (123,123,122) lay in the killing field and corridor
   between O1 and B2; 19 recruits (worn 53 %, no metal) died first, then 40+ civilians stood in the main hall with
   nobody between them and the invaders.

## Expected
- A destroyed manifest bridge is detected (no building at its footprint any more), reported once (class A), marked in
  the gate and siege state, and leaves the pull, want, STRANDED and intake logic; `state.bridges` and `inspect defense`
  say `destroyed`. A destroyed bridge is an open way for BREACH, RECOVERY and the refuge choice.
- Building destroyers in sight (or an army far larger than our squads, or weak squads): the civilians go to the
  separated refuge at once and the squads hold the core, never the corridor or the killing field; one class-A event
  names the destroyers.

## Cause
- gate cached the building id and, when it vanished, re-resolved the footprint every 20-100 ticks and read `unknown`;
  nothing told a bridge that was never built from one that was destroyed, so the want and its deadline stayed (GATE_FAIL
  `no_lever`), and siege treated it as a bridge still to raise (`gate_state ~= 'up'`: the BREACH raise hold, cut_holds,
  STRANDED forced).
- RECOVERY lowered the core and inner bridges and waited for them to read `down`; a destroyed one never did, so the
  alert never went off.
- sense marked building destroyers only inside `dz` (with trap avoiders and fliers, for the intake waves), read from a
  caste flag name that may not exist in DF 53 (the raws keep `[BUILDINGDESTROYER:1|2]` as a number); siege used `dz`
  only to refuse a wave.
- The SIEGE posture READY_IN puts every squad at `stations.melee` (inside B1, between B1 and B2) whatever the army's
  size or the squads' gear; the civ alert in SIEGE is Kern+ (Z3 + Z4).

## Fix (2026-10-16)
- **gate:** remembers the building of every manifest bridge it saw complete on its footprint (persist `m.gate.seen`).
  When it is gone and a fresh look at the footprint finds no bridge, the bridge is destroyed (`m.gate.gone`):
  BRIDGE_DESTROYED (A, once: `B1 destroyed: no bridge on its footprint at 128,127,122 any more (building 17880, last up,
  BREACH); no pulls for it, an open way until it is rebuilt`), its want, our pull and its move record are dropped,
  `gate.want` refuses it, no GATE_FAIL, its lever room has no duty, `state.bridges` says `destroyed` (schema enum).
  `gate.state(bridge)` still answers `unknown` (readiness keeps its `bridge:B` blocker) and adds the tick it was found
  destroyed as a third value. The footprint is looked at once a game day; a complete bridge there again is a plain
  manifest bridge (GATE C `rebuilt`). `inspect defense` lists it as `destroyed`; the audit snapshot draws its footprint
  as the tiles are (the audit then says `bridge B: footprint is not a bridge`).
- **siege, a destroyed bridge is an open way:** never wanted up, no raise hold, cut_holds or STRANDED for it (and an old
  hold on it is dropped), a destroyed O1/B1 in SIEGE is a BREACH at once (`breach: B1 destroyed: an open way`, why
  `destroyed`), BREACH never falls back to SIEGE while one is gone (not every gate is up), RECOVERY counts it as lowered
  (the alert goes off, the episode ends).
- **sense:** `census.h.bd` counts visible building destroyers (the caste flag or `caste_raw.misc.buildingdestroyer` > 0,
  read once per race/caste; both also set `dz`), list entries carry `bd = 1`.
- **siege, the deep defense (plan B), SIEGE only:** reasons `destroyers` (bd > 0, latched for the episode), `army`
  (visible hostiles > `stations.core_ratio` (3) x soldiers, only with soldiers), `weak` (worn < `stations.worn` (60 %)
  or the iron/steel share < `stations.metal` (0 = off)); config `config/reflex.json` `stations`. While it holds the civ
  alert confines to the separated refuge at seal's BREACH level (siege asks `seal.alert_burrow` as in a BREACH: the
  BUG-018/019 rules, no supply counts for `refuge.breach_days`; seal keeps the refuge afterwards until `back_days` are
  quiet), every squad, crossbows too, stands at the core station (new posture CORE: the manifest's `stations.core`,
  which fortcore stage 3 now sets on the core hub next to the civilians' stair one level below B2, else `stations.b2`),
  no kill orders, no intake wave (INTAKE refused `deep`; a wave already in the field ends by
  its own rules). SIEGE_DEEP (A) names the reasons and the destroyers (`deep defense: 6 building destroyers in sight
  (TROLL x6, 23 tiles from O1): the bridges are no barrier; army 58 > 3 x 19 soldiers; ...`), again only with a new
  reason or race. army/weak release after 2,400 ticks without them; RECOVERY, PEACE and ALERT end it. State
  `wave.deep`, status `DEEP destroyers,army: civilians in the refuge, squads in the core`.
- Kernel cost: no new scans (bd rides on sense's hostile pass, the deep check on siege's cached military KPI); a
  destroyed bridge costs one footprint look per game day instead of one every 20-100 ticks.
- Tests: `tests/lua/test_stranded.lua` (B1 and B2 destroyed in a breach with two citizens cut off: BRIDGE_DESTROYED
  once each, no STRANDED, GATE_FAIL or pull for them, state and `inspect defense` say destroyed, no SIEGE again,
  RECOVERY drops the alert and the episode ends; O1 destroyed in SIEGE: BREACH at once), `tests/lua/test_intake.lua`
  (3 trolls: SIEGE_DEEP, alert Tiefe+, every squad at 51,62, no wave, latched; 30 goblins vs 8 soldiers: deep `army`,
  INTAKE refused `deep`, released below the ratio; worn 0: `weak` at the manifest `stations.core`, off with
  `stations.worn` 0); all fail on 0430095 (the old code repeats `STRANDED B1/B2 raised although it cuts 2 citizens off`
  every 27 ticks). `tests/bp`: fortcore stage 3 sets `stations.core`.
- **Live check:** after `dfhack-run dfllm reload`, in the next siege with trolls: `dfllm events --type SIEGE_DEEP` (the
  destroyers named), `dfllm status` `DEEP destroyers` and `alert Tiefe+`, the squads screen: every squad's station
  order at `stations.core`, or `stations.b2` (138,127,122) in a manifest without it; a bridge they destroy: one
  BRIDGE_DESTROYED, `bridges ... DESTROYED`, no further STRANDED or GATE_FAIL naming it. Check the raws read once: `census.h.bd` > 0 with trolls in sight
  (`dfllm cmd inspect '{"what":"census"}'`); if it stays 0, the raws field is named differently in 53.16 (note it here).

## Open
- A manifest without `stations.core` (every fort made before this change, Run 10's too) falls back to `stations.b2`
  (fortcore [1,44]), one tile from B2's footprint: soldiers there hold a B2 raise (BUG-027 margin) until a hostile is
  within `force_near` (BREACH's B2_HOLD had the same problem: GATE_FORCED B2 in Run 10).
- The Z3 lever room keeps its two lever pullers in a deep SIEGE (gate's SIEGE duty); they leave it at the BREACH.
- A fort without soldiers relies on its bridges as before (no `army`/`weak` reason); destroyers still send it deep.
- `stations.metal` is 0 (off) by default: with iron/steel required, every year-1 siege would go deep.

Related: BUG-018/019 (separated refuge, BREACH level), BUG-027 (footprint rules), BUG-028 (raise hold, STRANDED),
BUG-029 (inner stations), Gordon's intake waves (2026-10-16)
