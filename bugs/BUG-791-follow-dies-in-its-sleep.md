# BUG-791: follow dies in its sleep

Part of Neuausrichtung 1 / P3; full design, interactions and Live-Erwartung: [docs/v2/NEU1-wecken.md](../docs/v2/NEU1-wecken.md).

- **Symptom:** follow died with `OSError [WinError 1450]` in `time.sleep` outside its error guard (Run 16a i1 Basementflew y555, follow.log line 1321); the fort ran overnight without follow or session, 7 citizens died.
- **Change:** `dfpilot/wake.py` `_sleep` (guarded, 5 s pause after an error) used by `run`.
- **Test:** tests/test_neu1_wecken.py test_bug791_*
- **Status:** fixed (offline, live-untested)

## Live-Erwartung
1. follow survives a failing sleep (WinError 1450 / OSError): follow.log shows the error and the next beat about 5 s later, never a traceback that ends the process.
2. `status` shows follow beating through a low-memory night; no night without follow while DF runs.
