# BUG-155 `dfllm bp preview workshops only=Quern` is refused (`unknown params ['only']`)
Status: fixed (offline, live-untested)
Severity: low (the preview the HANDOVER asks for before a bp.place does not work with `only`)
Found: 2026-10-28, live test i4 (M6-BUG-118 side note, new bug 3)
Module: `dfpilot/cmd.py` (`translate_only`, `place`), `dfpilot/cli.py` (`_preview`)

## Actual
The FR-76 translation `only=<types>` -> `skip` (the other moodable types) / `add` (extra shops) lived inside `cmd.place` only; `cli._preview`
passed the raw params to `bp.render.preview`: `bp: bp.render.preview(workshops): workshops: unknown params ['only']; known: ['add', 'burrow', 'skip']`.

## Fix
`cmd.translate_only(tpl, params) -> (params, types)`, used by `place` and by `_preview` (with a site label: the placed document's params).
An unknown type is refused in both with the known list.

## Tests
`tests/test_care_live_i4.py::test_bp_preview_accepts_only` (fails on main 2c0ffa3).

## Live check
`dfllm bp preview workshops only=Quern` and `... --site S1` render one Quern; `only=Nope` names the unknown type.
