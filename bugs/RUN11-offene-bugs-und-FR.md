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
