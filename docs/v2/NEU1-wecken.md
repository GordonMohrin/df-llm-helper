# NEU1-wecken: wake list, dead-man pause, bounded follow (Neuausrichtung 1, package P3)

Plan: `leitung/PLAN-NEUAUSRICHTUNG.md` P3, success measure "0 game days without a session; a wake under 60 s".
BUG numbers: BUG-791 (follow died on an OSError in its sleep), BUG-792 (`wait` woke only on interrupts),
BUG-793 (follow had no memory bound).

## 1. Old decision

* **`dfllm wait --until-interrupt`** (FR-53) returned only on `schema.INTERRUPTS`: ARRIVAL, INTRUDER, PREDATOR,
  DEATHS_3PLUS, NO_DEPOT, CURSED, TRANSFORM. The kernel's reflex already acted on each of them (lockdown default after
  `ack_timeout_s`), so the player woke for things he was told to `ack`. Every emergency the player CAN act on
  (PATIENT_DYING, MOOD_CRITICAL, a thirst/food decision, STRANDED, CUTOFF, SIEGE_START, BREACH, REFUGE_FAIL,
  PAUSED_BY_DF, YEAR_REVIEW, ...) only surfaced when the 300 s timeout of the play loop ran out (about 125 game days at
  PEACE speed). `follow` printed those wakes, but since round 16 nobody reads follow's stdout (no Monitor; the
  playloop forbids it), so its rate-limited wake line went into `follow.log` only.
* **No dead-man switch.** The arbiter "never pauses on its own". When the player session died (or ended at night),
  the fort ran on unattended: Run 16a i1 y555-y557 (19.11.) lost 7 citizens overnight with follow dead and no session.
* **follow** slept outside its error guard: `time.sleep(args.interval)` raised `OSError [WinError 1450]` (machine out of
  resources, 446 MB free of 32 GB) and the process died (Run 16a i1, follow.log line 1321). There was no memory bound.

## 2. New behaviour

### 2a. Wake list (`dfpilot/alarm.py`, config `config/wake.json` `wait`)

One rule: **every class-A event wakes `wait`, unless its type is in `wait.quiet_types` or it is a DECISION_NEEDED whose
`d.id` is in `wait.quiet_decisions`.** Unknown / new class-A types and decision ids wake (fail closed). Interrupts keep
their FR-53 path unchanged (alarm.txt, unacked items).

* A cursor `<save>/.wait.json` (`n` = newest event number a wait has looked at) makes sure an event that arrives while
  the player is busy between two waits is reported at the next call (not lost, not after a timeout). First use, a
  cursor beyond the log (an older save loaded) or a cursor more than `wait.backlog` events behind starts at the end of
  the log (no replay of history).
* One key (`type`, plus `d.id` of a decision) wakes at most once per `wait.repeat_s` (300 s = one play-loop timeout):
  a standing emergency the kernel re-emits wakes as often as a timeout would, never in a busy loop.
* Synthetic wake reasons, checked at every poll (same repeat rule):
  `DEADMAN` (the kernel paused the game because no session lived: the reply is `dfllm cmd resume`),
  `FOLLOW_OFF` (follow does not beat for this save: restart it), `KERNEL_STALE` (the kernel heartbeat is older than
  `wait.kernel_stale_s`: DF hangs or is closed).
* Output: one line per wake reason (at most 8, then `+N more: dfllm events --cls A --since X`), each with the
  `next:` hint follow uses (`wake.next_hint`), exit 0; a timeout prints the old line and exits 1.
* `wait` writes the session heartbeat at start and every 30 s while it blocks (a session inside `wait` is alive).

Wake classes before / after (class A types of `schema.EVENTS`):

| | before (wait) | after (wait) |
|---|---|---|
| wakes at once | ARRIVAL, INTRUDER, PREDATOR, DEATHS_3PLUS, NO_DEPOT, CURSED, TRANSFORM (7) | every class-A type except the quiet list (39 of 57 today) + DEADMAN, FOLLOW_OFF, KERNEL_STALE |
| quiet (brief / follow / `events --cls A` only) | everything else (50 types, incl. PATIENT_DYING, MOOD_CRITICAL, STRANDED, CUTOFF, SIEGE_START, BREACH, REFUGE_FAIL, DECISION_NEEDED, YEAR_REVIEW, PAUSED_BY_DF) | AQ_HEAVY, AQ_RING_STOP, AUTOLABOR_LEGACY, CAVERN_PLUG, CAVERN_SWEEP_END, DEPOT_MISSING, DRILL_FAIL, GATE_FORCED, GHOSTS, KERN_FAULT, LOCKDOWN_PARTIAL, ORDER_BAD, PERF_DEGRADED, PROJECT_BLOCKED, SEAL_STUCK, SIEGE_END, SIEGE_UNREADY, TOOL_BLOCKED; decisions: structural ids (seal_stalled, no_hard_stone, metal, steel, defense_gap, refuge_dry, refuge_levers, bridge_levers, project_released, caravan_stale, manager_office, manager_absent, trade_screen, coffin_space, coffin_material, squads, preventblocking, trap_friendly, piece_missing, gate_traffic, berserk) |

Frequency check on the four Run 16 forts (events.jsonl + events.1.jsonl): 10-57 waking events per game year before the
repeat rule; the repeat rule caps a chronic re-emit (patient_thirst x486 in Whirledrampart) at one wake per 5 min.

### 2b. Dead-man pause (kernel `lua/dfllm/arbiter.lua`, Python `dfpilot/session.py`, config `config/reflex.json` `deadman`)

