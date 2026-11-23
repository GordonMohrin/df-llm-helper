# NEU1 P1: Wertung (fort score) and Engpass-Leiter (ladder)

Neuausrichtung 1, package P1 (decisions E7, E9; GRUNDSATZ-REVIEW "Ziele und Messung"; EHRGEIZ-MECHANIK section 2).
Python only: `dfpilot/wertung.py`, `dfpilot/leiter.py`, CLI `dfpilot wertung` / `dfpilot leiter`, three lines in
`brief`, one in `status`. Offline, live-untested.

## Old decision

- Success was "nothing bad happened": 18 wish goals G1-G18 kept by hand in `runs/*/GOALS.md`, mostly bans or end
  values; no tool said whether a round helped, and "years survived" rewards a fort that stagnates.
- Deaths were counted by keyword in STAND.md (about +-15 %); there was no ranking of death causes.
- The PLAYBOOK told the player "everything green -> do nothing"; no tool named a next goal.

## New behaviour

### `dfpilot wertung` (dfpilot/wertung.py)

One score line per fort, computed by the tool from runtime files only (events.jsonl + events.1.jsonl in the live
timeline, perf.csv + perf.1.csv, the tool's own `<save>/wertung.json` pop samples):

    WERTUNG r16b7-whirledrampart y414-y478 (64.1 J) | 2310 ZJ | Tote 101 = 4.4/100ZJ: Durst/Hunger 38, ... |
    Belagerungen 4: Verlust Mittel 21 % max 62 % | R1 nach 25.3 J | Pop 7>65>98(y450)>44 | Daten Pop 67 %

- **Dwarf-years (ZJ)**: the population (perf `pop` = census citizens) integrated over game time, piecewise linear
  between samples; before the first sample the embark (7 citizens at the fort's first event) is joined linearly.
  `Daten Pop N %` = the share of the fort's time within one season of a real sample (the rest is interpolated).
- **Deaths**: the newest DEATH per unit (a "found dead" revision replaces "not found yet"), citizens only, at the
  tick of the first report. Classes, first matching rule wins: `alter` (old age) > `stimmung` (the victim in or after
  a strange mood) > `belagerung` (violent or missing inside a siege episode) > `geist_berserk` (killed, strangled or
  scared by a dwarf or ghost) > `unfall` (trap, crushed, bridge) > `graben_wasser` (drowned, cave-in, suffocated
  without killer) > `patient` (a patient dead of thirst, hunger, bleeding, infection) > `durst_hunger` > `tiere`
  (killed by a creature outside a siege) > `vermisst` (never found) > `sonst`.
- **Siege episodes**: a SIEGE_START opens an episode (repeated "siege again" starts inside it are merged); SIEGE_END
  or the next MODE change to PEACE closes it, else the fort's last event. Loss = citizen deaths of any class inside
  it (plus one day) / population at its start.
- **R1**: the first READY_CHANGE to >= 1, in game years after the fort's first event; `R1 nie` otherwise.
- **Pop curve**: embark > up to four evenly spaced samples > peak (year) > now.
- `wertung.json` (tool file, kind `wertung`, CONTRACTS 9.20) keeps at most one pop sample per game day from the perf
  rows, so the curve survives the rotation of perf.csv (perf.1.csv is deleted at the next rotation). `wertung`,
  `leiter`, `brief` and `status` refresh it; a clock jump back drops the samples after the new tick.
- Retrospective: `dfpilot wertung --dir <save folder>` for any old fort, `--alle <runtime root>` for every fort folder
  there, `--stand <STAND.md>` adds the player's `y### ... Pop N` lines of that fort's segment as extra pop samples
  where perf has none, `--md FILE` writes the table. `tools/wertung_rueckblick.py` builds
  `docs/v2/WERTUNG-rueckblick.md` for all Run 15/16 forts.

### `dfpilot leiter` (dfpilot/leiter.py)

Six tracks with three levels each (EHRGEIZ-MECHANIK 2), from the kernel state (`state.a/b.json`) and events only:

| Track | I | II | III |
|---|---|---|---|
| Versorgung | food_d >= 60 and drink_d >= 60 | drink_d >= 170 | drink_d >= 170 held one game year |
| Wehr | ready.open == 0 (every way in has a door or bridge) | ready.lvl >= 1 (R0 passed) | R1 and no trap shortfall (no `traps_short` / `traps<N` fail, no ready.ts) |
| Ruestung | a squad, soldiers, every soldier armed (kit.weapon >= kit.n) | kit.full >= 6 | kit.full >= 10 and metal_pct >= `ruestung_metal_pct` (50) |
| Volk | 30 citizens | 50 | 80 |
| Wohl | 0 ghosts, 0 old corpses | hospital with water (water.hosp >= 1, hosp_ok 1) | stressed_pct < 10 held one game year |
| Ausbau | phase >= P3 | P5 | P7 |

- Levels are consecutive (II needs I). Missing data counts as not met (fail closed); no state prints `LEITER ?`.
- **Gates**: Volk II needs Wehr II; Volk III needs Wehr III and Ruestung II (effective level = min(raw, gate)).
- **Lock per cause**: an avoidable citizen death of the last game year locks its track until the tool sees the cause
  fixed: `durst_hunger` -> Versorgung (fixed: food and drink >= 60 d); `patient` -> Wohl (fixed: hospital with
  water); `stimmung` -> Wohl (fixed: no open mood and the death older than a season); `graben_wasser` -> Ausbau (fixed:
  the death older than a season, no state can prove more); `belagerung` while the fort stood on R0 (READY_CHANGE
  history; unknown = R0) -> Volk (fixed: R1 now). A locked track cannot rise above its level at the death (Ausbau:
  the phase then, from PHASE events; Wohl: I; Volk and Versorgung: their level now). Old age never locks.
- **Acute floor**: SIEGE/BREACH mode, a lockdown, a citizen dying of thirst (`brief.thirst_items`), PATIENT_DYING in
  the last 3 days, an open perimeter in PEACE: NAECHST shows the duty and its command, never a build.
- **Blocked** only with tool evidence: a PROJECT_BLOCKED `breach:*` of a track's template in the last season; `bp
  sites <tpl>` with 0 ranked sites in the last 6 real hours (now logged to cli.log by `bp sites`);
  `stock.mroute == "no stone"` (Wehr III traps); `stock.metal == "explore"` with ore 0 (Ruestung III). The track is
  skipped for NAECHST and listed as BLOCKIERT with the evidence and "-> FR".
- **NAECHST**: the acute duty; else the first locked track's fix; else the weakest track (lowest effective level, ties
  Wehr, Versorgung, Ruestung, Wohl, Ausbau, Volk) not blocked and below III, with ONE command (allowed: plan content,
  `bp.place` templates, `trade.want`, `bp.resume`, `dfllm audit`; never drill, sortie, caverns or aquifer work).
- **Records**: `<save>/leiter.json` (tool file, kind `leiter`, CONTRACTS 9.21) holds the fort's best sum and per-track
  best, the one-year hold clocks (drink 170 / stress < 10: reset by a sample below, by a STOCK_LOW drink event and by a
  gap of more than a season between samples) and the session start. The run record is the best of the sibling save
  folders with the same run key (`r16b7-x` -> `r16b`); a new fort inherits nothing and shows `Vorfort X fiel auf N`.
- **Brief**: the three lines as their own section right after the head block (before `## plan`): the head keeps its
  trim order (BUG-159/J3 tests), the ladder is trimmed only after every later section. **Status**: the LEITER line
  last, rank 4 (a siege status keeps its defense lines first). Missing data never becomes the NAECHST target (it
  counts as "waiting"). Gear in stock that the soldiers do not wear (`mil.free`) is evidence, not a trade want:

      LEITER 7/18 (Rekord 8 y453) | schwaechste: Wehr I | VERLOREN Ruestung II
      NAECHST Wehr II: fehlt no_inner,no_outer -> dfllm plan propose (fortcore vorn)
      OFFEN Ruestung II: 4/6 voll -> dfllm cmd trade.want '{"add":["armor"]}' | GESPERRT Volk II (braucht Wehr II)

- The fair-play hook (lint.trust_violation) refuses a shell write to `leiter.json` / `wertung.json` (`>`, cp, mv, rm,
  tee, sed -i, Set-Content, json.dump, ...); the file tools were already refused under dfllm-runtime/.
- `dfpilot leiter --start` stores the session start (tick, event n, levels); `dfpilot leiter --sitzung` prints
  `SITZUNG y478->y481: Leiter 7->9 | Wehr I->II, Ruestung 4/6->6/6 | Tote 1 (Alter)` and a `blockiert:` line.
  Without a start it says so and exits 1.

## Config switches (config/wertung.json; `python -m dfpilot.lint --config` checks it)

`wertung.on` (true: `wertung` works), `wertung.series` (true: pop samples go to wertung.json), `leiter.on` (true:
`leiter` works), `leiter.brief` (true: the brief lines and the status line), `leiter.records` (true: leiter.json is
written), `leiter.locks` (true: per-cause locks), `leiter.gates` (true), `leiter.ruestung_metal_pct` (50),
`leiter.blocked_hours` (6).

## Deliberately not done

- `plan propose` does not put the weakest track's build first and does not raise phase_target (later round).
- No kernel change: no season snapshot from Lua, no cleaner death causes (BUG-379), no metal per soldier, no depth.
- No total score, no league, no death multiplier (EHRGEIZ 2: it makes waiting the best strategy).
- Stages IV-V, nobles, adamantine, megaprojects.
- No death ledger: if the kernel ever rotates events.jsonl twice, older deaths are gone (every Run 15/16 fort still has
  its full log in events.1.jsonl + events.jsonl).
- PLAYBOOK / playloop text (Leitung).

## Retrospective result (docs/v2/WERTUNG-rueckblick.md, 29 fort folders of Run 15/16)

2424 citizen deaths in about 41,000 dwarf-years (5.9 per 100). Ranking: Belagerung 48 %, Durst/Hunger 16 %, Stimmung
15 %, Geist/Berserker 7 %, Patient 6 %, the rest under 3 % each. Moods kill far more than the review's keyword estimate
(about 4 %): most mood deaths are insane dwarves after a failed mood dying of thirst. Data gaps: the pop curve of
Basementflew, Whirledrampart, Trumpetrealms and Pagedsculpture rests partly on STAND.md lines (perf rotated away).

## Live-Erwartung

1. `dfpilot brief` of every running fort shows three consecutive lines starting `LEITER `, `NAECHST ` and
   `OFFEN`/`GESPERRT`/`BLOCKIERT` after the head block; `dfpilot status` ends with the `LEITER` line in PEACE.
2. In SIEGE/BREACH or with a citizen dying of thirst the NAECHST line starts `NAECHST Pflicht:` and names no build.
3. After a dehydration death while drink or food is below 60 d the LEITER output shows `GESPERRT Versorgung` until
   both stand at 60 d again.
4. `dfpilot wertung` in a running fort prints one WERTUNG line whose death count equals the distinct citizen DEATH
   units of `dfpilot events --type DEATH --limit 0`.
5. `dfpilot leiter --start` at the session start and `--sitzung` at its end print a SITZUNG line whose deaths equal the
   DEATH events of that span.
