# BUG-355 the new fort's name is not readable before save-as
Status: fixed (offline, live-untested): `embark.py state` and the run status carry `fort`
Severity: low
Found: 2026-11-04, Run 16c (embark tools), kernel main 8890b59
Module: `tools/embark/embark.lua`, `view.lua`, `runner.lua`, `embark.py`

## Actual
Right after embark there was no way to read the new fort's name (it is only known to the kernel after adopt / in the save
header), so a save-as name or the notes could not name it.

## Fix
- `source().fort_name` (read only, pcall): `dfhack.world.getCurrentSite()` name translated, nil when no map is loaded.
  `View.fort` carries it; `embark.py state` prints `"fort": NAME`; every run doc has `fort` once a frame saw it, and
  `embark.py summarize` prints `fort name: NAME`.

## Tests
tests/lua/test_embark_fix6.lua `BUG-355` (view, run doc, none off a fort map).

## Live check
After `embark ... --play-now` (or `save-as`): `python tools/embark/embark.py state` shows `fort`.
