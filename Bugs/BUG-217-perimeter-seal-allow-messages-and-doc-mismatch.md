# BUG-217: `perimeter`: `seal` says "nothing to do" for a forbidden stair access (no explanation, advice loop); `allow` hides notes and accepts out-of-map coordinates; docs say "through the traps" while live says "bypasses the traps" for the allowed access

- **Status:** fixed, live check pending (see TESTPLAN-live)
- **Severity:** S3
- **Area:** `df_llm_helper/features/perimeter.py` (`seal_walls`/`plan_seal`/`seal`, `allow` command), `docs/manual-v3/01-perimeter.md`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, paused), fort date 27. Granite, Jahr 118. Live runs with a temp config (own state + temp `zugang-erlaubt.txt`); `seal` only without `--apply` (I never used `--apply`, also not in mock, because it copies into the game's `dfhack-config/blueprints`)

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper --config <temp cfg, empty allow list> perimeter scan
python -m df_llm_helper --config <temp cfg> perimeter seal --dry-run
python -m df_llm_helper --config <temp cfg> perimeter allow 9999 -5 70000 --note "x"
python -m df_llm_helper --config <temp cfg> perimeter allow 100 100 130 --note "..."
python -m df_llm_helper --config <temp cfg> perimeter allow                    # list
python -m df_llm_helper perimeter scan --dry-run                               # live allow list
```

## Expected
1. After a FORBIDDEN access the advice (`-> seal (python -m df_llm_helper perimeter seal --dry-run)`) leads to a proposal or to an explanation ("entry (99,94,z133) is a stair top whose neighbouring floor tiles are all outside: build a door/wall by hand").
2. `perimeter allow` (list) shows the notes of the file; entries outside the map or within the tolerance of the core are refused/warned (an allow entry at (100,100,130) legalises every access within +-4/+-2 of the core).
3. Doc example of an allowed access: `through the traps`.

## Actual
```
$ perimeter scan  (empty allow list, live)
WAKE perimeter: forbidden access to the core at (99,94,z133) 1 tile -> seal (python -m df_llm_helper perimeter seal --dry-run)
Accesses: 0 allowed, 1 forbidden (checked 12:03)
  FORBIDDEN: (99,94,z133) 1 tile, bypasses the traps
$ perimeter seal --dry-run
Seal: nothing to do (no forbidden access with a buildable tile)        rc 0, no note
$ perimeter allow ... ; perimeter allow
allowed: 99,94,132
allowed: 9999,-5,70000
allowed: 100,100,130                                   (notes are in the file, not in the listing)
$ perimeter scan --dry-run   (live allow list contains 99,94,132)
Accesses: 1 allowed, 0 forbidden (checked 12:02)
  allowed: (99,94,z133) 1 tile, bypasses the traps
```
Raw dump: `claude/pilot_reach dump 96 91 133 102 97 133` -> `",,,,,,,", ",CCCCC,", ",C,,,C,", "CC,>,C,", ",D,,,C,", ",CCDCC,", ",,CTCT,"`: the entry is the `>` at (99,94,z133), all 8 neighbours are outside floor (`,`) or wall; `seal_walls` only walls inside floor tiles, so it finds nothing and prints no note (the doc promises "note in the output" for door/trap tiles). `claude/zugaenge` (live, 17 s) agrees on the facts: `ZUGANG 99 94 132-132 1 true true` (leads to the core, bypasses traps) and no other access leading to the core.

## Evidence
`Bugs/evidence/BUG-217/` (outputs, raw dump `l_dump.jsonl`, scan records, the temp allow file).

## Analysis (reporter's hypothesis)
`seal_walls` returns `(walls=[], notes=[])` for stair tiles without inside neighbours; `seal()` then prints the generic text. `allow` stores the three integers without range checks. The doc text "through the traps" is from the synthetic fixture (the fixture traps at (99,95..96) are assumed).

## Suggested fix (optional)
Add a note for "stair/ramp entry without inside neighbour: seal by hand (door/wall on the stair)"; print notes in the listing; validate x/y/z against the map and warn when an entry lies within the tolerance of `perimeter.core`; fix the doc example.

## Info needed
Gordon: the only allowed access (stair T1) is reported as "bypasses the traps" by both `perimeter` and the live `claude/zugaenge` (`umgeht_Fallen = true`). Is that real (trap tiles not on the walking path of the gatehouse) or is the trap coverage test wrong? Compare with `defense status`: 58 stone traps loaded, 81 trap buildings in total.

## Fix
`seal_walls` adds a note for a stair/ramp entry without inside floor neighbour (`seal by hand`); `seal` then prints `no automatic proposal for ...` with rc 1 instead of `nothing to do`. `perimeter allow` lists notes, refuses tiles outside the map (claude/status map_size, negative values) and warns when an entry lies within the tolerance of the core. Doc example marked as fixture output. Test: `test_bug217_*` (dump `fixtures/bugs/BUG-217/l_dump.jsonl`). Gordon's question (does T1 really bypass the traps?) stays a live check.

Retest note (2026-10-02): `Bugs/evidence/BUG-217/l_per_scan_dry.jsonl` recorded `pilot_perimeter start ... 20000` before
the enclave threshold became the 8th argument; the record now carries the default ` 3000` (same behaviour as the live
run), so `--replay-file Bugs/evidence/BUG-217/l_per_scan_dry.jsonl perimeter scan --dry-run` replays again
(`FORBIDDEN: (99,94,z133) 1 tile, bypasses the traps`). The trap-bypass question stays live.
