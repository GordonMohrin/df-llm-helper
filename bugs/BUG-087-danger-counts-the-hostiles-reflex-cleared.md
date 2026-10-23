# BUG-087 military.danger counts every hostile in sight, also the ones reflex cleared and wildlife out of reach: the unstick, the drill and the militia turnover wait for them for ever
Status: fixed in the integration audit J1 commit (offline, live-untested): `military.danger` takes threat's reading of the
census (`threat.assess`), so a hostile reflex cleared (BUG-065's released harmless intruder, an invader whose lockdown
expired far) and wildlife out of reach no longer hold the unstick, the automatic drill and the FR-79 turnover; a great
danger, an undead, an invader not cleared, a hostile inside or in reach and a hostile the census list does not show still do
Severity: high (wrong decision: a gremlin or an ELK_BIRD that stays in sight stops the monthly unstick, the drill that R2
needs and the militia turnover of every year; nothing says so but one kern.log line per close)
Found: 2026-10-23, integration audit J1 (hypothesis 10: a lockdown that ends by itself, BUG-065, read with the FR-79
turnover; the same gate serves BUG-050 and BUG-051)
Module: `lua/dfllm/military.lua` (`M.danger`; callers `M.unstick`, `rot_turn`, `drill.lua` `danger`/`check`/`start`)

## Actual
`M.danger` (A3, BUG-050/051) answered `hostile` whenever `census.h.vis` was above 0. Four packages that came after or beside
it decided differently what a hostile in sight is:
- Run 11 (site98 y439): a lockdown that ends with every invader far makes them `reflex.far_ids` (reflex.lua `far_mark`);
  threat counts them for nothing (`threat.assess`, threat.lua:176-199).
- BUG-065 (Run 14, a gremlin in the caves for years): at the confinement limit the harmless intruder is cleared
  (`hl_clear`, reflex.lua:1450-1470, `st.far.hl`); threat, siege's `anchor_dist` (siege.lua:784-) and the sighting skip it
  "so no alert comes back for the same gremlin". It stays visible, so `census.h.vis` stays 1.
- An animal at the map edge (Run 11's ELK_BIRD, 45 days) or a beast in a revealed, sealed cavern is no hostile for threat
  (`counts`, predator rule and reach rule, threat.lua:120-129) but is `vis`.
So with the lockdown over, the mode PEACE and nothing near, `military.danger` still said `hostile`: the monthly
`uniform-unstick` (military.lua:2483), the automatic drill (drill.lua:157-161 `danger`, used by `start` :173 and `check` :314) and,
since FR-79, the militia turnover (military.lua:1450 `rot_turn`) all waited. The turnover waits through the whole off period and lapses
when the window reopens (`did not run before the window reopened (hostile)`), so the same members serve for a year more.

## Cause (proved from the code at c038ce9)
`military.lua:2463-2471`: `if type(h) == 'table' and (int(h.vis) or 0) > 0 then return 'hostile' end`. `sense.lua:424`
(`hs.vis = hs.vis + 1`) counts every visible hostile unit; nothing between sense and military subtracts the cleared ones.
BUG-065 (package C1) changed threat and siege to skip `reflex.far_ids`; A3's gate (package A3) was written against the raw
count and merged beside it. D1's turnover then took the gate over.

## Fix
`M.danger`: `mode <M>` and `lockdown` as before; with `census.h.vis` above 0 it asks `threat.assess` and answers `hostile`
for `a.hostile` (an invader reflex has not cleared, a hostile inside Kern+ or in reach), for a great danger or an undead in
sight (`a.great`, `a.undead`: any distance, as before), and for a census with more hostiles than its list shows (`vis` above
`#h.list`, the list holds the nearest 40). Without a threat module or without an answer every hostile in sight counts, as
before. Kernel cost: `threat.assess` is a pass over at most 40 list entries, asked once per upkeep at most.
Unchanged: SIEGE, BREACH, ALERT, RECOVERY, DRILL and a lockdown still refuse; the cleared hostile counts again the moment
reflex drops it from its list (it came near, another hostile appeared).

## Not decided offline
- Whether a hostile that threat does not count (wildlife beyond `threat.REACH` 100 tiles, off the z band) can be a reason to
  postpone a drill in the live game: the fort already treats it as peace everywhere else (ALERT, the lockdown, the clock).
- The size of a harmless intruder (`sz`, BUG-065) is still `[? live]`.

## Tests
`tests/lua/test_integration_j1.lua` (fail on c038ce9): `military.danger` with a cleared invader, a second invader, a
hostile beyond the list, a great danger, wildlife 250 tiles out, wildlife in reach and within 40 tiles of a citizen; the
turnover runs with a cleared intruder in sight for the whole off period (and still lapses with an uncleared one: control);
the monthly unstick runs with a cleared intruder in sight.

Related: BUG-065, BUG-050, BUG-051, FR-79, Run 11 (ELK_BIRD)
