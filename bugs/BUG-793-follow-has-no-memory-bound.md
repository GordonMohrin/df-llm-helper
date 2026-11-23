# BUG-793: follow has no memory bound

Part of Neuausrichtung 1 / P3; full design, interactions and Live-Erwartung: [docs/v2/NEU1-wecken.md](../docs/v2/NEU1-wecken.md).

- **Symptom:** MemoryError in follow and `plan check` (Run 16a i1, Run 16c i3, 446 MB free of 32 GB); follow had no memory bound and no self-restart.
- **Change:** `dfpilot/wake.py` `rss_mb`, `restart_why`, `spawn`, `run` (copy with --takeover above `follow.max_rss_mb` or after `follow.max_hours`).
- **Test:** tests/test_neu1_wecken.py test_bug793_*
- **Status:** fixed (offline, live-untested)
