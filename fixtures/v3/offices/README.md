# Fixtures FEATURE-001 (offices watch) - SYNTHETIC

Hand-written in the shape of `claude/pilot_offices status` (the Lua has not run in a real game yet); names and unit ids
follow the Run 5 notes (Adil the broker, Kosoth/Rovod, 4193 Urist, 4621 Kol), the values are invented. Each file carries
a `"_synthetic"` note.

| File | Case |
|---|---|
| status_siege_aftermath.json | after the siege: manager/bookkeeper/broker empty, captain/commander/chief medical dwarf on dead units (one histfig without a unit); wounded, moody, child and stressed citizens that must never be suggested |
| status_broker_mood.json | the mayor holds BROKER and is in a strange mood (Run 5 incident); trader 4193 is free |
| status_all_ok.json | all six offices filled by fit units (captain/commander in a squad) |
| status_broker_dead.json | everything ok except BROKER on a dead histfig (trade precheck) |

Gap: no live recording of `pilot_offices status`; `claude/aemter status` (fixtures/run5/aemter_status.txt) has the
assignments but none of the fitness fields.
