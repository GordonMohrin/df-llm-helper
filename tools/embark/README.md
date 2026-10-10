# Embark with the vanilla UI only (v2, WP11)

Picks a site by the DESIGN §5.1 checklist and embarks with every embark point spent, using only
what the vanilla embark screens show and only clicks a player could make. Runs before
`dfllm adopt`, so no kernel exists yet; this folder has its own small Lua runtime.

**Status: offline-tested only.** 32 Lua tests run the steps and `embark.lua` itself against a fake
DF (`fixtures/fake_df.lua`, fake `dfhack`/`df`/`gui` globals; it also models a placing rectangle that
follows the mouse and slow map preparation / fort loading). Nothing here has run in the v2 form in
game. Each step below is marked
- **run4-6**: the same UI pattern worked live with the v1 scratch scripts (Runs 4-6), or
- **untested**: new in v2, never tried live (mostly "Prepare carefully").

## 1. Fair play (binding)
**Reads**, all of it visible on screen:
- the text buffer (`dfhack.screen.readTile`, Lua API.txt:2716) and the native focus strings
  (`dfhack.gui.getFocusStrings(getDFViewscreen(true))`, :1131/:1152);
- the highlighted rectangle `location.embark_pos_min/max` and `region_pos` of
  `viewscreen_choose_start_sitest` (v1 `place.sh` read them live);
- on "Prepare carefully": `points_remaining`, `selected_u`, and per dwarf `skill_picks_left` and
  `skilllevel[skill]` for the planned skills (all shown on that screen).

**Writes**, UI state only, all in `embark.lua` table `W`:
- mouse position `gps.mouse_x/y`, `precise_mouse_x/y`, which simulated clicks need
  (Lua API.txt:4208-4212);
- simulated input `gui.simulateInput(native screen, keys)` (gui.lua:58), i.e. left/right clicks;
- camera centre `region_cent_x/y` (world map) and `zoom_cent_x/y` (local map). This equals
  scrolling the map and changes nothing in the world;
- list selection `selected_u` on "Prepare carefully", only as a fallback when a click on the dwarf
  row is ignored. DFHack's own `startdwarf` overlay does the same (startdwarf.lua:48).

**Never used**, even when a step fails:
- world data (`world_data`, `region_map`, `geo_biomes`, `sites`): the v1 `kandidaten_eisen.py`
  analysis is not ported;
- prospect/`prospector` (armok, inspection), `embark-assistant`, `embark-tools`,
  `gui/embark-anywhere` (armok, forces warnings away), `embark-skills`, `points`, `startdwarf N`,
  `embark-anyone` (all armok), `deep-embark`;
- direct writes to `skilllevel`, `skill_picks_left`, `points_remaining`, item lists, finder
  parameters or `warn_flags`. Run 6 set skills by writing `skilllevel`/`skill_picks_left`; v2 forbids
  that. If clicks do not work, use the fallback in §6.

Dark fortress evidence comes from the vanilla screens only: the Neighbors section of the embark
panel ("Neighbors:", race, "Nearest site: …"), the popup "You may be invaded very early by powerful
foes", or positions seen on the world map (icons, by eye) in `rules.json:dark_fortresses_seen`.
DF 53.16 has no separate Neighbors tab (the exe only holds the header `Neighbors:`); v1 `probe.sh`
and `scan3.sh` saw the section on the same screen as the biome panel. Old fort positions are
Gordon's own history.

