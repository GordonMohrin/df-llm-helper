# Camera profiles: `dfpilot camera` (spec v3-10, live-untested)

**What it does:** switches the weights of the camera director `claude/schau` without editing Lua.

| Profile | Shows | schau mode |
|---|---|---|
| ambient (default) | a bit of everything: burial 8, building 7, furniture 6, harvest 6, water 7, lever 5, kitchen 4, digging 3, hauling 1, sleep/eat 0; idle soldiers 0.005, sparring 0; variety 0.3; 18-24 s per unit | auto |
| combat | enemies and fights (sparring stays hidden: combat reports only with visible enemies) | combat |
| build | construction and furniture first | auto |
| events | reports only (moods, caravan, masterworks, finds) | events |
| calm | slow pans, one unit per 40 s | auto |

## Commands
- `python -m dfpilot camera` (= `status`): profile, schau mode/gate, shares per category of the last 30 min.
- `camera profile`: list; `camera profile <name>`: switch (writes `tools/schau_profile.json`, then
  `claude/schau profile reload` and `claude/schau mode <mode>`).
- `camera stats`: shares per category (sum 100 %).
- `camera watch --loop`: during an attack (`siege.flag`/`alert.flag`) switch to `combat` within 1 s, afterwards back.
  `check` does the same once per check.

## Safety
No action while `pause.hold` exists or a menu/sheet is open (focus not `dwarfmode/Default`). "Director paused" when
the player moved the view. Automatic switches never start a stopped director. At most 20 switches per hour.
`claude/schau profile default` returns to the built-in weights; deleting `tools/schau_profile.json` does the same at
the next `claude/schau start`.

## Install
Copy the updated `lua/claude/schau.lua` to `hack/scripts/claude/`. New profiles: add `data/camera/<name>.yaml`
(`extends: ambient` and only the changed keys).
