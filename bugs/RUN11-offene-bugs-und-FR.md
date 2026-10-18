# Run 11 – offene Bugs und Feature-Requests (Sammeldatei, noch ohne BUG-/FR-Nummern)

Hinweis: vom Spieler (Claude Code, 'claude spielt df') gesammelt; Nummern vergibt die Entwicklungssession beim Bulk-Übergang.

Regel (Gordon 17.10.2026): neue FR/Bugs nur hier aufschreiben, die Dev-Session NICHT einzeln anpingen; Übergabe gesammelt später.

## Offen (noch nicht gemeldet)
1. **Frame-Freezes im Spiel**: PERF_DEGRADED freeze 24-27 s regelmäßig beim Jahreswechsel/Save (y456, y483); Doctor y483: max frame gap 172094 ms, 13 Lücken > 3 s. DF 'Responding=False' bis 4 min. Quicksave dauert 54-110 s.
2. **drill wird abgelehnt**, solange Händler auf der Karte stehen ('merchants on the map') – Händler bleiben oft Wochen; Training fällt aus. Wunsch: Drill nur bei Gefahr sperren, nicht bei Händlern.
3. **Kernel legt immer wieder farms-Projekte an** (c1a148a867…, c1a14902f6…, c1a149545f…, c1a149b116…, c1a149e6ec…): alle 'build_lost, parked' (kein Boden/Soil). Sollte nach 1x build_lost nicht mehr neu angefordert werden.
4. **status ohne pop/stock-Zeilen** direkt nach Jahreswechsel/Hänger (nur clock-Zeile).
5. **plan check 'explore: only 0 free site(s)'** auch wenn es viele freie Orte gibt, weil abgebrochene/geparkte Projekte Sites belegen (taken c1a145ce63f0770a02); explore depth 12 wird immer abgelehnt (Kavernen z127/131), depth 6-8 geht.
6. **GatherPlants 250-450 unclaimed seit Jahren** (Kräuter-Designation); Wunsch: Designationen nach X Tagen ohne Bearbeitung entfernen.
7. **Idle-Anzeige 'N of M adults without a job (0 without reachable work)'** widersprüchlich: 40-70 % untätig trotz erreichbarer Arbeit; Ursachen oft Ruhephase (Rest/Verletzte) oder Kernel-Pausen (seal first). Eine Aufschlüsselung (Rest, Verletzt, Schlaf, pausiert) wäre hilfreich.
8. **Seal 'nothing to close' blockiert plan.check**, obwohl seal at=refuge schon fertig ist: plan check ERROR 'seal: nothing to close' bei Refuge-Luke, die schon steht (meine yearly.py fängt es ab).
9. **Fischerei wird zerstört** (Belagerungen in der Werkstatthalle) und nicht automatisch ersetzt (seit BUG-038 sollte es klappen; follow muss neu gestartet werden).
10. **Brauaufträge fehlen**, wenn kein Manager-Büro mit Tisch/Stuhl (BUG-042 behoben); Frage offen, ob DF weitere Möbel (Truhe/Schrank) fürs Büro braucht.
11. **Hospital**: 8 abstract-Orte (HOSPITAL) bleiben nach Zonenlöschung bestehen; kein Aufräumen.
12. **Statuszeile 'stock' fehlt bei Stress**: Stress 52-78 % dauerhaft (Geister, Tode); keine Gegenmaßnahme (Tempel/Taverne?) im Kernel.
13. **Zerstörte Außentore** (O1 14 Mal) – 'bridge_rebuild' DECISION_NEEDED nie beantwortet (Gordons Entscheidung: lassen).

## Schon gemeldet/behoben (zur Übersicht)
BUG-025..043 (Depot, Seal, Station auf Brücke, Recall, Runner-Hänger, Fishery/follow, Getränke, Manager-Büro, Strauch-Seal, bbox-Limit), FR-69 refuge_drink.

## Lehren für Run 12
- follow nach jedem Pull neu starten; Manager braucht Büro mit Stuhl+Tisch; Fischerei früh bauen; Brauaufträge prüfen; Seal-first; Eisen früh suchen (explore depth <= 6).

