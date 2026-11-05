# BUG-436 `plan check` says REJECTED with no ERROR in the tail right after propose
Status: fixed (offline, live-untested)
Severity: low (the player re-ran check, got `plan OK`, and distrusted the tool)
Found: 2026-11-05, Run 16d i4 Mazelanterns y400 (`runs/run-16d/FR-BUGS.md`: first `plan check` right after propose "plan REJECTED" without an ERROR line in the tail, "possible race with the snapshot")
Module: `dfpilot/plan.py` (`run`, `reject_tail`)

## Actual
`plan check` printed `plan REJECTED: <path>` as the last line; the second call after `apply` printed `plan OK`.

## Root cause
Two facts, no random race: (1) `run` prints the ERROR lines BEFORE the placement lines (up to 16) and the verdict, so a `| tail` showed only the verdict. (2) `run` first asks `snapshot_stale` and
refreshes the sites snapshot (BUG-369) when a stage finished after it: the dry placement run of `check` ranks on the NEW map, the draft was ranked on the old one, so a placement error can appear
(or vanish) between propose and check. The map moved; the output did not say so.

## Fix
`reject_tail`: the verdict line carries the number of errors, the first one (220 chars), the sites snapshot id the placement ranked on, and a refresh this very call made (`snapshot refreshed (<why>) ...: the map
changed since the draft; propose again if the first error is a placement`). `propose` prints `ranked on sites snapshot <id>` after the draft line, so the two ids can be compared.
Not changed: the refresh itself (BUG-369: never rank on an old map).

## Tests
`tests/test_bug434_436.py`: `reject_tail` texts, the verdict line of a real `plan check` with an ERROR.

## Live check
`plan propose` then `plan check | tail -1`: the last line shows `N error(s), first: ...` and the snapshot id; after a stage finished in between it names the refresh.
