# BUG-107: `plan armor` ignores the equipment soldiers already wear and the free stock, and counts the miner squad as soldiers

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S2
- **Area:** `df_llm_helper/cli.py:629-642` (`cmd_plan`, kind `armor`): `soldiers = [pl.Soldier(id=m.id, name=m.name) ...]`, `pl.plan_armor(snap.pop_total or 0, soldiers, {}, bars)`
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, **paused**), fort "Windrings", date `27. Granite, Jahr 118`

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper plan armor --bars "iron=32,bronze=31"        # live
python Bugs/evidence/BUG-107/repro.py                                # mock (shows the soldier table the CLI sees)
```

## Expected
Per docs/PLANNERS.md: "missing pieces from stock, the rest as forging orders" - only what the soldiers *lack*. `claude/mil tabelle` already tells how many of 9 slots every soldier fills (`Teile/9`), and
`planners/armor.Soldier` has an `equipped` field for exactly this.

## Actual
Live (pop 174 -> quota 18; the squads have 27 members, most of them 6-8 of 9 pieces):
```
Quota 18 soldiers (now 27, missing 0); bars needed 351, available 63, missing 288
  forge 10x weapon from iron (30 bars)
  forge 10x weapon from bronze (30 bars)
  ...
  deferred 27x breastplate (bars missing)
  deferred 27x helm ... 24x helm (bars missing)   deferred 27x shield / greaves / boots / gauntlets (bars missing)
  Note: 27 soldiers > quota 18
```
i.e. a full set for every one of 27 people (`Wache` soldiers show `battle axe | 8/9` in `claude/mil tabelle`; `Bergleute` = pick carriers `pick | 1/9`). `Soldier(...)` is built without `equipped` and `stock={}` is hard-coded,
so the "bars needed 351" and the "forge" list are wrong by an order of magnitude and cannot be used for a decision. The plan also says "27 soldiers > quota 18" and still plans for 27.
The six `Bergleute` (militia miners with pickaxes) are counted as soldiers as well (`truppmitglieder` 27 in `claude/report` includes them).

## Evidence
`Bugs/evidence/BUG-107/live_mil_tabelle_raw.txt` (raw `claude/mil tabelle`, 28 rows), `live_plan_armor.txt` (live output), `repro.py` / `output.txt` (mock).

## Analysis (reporter's hypothesis)
The parser already gives per-soldier equipment counts (`Teile/9`) but not *which* slots; `claude/mil equip` (read-only) lists pieces per soldier. Either call it (and pass `equipped` + free armor stock from `claude/mil lager`/`equip`)
or make the command honest: print `Note: existing equipment/stock NOT considered - upper bound` and exclude squads whose members only carry picks.
The slot "weapon" for the miners is also questionable (a pick is not a weapon the plan should replace).

## Suggested fix (optional)
Fetch `claude/mil equip` once; map to `Soldier.equipped` / `stock`; skip the mining squad (`squad_alias` / weapon == pick); until then print a visible disclaimer.

## Info needed
Cloud session: `claude/mil equip` (read-only) was recorded live: `Bugs/evidence/BUG-107/live_mil_equip_raw.txt` (per squad `members` and an `incomplete` list with `assigned/worn/slots/weapon` per soldier that lacks pieces; no slot *names*, only counts).
Is that enough to derive "pieces missing" per slot, or do you need another Lua output (per-slot list)? Note the output has the mojibake of BUG-401 in `name`.

## Fix
`plan armor` skips pick carriers (mining squad), treats a carried weapon as the weapon slot and 9/9 as a full set, and prints an `UPPER BOUND` note for soldiers below 9/9 (worn armor slots unknown, free stock not checked). Exact per-slot planning still needs a per-slot Lua output (`claude/mil equip` has only counts) - see Info needed. Test with the live `claude/mil tabelle`: `test_bug107_*`.
