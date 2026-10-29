# BUG-222 plan check demands refuge_beds at P3+ that no site takes before fortcore stage 3 is dug
Status: fixed (offline, live-untested)
Severity: high (the first propose on a fort with only fortcore stage 1 gave a P5 draft no hand edit could fix; PLAYBOOK then stops)
Found: 2026-10-29, live round 4, i-test3 "Earthboat" (BUG-197 / refuge gate)
Module: `dfpilot/plan.py` (`refuge_gate`)

## Actual
`plan propose`: `ERROR refuge: Tiefe+ has 0 beds < 8; phase_target P5 (P3+) needs a separated refuge ...: add {"tpl":"refuge_beds",...}`.
Adding that build: `ERROR blueprint: ... 0 free site(s) for refuge_beds` (the room comes with stage 3, drafted in s1 of the same plan).
P4: the same. Only P2 passed. The bed_site False exemption in refuge_gate held only below P3.

## Fix
At any phase, while refuge_beds has no site (fort.refuge.bed_site False), no plan build gives the beds, and fortcore stage 3 is planned in
this plan or under way (fort.refuge.stage3): a warning `refuge: Tiefe+ has N beds < M; beds follow fortcore stage 3 (no refuge room takes
refuge_beds yet): apply, wait for s3.dig, propose again`, no ERROR asking for an unsiteable build. Without stage 3 or with a site the ERROR
stays; stage3_gate still makes stage 3 come first.

## Tests
`tests/test_bug220_223_cli.py::test_refuge_beds_without_a_site_wait_for_stage_3_at_p3_plus`, fails on 5e9e719.

## Live check
Earthboat-like fort with fortcore stage 1 only: `python -m dfpilot plan propose <scratch>/p.json` at P5: no `ERROR refuge: ... beds`, a
`refuge: ... beds follow fortcore stage 3 ...` warning; `plan check` passes the refuge gate; after s3.dig a new propose drafts refuge_beds.