## Live-Check BUG-043 (dfd426d, y484 Sommer d30) – Dev-Session war nicht erreichbar, hier festgehalten
- `dfllm audit` läuft, 'audit stored, R0'; einziger Fail: 'bridge O1: footprint is not a bridge' (erwartet). audit_old weg. Kein 'audit snapshot not exported' mehr.
- Audit-Datei aud1a14ba261dd94c201.json: 356 KB, 337440 Kacheln (44431 ' '), parts 3, margin [16,16,2], bbox [44,9,132,191,160,146].
- `bp sites refuge_drink --fresh`: 'no site for 12 barrels (5x3) beside the refuge room 110-118,114-120 z136' (mein n=11 bei 118,114,136 steht schon).
- Kein neuer bypass bemerkt.

## Nachtrag y485 (17.10.2026)
14. **Stimmungs-Tode durch Durst/Hunger (wiederkehrend)**: y484 Fey-Stimmung (Einheit 28872, thirst 75000, hunger 76725) und y485 Possessed-Stimmung (28844, thirst 75002, hunger 100339, 'patient') – Zwerge in strange mood essen/trinken nicht und sterben, wenn die Werkstatt-Arbeit nicht zustande kommt (MOOD_RISK meldete nur 'nothing missing; a mood job cannot be cancelled'). Wunsch: Kernel soll Stimmungs-Zwerge mit Durst > 40000 per Trink-Job versorgen oder die Materialsuche beschleunigen; FR: Stimmungs-Zwerg-Überwachung (Hunger/Durst) mit Notversorgung (Getränk neben die Werkstatt legen).
15. **Bevölkerung sinkt in Frieden (50 -> 33 in 2 Jahren)** ohne Belagerung: Stimmungs-Tode, Altersschwund; keine Migranten seit y481. Pop 33, erwachsene Zwerge nur 16 (Rest?) – zu klären, ob 'adults' Kinder zählt. 'Migrants'-Wellen bleiben aus (Fort-Wohlstand/Pop-Cap?).
16. **Seal 115,73,143 (Tür) bleibt offen** trotz seal-Projekt c1a14b92909f3d7801 seit y483 Sommer d69; status zeigt weiter '1 way in without door or bridge: 115,73,143 floor'.

## Nachtrag y487 Herbst (18.10.2026)
17. **Belagerung 13 (y487 Herbst d26-27): 36 Verluste** (Pop 51 -> 21, Soldaten 20 -> 9). SIEGE_END '6 hostiles, 1 killed, 36 lost, sealed 0 ticks' – 'sealed 0 ticks': das Fort wurde nie abgeriegelt (Tür 115,73,143 offen seit y483, audit_fail), O1/B1/B2 verloren ('lost:O1,bridge:B1,levers:B1,bridge:B2,levers:B2' im Status seit Jahren). Die Belagerung lief zwischen zwei 15-Minuten-Durchgängen ab; keine Zeit zum Eingreifen. Wunsch: Der Kernel soll bei offenem Zugang UND fehlenden Brücken/Hebeln früher eskalieren (Seal-Priorität, Brücken wieder bauen, ggf. Gordon-Entscheidung 'bridge_rebuild' automatisch beantworten).
18. **patient_thirst DECISION_NEEDED trotz 'water, buckets and caregivers present'**: 3-5 Patienten mit Durst 30000-40293 (Einheiten 28970, 28642, 28483), 24-27 freie Eimer von 62, nur 4 Pfleger (29009, 29031, 29032, 29035) – die Pfleger sind überfordert; Patienten über der 25000-Schwelle, aber Zonen-Entfernung greift nicht, weil Wasser da ist. Wunsch: mehr Pfleger (Labor GIVE_WATER) bei patient_thirst > 30000 aktivieren.
19. **TOOL_BLOCKED Miners (y487)**: '5 of 6 hold no pick for 1081 days, 16 free picks (16 loose) at 157,57,139'. Die Spitzhacken liegen 'loose' an einem Ort (157,57,139) außerhalb der Gehgruppe/Burrow der Miner. Wunsch: Hauler-Job, der lose Picken zu einem Werkzeug-Lager bringt; oder Kernel erkennt 'off their walk group'.
20. **PERIMETER_BROKEN bridge 113,106,142: 'requeued=0'** nach Belagerung 13 (Brücke wird nicht neu gebaut: 'only in quiet PEACE', aber PEACE seit 35 d).

