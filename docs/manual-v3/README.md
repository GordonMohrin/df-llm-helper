# Manual – v3 features

Each v3 feature is a plug-in in `dfpilot/features/` (own command, own config section, optional lines in `dfpilot check`).
All are tested against fixtures, **not yet live-tested**; the live checks are listed in `docs/INTEGRATION.md` (section v3).

| Spec | Command | Section |
|---|---|---|
| 01 Access guard | `perimeter scan/status/seal/allow` | [01-perimeter.md](01-perimeter.md) |
| 02 Dig safety checker | `digcheck` (alias `dig check`) | [02-digcheck.md](02-digcheck.md) |
| 03 Freeze profiler | `perf sample/bisect/status` | [03-perf.md](03-perf.md) |
| 04 Time-standstill / window guard | automatic in `waechter` | [04-freeze-guard.md](04-freeze-guard.md) |
| 05 Work-tool manager | `tools check/status/after-load` | [05-tools.md](05-tools.md) |
| 06 Remote-worker protection | `remote check/status/restore` | [06-remote.md](06-remote.md) |
| 07 Item hygiene | `hygiene status/mark/zones` | [07-hygiene.md](07-hygiene.md) |
| 08 Defense designer | `defense design/status/stats` | [08-defense.md](08-defense.md) |
| 09 Settings manager | `settings get/set/pending/verify/revert/restart-plan` | [09-settings.md](09-settings.md) |
| 10 Camera director profiles | `camera status/profile/stats/watch` | [10-camera.md](10-camera.md) |
| 11 Reachability guard | `reach check/what-if/correlate/points` | [11-reach.md](11-reach.md) |

Add your own feature: create `dfpilot/features/<name>.py` with `KEY`, `DEFAULTS`, `register(sub)` and optionally
`check_hook(pilot, report, dry)` (see the docstring of `dfpilot/features/__init__.py`).

**Fair-play notes:** `tools` runs the pick fix only with an exception-register entry FP08 (player consent);
`settings set` needs `--reason` with the player's words; `perimeter seal --apply` and `defense design --apply --confirm`
are explicit build orders, never automatic.
