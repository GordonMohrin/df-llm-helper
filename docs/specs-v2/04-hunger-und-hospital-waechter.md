# Spec 04: Hunger and Hospital Watchdog (`dfpilot care`)

Priority: P0 | As of: 01.10.2026 (Run 5, Windrings) | Status: implemented (PR v2-04), not yet live-tested | Framework: see README.md

## Goal and Benefit
Letting the wounded starve or die of thirst costs dwarves (Run 5: Urvad, Rovod, Åblel, Stûkud and others). Causes: no doctor labors (DIAGNOSE/SURGERY/BONE_SETTING at 0 dwarves), "Give water" fails without a water source and blocks "Give food", meal shortage, duplicate hospital zones.
**Expected gain:** fewer losses, approx. 10 tool calls saved per case, no repeating of the cause.

## As-Is State
`notfall.flag` ("HOSPITAL/REST(Wasser?)") reports cases; the wake filter has meanwhile gone quiet on it. Treatment was manual work: set labors, check zone, count care jobs.

## Behavior
1. **Measure** per cycle: injured (`#wounds>0` or `limbs_stand_count==0`), hunger/thirst, location (hospital zone yes/no), care jobs (`GiveWater/GiveFood/DiagnosePatient/...`), dwarves with labors (DIAGNOSE, SURGERY, BONE_SETTING, SUTURING, DRESSING_WOUNDS, FEED_WATER_CIVILIANS, RECOVER_WOUNDED), beds/traction benches in the hospital, meals, `Give water: No water source` counter.
2. **Rules (maintenance, automatic):**
   - `care_labors`: fewer than `min_doctors` dwarves with doctor labors → give 5 idle dwarves without military duty all care labors (labor menu), selection by skill.
   - `care_duplicate_hospital`: several hospital locations/zones at the same place → only report, never delete automatically.
   - `care_floor_zone`: patients on the floor outside the hospital → hint (zone missing or too small).
3. **Escalation (proposal):** `Give water: No water source` > 50 → hint water source (KB `wasser_quelle`); meals < 0.2 per head → Spec 05; patient with hunger > `crit_hunger` → top-5 list in the digest.
4. **Digest:** one line per critical patient (id, name, hunger/thirst, location), otherwise "care ok" (German: "Pflege ok").

## Configuration
`care: {min_doctors: 3, crit_hunger: 50000, crit_thirst: 50000, labors: [DIAGNOSE, SURGERY, BONE_SETTING, SUTURING, DRESSING_WOUNDS, FEED_WATER_CIVILIANS, RECOVER_WOUNDED]}`

## Fair Play
Labors are UI operation (labor menu). No direct change of hunger/thirst, no item manipulation.

## Acceptance Criteria
1. Test "0 doctors, 5 injured": rule sets labors on 5 idle dwarves and logs the reason.
2. Test "already 3 doctors": no action (idempotence).
3. Test "hospital duplicated": warning, no deletion.
4. Test "GiveWater cancellations 100×": hint about water source.
5. Property test: soldiers and miners with a pick are never selected.

## Fixtures/Tests
`units` excerpts, gamelog lines "cancels Give water/food", labor lists before/after, zone list.
