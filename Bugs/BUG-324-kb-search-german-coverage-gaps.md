# BUG-324: `kb search` with natural German terms returns no hits or a wrong first hit (`Zwerge`, `Händler hängt`, `Überschwemmung`, `Grundwasser`, `Küche`, `Flagge`, `Ruckeln`; `Holzkohle` ranks `bett_ohne_holz` first)

- **Status:** open
- **Severity:** S3
- **Area:** `kb search` (`df_llm_helper/kb.py:SYNONYMS`, `data/kb/curated.yaml`)
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
for q in Zwerge "Händler hängt" Überschwemmung Grundwasser Küche Flagge Ruckeln Bestie Holzkohle; do python -m df_llm_helper --mock fixtures/run5 kb search "$q"; done
```

## Expected
German symptom words used by the players/agents (the memory files and the in-game messages are German) find the matching entries: `Händler hängt` -> `handel_ablauf`/`makler_squad`, `Überschwemmung`/`Grundwasser` -> `wasser_diagonal`/`aquifer`, `Küche` -> `kochschleife`, `Flagge` -> `flags_stale`, `Holzkohle` -> `koks_brennstoff`.

## Actual
```
$ for q in <queries>: python -m df_llm_helper --mock fixtures/run5 kb search "$q"      # top hits (ids)
Zwerge                       -> No hits
Händler hängt                -> No hits
Überschwemmung               -> No hits
Grundwasser                  -> No hits
Küche                        -> No hits
Flagge                       -> No hits
Ruckeln                      -> No hits
Bestie                       -> kavernen_schleuse, flags_stale
Holzkohle                    -> bett_ohne_holz, waechter_blind, koks_brennstoff
Betten Holz                  -> bett_ohne_holz, waechter_blind, koks_brennstoff
Leerlauf                     -> zuflucht_burrow
dwarves die of thirst        -> getraenke_wueste, grabstau_arbeitsgruppen, e18_pick
Wasser fließt diagonal       -> wasser_diagonal, wasser_quelle, zuflucht_burrow
Karawane Händler             -> handel_ablauf, flags_stale, makler_squad
Spitzhacke                   -> e18_pick, fairplay_foreign, e18_release
Wächter blind                -> waechter_blind, guard_start, belagerung_pop
Verletzte ohne Krankenhaus   -> hospital, bett_ohne_holz, wasser_quelle
[exit 0]

$ python -c "print(key in kb.SYNONYMS for the German words ...)"
False False False False False False
['water', 'groundwater', 'grundwasser']
['caravan', 'trade', 'haendler']
['flagge']
[exit 0]
```

## Evidence
`Bugs/evidence/BUG-324/*.txt`. (About 70 queries were run; all English queries and the German ones that have a synonym entry found the right KB id.)

## Analysis (reporter's hypothesis)
`kb.py:SYNONYMS` is one-directional (English key -> German aliases): `"aquifer": [..., "grundwasser"]` helps an English query, but there is no key `grundwasser`, `haendler`, `flagge`, `zwerg`, `kueche`, `ueberschwemmung`, `ruckel`. Entries are English only, so a German term without a key matches nothing. `Holzkohle` is split into `holz`+`kohle` (`holz` -> `wood` -> `bett_ohne_holz`). There is no KB entry about megabeasts/forgotten beasts at all (`Bestie` finds `kavernen_schleuse`), although Run 3 lost 14 dwarves to one (`feedback_df_beast_lehren_run3`).

## Suggested fix (optional)
Add the missing German keys (and make `SYNONYMS` symmetric automatically), add `symptom_keywords` in German to the curated entries, add a beast/megabeast KB entry.

## Info needed
Question for the cloud session / player: which German terms do agents really use when they search? (The scope memories are in German.)
