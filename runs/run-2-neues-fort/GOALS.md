# Run 2: Ziele und Messung

Messung jede Saison (Frühling/Sommer/Herbst/Winter) mit
`python -m df_llm_helper status`, `python tools/goals.py --json` und `python -m df_llm_helper cmd inspect what=census`;
Ergebnis als eine Zeile in `JOURNAL.md`. Ein Ziel gilt nur als erreicht, wenn die Messung es zeigt (Bauten: Stufe 3/3
UND in Betrieb, z. B. Kochauftrag hat Mahlzeiten erzeugt).

## Stufenleiter (nächste Stufe erst, wenn die vorige grün ist)
| Stufe | Zeit (Spieljahr) | Ziel | Messgröße (Schwelle) | Messquelle |
|---|---|---|---|---|
| 0 Start | Tag 0 | Embark, Adopt, Selbsttest | `selftest full` 0 fail, Plan angewandt | dfllm selftest/status |
| 1 Überleben | Jahr 1 Frühling-Herbst | Wasser, Essen, Trinken sichern | Brunnen/Wasser JA; Drink >= 30 Tage; Food >= 30 Tage (erreichbar); Küche + Destille Stufe 3/3 | status, census, bp list |
| 2 Ordnung | Jahr 1 Winter | Tote bestatten | lose Leichen <= 5; Geister = 0; Gräber frei >= Bewohner/4 | goals.py (burial, ghosts) |
| 3 Industrie | Jahr 2 | Stein, Holz, Metall im Fluss | Holz >= 60; Boulder frei >= 20; Eisen/Bronze-Barren >= 10; Leerlauf <= 30 % | census, status |
| 4 Verteidigung | Jahr 2-3 | Eingang, Fallen, Soldaten | Fallen >= 20; 1 Trupp >= 8 ausgerüstet; Audit pass; Brücke/Hebel linked | status (traps, audit, mil) |
| 5 Wachstum | ab Jahr 3 | Pop wachsen lassen | Pop 30 -> 50; Stress < 60 %; kein Zwerg > 50000 Stress | status, goals.py |

## Frühwarnschwellen (jede Saison prüfen; Überschreitung = sofort handeln)
- Food- oder Drink-Tage < 10 · lose Leichen > 20 · Geister > 5 · Bau auf Stufe 0 seit > 30 Tagen · Auftrag ohne Werkstatt
  · Leerlauf > 40 % · Stress > 70 % · Pop-Rückgang > 10 % in einer Saison.

## Wie ich das Fort voranbringe (Regelkreis)
1. Saisonbeginn: messen, Zeile ins Journal, Schwellen prüfen.
2. Niedrigste unerfüllte Stufe bestimmen; nur dafür Aufträge/Bauten über `plan propose/check/apply` und `dfllm cmd bp.place`.
3. Bau nie als erledigt melden, bevor Stufe 3/3 gemessen ist; hängt er > 30 Tage, Ursache klären (Job-Diagnose = FR-05)
   statt abzuwarten.
4. Fehlendes Werkzeug -> Eintrag in `docs/feature-requests/README.md`, nicht im laufenden Spiel basteln (RULES §1.7).
5. Nach Meilenstein Ziele neu priorisieren, Memory-Zeile `project_ziele_aktuell.md` anpassen.

## Kurz-/Langfristziele
Kurz: (1) Embark durch Gordon, Adopt, Jahresplan · (2) Stufe 1 + 2 grün · (3) Frühwarnung aktiv.
Lang: Stufe 5 mit Pop 50+, Fort 5+ Jahre ohne Hungersnot · Feature-Requests FR-01/02/04/05 umgesetzt · Post-Mortem je Fall.
