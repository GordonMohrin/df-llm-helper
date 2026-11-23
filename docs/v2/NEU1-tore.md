# NEU1 P5 Tore: the inner gate is shut in peace, nobody is waited for once a hostile is on the map, a gate that could not be closed again is never opened

Round: Neuausrichtung 1 (decision E2 of `leitung/PLAN-NEUAUSRICHTUNG.md`, 2026-11-23). Status: offline, live-untested.
Measurable goal of the plan: loss per siege under 10 %, at most one lost caravan a year.

## Old decision

- D-14 `peace_gates` = `down` (Gordon, 2026-10-15): every gate bridge is down in PEACE; the arrival reflex (an announcement,
  INVASION, the first armed hostile in sight) raises them, a race between the lever pull (256-400 ticks plus the walk of the
  puller) and the army.
- Straggler holds: the lockdown's first raise of B1 waited up to 900 ticks while civilians stood on its attack side (BUG-338
  `inner_wait`); siege's SIEGE raise waited for "nobody outside" until T+450 (`RAISE_BY`) and a raise that would cut citizens
  off from drink or food waited until a hostile was 30 tiles from that bridge (BUG-028 c, `cut_holds`), in SIEGE and BREACH.
- A gate the kernel lowered could be one nobody can raise again (no linked lever, every lever outside the walls, BUG-774):
  the fort then stood open ("open on failure", GRUNDSATZ-REVIEW §3.4).

## New behaviour

1. **D-14 `inner` (new default, `config/decisions.yaml`, `contract.DECISIONS`, `schema.DECISIONS`).** In PEACE every manifest
   bridge of role `inner` (B1) is wanted up, `outer` (O1) and `core` (B2) down. The depot lies in the bailey between O1 and B1
   (DOCTRINE geometry), so wagons and merchants reach it with only O1 down. Unmanaged bridges keep the `down` rule (no role is
   known for them). An unknown D-14 value is `inner` (fail closed). `up` and `down` keep their old meaning.
2. **Windows of the inner gate** (D-14 `inner` uses the windows `up` already had; `gate.window_open`): a caravan on the map
   (trade state) or its arrival report (4,800 ticks), a migrant report (2,400), the player's `lever` down (2,400), and new: a
   **return window** - civilians on the attack side of the raised inner gate (`census.u.atk`) for `gate.return_every` ticks
   (1,200) open it for `gate.return_open` ticks (600), GATE (C) state `return`. Every window needs a fresh census without a
   visible hostile; any hostile closes it at once (the window is level-triggered, the lockdown raises it too). So nobody is
   walled out of drink in peace: an outside worker is let in at least once a game day; deeper thirst still gets siege's
   STRANDED rescue (BUG-234/235, PEACE).
3. **Drink inside (`gate.drink_inside`).** With D-14 `inner` the inner gate stays down in PEACE (why `no_drink_inside`,
   kern.log once a day) while seal's audit of Kern+ knows NO drink item and no wet well there; an unknown audit keeps it up.
   A fort whose drink still lies outside (the week-1 surface set of P6) is not sealed away from it.
4. **Close at once (`gate.close_at_once`).** With a hostile on the map nobody outside is waited for: gate's `inner_wait`
   (BUG-338) holds nothing; siege's SIEGE raise wants outer and inner up at once (why `hostile`) instead of waiting for
   "inside" / T+450; the BUG-028 c cut hold is skipped in SIEGE and in BREACH while a hostile is in sight or inside. Those
   shut out are siege's STRANDED rescue (airlock: outer up, then the inner gate lowers for them) and the
   `stranded_drink` / `stranded_food` decision. The crush rules of gate are unchanged: a unit ON a footprint or walking onto it
   within the timed reach still holds a raise (BUG-310/335/380/492/543), BUG-775's 20-tile release still applies.
5. **Fail closed (`gate.fail_closed`).** `gate.missing(K, name)` names what is missing to raise a manifest bridge again: no
   linked lever (lever or link mechanisms), no linked lever on a tile of Kern+ or the refuge, no Kern+ burrow, no fresh census,
   no civilian inside Kern+ to pull. While anything is missing an automatic lowering of a RAISED manifest bridge is refused in
   `down_guard` (so `gate.want`, the PEACE pass and every queued lowering pull): the bridge stays up and GATE (C) state
   `fail_closed` says `missing` and the refused `why` (once a game day per bridge, again when the cause changes). Exempt: the
   player's `lever`, siege's `rescue` (lives), `intake` and `sortie` (SIEGE, own checks).
