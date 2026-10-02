# BUG-102: danger line of the digest prints `Threat:` as raw Python dict reprs (`{'n': 1, 'name': ...}`) and cuts the second threat in half

- **Status:** open
- **Severity:** S2
- **Area:** `df_llm_helper/snapshot.py:308` (`snap.alerts.threats = [str(a) for a in _l(j.get("threats"))]`), used by `df_llm_helper/digest.py:104-105`
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, **paused**), fort "Windrings", date `27. Granite, Jahr 118` (live), mock for the repro

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper digest --full          # live, game with hostile thieves on the map
python Bugs/evidence/BUG-102/repro.py          # same with a patched mock fixture, no game needed
```

## Expected
Names only, readable, e.g. `!! 5 enemies on map, Threat: Snodub Emgen "Jackalluster", Goblin Thief; Smunstu Ezrûamxu "Crewseduced", Goblin Thief`.

## Actual
`claude/status` returns `"threats"` as a list of objects (`{"n": 1, "name": "..."}`, see `Bugs/evidence/BUG-102/live_status_threats_excerpt.txt`), the parser `str()`s the dict:
```
!! 5 enemies on map, Threat: {'n': 1, 'name': 'Snodub Emgen "Jackalluster", Goblin Thief'}; {'n': 1, 'name': 
```
(live, `Bugs/evidence/BUG-102/live_digest_full.txt`; mock repro: `output.txt`). The first threat already uses the whole 80-character budget of
`"; ".join(a.threats[:2])[:80]`, the second is cut after `'name': `, and the name itself (the useful part) is the only thing the orchestrator needs.
This is the most important line of the digest (class `!!`), and the text is also reused by the overlay/wake paths.

## Evidence
`Bugs/evidence/BUG-102/` : `live_status_threats_excerpt.txt` (raw `claude/status`), `live_digest_full.txt` (live digest), `repro.py`, `output.txt`.
The shipped fixture `fixtures/run5/status.txt` has `"threats": []`, so no test covers this.

## Analysis (reporter's hypothesis)
`_parse_status` assumes a list of strings. The live format is a list of `{"n": int, "name": str}`. Convert to `f"{n}x {name}"` (or just the name) in the parser, and add a threats example to a fixture.

## Suggested fix (optional)
```python
snap.alerts.threats = [(f"{t.get('n', 1)}x " if isinstance(t, dict) and t.get("n", 1) != 1 else "") + str(t.get("name", t))
                       if isinstance(t, dict) else str(t) for t in _l(j.get("threats"))]
```
and cut at a word boundary / per threat instead of a flat `[:80]`.

## Info needed
None.