* **Heartbeat:** `dfllm wait`, `brief`, `cmd`, `ack`, `plan`, `next` write `<save>/session.json`
  `{v:2, wall, by, pid}` (`dfpilot/session.py touch`). Not written by `follow`, `supervise`, `status`, `events`,
  `doctor` (background processes and a supervisor's look must not keep a fort alive) and never with
  `DFLLM_NO_SESSION=1`.
* **Kernel:** the arbiter (sole writer of pause) reads the file every `deadman.check_s` (5 s). Session age >
  `deadman.timeout_s` (600 s; a missing file counts as stale, after a boot grace of `deadman.grace_s` 60 s) and the game
  runs (or only the inbox's own TTL pause holds it) -> pause, owner `deadman`, DEADMAN_PAUSE (class A, once per stale
  heartbeat). **Pause only:** it never unpauses, never saves, never kills. A pause somebody else owns (`df` after a
  load, `popup`, `gordon`) is left as it is and not claimed; when that pause ends while the session is still dead the
  dead-man pauses then. After a dead-man pause the next fire needs a newer heartbeat: if a human unpauses the
  dead-man pause in DF, it stays unpaused (a human is never fought).
* **Park / resume:** inbox verb `park {why?}` (`dfllm cmd park`) pauses and owns the pause as `park` (from any owner);
  nothing wakes for it (no PAUSED_BY_DF, no 10-minute DECISION_NEEDED pause, no dead-man event). `resume` now
  releases `df`, `popup`, `deadman` and `park` (same popup and DENY rules as before). `unpause` stays the inbox hold's
  release only.
* **Interactions (analysed, tested):** load pause (`df`, set in `init`): the dead-man does nothing while it stands;
  `resume` (a session) releases it. Siege: there is no siege pause in the kernel (the reflex lowers the clock only);
  the dead-man pause also holds in SIEGE/BREACH (a paused siege kills nobody). Inbox `pause` TTL: a dead-man fire takes
  the hold over (the TTL expiry would otherwise unpause). Popups: while `deadman`/`park` own the pause,
  pause_state is true, so whitelisted popups are not dismissed-and-unpaused; threat popups are still announced to the
  reflex. follow's TICK_STALL / PAUSED_BY_DF treat `deadman` and `park` like the player's own pause (no wake);
  `supervise` honours any pause (no restart while paused), unchanged.

### 2c. Bounded follow (`dfpilot/wake.py run`, config `config/wake.json` `follow`)

* The sleep is inside the error guard; an OSError / MemoryError in it waits 5 s (a plain busy loop is impossible) and
  goes on (BUG-791).
* Memory bound (BUG-793): every 60 s follow reads its own working set (`GetProcessMemoryInfo`, `resource` on POSIX);
  above `follow.max_rss_mb` (400) or after `follow.max_hours` (12) it saves its state, releases the lock, starts a
  copy of itself with the same arguments plus `--takeover` (same stdout/stderr) and exits with code 0. A copy that
  cannot be started keeps the old one running (logged once per hour).
* Static audit of follow's own containers (Follower, WakeGate, _Lock, EventTail, module caches in files.py / cmd.py /
  fairplay.py): see section 4.

## 3. Config switches (all new behaviour default ON)

* `config/wake.json` `wait`: `act` (true; false = the old interrupts-only wait), `repeat_s` (300), `backlog` (2000),
  `kernel_stale_s` (120), `follow_check` (true), `quiet_types`, `quiet_decisions`.
* `config/wake.json` `session`: `on` (true; false = no session.json written).
* `config/wake.json` `follow`: `restart` (true), `max_rss_mb` (400), `max_hours` (12).
* `config/reflex.json` `deadman`: `on` (true), `timeout_s` (600), `check_s` (5), `grace_s` (60).

## 4. Deliberately not done

* No leak was proven by measurement in follow's own data structures (see the probe below); the memory bound is the
  guarantee, not a proof of absence. The machine-wide exhaustion (four DF instances) is not follow's to fix.
* follow's own synthetic wakes (AUTO_FAIL, QUICKSAVE_FAILED, NEEDS_CLICK, SUPERVISE, PLAN_AUTO, PROJECT_STALE) are not
  routed into `wait`; only the three listed above are checked by `wait` itself. follow's stdout rate limits stay.
* The dead-man never unpauses; the session must `dfllm cmd resume`. No auto-resume when a session comes back.
* The playloop/PLAYBOOK text (Leitung's job) is not changed here; it should say: after a wake, act on the named line;
  `dfllm cmd resume` after DEADMAN; `dfllm cmd park` before a deliberate stop.

## 5. Live-Erwartung

1. After a session ends (no `wait`/`brief`/`cmd` for 10 real minutes) `events --type DEADMAN_PAUSE` shows one event and
   the heartbeat says `paused` with `owners.pause` `deadman`; the game tick does not move until a `dfllm cmd resume`.
   Overnight runs show 0 game days between the last session command and the dead-man pause beyond ~10 min of play.
2. A MOOD_CRITICAL / PATIENT_DYING / DECISION_NEEDED thirst_unit event in events.jsonl is followed by a `wait` return
   naming it within seconds (cli.log `wait` line with the event n); the player's STAND/commands show the reaction in
   the same minute, not 5 minutes later.
3. `wait` does not return more than once per 5 minutes for the same key (no wait storms in cli.log).
4. A follow running more than 12 h restarts itself (`follow: restart` in cli.log and follow.log) instead of dying with
   MemoryError / WinError 1450; `status` never shows `follow: OFF` for longer than a minute because of it.
5. `dfllm cmd park` leaves the fort paused (owner `park`) for hours with no PAUSED_BY_DF, no DECISION_NEEDED pause and no
   DEADMAN_PAUSE; `dfllm cmd resume` runs it again.
