# Embark with the vanilla UI only (v2, WP11)

## Live L0 findings (2026-10-10, DF 53.16, window on a hidden virtual desktop)
Proven live: `newgame`, `scan` (about 12 s per site, about 20 s with `--tiles`) and `embark … --play-now`
(fort Rimtarlocun "Castlerisen", world tile 8,14, rectangle 131,233). Not working: Prepare carefully.
- **No mouse focus.** DF never gets OS mouse events, so `enabler.mouse_focus` is false and DF writes
  the mouse itself before every render frame (-1, or with the focus claimed the cached OS cursor).
  The placing rectangle and the site panel follow the mouse that render frames see. `embark.lua`
  therefore shows a pass-through DFHack screen (the *mouse injector*) on top of the embark screen
  while the local map is used: it writes our mouse right before the native render, forwards input,
  runs the native logic, and is dismissed before Confirm and at the end of every run.
- **Placing:** the rectangle follows a held mouse, 16 px per embark tile:
  `rect_min = zoom_cent + k + floor((px - window centre) / 16)`, k = (-1, 0) at 1716x1000. A map
  click does not move it; it opens the Confirm popup on it. `location.region_pos` only changes after
  placing; the zoomed world tile is `zoom_cent // 16`.
- **Panel:** shown only in placing mode WITHOUT the popup, for the region of the HOVERED tile (the
  rectangle can span several regions). The popup covers the whole rectangle. `site.read` reads the
  panel first, then clicks and reads the popup; `--tiles` (default for `embark`) hovers all 16 tiles
  and merges them (best water/trees/metals, worst evil/savagery/aquifer, nearest neighbours). Panel
  lines: region name, biome, `Temperature:`, `Trees:`, `Other Vegetation:`, `Surroundings:`,
  `Brook:/Stream: <name>`, soil, aquifer, metals, `Flux stone layer`, `Neighbors:` with
  `Nearest site: …` (also `Here`). A site panel says `Cannot embark on another site.` (no popup).
- **Captures:** `fixtures/live/*.txt` (tests use them).
- **Window size:** returning to the title once left DF at 1522x1000 with a broken local map (garbage
  rectangle); resizing the window back to 1716x1000 fixed it.
- **BUG-020 (2026-10-15, DF restarted and its window moved):** the rectangle stayed at one place
  whatever pixel was held. `local.place` now fails early with `rectangle does not follow the mouse:
  held A and B, rectangle stays at X` once two confirmed misses that should land on different tiles
  show the same rectangle (it no longer learns a k from them); the cause is still open.