## 2. Files
| File | Role |
|---|---|
| `embark.lua` | entry for `dfhack-run lua -f <repo>/tools/embark/embark.lua <cmd>`; all DF reads (`source`) and writes (`W`) |
| `view.lua` | screen text → lines, cells (split at 2+ spaces), paragraphs (wrapped text joined), `kind()` |
| `panel.lua` | panel, popup and Neighbors text → site record (phrases taken from `Dwarf Fortress.exe` 53.16) |
| `checklist.lua` | DESIGN §5.1 → `ok` / `review` / `reject`, score, per-criterion pass/warn/fail/unknown |
| `input.lua` | click = hover (mouse held) → one press → hold, played over frames |
| `runner.lua` | steps: wait → act → settle → check; tries, stale progress, timeouts, `wait` results that spend no try, `status.json` |
| `steps.lua` | the procedure (§4) and run specs (`newgame`, `scan`, `embark`, `prep`) |
| `embark.py` | Python driver: writes a spec, ONE `dfhack-run` call, then only reads `status.json` |
| `ui.json` | calibration (§5); `rules.json` checklist thresholds; `loadout.json` skills and buys |
| `fixtures/` | synthetic screen dumps and `fake_df.lua` for the offline tests |

Output: `<DF>/dfllm-runtime/embark/` with `status.json` (rewritten in place), `result-<id>.json`,
`spec-<id>.json` and `capture/*.txt` (screen dumps of every read site and of every failure).

## 3. Use
Preconditions:
- DF runs (any desktop, unfocused is fine: input is simulated in-process, no OS focus) and shows the
  title screen or the embark world map. Sound muted.
