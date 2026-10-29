# BUG-169 The kernel's lone-intruder kill order also targets the far ones; the sortie end names only the last target
Status: fixed (offline, live-untested)
Severity: high (the squad marched 150 tiles out of the fort during a BREACH)
Found: 2026-10-29, live test round 2 i3 (M3-killorder regression, NEW2, NEW7-kill-sortie-end-text)
Module: `lua/dfllm/reflex.lua` (`lone_picture`, `lone_step`), `lua/dfllm/military.lua` (`kill_lone`, `so_begin`, `so_end`, `sortie_pass`),
`dfpilot/schema.py` (SORTIE `dead`)

## Actual
Trog 42713 stood inside Kern+ (census zn 2), rat 42739 at 191,191,129 (zn 0, 149 tiles out). After kill_hours: "sortie A: the kernel orders a
kill on the harmless intruders 42713,42739 inside the fort", DF's kill list held both; after 42713 died soldiers walked to 188,186,129 during
the BREACH. lone_picture set `inside` when ANY entry was inside and lone_step passed every id; kill_lone took every visible id and the first as
the sortie position. The sortie closed with "target 42739 dead" only (so.ids keeps the living targets).

## Fix
lone_picture returns `in_ids` (entries with `how == 'inside'`); lone_step passes only those (the far ones keep the question and siege_release).
kill_lone keeps only ids the census shows at zn 2 (refusal "the target is not inside the fort"). A kill sortie keeps every target (`so.ids0`):
the `dead` end names all of them ("targets 42713,42739 dead", d.units), any other end adds the ones that died on the way (d.dead, "; dead: ").

## Tests
`tests/lua/test_bug169_kill_order.lua` (fails on b805745); `tests/lua/test_m3_sortie.lua` kill_lone target moved inside Kern+.

## Live check
BREACH with one harmless intruder inside Kern+ and one far out, `sortie.worn` low enough: the kill order names only the inside one, the squad
stays inside; with two inside, the end event reads "targets A,B dead"; an abort after one died lists it in d.dead.
