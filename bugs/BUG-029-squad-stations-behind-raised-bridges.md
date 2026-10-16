# BUG-029 Squad stations behind raised bridges: soldiers cut off from drink for a whole siege
Status: fixed (offline, live-untested): inner station READY_IN, stray return, unseal (Claude, 2026-10-16); flasks open
Severity: high (wrong decision: soldiers stand where our own gates cut them off from drink; recruits died of thirst in BUG-028)
Found: 2026-10-16, Run 10 fort Erushthak Handlelock (region2-site97), y419 siege of 47-48 goblins, after the kernel
restart in SIEGE (6455f16), Claude playing
Module: `lua/dfllm/military.lua` (station_of: READY_STATION sent the melee squads to `stations.melee` and the crossbows to
`stations.gallery` for the whole siege), `lua/dfllm/siege.lua` (POSTURE.SIEGE; BUG-028 leaves soldiers out of the
supply check before raising), the manifest stations

## Actual
1. Live stations: `stations.gallery` (123,123,122) and `stations.melee` (130,128,122) lie between O1 (x 101) and B2;
   the gallery on the killing field side of B1 (west of it), the melee station between B1 and B2; only `stations.b2`
   (138,127,122) lies behind B2, on the side of the drink stock (737 units in the core, 3093 outside O1).
2. After a kernel restart in SIEGE, B1 and B2 were raised again and 10 recruits whose squad stations lie west of the
   bridges (killing field side) were locked out from drink.
3. BUG-028's fix leaves soldiers out of the supply check before a raise on purpose ("their stations lie between the
   gates"); its STRANDED rescue acts only above thirst 30,000 and is refused while a hostile is near a bridge.
4. The coordinator's note after the siege ended by itself (48 goblins left after 30 days; BREACH -> SIEGE (sealed) ->
   RECOVERY -> PEACE ran with the BUG-028 fix): soldiers at those stations have no water in a long SIEGE.

## Cases
- **(a)** a station on the killing field side of B1 (the gallery without its own way to the gatehouse, or the field)
  while B1 is up: SIEGE's READY_STATION stood the crossbows there for the whole siege, no drink.
- **(b)** a station between B1 and B2 (`stations.melee`) while B2 is up: BREACH raises B2, BREACH -> SIEGE (BUG-028 b)
  leaves it up and nothing in SIEGE lowers it again (the mode table says B2 down in SIEGE); a restart in BREACH raised
  the gates again.
- **(c)** soldiers outside B1 when it rises: the T0 rule "nobody outside" counts civilians only, a restart re-raises;
  they stay out until thirst 30,000 (rescue) or for good (rescue refused with hostiles near).
- **(d)** new with the intake waves and the sortie (same day): soldiers sent to the field, the gallery or the bailey;
  the wave's and the sortie's own `back`/`home` phases bring them in through the airlock.

## Expected
Stations outside B1 only while an intake wave or an approved sortie needs them there; otherwise every squad stands on
the side of the fort that holds the drink and food; soldiers caught outside come in; flasks if the uniform code can.

## Cause
- `siege.POSTURE.SIEGE = 'READY_STATION'` and `military.station_of(READY_STATION)` = melee at `stations.melee`, crossbows
  at `stations.gallery`, with no regard to which bridges are up; no posture knew about B2.
- Nothing brought soldiers in once B1 rose: siege's raise hold and the rescue were built for civilians (BUG-028 c
  excluded soldiers), and the rescue waits until 30,000.

## Fix (Claude, 2026-10-16)
- **Inner station (a, b):** new posture READY_IN, SIEGE's posture between waves: routine Ready, every squad (crossbows
  too) at `stations.melee`, or at `stations.b2` while a core bridge (B2) is not down. STATION_B1 (ALERT, RECOVERY)
  uses the same inner station. siege re-issues the posture as soon as a core bridge changes state. The new INTAKE
  posture (field and gallery) is used only while an intake wave musters, is open or fights; DRILL keeps
  READY_STATION (a short test of the stations).
- **Stray (c):** in SIEGE with O1 and B1 up, nothing hostile in the intake area or past B1, no rescue and no sortie,
  soldiers following their posture who stand in the intake area (Z1, Z2, killboxes) or within 3 tiles of the gallery
  get B1 lowered (O1 stays up: the airlock) until they are in, at most `IK_BACK_MAX` (1,200) ticks, then B1 rises
  again; INTAKE `stray` / `back`. If some do not come, not again before 4,800 ticks. Works with `intake.on` false too.
- **Unseal (b):** soldiers between B1 and a raised core seal (zone Z3) get the core seal lowered once (the SIEGE state
  of the mode table), INTAKE `unseal`.
- **Flasks: not done.** `act.squad_uniform` writes only the uniform categories (body, head, pants, gloves, shoes,
  shield, weapon); the flask, backpack and quiver are position slots DF fills from the squad's supplies setting
  (`act.squad_unequip` only clears them), which act does not set, and the squad fields for it (carried food and water)
  are unverified for 53.16. Follow-up: read the squads screen's supplies on a live save, then an `act.squad_supplies`.
- **Drink rotation by half squads: not done.** On a station with drink, DF's own drink and food breaks reach the stock
  (bounded by the routine's minimum soldiers per order, set once in the UI).
- Tests: `tests/lua/test_intake.lua` (between waves every squad, the crossbows too, at 51,44 inside B1; behind B2 at
  51,62 while B2 is up; READY_STATION keeps the gallery; two crossbowmen in the field come in through the airlock while
  O1 stays up; a squad between B1 and a raised B2 gets B2 lowered; all fail on 6455f16), `tests/lua/test_siege.lua`
  (SIEGE posture READY_IN).
- **Live check:** in the next siege `dfllm events --type INTAKE` and the squads screen: between waves every squad's
  station order is `stations.melee` (130,128,122), or `stations.b2` (138,127,122) while B2 is up; no soldier at the
  gallery (123,123,122) outside a wave; with soldiers left on the field side after a restart an INTAKE `stray`
  (B1 down with O1 up, then up again).

Related: BUG-028 (rescue, raise hold), BUG-027 (footprint rules), Gordon's decision 2026-10-16 (intake waves, sortie)