- `prefs/d_init.txt` has `[EMBARK_WARNING_ALWAYS:YES]` (Settings: "Confirmation window for all
  embarks"), so every placement click opens the Confirm popup; `embark.lua` refuses `scan` and
  `embark` otherwise, because a click could embark at once. `[POST_PREPARE_EMBARK_CONFIRMATION:
  IF_POINTS_REMAIN]` makes DF warn about unspent points. Both are already set on Gordon's install;
  prefs are only read, never edited.
- No other embark run is active (`status`, `stop`).

```
python tools/embark/embark.py newgame [--world Zilirr]     # title -> world map
python tools/embark/embark.py scan 26,10 18,9,6,6 7,23     # read and rank sites, embark nowhere
python tools/embark/embark.py embark 7,23,6,6              # read -> gate -> confirm -> prepare -> Embark!
python tools/embark/embark.py embark 7,23,6,6 --waive dark_fortress   # one criterion checked by eye
python tools/embark/embark.py state | check | screen NAME | status | stop
```
`WX,WY` is the world tile, optional `LX,LY` (0-15) the local tile of the rectangle's top-left
corner (default `6,6`, the tile centre; v1 lesson: edges pick up neighbour geology). Then in the
fort: `dfhack-run dfllm adopt`.

Raw form: `dfhack-run lua -f <repo>/tools/embark/embark.lua run <spec.json>` with
`{"v":2,"id":"s1","mode":"scan","cands":[[26,10],[18,9,6,6]]}`. Embark options: `waive` (list of
criterion ids), `play_now`, `allow_unspent`. The old blanket `accept_review` is refused.

## 4. Procedure
| Step | UI action | Done when | Live |
|---|---|---|---|
| title.new | click "Start new game in existing world" | text gone | run4-6 |
| title.world | click the world name (ASCII part; accents read as `?`) | game type shown | run4-6 |
| title.fortress | click "Fortress" | "Select a game type" gone | run4-6 |
| title.load | wait (up to 10 min) | world map or "Skip tutorial" | run4-6 |
| title.tutorial / title.okay | click "Skip tutorial", then "Okay" (optional) | popups gone | run4-6 |
| world.goto | right-click until zoomed out; camera to the tile; click the map | `region_pos` = tile; else learn the offset and retry | run4-6 |
| local.place | click the "Embark" button; camera; click the local map | `embark_pos_min` = target; else learn k = rect - camera and retry | run4-6 |
| site.read | ONE capture with the Confirm popup open: popup sentences, panel, Neighbors section and the rectangle; fail unless the rectangle is still the target; evaluate §5.1; save `capture/<id>-site-<tag>.txt` | read | run4-6 (probe.sh) |
| site.abort (scan only) | click the popup's Abort (the one next to Confirm; the bottom-bar Abort leaves the embark) | popup gone | run4-6 |
| site.gate (embark only) | refuse any fail; refuse any unknown criterion not named in `waive` | verdict | untested |
| site.confirm | rectangle still the target, then click "Confirm" once and wait | "Prepare carefully" screen (≤ 3 min) | run4-6 |
| prep.choice | click "Prepare for the journey carefully" (or "Play now!") once and wait | Dwarves tab (or the fort, ≤ 10 min) | run4-6 |
| prep.skills.N | click dwarf row N (fallback `selected_u`), click skill rows until the role is done or picks are 0 | levels read back | untested |
| prep.tab.* | click the tab label | focus `setupdwarfgame/Items` etc. | untested |
| prep.buy.* | click the item row `add` times | each click must lower `points_remaining` | untested |
| prep.buy (rest) | buy `rest` items until a click no longer lowers the points | points 0 | untested |
| prep.embark | click "Embark!" once; on "Are you sure?" click "Go back" and fail (unless `allow_unspent`: "I am ready!" once) | `dwarfmode` (≤ 10 min) | untested |

Without the popup the placing rectangle follows the mouse (v1 needed `hold.lua` for that), so the
site is read while the popup is open, and `embark` confirms that same rectangle without closing the
popup. Screen-changing buttons (Confirm, Play now!, Embark!, I am ready!) are clicked exactly once;
the step then waits (`act` returns `wait`, the runner spends no try) until the next screen or the
timeout. A second click is never sent (v1: a fast double click crashed DF once), so an ignored
click ends in a timeout. Steps that fail write a screen dump. Optional steps (tutorial popups, single buys) log a warning
and the run goes on; the final `status.json` lists them under `warnings`.

## 5. Site checklist (DESIGN §5.1; `rules.json`)
| Criterion | Source on screen | pass / warn / fail |
|---|---|---|
| panel | any recognised panel line | fail if nothing readable |
| old_sites | rectangle world tile vs `old_sites` | fail < 10 tiles |
| dark_fortress | `dark_fortresses_seen`, Neighbors "Nearest site:" of goblins, popup "invaded very early" | fail < 10 tiles, goblins nearer than `goblin_min_rank`, or popup; pass with parsed Neighbors entries and no near goblins; else unknown |
| evil, savagery | "Surroundings:" (Serene/Mirthful/Calm/Wilderness pass), popups "evil area"/"savage area" | evil or high savagery fail |
| trees | "Trees:" | Heavily Forested/Woodland pass, Sparse warn, else fail |
| water | "Brook:"/"Stream:"/"Minor River:"/"River:"/"Major River:" | none fail |
| aquifer | "Light/Heavy/Varied aquifer" line and popup | none pass, light warn (probe protocol), heavy/varied fail |
| flux | "Flux stone layer" | missing warn |
| ore | a line of metal names, if DF shows one | iron pass, bronze only / no iron warn, not shown skip |
| soil | "Little soil"/"Some soil" … "Extremely deep soil" | little/some pass, deeper or none warn |
| temperature | "Temperature:", "Ice" | Temperate pass, Warm/Cold warn, else fail |
| size | rectangle | 3x3 or 4x4 pass (DF default is 4x4; size is not changed by these steps) |
| popup | other warning sentences | `fail_popups` fail, `warn_popups` warn |

Verdict: any fail → `reject`; else any unknown → `review`; else `ok`. Score = 100 − 30·fail −
12·warn − 4·unknown. The embark gate needs `ok`, or `review` where **every** unknown criterion is
named with `--waive ID` (ids: old_sites, dark_fortress, evil, savagery, trees, water, aquifer, soil,
temperature, size) after checking it by eye; waivers are listed in the run warnings. If the
Neighbors header is shown but no entry parses, dark_fortress stays unknown: recalibrate
`panel.lua` from the capture rather than waiving it routinely.

## 6. Loadout and fallbacks (`loadout.json`)
Skills (1 pick per level, 10 picks per dwarf in Run 6): miner (Mining 5, Engraving 3, Masonry 2),
miner (Mining 5, Woodcutting 3, Carpentry 2), mason/engraver (5/5), carpenter (Carpentry 5,
Woodcutting 3, Mechanics 2), brewer/grower (5/5), mechanic (Mechanics 5, Masonry 3, Engraving 2),
cook/doctor (Cooking 3, Diagnostics 3, Surgery 2, Bone Setting 1, Suturing 1).
Buys on top of DF's default list (2 picks, 2 battle axes, anvil, seeds, food, drink, wood): +1 pick
(3 total), 10 bars, 10 plump helmet spawn, 10 seeds, 20 logs, 2 poultry and 2 pigs (1-2 breeding
pairs, never cats); the rest into bars, then logs, so no point stays unspent.

If the skill or item clicks are ignored (the Run 6 symptom), the run fails at that step with
"no progress". Then, in this order:
1. Calibrate (§7) and run `embark.py prep` again from the Prepare carefully screen.
2. Gordon does Prepare carefully by hand (about 5 minutes) with the list above.
3. `embark.py embark … --play-now` (DF defaults; points stay unspent; note it in the run log).
Never write skills, picks or points directly.

## 7. Calibration at live slot L0 (spike list)
1. `embark.py screen <name>` on the world map, the local view, the placing popup, the Neighbors
   tab, Prepare carefully (Dwarves, Items, Animals). Replace the synthetic `fixtures/*.txt` and
   re-run the tests; fix `panel.lua` if a label differs.
2. `world_click` and `place_px` only need to land on the map; the closed loops learn the offsets
   (watch `wofs`/`pk` in the log). Check that `zoom_cent` is in absolute embark tiles.
3. `citizens` (dwarf row tiles), `tabs` labels, `buy.dx`: from the Prepare carefully dumps. Check
   that one click on a skill row adds one level and one click on an item row adds one item.
4. Check the Neighbors section layout (header, race lines, "Nearest site:") and calibrate
   `goblin_min_rank` against the world map.
5. Check whether DF shows a metal line in the panel (Run 5 notes say "Iron Silver Copper").
6. With the popup open, move the mouse over the map and confirm that `emb_min` stays fixed; without
   the popup confirm that it follows the mouse.
7. Measure seconds per site (v1: about 13 s), per Prepare carefully click, for "Preparing map..."
   and for loading the fort (timeouts: 3 and 10 min).

## 8. Port map (v1 → v2)
| v1 (repo B `tools/embark`, also copied here) | v2 |
|---|---|
| `screen.lua` | `embark.lua screen` / `view.lua` (`dump`, `parse_dump`) |
| `findclick.lua`, `findclick_bottom.lua`, `fc2.lua`, `hc.sh` | `steps.tap` + `input.lua` (hover-then-click, correct pixel scale) |
| `clickonly.lua`, `clickpx2.lua`, `pc.sh`, `hold.lua`, `hover.lua` | `input.lua` (`click_tile`, `click_px`, `click_pct`) |
| `place.sh`, `probe.sh`, `probe2.sh` | `steps.goto_world`, `steps.place` (closed loop instead of fixed offsets) |
| `scan2.sh`, `scan3.sh` | `embark.py scan` / spec mode `scan` |
| `kandidaten_eisen.py` (world-data pickles) | dropped: not vanilla-screen information |
| Run 6 direct skill writes | dropped: clicks or the fallbacks in §6 |
The v1 copies in this folder (`clickonly.lua`, `clickpx2.lua`, `findclick*.lua`, `hold.lua`,
`probe.sh`, `scan2.sh`, `screen.lua`) are superseded and go with the v1 cleanup (WP11, wave 3).
