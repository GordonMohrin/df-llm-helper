# Offices watch (`python -m df_llm_helper offices`) – FEATURE-001

Status: implemented, **not yet live-tested**. The Lua part (`lua/pilot_offices.lua`, installed as
`claude/pilot_offices`) is read-only and LIVE-UNTESTED.

Checks whether the important positions of the nobles menu are filled by someone who can do the job. Run 5, year
120/121: the broker was dead and the mayor holding the office was in a strange mood (a caravan was missed); after the
siege the captain of the guard, the militia commander and the chief medical dwarf were still assigned to dead units.

## Commands
| Command | What it does | DF access |
|---|---|---|
| `python -m df_llm_helper offices [--json]` | State of every required office (`ok`, `empty`, `dead`, `unfit (<reason>)`) and one successor per problem; exit 1 when an office has a problem | `claude/pilot_offices status` (read only) |
| `python -m df_llm_helper offices --plan` | additionally prints the `claude/aemter` commands `--apply` would send | read only |
| `python -m df_llm_helper offices --apply [--replace-unfit]` | assigns the suggested successors through `claude/aemter vacate <CODE>` + `assign <CODE> <unit>` (dead/unfit holder) or `assign` alone (empty office); needs the register entry `OFFICES`; `--replace-unfit` also replaces holders in a mood, stressed, wounded ... | `claude/aemter` (nobles menu equivalent, logged to `tools/out/aemter-log.json`) |
| `python -m df_llm_helper offices watch` | one evaluation with the state-change rule (prints only when the problem set changed) | read only |
| `python -m df_llm_helper offices --file status.json` | offline on a recorded `pilot_offices status` answer | none |

Example (fixture `fixtures/v3/offices/status_siege_aftermath.json`):
```
OFFICES: MANAGER empty, BOOKKEEPER empty, BROKER empty, CAPTAIN_OF_THE_GUARD dead (Kosoth), ... -> suggest MANAGER 4621 Kol (Mechanic), BOOKKEEPER 4310 Monom (Clerk), ...
  MANAGER: empty, holder - -> 4621 Kol Rakustlolor (Mechanic, score 14.0)
  CAPTAIN_OF_THE_GUARD: dead, holder Kosoth Tilatbembul -> 4080 Mafol Tunemsibrek (Axedwarf, score 35.0)
```

## Rules
- **Required offices:** `offices.required` (default MANAGER, BOOKKEEPER, BROKER, CAPTAIN_OF_THE_GUARD,
  MILITIA_COMMANDER, CHIEF_MEDICAL_DWARF; the player wants the captain of the guard as a mandatory office) plus MAYOR
  when the fort has the position. MAYOR is elected: reported, never suggested or assigned. A required position the fort
  does not have yet is `n/a` and not counted.
- **ok** = holder alive, adult, no mood, no prisoner, not a patient (cannot stand / resting), stress <=
  `offices.stress_max` (75000), the broker reaches the trade depot, captain/commander are soldiers.
  **dead** = the assignment points at a dead unit or a histfig without a unit (`gone`). **empty** = nobody assigned.
  `offices.on_demand` lists offices that may stay empty (e.g. `["BROKER"]` when `claude/handel prep` appoints the broker
  per caravan).
- **Successor score** (`offices.score`, pure): skills for the job (manager ORGANIZATION, bookkeeper RECORD_KEEPING,
  broker NEGOTIATION/APPRAISAL/JUDGING_INTENT, captain/commander LEADERSHIP + best weapon + squad membership, chief
  medical dwarf DIAGNOSE/SURGERY/SET_BONE), minus stress (1 point per 25000), minus 0.5 per wound (scars count too),
  minus 6 for a pickaxe holder as manager/bookkeeper (no heavy labor), minus 4 for a caretaker while patients exist.
  Not eligible: dead, child, prisoner, mood, patient, stress above the limit, a soldier for a civil office, a broker
  who cannot reach the depot, a unit that already holds another office. Each office gets a different unit.
- **Digest/wake:** `check` runs the watch every `offices.every_s` (300 s). A changed problem set writes ONE warning
  for the digest (`[offices] OFFICES: ...`): level crit when an office is dead or empty (exactly one wake line), warn
  when holders are only unfit. An unchanged state stays silent; `Offices: 6/6 filled (resolved)` when it is fixed.
- **Trade precheck:** before PAUSE the trade automaton (`trade step`, `caravan`) asks for the broker. Dead, in a mood,
  prisoner, child, wounded, depot unreachable, or empty without any candidate -> the trade goes to FAILED at once with
  `offices: BROKER dead (Adil); candidate 4193 Urist -> python -m df_llm_helper offices --apply ..., then trade reset`;
  no pause, no `pause.hold`. An empty office with a candidate passes (`claude/handel prep` appoints one); stress alone
  does not block. `offices.trade_precheck: false` switches it off; an unreadable `pilot_offices` never blocks a trade.

## Fair play
Reading is free. `--apply` only with the player's consent in the register (assigning is a nobles-menu action, but it
changes the fort):
```bash
python -m df_llm_helper exception add OFFICES --local --reason "fill dead/empty offices" --ja "<verbatim quote>"
```
It never assigns a unit in a mood or in the hospital (they are not eligible), never touches elected offices, and stops
when a `vacate` fails.
