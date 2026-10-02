# Spec v3-10: Camera Director Profiles (`python -m df_llm_helper camera`)

Priority: P2 | As of: 01.10.2026 (Run 5, Y109) | Status: implemented (v3), not yet live-tested; Lua `claude/schau` exists (auto/follow/events/combat), small profile hook added | Framework: see `../specs-v2/README.md`

## Goal and Benefit
The player wants to watch the fort, but **not** constant fights and sparring, rather "a bit of everything": furniture building, burial, harvest, fetching water from the well. I changed the weighting by hand in `schau.lua` in Run 5 (`JOB_W`, hide soldiers without a job, combat only with enemies, category variety). That belongs in a profile that can be switched.
**Expected gain:** quick adjustment without a Lua edit (approx. 6 calls saved per request); the player gets the view he wants.

## Profiles (`data/camera/*.yaml`)
- `ambient` (default since 01.10.): weights for job types (building/furniture 6–7, burial 8, harvest/plants 6, fetching water 7, lever 5, kitchen/brewing 4, digging 3, hauling 1, sleeping/eating 0); soldiers without a job 0.005; variety factor 0.3 for the same category; dwell time 18–24 s.
- `combat`: fights and enemies first, sparring hidden (only with `S.enemy_n > 0`).
- `build`: focus on buildings under construction and completions.
- `events`: reports only (moods, caravan, masterworks).
- `calm`: slow pans, only one unit per 40 s.

## Behavior
1. `python -m df_llm_helper camera profile <name>` writes the weights into `config` and calls `claude/schau mode ... + reload`.
2. **Event priority:** alarm level 5 (real attacks) overrides every profile; moods (level 3) briefly.
3. **Context:** on attacks switch to `combat` automatically, afterwards back to the previous profile.
4. **Statistics:** shares per category of the last 30 minutes, so that "fights/sparring too often" can be measured.
5. **Safety:** as in `schau`: only camera and text lines, no pause, no windows; locked while `pause.hold` exists or a menu is open; note "director paused" when the player moves the camera himself (`hold`).

## Configuration
`camera: {default_profile: ambient, dwell_s: [18, 24], variety_factor: 0.3, ignore_soldiers_idle: true}`

## Fair Play
Only camera and overlay text.

## Acceptance Criteria
1. A profile switch changes the weight table (test on the Lua config file) and `status` shows the profile.
2. Test "soldiers without a job, sparring": probability < 1 % in the `ambient` profile (Monte Carlo over 1,000 picks).
3. Test "attack": switch to `combat` within 2 s, return after the end.
4. Statistics output per category adds up to 100 % ± 1.
5. No intervention if the focus ≠ `dwarfmode/Default`.

## Fixtures/Tests
`schau status` outputs, job distribution (Dig, Construct, PlaceItemInTomb, GiveWater, Plant/Harvest), report types.

## Implementation (v3)
- **Code:** `df_llm_helper/features/camera.py` (`camera status|profile [name]|stats|watch [--loop]`, `check_hook`), profiles `data/camera/{ambient,combat,build,events,calm}.yaml` (`extends:` inherits; English names instead of `kampf/bau/ereignisse/ruhig`).
- **Weight file instead of `config`:** a switch writes `<paths.tools>/schau_profile.json` (= `util.home()/tools/` in Lua), then `claude/schau profile reload` and `claude/schau mode <mode>`. Hook in `lua/claude/schau.lua`: `load_profile()`, `clear_profile()`, `weight_for(job, soldier)`, `pick_stats()`; new CLI `claude/schau profile reload|default`; `status` adds `profile` and `cats` (picks per category, last 30 min). Without the file the built-in `JOB_W` and constants apply unchanged (old behavior is the default); `start` loads an existing profile file.
- **Gate:** no action (no file write, no DF write) while `pause.hold` exists or the focus is not `dwarfmode/Default`; `hold_s > 0` gives the note "director paused". Automatic switches never start a stopped director (`schau mode` would start it).
- **Attack context:** attack = `siege.flag` or `alert.flag` (set by the watcher). `camera watch --loop` polls every `poll_s` (1 s) → switch within one poll; `check` does the same once per check (no DF call without an attack). After the attack it switches back to the stored previous profile. Level-5 events and moods are still handled inside schau itself (event queue), independent of the profile.
- **Loop protection:** at most `max_switches_per_hour` (20) switches, logged as `state.db` actions.
- **Tests:** `tests/test_camera.py` (Monte Carlo over a Python mirror of `pick_follow`, mirror checked against the Lua hook through `fixtures/v3/camera/schau_mock.lua`; attack timing with `FakeClock`; stats with largest-remainder rounding = exactly 100 %).
- **Deviations:** "ambient" sparring is additionally covered by a `^Spar` weight 0; `calm` slows pans via `pan_steps` (8 instead of 4); the stats count camera picks (ambient categories and `event:<kind>`), not screen time.
- **Open live checks:** DFHack `json.decode` of the weight file; `claude/schau profile reload` while the director runs; whether sparring soldiers really have no `current_job` in DF 53.
