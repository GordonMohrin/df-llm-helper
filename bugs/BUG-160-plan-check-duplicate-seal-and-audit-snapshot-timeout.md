# BUG-160 `plan check` calls seal at=audit and seal at=refuge a duplicate; `dfllm audit` gives up on a big fort after 60 s
Status: fixed (offline, live-untested)
Severity: low (a false warning; the audit's way out `dfllm audit --snap ID` worked, but the default always failed on Trussroads)
Found: 2026-10-29, live test round 2, instance i1 (Trussroads y722), items NEW2 and NEW3, both confirmed by the skeptic
Module: `dfpilot/plan.py` (`check`), `dfpilot/wake.py` (`audit_timeout`, `run_audit`, `add_audit_parser`)

## Actual
1. NEW2: the duplicate key of a season's builds was `(tpl, site)`: `seal@S1 p.at=audit` and `seal@S1 p.at=refuge` (two different builds)
   gave `warn seasons[3].build[1]: duplicate seal@S1 in one season`.
2. NEW3: `AUDIT_SNAP_S = 60`. A 323k-tile audit snapshot came 70 s after the request (40 s scanning, plus the wait behind a running readiness
   export): `audit: no snapshot aud... within 60 s`.

## Fix
1. The key is `(tpl, site, json.dumps(p, sort_keys=True, default=str))`; equal params still warn.
2. `--timeout` defaults to `audit_timeout(save)`: `min(900, max(180, 60 + 3 * largest snapshot bytes / 16000))` (three scans of the fort: its own export
   and a readiness export it may queue behind). `dfllm audit` prints the wait it uses (`waiting up to N s ...; --timeout sets it`) and one
   `still waiting for ID after 30 s` line.

## Tests
`tests/test_bug159_161_live2.py` (two seals, the adaptive wait, the progress lines, the parser default); fail on main b805745.

## Live check
`dfllm plan check` on a draft with seal at=audit and seal at=refuge in one season: no duplicate warning. `dfllm audit` on Trussroads: the
`waiting up to N s` line (N > 180 on a big fort), then `audit stored, readiness R..` without `--snap`.
