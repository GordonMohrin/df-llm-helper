#!/bin/bash
# Reproduces BUG-203 in an isolated copy of the state (uses --mock/--replay-file => runtime/mock/state.db, NOT the live state)
cd "<project folder>"
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1
DB=runtime/mock/state.db
python Bugs/evidence/BUG-203/warnings_query.py $DB siege mood caravan          # before
python -m df_llm_helper --mock fixtures/run5 siege --dry-run                    # prints "Siege ABORTED ... pilot_siege status not readable"
python -m df_llm_helper --mock fixtures/run5 mood reserve --dry-run             # prints "Mood reserve missing: ..."
python -m df_llm_helper --replay-file Bugs/evidence/BUG-203/car_replay_low.jsonl caravan reset
python -m df_llm_helper --replay-file Bugs/evidence/BUG-203/car_replay_low.jsonl caravan --dry-run --loop --interval 0
python Bugs/evidence/BUG-203/warnings_query.py $DB siege mood caravan          # after: rows with level crit/warn, shown=0
