# BUG-386 the runtime name stays region1-site97 after save-as although BUG-362 is in
Status: fixed (offline, live-untested): the re-key finds the player's save name behind 'autosave N' (marker.want, else the BOOT events)
Severity: medium
Found: 2026-11-04, Run 16b (i2, `runs/run-16b/FR-BUGS.md`: "status/doctor zeigen weiter region1-site97 ... Fix 18 wirkt hier nicht")
Module: `lua/dfllm/kern.lua` (player_name, note_player_save, rekey), `dfpilot/schema.py` (persist.marker)

## Actual
i2 kept `region1-site97` after the fix round 18 (BUG-362) and several kernel reloads.

## Root cause
Not a missed adopt: the evidence is in `region1-site97/events.jsonl`. `boot region1 #1` and `boot r16b-ostgate #2` (the save-as) are
from 14:15, BUG-362 landed at 15:31, so the only boot that ran in a player-named folder ran on code without the re-key. All later boots
(#3 `autosave 2`, #4 `autosave 1`, #5 `autosave 3`) run in DF's autosave folders, and `kern.lua` `M.rekey_to` ignores those by design.
The name the player gave was gone for good: the marker holds only the first adopt's folder (`region1`). So every `dfllm reload` /
adopt after the code fix saw `autosave N` and left the key alone. The same happens for any save-as whose first boot fails to rename
(a tool holds a file open): the next boot already runs in an autosave folder.

## Fix
- `M.player_save(name)`: the shape check (not 'autosave N', 'current', no path), shared by `rekey_to`.
- `M.player_name(marker, save, root)` (kern.lua:1525): the loaded folder if it is a player name, else `marker.want`, else the newest BOOT
  event of the fort's runtime folder (events.jsonl, then its rotation) whose save is a player name. `rekey` (boot, :1584) re-keys by it:
  an old fort like i2 gets `r16b-ostgate-site97` at its next `dfllm reload` / adopt, old data moved along (nothing merged, as BUG-362).
- `M.note_player_save` (:1553, frame, with the save folder poll): the running kernel writes a player-named loaded folder into the
  marker as `want` (once, site data), so a save-as survives the DF rename to 'autosave N' even when the rename fails at that boot (the
  next boot retries). A successful re-key clears `want`. Schema `persist.marker` takes the optional `want`.

## Tests
tests/lua/test_bug386_player_name.lua (4).

## Open
A target folder that exists already (another fort of the same name) still keeps the old key (BUG-362, nothing merged); kern.log says so at every boot.

## Live check
i2: `dfhack-run dfllm reload` (or adopt): kern.log `BUG-362: runtime folder region1-site97 > r16b-ostgate-site97 (save-as r16b-ostgate)`,
`dfpilot status` shows the new key, `dfllm-runtime/r16b-ostgate-site97/` holds the old plan/bp/events. On a new save-as, kern.log
`BUG-386: save folder NAME noted for the next boot` while the fort runs.
