"""Config only (spec v3-04, time-standstill and window guard). The logic lives in dfpilot/freeze_guard.py and runs
inside the watcher (dfpilot/waechter.py); there is no CLI command of its own."""
from __future__ import annotations

KEY = "freeze_guard"
DEFAULTS = {
    "enabled": True,
    "ticks_to_act": 3,          # watcher ticks (2 s each) without frame/year-tick movement before acting
    "max_leave": 4,             # LEAVESCREEN inputs per attempt (until dwarfmode/Default)
    "leave_gap_s": 1.0,         # pause between two inputs of one attempt
    "grace_s": 20,              # a window the player opened while time was running is left alone this long
    "classes": ["Info", "Help", "MessageBox", "ViewSheets"],   # focus classes the guard may close
    "max_attempts": 3,          # unsuccessful attempts in a row -> critical warning, no further inputs
    "max_per_hour": 10,         # hard cap of close attempts per hour (state.db actions)
    "aftercare": True,          # trade aftercare after trade.flow == DONE
}
