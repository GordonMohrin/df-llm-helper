# NEU1 P2 Live-Rückmeldung (Neuausrichtung 1, E9)

## Alte Entscheidung
"fixed" hieß: ein Offline-Test gegen die eigene Attrappe ist grün. `bugs/README.md` trug für rund 730 von 782 Bugs
"fixed (offline, live-untested)"; ob ein Fix im Spiel wirkt, stand nur verstreut in den Spieler-Logs
(`runs/run-*/STAND.md`, `FR-BUGS.md`) und wurde nie zurückgetragen.

## Neues Verhalten
- `tools/live_status.py` liest die Spieler-Logs (Run 15/16 STAND.md und FR-BUGS.md), die Live-Berichte in
  `docs/v2/STATUS.md` und `docs/v2/POSTMORTEM-*.md` sowie die `Status:`-Zeile der Bugdateien ("confirmed live").
  Je Nennung `BUG-NNN` (auch `BUG-300..302`, `BUG-328/329`) wertet es nur den Satzteil NACH der Nennung bis zur
  nächsten Nennung oder zum Satzende:
  - widerlegt: `wirkt (hier) nicht`, `FAIL`, `greift/griff nicht`, `nur halb`, `Fehlalarm`, `ins Leere`, `NICHT`,
    `wieder weg`, `nicht rechtzeitig`, `hat bisher nichts`, `kein sichtbarer Effekt`, `did not work/help`;
  - bestätigt: `wirkt`, `WIRKT`, `OK`/`ok`, `funktioniert`, `klappt`, `behoben`, `confirmed`, `works`;
  - unsicher (ändert den Status nicht, eigene Liste): `scheint`, `nicht prüfbar/auslösbar/beobachtet`, `ungesehen`,
    `ungeprüft`, `not confirmed`, `wird beobachtet`, `wirkt nur`, und jede Nennung ohne Urteilswort.
  Fail closed: ohne klares Urteilswort bleibt ein Bug "offen, nie live gesehen".
- Eine Frage im Satzteil ("greift nicht?") ist kein Urteil.
- Status je Bug (neue Spalte `Live` in `bugs/README.md` nach `Status`, die Wahrheit über die Wirkung):
  `live bestätigt` (nur positive Belege), `live widerlegt` (nur negative), `live gemischt` (beides: wirkte einmal,
  versagte oder kam wieder), `offen, nie live gesehen` (kein Beleg).
- Bugdateien: eine `Found:`-Zeile einer Live-Nachprüfung ("live test round 2 (BUG-130 PARTIAL ...)", "retest of
  BUG-170", "BUG-131b") zählt als `widerlegt` für die nachgeprüfte Nummer (die Nachprüfung fand einen Folgefehler,
  der neue Bug steht als Beleg dabei); "side note" bleibt unsicher.
- Kuratierte Schicht in `config/process.json` `live_status.drop` (eine automatische Fundstelle wird unsicher,
  `datei:zeile:BUG-NNN: Grund`, z. B. "BUG-313..315 für FarmPlot-Jobs FAIL" trifft 314/315 nicht) und
  `live_status.add` (ein Beleg, den ein Satz ohne Urteilswort gibt, mit Datei, Zeile, Urteil, Grund; das Zitat liest
  das Skript selbst aus der Datei). Stand dieser Runde: 14 `drop`, 10 `add` (STATUS-Retests 15.10. in den Bugdateien
  011-014, 041; 274, 399, 532, 570, 602).
- `docs/v2/LIVE-STATUS.md`: Zählung, je Bug die Belegzitate (Datei:Zeile), unsichere Fundstellen getrennt.
- Prozess (`docs/v2/PROCESS.md`): "fixed" verlangt eine Live-Erwartung; die Spalte `Live` ist die Wahrheit.
- `dfpilot/lint.py` `bug_files()`: Bugdateien ab BUG-783 brauchen einen Abschnitt `Live-Erwartung`
  (Regel `live_expectation`); läuft im Standardlauf `python -m dfpilot lint` und einzeln mit `--bugs`.

## Schalter (`config/process.json`, Standard an)
- `live_status.on` (true): das Skript schreibt; aus = nur Bericht auf stdout, README unverändert.
- `live_status.ranges` (true): `BUG-300..302` / `BUG-328/329` zählen für jede Nummer.
- `live_status.status_line` (true): "confirmed live" in der `Status:`-Zeile einer Bugdatei zählt (nicht "the cause
  live confirmed ... live-untested").
- `live_status.found_line` (true): die `Found:`-Zeile einer Live-Nachprüfung zählt (siehe oben).
- `live_status.window` (120): höchstens so viele Zeichen nach einer Nennung werden gewertet.
- `lint.live_expectation` (true), `lint.live_expectation_from` (783).

## Bewusst nicht gemacht
- Keine Symptom-Suche ohne Bugnummer (zu viele Fehltreffer; nur über `add` von Hand mit Beleg).
- Keine Wertung von `events.jsonl`/`kern.log` (keine Live-Erwartungen maschinenlesbar in alten Bugdateien).
- Der alte Text der Spalte `Status` bleibt (Commit-Historie); "fixed" darin heißt weiter nur "offline grün".
- Kein "nicht wieder aufgetreten": Abwesenheit eines Symptoms ist ohne prüfbare Erwartung kein Beleg.

## Live-Erwartung
1. Nach der nächsten Spielrunde: `python tools/live_status.py --write` ändert mindestens eine `Live`-Zelle eines in
   der Runde genannten Bugs; `docs/v2/LIVE-STATUS.md` zitiert die neue STAND/FR-BUGS-Zeile mit Datei:Zeile.
2. Ein Spieler-Satz "BUG-NNN wirkt nicht" macht den Bug `live widerlegt` oder `live gemischt`, nie `bestätigt`.
3. Neue Bugdateien ab BUG-783 ohne `Live-Erwartung` lassen `python -m dfpilot lint` mit `live_expectation` scheitern.
4. Die Zahl "Bugs mit Live-Urteil" in LIVE-STATUS.md steigt von Runde zu Runde; "live widerlegt/gemischt" wird zur
   Arbeitsliste der Fixrunde (zwei oberste Todesklassen zuerst).

## Ergebnis dieser Runde (23.11.2026)
62 von 748 Bugs tragen ein Live-Urteil: 34 bestätigt, 25 widerlegt, 3 gemischt (399, 523, 562); 686 offen, 67 weitere
Nennungen ohne klares Urteil stehen getrennt in `docs/v2/LIVE-STATUS.md`. Herkunft: 33 Bugs aus den Spieler-Logs
Run 15/16, 23 aus den Live-Nachprüfungen vom Oktober (Bugdateien), 7 aus docs/v2 (STATUS, POSTMORTEM). Ohne die
Oktober-Nachprüfungen wären es rund 40: die Spieler-Logs nennen 88 Bugnummern (Bereiche mitgezählt), davon 33
mit Urteil. Wirkt nicht (widerlegt + gemischt): 28, also fast jeder zweite live beurteilte Fix.
