# BUG-280 audit 'fail: refuge: none (manifest refuge.anchor)' right after fortcore stage 1
Status: fixed (offline, live-untested)
Severity: low (a fail that is only a stage still to come)
Found: 2026-10-29, Run 15 Inkintense (y372), fix6-alarm-noise
Module: `dfpilot/bp/topo.py` (`audit`, section 3), `dfpilot/bp/validate.py` (`check_world`)

## Actual
`runs/run-15c-inkintense/FR-BUGS.md`: `audit` winter d74: 'ok no ... refuge_sep no ... fail: refuge: none (manifest refuge.anchor) or
not walkable', fortcore stage 1 done, stages 2/3 in plan y372b.

## Cause
`bp/topo.audit` appended the fail whenever no refuge point was walkable, also when the manifest had no refuge at all: fortcore adds
`refuge.anchor` to the manifest only with stage 3.

## Fix
No refuge in the manifest and no refuge mark: no fail; `info["pending"]` says 'refuge: pending fortcore stage 3 (no refuge in the
manifest yet)'; `refuge_sep` stays false, so readiness R0 keeps asking for it. A manifest refuge that is not walkable still fails.
bp.validate.check_world with `final` (fortcore stage 3+ as built) still turns the pending note into a `refuge` finding.

## Tests
`tests/bp/test_topo_refuge_pending.py` x2 (the first fails on 2b9c009).

## Live check
`dfllm audit` in a fort with fortcore stage 1 or 2 only: no 'fail: refuge: none' line, refuge_sep no; after stage 3 the refuge
checks run as before.
