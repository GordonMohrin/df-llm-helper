# Fixtures FEATURE-004 (hospital watch) - SYNTHETIC

Hand-written in the shape of `claude/pilot_hospital status` (the Lua has not run in a real game yet). Location 11 /
zone 3760 and the 8 posts (2x DOCTOR, DIAGNOSTICIAN, SURGEON, BONE_DOCTOR, occupations 6..13) follow the live notes of
02.10.2026; orphaned locations 0/3/4/10 likewise. Everything else is invented. Each file carries a `"_synthetic"` note.

| File | Case |
|---|---|
| status_all_ok.json | posts filled by living doctors, zone with beds/table/chest, water reachable, refuge supplied, no gypsum |
| status_patients_no_surgeon.json | 3 patients (2 without a care job), nobody with the SURGERY labor |
| status_refuge_no_water.json | refuge burrow without drink/well/water tile (BUG-423 `refuge_supply` shape) |
| status_posts_unfilled.json | all 8 posts empty, 1 patient, orphaned locations, soldier/miner/child/moody/stressed citizens |
| status_post_dead.json | DOCTOR post 6 still points at dead unit 4390, the other posts empty |
| status_alabaster.json | like all_ok, with 3 alabaster boulders (plaster order allowed) |

Gaps: no live recording of `pilot_hospital status`; stone types in stock (`claude/material`) not recorded.
