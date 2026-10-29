# BUG-250 embark tools missing: embark --here, save-as, best compromise and brook distance in the scan summary
Status: fixed (offline, live-untested)
Severity: medium (after a hand placement the gate and accept.log were bypassed; saving under a new name needed PostMessage
scripts; 14 rectangles were compared by hand)
Found: 2026-10-29, Run 15c Inkintense (i1) and Run 15d Drillchamber (i4), y372
Module: `tools/embark/steps.lua` (`S.here`, `S.here_rec`, `S.save_steps`, `record` parts, `merge_tiles` water_at),
`tools/embark/embark.py` (`embark --here`, `prior_rows`, `save-as`, `df_window`, `post_key`, `esc_poster`, `water_points`,
`brook_text`, `best_compromise`), `tools/embark/embark.lua` (`source().save_path`), `tools/embark/view.lua`

## Actual
(1) 15d placed the rectangle by hand (local.place failed, BUG-247), opened the Confirm popup and clicked Confirm/Play now with
click4.lua: no checklist gate, no accept.log; `embark.py state` with the popup open said "panel not readable". (2) "Save and
continue playing" under a new name: simulateInput LEAVESCREEN does not open the Esc menu in fort mode, `_STRING` types
nothing; 15c used PostMessage (Esc, Enter, WM_CHAR), 15d `STRING_A<code>` per character + SELECT. (3) 15c scanned 14
rectangles by hand: brook only in the treeless part, forest+stone+iron without brook; the summary named neither the best
compromise nor how far the brook was.

## Fix
(1) `embark --here [--waive/--accept/--explore-first] [--play-now]`: embark.py passes the rows of the newest 30 result files
(`prior`: rectangle, merged record, hovered tiles `parts`); `site.here` needs the Confirm popup, reads the rectangle on the
screen, merges the hovered tiles inside it (and a read of exactly that rectangle) and the popup's sentences, warns "N of 16
tiles were hovered", and refuses a rectangle with no read ("scan WX,WY --hover first"); then the same gate and Confirm as
`embark`; accept.log site `here`. (2) `save-as NAME`: fort.menu logs whether the Esc menu is open; embark.py posts one Esc key
(WM_KEYDOWN/UP) to the window of THIS DF (matched by the executable's folder) only while `fort.menu.wait` waits after "Esc menu
not open" (at most twice, 15 s apart; `--no-post`); then "Save and continue playing" once, STRING_A000 x48 (backspace), NAME as
STRING_A<code>, the field must show NAME, SELECT, done when `dfhack.getSavePath()` ends in /NAME; names are letters, digits,
space, _ and -, an existing folder is refused. (3) Rows keep `tiles.water_at` (hovered tiles with water); each summary row ends
`brook=in (kind)` or `brook=N tiles at x,y (tag)`; with no `ok` row a line `best compromise: <tag> ... : embark WX,WY,LX,LY
--accept ... --reason TEXT [--explore-first TEXT]` (fewest fails FR-08 can accept, then score).

## Tests
`tests/lua/test_embark_fix6.lua` `BUG-250 ...` (here: gated on earlier hovered tiles and confirmed; refused without popup,
without reads, on a failing criterion; save-as with the Esc menu late and open, typing lost);
`tests/test_bug245_250_embark_tools.py::test_bug250_...` (prior rows, --here spec and accept.log, summary, save-as spec and no
overwrite, Esc only at fort.menu.wait after a closed menu). All fail on 6dc0f19.

## Live check
(1) After `scan WX,WY --hover`, place a rectangle by hand inside the read grid and click it (Confirm popup open), then
`embark.py embark --here --play-now`: the result row is that rectangle with a verdict, accept.log has `here`, the fort loads.
(2) In a fort: `embark.py save-as r15x-test`: output "posted Esc to DF's window" (or nothing when the menu was open), the run
ends `saved as .../save/r15x-test`; the folder exists. If the name field is not shown as text, the run fails with "does not
show": read `embark.py screen` there. (3) `embark.py scan ... --tiles` prints `brook=` on every row and a best compromise line
when nothing is ok.
