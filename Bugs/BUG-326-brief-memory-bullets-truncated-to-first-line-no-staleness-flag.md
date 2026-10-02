# BUG-326: `brief`: memory bullets are cut at the first colon / `->` / sentence end, so `label: content` lines become label-only (`- 2. Hauptthread…`, `- 3. Wache aktivieren…`, `- Bestand…`); stale memory from an older game date is shown without a warning

- **Status:** open
- **Severity:** S3
- **Area:** `df_llm_helper/memory.py:shorten`, `extract_for_brief`, `brief.py`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-326/cfg.yaml tmp_bug/cfg.yaml && mkdir tmp_bug/scopes tmp_bug/tools
cp fixtures/run5/scopes_sample/militaer.md fixtures/run5/scopes_sample/inbox-orchestrator.md tmp_bug/scopes/
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 brief militaer
```

## Expected
Each `Open`/`Insights`/`Last state` bullet carries its content (up to the 160 characters the brief allows); the text before a colon is not mistaken for the whole statement; the briefing says how old the memory is when its game date is far behind the current one.

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 brief militaer
# Briefing militaer
## Mission
Squads, barracks, training (constant), uniforms, equipment. ~10 % soldiers, quality over quantity (the player, 01.10.).
## Situation Y102 Hematite 12
Soldiers 6 (target ~10 % of pop); Pop 24 (target Gate 60: guard in metal)
## Open (memory)
- 1. Waffen-/Rüstungsfertigung (material/Schmiede): Spitzhacken zuerst, dann 3 Sätze; festen Schmied bestimmen.
- 2. Quote nachführen…
- 3. Skill-Verlauf alle ~30 Min in `tools/out/mil-skills.log` messen; Sparring/Waffenübung läuft über die TRAIN-Order der Routine.
- 4. Gate Pop 60 unverändert: Torhaus A + 11 Steinfallen stehen (bau), P1/P2 möbelfrei, Zugang B im Bau.
## Last state
- (Essen/Trinken/Schlaf der Soldaten)
- Routine 2 hat sleep_mode 0 und keinen Stationsbefehl…
## Insights
- 1. Automatisch (watchdog 60 Ticks + mil guard)…
- 2. Hauptthread…
- 3. Wache aktivieren…
- 4. Klasse A (Bestie/Megabestie) zu Fuß am Tor…
- 5. Entwarnung…
## Known traps (python -m df_llm_helper kb get <id>)
- [belagerung_pop] Sieges from population 80: Guard in full metal armor on duty, barracks assigned before pop 60; alarm rehearsal. ~10 % soldiers, quality over quantity (the player, 01.10.).
- [e18_pick] E18: miners do not pick up pickaxes: Militia squad 'Miners' (leader…
- [makler_squad] Broker loses the trade job (squad/labors): Broker without a squad (claude/handel prep picks one), restore labors only after the trade (release).
- [manager_buero] Manager does not validate orders: Assign an office zone with chair+table (Run 5: zone 1613), separate the offices, claude/aemter repair. Runbook rb18.
## Commands
- claude/mil status|report|equip|tabelle; claude/mil add|remove|uniform|barracks ... --apply; claude/mil workmode <squad> on|off --apply
## Fair Play
Fair play: player actions only (dig/build/zones/stockpiles/orders/squads/offices/trade, quickfort own grids). Forbidden: createitem, dig-now, build-now, reveal, prospect all, direct unit/item edits. Exceptions only with the player's yes.
## Report
Report <= 10 lines: 1) KPIs before->after 2) done (command -> effect) 3) blocked/needs 4) messages to scopes (python -m df_llm_helper bus post) 5) next pass. Update the memory.
[exit 0]

$ sed -n '/## Alarmprozedur/,+8p' tmp_bug/scopes/militaer.md   # the real content behind "Insights" 1-5
## Alarmprozedur Run 5 (Hauptthread bei Gefahr)
1. Automatisch (watchdog 60 Ticks + mil guard): `gefahr.handle` -> Pause, alert.flag/siege.flag/pause.hold, civ_alert_idx=1, `schau say`; Zeitlupe fps 50 bei Bodenfeind <= 90 Kacheln.
2. Hauptthread: fps <= 50 oder Schrittbetrieb (`claude/advance N`); `claude/mil enemies`, `claude/mil status` (ALLE Bürger+Soldaten prüfen, nicht nur den Feind), Flags danach löschen.
3. Wache aktivieren: `claude/mil train 33 2 --apply` (Constant training = Uniform an, geht zur Kaserne); Kill-Befehl nur per `tools/killorder.lua` (danach entfernen, `sq.orders` prüfen).
4. Klasse A (Bestie/Megabestie) zu Fuß am Tor: alle Zivilisten in den Kern, Miner/Stollen heraufrufen, **P1 (101,99,z130) und P2 (100,94,z132) von innen bauen** (Konstruktionswand, Boulder >= 2 im Ker
5. Entwarnung: watchdog nimmt civ_alert nach 5 ruhigen Prüfungen (300 Ticks) zurück; Trupp zurück `mil train 33 0 --apply`, Befehle `mil release` (experimental) bzw. killorder --release.

## Offen / nächster Durchlauf
1. Prüfen, ob Kosoth+Kib die Streitäxte tragen (`claude/mil equip --squad 33`, `tabelle`); Wache bei Pop >= 15 aufstocken (nicht Miner/Mason/Brauer/Planter).
[exit 0]
```

Live observation (real memory of the running fort, game date Y118 Granite 27): `brief essen` shows `Last state: (Durchlauf 6 (J102 Opal 7, Pop 36))` and `brief bau` `Last state: - Bestand…` / `- Von mir designiert (z130)…`, `Inbox: - von essen, 01.10. J107: NAHRUNGS-NOTFALL…` while the fort is 16 game years later; nothing tells the agent that these notes are old. (`brief` outputs of all 12 scopes, 600-1165 tokens each, are within the 1500 token budget.)

## Evidence
`Bugs/evidence/BUG-326/`.

## Analysis (reporter's hypothesis)
`memory.py:67-77` `shorten()` keeps only the "first statement" of a line longer than the width: it splits at `[.;!?]`, ` -> ` **and at a colon followed by a space** (`(?<=\D):\s`). Memory bullets are almost always `N. Label: long explanation`, so the cut falls right after the label: `2. Hauptthread: fps <= 50 oder Schrittbetrieb ...` becomes `2. Hauptthread…` (see the memory excerpt above). 5 of the 11 bullets in the sample brief are label-only. `brief.py:97-101` calls `shorten(x, 160)`. There is no comparison of the memory's date marker (`J102 Opal 7`) with `snap.date`.

## Suggested fix (optional)
In `shorten()` do not split at a colon when the part before it is shorter than ~40 characters (cut at the sentence end or at the width instead); print `(memory last updated J102 Opal 7, 16 years ago)` when the dates differ.

## Info needed
Question for the cloud session: is the colon cut intentional to save tokens (the budget use is only 40-80 %, see BUG-329 table)?
