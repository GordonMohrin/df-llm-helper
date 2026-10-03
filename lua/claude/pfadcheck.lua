-- claude/pfadcheck [cx cy cz [zmin zmax]] - can enemies reach the core from outside, and can they do it WITHOUT a trap?
-- BUG-424: replaces the old game-folder-only copy (box x30..150/y60..135/z127..137, a diagonal step needed a free
-- orthogonal neighbour, forbidden doors counted as walls -> two bypasses of the trap alley were missed). Now a thin
-- front end of claude/pilot_perimeter scan (synchronous, whole map in x/y, holds the game ~seconds like before):
--   * DF movement rule: 8 directions, a diagonal step between two corner-touching walls IS possible
--   * doors/hatches are always walkable (the game resets door_flags.forbidden; a locked door is no seal)
--   * core = arguments or config FORT_REFS[1]; levels = arguments or config Z_MIN..Z_MAX
-- Output: the pilot_perimeter JSON; core_reached = "A" (outside reaches the core), bypass = "B" (without a trap tile),
-- entries [x,y,z,core,notrap] (notrap = 1 marks the bypass tiles), door_entries.
-- Read only. Better for regular use: python -m df_llm_helper perimeter (chunked, clusters, allow-list, seal proposal).
local args = { ... }
local a = {}
for i = 1, 5 do a[i] = args[i] or '-' end
dfhack.run_script('claude/pilot_perimeter', 'scan', a[1], a[2], a[3], a[4], a[5])
