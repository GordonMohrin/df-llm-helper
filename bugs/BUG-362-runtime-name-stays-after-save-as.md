# BUG-362 the runtime folder and the status keep the old name after save-as
Status: fixed (offline, live-untested): the next boot in the new save folder moves the runtime folder; embark.py save-as asks for it
Severity: medium
Found: 2026-11-04, Run 16b (i2, `runs/run-16b/FR-BUGS.md` "Runtime-Name bleibt region1-site97 nach save-as"), main 595364a
Module: `lua/dfllm/kern.lua` (adopt, boot, rekey_to), `tools/embark/embark.py`

## Actual
i2: embark in the world save `region1`, `dfllm adopt` (key `region1-site97`), `embark.py save-as r16b-ostgate`, `dfllm adopt`
again: events show `boot region1 #1`, `boot r16b-ostgate #2`, but ACTIVE, status and the runtime folder stayed
`region1-site97`. Two forts of one world at one site id (the Oct 28 fort was `region1-site97` too) share that folder.

## Root cause
kern.lua `M.adopt` (:1713): the key is `<save folder at adopt>-site<N>` and lives in the marker (`marker.save`);
`M.runtime_key` (:1507) returns it at every later boot by design (DF renames the loaded save to `autosave N`, a folder per
loaded name would split bp/plan/events). Nothing ever replaced the key by the folder the player gave the fort.

## Fix
- kern `M.rekey_to(marker, save)` (pure) and `rekey` (boot, before the paths are built): the loaded folder is a player name
  (not `autosave N`, not `current`) different from `marker.base` (the folder the key came from; for a marker without it the
  part before `-site<N>`) -> `<runtime>/<old>` is renamed to `<runtime>/<save>-site<N>`, `marker.save/base` are rewritten
  into the site data at once, ACTIVE, the world data `dfllm.active` and the BOOT line carry the new key. The old data moves
  along. Nothing is merged: when the new folder exists, or the rename fails (a tool holds a file open), the old key stays
  and kern.log says why. A key without `-site<N>` (legacy) never changes.
- `adopt` writes `marker.base`; schema `persist.marker` accepts the optional `base`; CONTRACTS 3.5 text.
- `embark.py save-as` ends with the line to run `dfhack-run dfllm adopt` (an adopted fort: adopt = boot = the re-key).

## Tests
tests/lua/test_bug362_rekey.lua (3), tests/test_bug245_250_embark_tools.py `test_bug362_*`.

## Open
Saves written before the re-key still carry the old key in their marker; supervise matches a fort by (marker.save, adopted),
so a crash restore before the first save under the new key falls back to the single marker of the loaded folder (fine for a
fort alone in its world save, ambiguous with several forts). The first autosave after the boot writes the new key.

## Live check
i2-like: embark, adopt, `embark.py save-as NAME`, `dfllm adopt`: kern.log `BUG-362: runtime folder old > NAME-siteN`,
`dfpilot status` shows `NAME-siteN`, `dfllm-runtime/NAME-siteN/` holds the old plan/bp/events.