## Nachtrag y488 (18.10.2026)
21. **Ursache der Dauer-Sperre 115,73,143 (seit y483): DFHack `suspendmanager`** setzt den ConstructBuilding-Job der Seal-Tür auf SUSPENDED ('Blocks another build job'). Ich habe den Job mehrfach per Lua fortgesetzt (job.flags.suspend=false); suspendmanager hat ihn sofort wieder suspendiert; erst nach `disable suspendmanager` + Fortsetzen verschwand der Bauplatz (Gebäude danach 'none'). Wunsch: Kernel soll Seal-Jobs von suspendmanager ausnehmen (`suspendmanager`-Ausnahmeliste/`unsuspend`) oder die Sperre bei SEAL_STUCK mit Ursache 'suspended by suspendmanager' melden. Status zeigte nur 'stalled'.
22. (Korrektur zu 21) Auch mit `disable suspendmanager` blieb der Bau-Job der Tür 115,73,143 nach dem Fortsetzen wieder SUSPENDED (8 Messungen à 10 s). Es ist also nicht nur suspendmanager; der Job wird vom Kernel/DF selbst wieder angehalten (z. B. DF-eigenes 'cannot reach/no material' oder kernel construction 'resuspended'). Zwischendurch war der Bauplatz kurz 'none' (Projekt legt ihn neu an). Ursache offen: Material-Item (ConstructDoor: 110 Aufträge) oder Erreichbarkeit der Kachel prüfen.

## Nachtrag y497 Sommer d29 (18.10.2026)
23. **Belagerung 14 (y497 Sommer d23-29): 24 Verluste** (Pop 49 -> 26; 'on_station=0', also keine Soldaten an der Station). Die beiden offenen Zugänge 113,73,143 und 115,73,143 (Tür-Bau seit y483 ungelöst, siehe 21/22) waren wieder offen; recall '10 of 30 still outside Tiefe+, 10 cannot come'. Das Muster: jede 2.-3. Belagerung kostet 20-36 Bürger, solange diese Zugänge offen sind und kein Metall-Gear existiert (worn 36 %). Die ungelöste Tür ist inzwischen der teuerste Einzelfehler des Runs.

## Nachtrag y497 Herbst d45 (18.10.2026) – Fort fast tot
24. **Pop 49 -> 26 -> 1 in einem Spieljahr**: nach Belagerung 14 (24 Verluste) starben am d31 fünf Patienten gleichzeitig an Durst (28970, 29039, 28627, 29100, 28968: thirst 75000, hunger 80-119k) – trotz 'hospital ok' und 24-27 freien Eimern und 4 Pflegern (siehe 18). Danach weitere Tode; zuletzt 1 Bürger (1 Soldat), 0 Erwachsene mit Arbeit. act.manager_office 'no manager', act.appoint 'not an adult living citizen', BREWER/PRESSING 'no worker' seit 24 Tagen.
25. **DECISION_NEEDED squads: 'appoint a militia commander/captain (nobles screen)'** – der Kernel kann keinen Hauptmann ernennen, ohne Hauptmann keine Squads (S2). Wunsch: act.appoint über die DF-Ernennungsliste (assignments.histfig) bzw. Hinweis, wie der Spieler es per Lua-Ernennung tut.
26. **Run-Fazit Run 11**: y431 bis y497 (66 Spieljahre); Hauptursachen für die dauernden Verluste: (a) offene Zugänge (Tür 115,73,143) durch einen nicht lösbaren Bau-Job, (b) verlorene Brücken/Hebel nie wiederaufgebaut, (c) Hospital-Durst (4+ Patienten gleichzeitig tot) trotz Wasser, (d) kein Metall-Gear (worn 20-50 %).

## Run 12 (Trussroads, Reclaim) – erste Befunde 18.10.2026
27. **DF stürzt nach 'Start tutorial' (Quick start) in der 497-jährigen Welt ab** (2 von 2 Versuchen, ~2 min nach Klick, kein DFHack-Log gesichert); Reclaim funktioniert. Tooling-FR: start_df_desktop1 + embark-Tools um 'Reclaim' erweitern (findclick: 'Skip tutorial' -> 'Okay' -> 'Reclaim/unretire' -> Ruinenname -> 'Reclaim!' -> 'Play now!').
28. **Reclaim-Fort hat alte Brücken/Hebel (X10972, X11814):** Kernel zieht den Hebel 11808 mehrfach in Folge (LEVER pull X11814 up x6 in einer Sekunde) ohne Wirkung; ACT_FAIL act.run failed for baseline: nil.