- **Prepare carefully:** skill and dwarf rows ignore simulated clicks with or without focus, with the
  injector and with raw `enabler.mouse_lbut` flags; keys do nothing there except Esc (menu). Buttons
  (Embark!, Go back, menu items) work. Fallback used: Esc → Return to title → `newgame` → `embark …
  --play-now` (DF's skilled default seven; 324 points unspent). Spending points needs Gordon (5 min).
- **Never** leave `enabler.mouse_lbut*` set: a stuck flag plus the cached cursor over "Embark!" once
  clicked Embark! (DF's unspent-points warning caught it).

Picks a site by the DESIGN §5.1 checklist and embarks with every embark point spent, using only
what the vanilla embark screens show and only clicks a player could make. Runs before
`dfllm adopt`, so no kernel exists yet; this folder has its own small Lua runtime.

**Status:** `newgame`, `scan` and `embark … --play-now` ran live in v2 form at slot L0 (findings
above); Prepare carefully does not work yet. Offline, 35 Lua tests (`tests/lua/test_embark*.lua`) run
the steps and `embark.lua` itself against a fake DF (`fixtures/fake_df.lua`, fake `dfhack`/`df`/`gui`
globals; it also models a placing rectangle that follows the mouse and slow map preparation / fort
loading). Each step below is marked
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
  row is ignored. DFHack's own `startdwarf` overlay does the same (startdwarf.lua:48);
- K2: DFHack's own stock `load-save` through `W.stock_load` (RULES 1.2 allows it), only at the title screen and only where the
  field it writes still exists (§9).

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
| `loadsave.lua` | K2: load a saved fort from the title screen by clicks (§9); pure text functions + the two steps of mode `load` |
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
python tools/embark/embark.py embark 7,23,6,6 --accept ore --reason "copper/tin listed, iron by trade"   # FR-08
python tools/embark/embark.py state | check | screen NAME | status | stop
```
`WX,WY` is the world tile, optional `LX,LY` (0-15) the local tile of the rectangle's top-left
corner (default `6,6`, the tile centre; v1 lesson: edges pick up neighbour geology). Then in the
fort: `dfhack-run dfllm adopt`.

Raw form: `dfhack-run lua -f <repo>/tools/embark/embark.lua run <spec.json>` with
`{"v":2,"id":"s1","mode":"scan","cands":[[26,10],[18,9,6,6]]}`. Embark options: `waive` (list of
criterion ids), `accept` (list of `{id, why}`), `play_now`, `allow_unspent`. The old blanket `accept_review` is
refused.

**Metal and stone (Run 9 postmortem, lesson 1).** A site must list a metal ore (`ore`: no metal line = fail; iron
passes, copper/tin or other metals warn) and have a hard stone layer within reach (`stone`: fails for deep, very deep
or extremely deep soil and for the popup "difficult to obtain stone"; the shallowest soil of the 16 hovered tiles
counts; stone layer names on the panel are listed as evidence). Both come from the embark panel's layer lines only:
no prospect, no world data, no hidden tiles.

**Waiver for failed criteria (FR-08).** `--waive ID` covers a criterion the panel did not show (`unknown`).
`--accept ID --reason TEXT` lets the gate pass one criterion that FAILED (a known trade-off: an old fort's ruins
nearby, scarce trees, no iron), one id at a time, never `panel` or a failing warning popup (heavy aquifer, evil,
savage, necromancer, early invasion). The reason is required; `embark.py` appends one line per accepted id to
`<DF>/dfllm-runtime/embark/accept.log` (time, run id, site, id, reason) and the gate writes
`site.gate: accepted ID (reason)` into the run's warnings.

## 4. Procedure
| Step | UI action | Done when | Live |
|---|---|---|---|
| title.new | click "Start new game in existing world" | text gone | run4-6 |
| title.world | click the world name (ASCII part; accents read as `?`) | game type shown | run4-6 |
| title.fortress | click "Fortress" | "Select a game type" gone | run4-6 |
| title.load | wait (up to 10 min) | world map or "Skip tutorial" | run4-6 |
| title.tutorial / title.okay | click "Skip tutorial", then "Okay" (optional) | popups gone | run4-6 |
| world.goto | right-click until zoomed out; camera to the tile; click the map | `region_pos` = tile; else learn the offset and retry | run4-6 |
| local.place | click the "Embark" button; camera; click the local map | `embark_pos_min` = target; else learn k = rect - camera and retry; the same rectangle for two different holds fails (`rectangle does not follow the mouse`, BUG-020) | run4-6 |
| site.read | ONE capture with the Confirm popup open: popup sentences, panel, Neighbors section and the rectangle; fail unless the rectangle is still the target; evaluate §5.1; save `capture/<id>-site-<tag>.txt` | read | run4-6 (probe.sh) |
| site.abort (scan only) | click the popup's Abort (the one next to Confirm; the bottom-bar Abort leaves the embark) | popup gone | run4-6 |
| site.gate (embark only) | refuse any fail not named in `accept` (with a reason); refuse any unknown criterion not named in `waive`/`accept` | verdict | untested |
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
| stone | the soil depth | deep, very deep or extremely deep soil warn: no stone layer in the upper levels, with a light aquifer the first stone lies below the water (live L6, Laborkings: no boulders for a year); skip when soil is not shown |
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
The v1 scratch copies listed above were removed from this folder; they remain in tag `v1-final`.

## 9. Load a saved fort from the title screen (K2, BUG-098)
DFHack 53.16-r3 renamed `viewscreen_titlest.sel_menu_line` to `selected`: the stock `load-save` dies with "Cannot write field
viewscreen_titlest.sel_menu_line: not found", and writing `selected` plus `simulateInput(SELECT)` moves nothing (the title menu
follows the mouse). `dfpilot supervise` therefore falls back to this helper when `load-save` fails (anything but "can't find
save" and "DFHack does not answer yet"); a player or the orchestrator can run it by hand at the title screen:
```
python tools/embark/embark.py load "autosave 1"                  # stock load-save first where it can work, then the clicks
python tools/embark/embark.py load "autosave 1" --no-stock       # clicks only (what supervise sends; it tried the stock script)
python tools/embark/embark.py load "autosave 1" --entry Ostlysh  # the text to click in the list when it shows no folder name
```
It is the `load` mode of the same runner (`embark.lua run <spec>` with `{"v":2,"id":"load…","mode":"load","save":…}`; `embark.lua
load <save> [--entry T] [--no-stock]` writes the spec itself). **Fair play:** it reads the text buffer and clicks visible text, only
on the title family of screens (main menu, list of saved games, a confirming popup); on a fort, a map, an embark screen or any
screen it does not know it clicks nothing; no title screen field is written, no save file is touched, and the list entry must show
the folder name as a whole token (`autosave 1` is not `autosave 10`, `region2` not `region2-spr-0050`), else the run fails and says
what it saw. A popup that talks of delete, erase, overwrite, abandon or retire stops the run (the player's decision).

| Step | UI action | Done when |
|---|---|---|
| `load.stock` (optional) | DFHack's `load-save`, only where `viewscreen_titlest.sel_menu_line` still exists (older DFHack) and `stock` is not false | the screen says loading, or a fort |
| `load.drive` | per screen: main menu → click "Continue …" (else "Load …"); the list → click the entry named; a popup → click Okay/Yes/Load/…; loading → wait; again when the screen did not change (`tries`, `stale`, `settle_ms` in `ui.json` `load`) | loading or the fort, after a click of ours |

`status.json` `results` of a load run: `screen` and `rows` (the last screen as cells), `title` (the title screen fields read: both
names, `old_field`, `selected`, `selected_r`, `mode`), `clicks` (kind, text, tile and pixel of every click: the first live use is
calibrated from these), `outcome`, `stock`. `embark.py load` prints them; supervise copies them into `supervise.log`.
**Not decided offline (first live use):** the exact labels of the 53.16-r3 menu and list, whether the list shows the folder name
(else `--entry`), whether one click is enough (the run clicks again when the screen did not change), whether an entry loads at once
or needs a Load button (both are handled), and whether "Continue" loads the newest save (supervise only wants the newest).
