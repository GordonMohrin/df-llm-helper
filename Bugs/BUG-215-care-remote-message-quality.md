# BUG-215: `care` cuts names at 24 characters (open quote), critical lines name no action; `remote check` always prints an unexplained `Fish N` line and never `Remote ok`

- **Status:** open
- **Severity:** S3 (messages; the orchestrator gets lines it cannot act on)
- **Area:** `df_llm_helper/care.py` (`str(p.get('name',''))[:24]`, `!! ... hospital/outside` line), `df_llm_helper/features/remote.py` (`fish_line`, `if not out: "Remote ok"`, `short_name`)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, paused), fort date 27. Granite, Jahr 118

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper care --dry-run
python -m df_llm_helper --replay-file Bugs/evidence/BUG-215/l_care.jsonl care --dry-run      # same data, offline
python -m df_llm_helper --config <temp cfg> remote check --dry-run                            # live
python -m df_llm_helper --replay-file Bugs/evidence/BUG-215/remote_river.jsonl remote check --dry-run
```

## Expected
Names are shortened at a word/quote boundary (`Aban Stelidkol "Washedwhips"` or only the first name + id); every `!!` line says what to do ("patient in the hospital, hunger 50248: check GiveFood jobs / food stockpile near (x,y,z)" or points to a command); `remote check` says `Remote ok (0 labors held back)` when nothing happens and labels the fish counter (`Fish catch counter 7 (0 fishers)`).

## Actual
```
!! 486 Aban Stelidkol "Washedwh: hunger 50248, thirst 18680, hospital
!! 4165 Ber Thadudib "Crowdedsyr: hunger 50014, thirst 18470, hospital
Hospital location without zone (orphaned): [0, 4] - report only, nothing deleted
...
$ remote check --dry-run  (live, nothing to do)
Fish 7
```
Plausibility: matches the game (`claude/report` `gefaehrdet`: 486 hunger=50248, 4165 hunger=50014; both are patients resting in the hospital zone 1493 with `job: Rest`, 21 patients and 6 doctors, `GiveFood` x2 open): the data is right, the lines are not actionable. The `!!` text does not distinguish "starving patient in the hospital (feed-job pending)" from "starving dwarf somewhere outside". Also `care` lists a *child* (4165) and `remote status` too (rules refuse to touch children, the status list does not say so).

## Evidence
`Bugs/evidence/BUG-215/` (raw `claude/pilot_care status` answer, outputs).

## Analysis (reporter's hypothesis)
Hard `[:24]` slice; no action text in `CareWatch.run`; `fish_line` returns a string whenever `obs.fish is not None`, so `out` is never empty.

## Suggested fix (optional)
`short_name()` (as in remote.py) for care; add a hint per critical patient (`GiveFood jobs: 2`, `meals 176`); `Remote ok (...)` when no action; label the fish counter.

## Info needed
None.