6. **RECOVERY** (siege `lower`): with D-14 `inner` B2 comes down, B1 stays up, O1 comes down at +2,400.
7. **Lever in the core from stage 1.** fortcore already paints Kern+ over the Z3 lever strip in stage 1 and builds B1 (stage 2),
   O1 and B2 (stage 3) with their levers inside it; a test now pins this (`tests/test_neu1_tore.py`). For other forts BUG-774's
   `home_step` builds a lever inside Kern+, and fail closed keeps a bridge whose levers all lie outside up instead of opening it.

## Config switches (all default ON)

| Where | Key | Default | Off |
|---|---|---|---|
| `config/decisions.yaml` | `D-14` | `inner` | `down` (old: all gates down in peace) or `up` (all up) |
| `config/reflex.json` `gate` | `close_at_once` | `true` | `false`: BUG-338 / RAISE_BY / BUG-028 c holds as before |
| `config/reflex.json` `gate` | `fail_closed` | `true` | `false`: lowering as before |
| `config/reflex.json` `gate` | `drink_inside` | `true` | `false`: B1 up in peace even with Kern+ dry |
| `config/reflex.json` `gate` | `return_every` / `return_open` | `1200` / `600` | `return_every: 0` |

## Deliberately not done

- No change to the crush rules (footprint, walkers, timed reach, forced raises): "close at once" never means "onto a unit".
- No outside refuge built for those shut out; the existing STRANDED rescue / decisions are the answer.
- No burrow or civ alert in PEACE to keep workers in (the alert is siege's); outdoor work (woodcutting, gathering) now happens
  only in windows. That is the accepted cost of E2.
- No change to the intake waves, the sortie, the deep defense or the perimeter keeper.
- The unmanaged-bridge rule (no manifest) is unchanged: without a role the kernel cannot tell an inner gate from a shortcut.
- Building destroyers: see the evidence below. A raised gate is not a defense against them; the deep defense (refuge, core
  station) stays the answer and nothing here pretends otherwise.

## Evidence: are raised bridges destroyed by building destroyers? (review doubt)

Yes. Runtime events (read only):
- Run 16a Syrupobeyed (`r16a4-syrupobeyed-site97`, y387): BRIDGE_DESTROYED #19670 O1 `last up`, BREACH, toppled by "Ber, Troll
  Miner" (bd 1); #19727 B2 `last up`, BREACH, toppled by "Ngerxung, Troll Siege Engineer". kern.log shows no lowering of O1/B2
  between the raise and the loss.
- Run 16b Brotherarrow (`r16b4-brotherarrow-site97`): #13527 O1 `last up`, SIEGE, toppled by "Amxu, Blind Cave Ogre Miner";
  #13585 B2 `last up`, BREACH, toppled by "Stosbûb, Blind Cave Ogre Siege Engineer".
`last` is gate's last read of the bridge (every 25 ticks in SIEGE/BREACH) before it vanished. All four losses were raised
bridges broken by a named building destroyer (BUG-462 drew the same conclusion). Other Run 16b losses of B1/B2 in PEACE were
tantrums ("toppled by Tholtig, Farmer"), which a raised gate does not prevent either. So: a raised gate stops goblin armies
(no destroyers) and the arrival massacre; against trolls / ogres / dragons only depth helps.

## Live-Erwartung

1. In PEACE with fortcore stage 2+: `dfllm status` / state `bridges` shows B1 `up`, O1 `down`; kern.log has no "B1 ... down
   (peace)" pulls outside windows; events show GATE `B1 opens for 600 ticks: N civilians outside it in PEACE (return window)`
   at most about once a game day per stay outside.
2. A caravan visit: kern.log `gate: peace gates open for CARAVAN_ARRIVAL`, B1 down while the caravan is on the map and no
   hostile is visible, B1 up again within ~600 ticks after it left; trade completes (no "time" failure from a raised B1).
3. An arrival / SIEGE_START: B1 already up; O1 wanted up at T0 with why `hostile` (siege) or `lockdown` (reflex), no GATE
   `up held: N civilians on its attack side` lines, no STRANDED `raising ... held` lines; BRIDGE_CRUSH 0.
4. Wertung (P1): loss per siege under 10 % for forts on D-14 `inner` versus the `down` instances.
5. If a lever or puller is missing: GATE `... stays up (fail closed, window down refused): <missing>` instead of an open
   gate; never a GATE_FAIL `no_lever` on a bridge that was lowered by the kernel in PEACE.
