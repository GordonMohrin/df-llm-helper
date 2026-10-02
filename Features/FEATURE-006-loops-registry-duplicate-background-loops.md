# FEATURE-006: `df_llm_helper loops` - registry of background loops, duplicate detection

- **Status:** proposed
- **Priority:** P2
- **Requested by:** Gordon (player), 2026-10-03, via the local orchestrator
- **Area:** new `df_llm_helper loops`, lockfile/heartbeat convention for every loop (`holdguard.sh`, guard, siege, watchdog helpers)

## Problem
Several background loops were started more than once (multiple `holdguard.sh`, one forgotten siege loop). They produced contradicting orders (e.g. kill orders set again after deletion, see BUG-426) and were hard to find.

## Proposed behaviour
1. Every loop takes a lockfile (`tools/loops/<name>.lock` with PID, start time, command) and writes a heartbeat timestamp.
2. `loops list [--json]`: all registered loops, heartbeat age, stale/duplicate marks; `loops stop <name>` ends one (kill PID or stop flag).
3. A second start of the same loop name refuses or warns; `wake`/`digest` warn on duplicates and on loops without heartbeat.

## Safety
Manages only helper-own processes; read-only by default.

## Acceptance (fixture based)
Two lockfiles with the same name -> `DUPLICATE`; stale heartbeat -> `STALE`; `stop` removes the lock.

## Info needed
List of loop names/scripts used on the orchestrator side and where they are started.
