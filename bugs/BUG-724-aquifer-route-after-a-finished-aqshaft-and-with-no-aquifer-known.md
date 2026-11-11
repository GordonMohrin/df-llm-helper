# BUG-724 the aquifer route after a finished aqshaft: core near the shaft, and with no aquifer known the fortcore is no longer dropped
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10/11, Run 16c i3 Doorwings (`plan propose` after the finished aqshaft drew no fortcore with aquifer=pass; the core site lay 30 tiles from the shaft at 94,98; E13) and Run 16d i4 Pagedsculpture y372-y373 ('no fortcore ... no aquifer level known' for years, `bp sites fortcore aquifer=pass` 'known levels none' after an aqshaft that found no aquifer; E22)
Module: `dfpilot/plan.py` (`aquifer_route`, `_route_unknown`, `_pass_sites`, `aq_done_shaft`, `aquifer_core_swap`), `dfpilot/bp/sites.py` (`_rank_pass`)

## Root cause
`aquifer_route` ended with 'no aquifer level is known: nothing to pass' when the known set was empty, and `aquifer_core_swap` then removed every fortcore build: a fort whose first site was unusable (`surface_facts.need`) and whose probe shaft found no aquifer never got a core. With a known aquifer the sites were ranked without a position, so the core stood where the ranking liked it, not beside the shaft that had passed. `_rank_pass` named 'known levels none' and 'under the aquifer' with no aquifer to pass.

## Fix
- `aq_done_shaft`: the finished aqshaft with the lowest bottom (AQ_PASS_DONE bot, else top - depth + 1) and its anchor.
- `_pass_sites`: with a finished shaft that passed every known level, the pass sites within `AQ_CORE_NEAR` (24) tiles of it first (`free_sites where=near/within`), else the plain ranking; no new shaft column is needed then.
- `_route_unknown` (no aquifer level known): a shaft under way -> wait (nothing drafted, reason named); a finished shaft -> fortcore p.aquifer=pass at the shallowest depth 3, 2, 1 whose deepest level the shaft reached; no shaft -> the probe column (`core_probe_args`) first, the core with p.aquifer=pass behind it. `aquifer_core_swap` takes a route without a column and words the note (BUG-724). The runner (BUG-723) digs the core only once a shaft reached its deepest level, in observe mode: nothing is dug blind.
- `sites._rank_pass` with no aquifer known: says there is nothing to pass and that the sites fail for other reasons (no 'known levels none').

## Tests
`tests/test_bug723_726_aq_core.py` (8): `aq_done_shaft`; the core near the passing shaft (the `where` call), a shaft above the heavy layers is no reason to stay near and a second shaft is drawn; no aquifer + finished shaft -> fortcore pass depth 3, no new shaft; a shaft that ended above the core is not enough; no shaft -> seal, probe aqshaft, fortcore pass; a shaft under way waits; the `_rank_pass` message.

## Live check
`plan propose` on a fort with a finished aqshaft and no known aquifer lists `fortcore p.aquifer=pass` with the BUG-724 note instead of 'no aquifer level is known: nothing to pass'. Open: the core waits (`shaft ends zN, core zM`) when the finished shaft is too shallow and no aquifer is known: a deeper aqshaft is not drawn by itself then (a re-draft after the shaft stops on a level it finds is).
