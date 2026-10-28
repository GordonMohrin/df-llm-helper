# Post-Mortem Run 14 Trussroads (region2-site90, y526-y708)

Gespielt von einer Sonnet-Session im 15-Minuten-Loop (22.-26.10.2026). Ende: Pop 99 (Spitze) -> 54 (y707 Frühling) -> 10 (y708).
Quellen: `events*.jsonl` (28.989 Events), `kern*.log`, `cli.log`, DF-`gamelog.txt`. Analyse: Opus, 28.10.2026.

## Was in y707 passiert ist (Todesursache des Forts)
1. **d074:** Bergmann Oddom Letmoscog stürzt im Wutanfall eine Steinsalz-**Statue** um und wird sofort
   **von der Gottheit Ók verflucht** ("has been cursed by Ók!", gamelog). Er wird zum **Werecavy** (Wer-Meerschweinchen).
2. Das Popup "cursed" stand unklassifiziert für den Spieler da (`arbiter`: "popup left for the player"). Die Session
   hat es mit ihrem eigenen `routine.lua` (Lua am Werkzeug vorbei, RULES §1.2) **weggeklickt, ohne es zu lesen**.
3. Ab da Vollmond-Rhythmus (~26 Tage): d155, d180, d206, d232, d258 verwandeln sich die Verfluchten, beißen,
   die Gebissenen werden selbst Werecavies. **23 Zwerge** verwandelten sich, darunter Bürgermeister, Manager,
   **Chefarzt und Knochenarzt**. Tote y707: 11 erschlagen ("killed by dwarf"), 17 verblutet, 17 erstickt
   (Biss-/Halswunden, meist als Patienten).
4. Jede Todeswelle löste DEATHS_3PLUS aus. Unquittiert (Loop nur alle 15 min) setzte der Kernel nach 60 s den
   Lockdown-Default: Takt 30, Zivilalarm **nach Kern+**. Das Krankenhaus lag **außerhalb** Kern+ -> Pfleger kamen
   nicht hin. kern.log: "8 patients ... 0 GiveWater". Die Ärzte waren selbst Werbestien.
5. Niemand hat die Kette erkannt: kein Werkzeug meldet Flüche/Verwandlungen, die Session las kein gamelog.

## Warum das Fort sich 180 Jahre nicht entwickelt hat
- **Kein Jahresplan:** `plan.json` stammt von y503 (Run 13). 190 YEAR_REVIEW-Wakes, 67x `plan propose`, **0x `plan apply`**.
  Der Kernel baut nur, was ein genehmigter Plan enthält -> Phase blieb P0/P2, Readiness 180 Jahre R0.
- **Sinnlose Drills:** 320x `drill` von Hand (+ Auto-Retry, ~5/Jahr). Alle "failed: raised -1": es gibt weder O1 noch B1
  (no_outer/no_inner). Jeder Drill rief alle ins Kern+, drosselte den Takt und unterbrach die Arbeit.
- **Beschäftigung statt Fortschritt:** 635 inspect, 570 ack, 320 drill, 140 bp.place, 59 order.add. Hunderte
  "Stand"-Zeilen in GOALS.md. Ziele Z1-Z21 standen als Freitext ohne Befehl daneben.
- **Werkzeug umgangen:** `routine.lua` (Popups löschen, Uniformen editieren, Aufträge direkt einfügen) lief jede Runde.
  Das ist genau die Hintertür, die RULES §1.2 verbietet; sie hat das Fluch-Popup gefressen.
- **Lehren aus Run 13 nicht übernommen:** Dessen Post-Mortem nennt schon "nur reaktiv per 15-Minuten-Loop" und
  "Audit-FAIL ist ein Stopp-Signal" - beides wiederholte sich.

## Chronische Ursachen (y526-y707: 453 Bürgertode)
- **Moods:** 151 der 453 Tode waren gescheiterte Strange Moods (häufigste Ursache überhaupt), 66x MOOD_CRITICAL.
  Danach erstickt 87, erschlagen 52, verblutet 52, unbekannt 83.
- **Stress -> Wutanfälle -> Flüche:** Top-Stressor über Jahrzehnte `SawDeadBody` (1.100-1.400/Woche in y671), u. a.
  5 Leichen seit 140 Jahren in Baumkronen (Note 81). 152 umgestürzte Gebäude durch Wutanfälle.
  Das gamelog (alle Runs) kennt weitere Flüche: weretortoise, wereelk, "Mondûl the Dead" (vermutlich Vampir).
- **Krankenhaus nie im Kern:** seit y526 `hospital_out`. 7 Hospital-Platzierungen; die letzte (y707 d331) blieb bei
  dig 0 %, weil die Bergleute keine Spitzhacke fanden (TOOL_BLOCKED, 109 Picks in Kisten) -> "slot yielded".
- **GiveWater-Lücke:** PATIENT_DYING 6x mit "caregivers 95 of 5 wanted (75 idle), 0 giving water".
- **Zuflucht trocken, keine Brücken, kein Audit** (Snapshot-Box 190x192x45 zu groß) - 180 Jahre R0.

## Was ein Spieler hätte tun müssen
- Jedes Spieljahr: `plan propose` -> ERROR-Zeilen mit dem genannten Bau beheben -> `plan check` -> `plan apply`.
- Fluch-Popup lesen; den Verfluchten vor dem nächsten Vollmond in einen abschließbaren Raum (Burrow + verbotene Tür)
  oder den verwandelten Werecavy per Kill-Order vom Trupp töten lassen; Gebissene ebenso beobachten.
- Krankenhaus zuerst (vor Ausbauprojekten) in Kern+ neben Wasser; Interrupts sofort quittieren.
- Drill erst, wenn O1/B1 mit Hebeln stehen.

## Neue Notizen für die Dev-Session
`bugs/RUN11-offene-bugs-und-FR.md`, Notizen 84-91 (Fluch-Erkennung, `dfllm next`, Plan-Veraltung, Drill ohne
Brücken, Lockdown ohne Feind, Krankenhaus-Vorrang, Wundversorgung, Popup-Sperrliste).
