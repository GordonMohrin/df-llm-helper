# BUG-135 `unit.curse` does not exist in DF 53.16: the sheet-based curse detection was dead code
Status: fixed in the fix-live-curse commit (offline, live-untested)
Severity: high (a citizen cursed before the boot, or bitten before his first moon, was never found)
Found: 2026-10-28, live test i2 (E:/DF-test2, DFHack port 5001, region2-site90 y717, DF 53.16 / DFHack 53.16-r3) of the M4 curse package, confirmed by the verifier
Module: `lua/dfllm/curse.lua` (`M.sheet`, `were_syn`, `M.look`, `inspect_unit`)

## Actual
`dfhack-run lua` on 5001: `Cannot read field unit.curse: not found`. The unit has flat fields: `uwss_display_name_sing` and
`uwss_use_display_name` (empty/false for a werebeast curse), `curse_year`/`curse_time` (717/46553 for 41657). `M.sheet` read `u.curse`
through `rd()`, which returned nil silently: the sheet never showed a curse in dwarf form. The bitten 42171 (curse_year 717, syndrome 189)
had no record at all in `inspect what=curse`.

## Fix
- `M.sheet(u, miss)`: the shown curse name is `uwss_display_name_sing` while `uwss_use_display_name` is true (a hidden vampire stays
  hidden); the were-form is the race (raw name `werecavy`; live: race 1049 NIGHT_CREATURE_36, `enemy.normal_race` 572); a were-curse
  the game keeps on the unit = `curse_year >= 0` AND an active syndrome with a `BODY_TRANSFORMATION` effect (`u.syndromes.active`,
  `df.syndrome.find(type).ce`, `ce:getType()`): record source `syndrome`, CURSED `ann syndrome`, kind `were`.
- A field read that fails is logged once (`care curse: cannot read unit.<field>`) and listed in `inspect what=unit` `unread`.
- The old tests that set `u.curse` now set the 53.16 fields.

## Decided (fair play, RULES section 1.1)
`curse_year` and the syndromes are not on the unit sheet. They are read only for a were-curse (the body-transformation syndrome), whose
origin the player was shown: the deity curse is a BOX announcement, the bite is in the combat log. A vampire's or a necromancer's curse
(no transformation) is NOT found this way; it stays hidden until the sheet shows its name. The read only informs (CURSED, the recipe);
nothing is done to the unit. `care.curse` false switches the whole reader off.

## Not decided offline
That `df.syndrome.find` and `ce:getType()` read the live syndrome 188/189 as written (the read is guarded; a failure is logged once).

## Tests
`tests/lua/test_curse_live.lua` (BUG-135, the bitten citizen of BUG-136); `tests/lua/test_curse.lua` updated.
