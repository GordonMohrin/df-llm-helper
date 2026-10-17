# Post-Mortem Run 11 (Kilrudrabed "Bronzefreckles", region2-site98) - Siege 8, y441 Frühling d23

Stand beim Schreiben: Pop 52 -> 10 innerhalb von ca. 3 Spieltagen, 4 Soldaten, 4 Goblins + 1 Jabberer im Kern+, 2 Cave Dragons. Siege 8 = Invasion 12 (ARRIVAL siege, Snatcher, Ambush).

## Verlauf Run 11 (y431-y441)
- y431: Start per Quick-start. Idle 46-80 % wegen Steinmangel (1 Boulder), nur 2 Picken, kein Eisen.
- y432 Frühling-Winter: Fishery fehlt -> food 5 d bei 883 rohen Fischen; selbst per quickfort `wh` gebaut (food 5 -> 174 d).
- y433 Sommer: Siege 3 (2 Cave Dragons + Hammer-Lord): 25 Tote (54 -> 29). Ursachen: Tür (128,121,143) seit y432 offen (Tür `d` unsuitable ohne Wandnachbar), B2 durch Station blockiert (BUG-032), O1-Hebel no_worker, leere Squads.
- y434-y438: Dev-Fixes (c75b7c0, e3a62ab, 6dd9f2d, fcada16, e289065, cc63d33, 9089d54, 2f6ab27) -> Siege 4-7 mit 7 / 3 / 3 / 0 Verlusten.
- y439 Frühling: 9 Patienten verdurstet (Hospital ohne Wasser, Plan enthielt hospital); Dauer-ALERT 120 d wegen ELK_BIRD (cc63d33).
- y441 Frühling d23: Siege 8, Pop 52 -> 10.

## Ursachen Siege 8 (vorläufig)
1. Lücke (114,73,143) ohne Tür; mein Seal-Projekt (c1a147c261, platziert 2 Tage vor dem Angriff) war nicht fertig.
2. O1 zerstört (Cave Dragons reißen die Brücke jedes Mal ab), 2 Dragons im Kern.
3. 16 Bürger bei Ankunft außerhalb von Kern+ (7 draußen beim Breach), Tiefe+ ohne Trinkwasser, Refuge-Wechsel Tiefe+/Kern+ im Kampf.
4. Soldaten: nur 10, `worn 58 %`, kein Eisen/Metallrüstung (bars 0 seit Beginn).
5. Seal-Arbeit lief zu langsam: Seal wurde erst im Jahr nach der Entdeckung vorbereitet (audit FAIL 113 t), Planungen und Stau (BUG-033) kosteten Monate.

## Lehren
- Kein Metall = keine Verteidigung; Eisensuche (Explore) darf nie wegen Snapshot-Stau ausfallen.
- Offene Zugänge müssen in PEACE sofort zu sein (nicht bis zur nächsten Saison); Seal vor allem anderen und nach jedem Bau Audit.
- Hospital nur mit Brunnen; HOSPITAL_DRY mit Patienten = sofort Zonen löschen (jetzt im Kernel, 2f6ab27).
- Dauer-ALERT durch ferne Tiere (jetzt behoben, cc63d33).
- O1 gegen Cave Dragons sinnlos (Gebäudezerstörer), Wand + Türeingang oder zweites Tor.
