# Fix-Prozess (Neuausrichtung 1, Entscheidung E9)

Kurz und verbindlich für jede Fixrunde. Entwurf und Begründung: `docs/v2/NEU1-rueckmeldung.md`.

1. **Kein "fixed" ohne Live-Erwartung.** Jede Bugdatei ab BUG-783 hat einen Abschnitt `## Live-Erwartung` mit 2-5
   prüfbaren Sätzen: was in `events.jsonl`, `kern.log`, `status`/`brief` oder den Spieler-Logs binnen N Spieltagen zu
   sehen ist, wenn der Fix wirkt (und was, wenn nicht). `python -m dfpilot lint` meldet eine fehlende Erwartung
   (`live_expectation`, Schalter `config/process.json` `lint.live_expectation`, ab `lint.live_expectation_from`).
2. **Die Spalte `Live` in `bugs/README.md` ist die Wahrheit.** `Status` sagt nur, was offline grün ist.
   Werte: `live bestaetigt`, `live widerlegt` (mindestens teilweise: ein Spieler-Satz "wirkt nicht", "FAIL", oder eine
   Live-Nachprüfung fand einen Folgefehler), `live gemischt` (beides), `offen, nie live gesehen`.
3. **Rücktragen nach jeder Spielrunde:** `python tools/live_status.py --write` liest die Spieler-Logs
   (`runs/run-15*/run-16*` STAND.md, FR-BUGS.md; weitere Runs in `config/process.json` `live_status.logs`) und schreibt
   die Spalte und `docs/v2/LIVE-STATUS.md` (Belege mit Datei:Zeile, unsichere Fundstellen getrennt). Die Cells nie von
   Hand ändern; Kuratierung nur über `live_status.drop` / `live_status.add` mit Datei, Zeile und Grund.
4. **Spieler schreiben die Bugnummer** in STAND.md/FR-BUGS.md mit einem klaren Urteil im selben Satz, z. B.
   "BUG-543 wirkt: ...", "BUG-523 wirkt hier NICHT", "BUG-297: FAIL". Ohne Nummer oder ohne Urteil zählt der Satz nicht.
5. **Arbeitsliste:** `live widerlegt` und `live gemischt` gehen vor neue Bugs; kehrt ein Symptom nach zwei Fixes wieder,
   wird es eine Designfrage statt eines dritten Fixes. Pro Runde nur die zwei obersten Todesklassen.
6. **Nach einem Merge** mit neuen Tabellenzeilen (5 Zellen): `python tools/live_status.py --write` ergänzt die Spalte;
   `tests/test_integration_docs.py` prüft 6 Zellen und einen bekannten Live-Wert.
