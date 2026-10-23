# BUG-093 The militia rotation line (FR-79) takes the bridges, the alert and the refuge trust out of the status
Status: fixed in the integration audit J3 commit (offline, live-untested): the defense line is split into a core and the army's
detail; the detail (melee sets, free metal gear, the rotation lines) is the lowest-ranked item of the status and the end of the
brief's head
Severity: medium (a wrong report: at 80 citizens the status loses `bridges`, `alert Kern+` and `refuge NOT TRUSTED` the day the
first rotation line exists, and in a siege the line does not fit at all)
Found: 2026-10-23, integration audit J3 (wave D's `mil.rot` read against BUG-071/BUG-080's status ranking and BUG-049's refuge trust)
Module: `dfpilot/brief.py` (`def_parts`, `status_text`, `brief_text`)

## Actual
`brief.line_def` joined threat, bridges, alert (with `refuge NOT TRUSTED`, BUG-049), the army (`mil ...`, `melee ...`, `free
metal ...`), the militia rotation lines (FR-79, one per squad of `military.militia`, 35-45 tokens each), the intake wave and
the caravan into ONE status item of rank 3. `fit_ranked` drops whole lines: over the 300-token budget the rank-3 line goes
whole. Measured on a fort of 80 in PEACE with the optional fields a game year fills (stress, adopted workshops, idle breakdown),
its refuge not trusted: 265 tokens without the rotation, 183 with squad B's line, the whole defense line gone (bridges,
alert, `refuge NOT TRUSTED`, soldiers on station). In a siege with a lockdown, a recall and the usual pop and stock lines the
status stood at 213 tokens WITHOUT the defense line, which with its detail (95 tokens) did not fit into the 300 any more, so
a siege status never named the bridges. The brief had the mirror image: the maximal state of audit I1 (1,487 of 1,500) plus
three rotation lines lost its `proj`, `kern` and snapshot lines (the head's tail).

## Cause
BUG-080 (audit I1) split the pop, supply and alarm bundles into ranked items for exactly this reason, but the defense bundle
stayed one atomic item. FR-79 (wave D, merged after that audit) added lines to it; nobody read the status of a fort with a
militia squad.

## Fix
`def_parts(ctx)` returns the core (threat, bridges, alert + trust, the army's count, intake, caravan) and the detail (melee
sets, free metal gear, the rotation lines). `status_text` ranks the core 3 as before and the detail 5, so it is the first
line to go; the brief's head ends with the detail line (it goes before `proj`, `kern` and the snapshot queue). `line_def`
still joins both (tests and callers unchanged). Nothing changes while there is room: the D1 test of the status line passes.

## Tests
`tests/test_j3_whole.py` (fails on c038ce9): the fort of 80 keeps `bridges B1 up`, `alert Kern+`, `refuge NOT TRUSTED` and
`mil 3sq 22sol` with the rotation line present (the rotation is the line that went, the brief has it); a siege status names
`bridges O1 down ... O4 down`; the brief of the maximal state plus three rotation lines keeps `proj` and `kern`.
