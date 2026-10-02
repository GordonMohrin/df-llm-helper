# Scope militaer+verteidigung – Gedächtnis (Run 5, Windrings, Wüste, Weltkachel (26,10))
Erfahrung aus früheren Läufen: `tools/scopes/run4/militaer.md` (enthält Run 3: mil create/add/uniform/barracks/refuge/guard, killorder, Alarmprobe). Hier nur der Run-5-Zustand.
Stand: Durchlauf 1, 01.10.2026 ~09:15–09:40 Echtzeit, J101 Granite 14, Pop 7 (7 Erwachsene), fps 100, nichts pausiert.

## Zustand (gemessen)
| Was | Stand |
|---|---|
| **Zuflucht-Burrow "Zuflucht" (id 0) + Alarm 1 "civ-alert"** | `config.ZUFLUCHT` GESETZT (nicht mehr Platzhalter): F1 {100,92,109,100,z132} + Treppenspalte T1 {99,94,z131..132} + Kern {80,94,127,114,z127..130}; probe (101,101,130), treppe (99,94). `claude/mil refuge` angelegt (39 Blöcke). **Format `x1,y1,x2,y2,z[,z2]` verlangt z <= z2** (bau-Vorschlag "130,127" hätte 0 Kacheln ergeben, Schleife läuft nicht rückwärts). |
| `config.INNEN_BOXEN` | Fort x76..130,y92..118,z101..131 + F1 x99..109,y92..100,z132 (Oberfläche z133 und Dünenrampen z132 außerhalb F1 NICHT innen). Erzstollen y<92 lösen über `nah` (ALERT_RANGE 45) aus. |
| **Alarmprobe 09:15** | civ_alert_idx=1 für ~12 s Echtzeit gehalten: 7/7 im Burrow (alle arbeiteten ohnehin im Kern), Dig/MakeCrafts/ConstructDoor/Mechanisms liefen im Alarm weiter, Såkzul holte Getränke in F1 (z132) und kam zurück = Burrow ist über die Treppenspalte T1 durchgängig (Wege Kern <-> F1 funktionieren unter Beschränkung). Nachher idx=0, alle normal. **Schwäche der Probe:** keiner war draußen; ein trennscharfer Test geht erst, wenn jemand auf z133 ist. |
| `claude/gefahr selftest` / `sim` | selftest ok (kein toter FB in dieser Welt -> `sim`-Teil leer; stattdessen `claude/gefahr sim 3938 x y z` mit Dämon-Id aus `gefahr status`). Ergebnisse (Klasse A): (96,96,133) nah, T1-Kopf (99,94,133) nah, (101,101,130) innen, F1 (104,95,132) innen, (136,96,133) d=40 nah = Alarm+Pause+alert/siege.flag+pause.hold+civ_alert on+schau say; (170,96,133) d=74: kein Alarm, aber `slow=true` (Zeitlupe, SLOWMO_RANGE 90); Kaverne (96,96,93): nur Warnung (Flieger = immer "erreichbar"; Bodenwesen sind laut `canWalkBetween` NICHT mit dem Fort verbunden: Troglodyt 3916, Troll 3915 -> alle false). Echter fps-Wechsel auf 50 nur mit echtem Feind prüfbar (**Annahme**: gleicher Pfad wie Run 3, `watchdog.set_fps`). `refuge ok`, `selbsttest []`, mil guard läuft (Start 08:58, 0 Treffer). |
| **Trupp 32 "Bergleute"** (nicht meiner; erkundung/wirtschaft): Monom 3750, Uzol 3746 (hält Pick 187405), Inod 3745; Uniform nur Spitzhacke, Routine 0. **NICHT erneut `workmode` anwenden.** | |
| **Trupp 33 "Wache"** (angelegt 09:30) | Hauptmann Kosoth 3748 (manager, MELEE_COMBAT 5 = bester Kämpfer), Kib 3747 (Stonecrafter). Vorlage 1 "Melee, metal armor" + Waffe ITEM_WEAPON_AXE_BATTLE (Subtype 1), 70 Specs, "Update equipment" gesetzt -> beide haben 1 Item zugewiesen (Streitaxt), Kosoth holt sie (PickupEquipment). Routine 0 (Off duty), 8 Plätze frei. Rüstung 0/18 (kein Metall). Barracks: temporäre Zone 1387 (Quickfort `mil5_kaserne_temp.csv`, Haupthalle-West x80..87,y100..102,z130) per `mil barracks 33 1387` zugewiesen; **echte Kaserne später z128 x82..97,y94..99 (bau, Etappe 3), dann umhängen und Zone 1387 löschen.** |
| **Fair-Play-Ausnahme (RUN5-START Lehre 3, Auftrag Orchestrator)** | `foreign=false` NUR für die Embark-Streitäxte (Bronze) **187406 + 187431** (vorher true, Wagen-Position (95,97,133)/(94,98,133)); 187460 (87,82,z132) bleibt foreign=true/ungenutzt. Keine anderen Item-/Einheiten-Änderungen. |
| Zugänge Ist | Nur EIN Oberflächenzugang: T1 (99,94) z133 D / z132 X / z131 X / z130 U -> Torhaus Q (x99..104,y94..98 z130, Meeting-Area + Steinlager drin) -> **Tür (101,99)** (gebaut) -> Haupthalle. Stummel ohne Anschluss: (96,88) Schacht z133..131 (Sackgasse, kein Fort-Anschluss), (100,98) z133 'D' mit Fels darunter (dig=No) – NICHT weiterbauen (zweiter Zugang in dasselbe Q). Erkundungsschacht E (99,95) z130 -> z121+ (noch nicht zur Kaverne: Kaverne 1 z92-96 laut Weltdaten, Troglodyt/Troll bei z92/93; canWalkBetween false). |

## Defensivkonzept Windrings (Vorschlag an bau/Orchestrator, Pop-Gate 60 verbindlich)
**Gegner (Lage):** Goblin-Dark-Fortress Stolenshoved (26,13) 3 Weltkacheln, Camps (28,9) (29,12) (25,14) (24,8): Diebe/Hinterhalte ab Pop ~?, Belagerung ab ~80 Bürger (Run 2). Vergessene Bestie "Neca Mangyfin" (Oberfläche, nahe Razordrums 4 Kacheln) = Klasse A zu Fuß am Tor möglich -> Türen halten sie nicht (buildingdestroyer), nur Konstruktionswände.
1. **Torhaus A (Oberfläche, T1-Kopf):** Ring aus Konstruktionswänden x97..101,y92..96 um (99,94,z133) (Innen 3x3 x98..100,y93..95; 15 Wände + Tür (99,96) Süd; ~15 Boulder, 45 im Lager). Das Vorfeld y97..101 (flach, sichtbar) später Käfigfallen-Teppich (Mechaniker WN3 steht) + Schießscharten erst bei Schützen. (100,98,z133) 'D' mit Fels darunter nicht weiterbauen.
2. **Innere Pfropfen (Notfall, nur von INNEN gebaut, nie öffnen bevor die zweite steht):** **P1 = (101,99,z130)** (Q->Haupthalle; heute Tür -> Tür abbauen, Konstruktionswand setzen; 1 Kachel breit) schützt Kern/Zuflucht komplett; **P2 = (100,94,z132)** (Treppenspalte -> Farmhalle F1; 1 Kachel breit, Westeingang der Beete) schützt F1 (Nahrung/Getränke/Still/Küche). Mit P1+P2 ist alles hinter ihnen für Bodenfeinde/Bestien dicht; Q + Erzstollen/E-Schacht bleiben Feindseite (Miner im Stollen vorher heraufrufen!). Das ist die "Pfropfen"-Position aus LAYOUT-run5.md Abschn. 3 (101,99) + neu P2.
3. **Zugang B (122,97)** wie LAYOUT-run5 (Torhaus B x122..127,y97..101, Tür (119,101), Pfropfen (120,101)), Etappe 3; Abstand A-B 23. Vor Pop 30 stehen, Käfigfallen/Tor je Zugang. Kavernen: weiter KEIN Anschluss (Gate: Wache mit Metallrüstung IM Dienst + doppelte Konstruktionswand+Tor, `claude/sperre`).
4. **Zuflucht-Inhalt (bau/material/essen):** Betten fehlen (Holz 3 -> Schlafen am Boden/Zonen), Essen+Getränke liegen in F1 (z132, jetzt innen); für Pfropfen-Fall zusätzlich ein Getränke-/Essenslager im Kern (Lager SW x80..98,y106..109 ist Teil des Burrows) mit >= 2 Tagen/Kopf, Werkstätten WN im Kern stehen (Steinmetz, Handwerker, Mechaniker, Tischler; wirtschaft Webstuhl/Schneider). Burrow im Kampf NIE ändern; Erweiterungen (z129 Schlafsäle, z127 Krypta) liegen bereits in der Box.
5. **Trupps/Gate:** Pop 7: Wache 33 (2) als Skelett Off duty; Pop >= 15: Wache auf 4-5, Routine 2 im Barracks; Pop 40: 2 Trupps; **Gate Pop 60: 3 Trupps (~25 % der Erwachsenen), Metallrüstung IM Dienst, Torhaus A + P1/P2 + 2 Zugänge**. Kinder bei Gefahr nach innen. Metall: siehe Bedarf.

## Metallbedarf (an erkundung/material/wirtschaft gemeldet)
- Heute Metall: 0 Barren; Waffen: 3 Bronze-Streitäxte (Embark). Rüstung 0.
- Voll gerüsteter Soldat (Brustpanzer, Helm, Beinschienen, 2 Handschuhe, 2 Stiefel, Schild, Waffe): **~12-15 Barren je Kopf [Schätzung, nicht aus Raws belegt]**. Ziel Eisen (Magnetit z114..108 / Hämatit z107..104, Schmelzer + Schmiede + Kohle) oder Bronze (Kupfer Tetrahedrit z107..104 + Zinn Cassiterit z124).
- Bedarf: Pop 15 -> 4-5 Soldaten ~60 Barren; Pop 40 -> 8 Soldaten ~110; Gate Pop 60 -> 15 Soldaten ~200 Barren (+ Brennstoff Kohle ~1 je Barren/Gegenstand; Kohle-Cluster (101..104,93..94,z124)). Zusätzlich Mechanismen/Fallen (Stein vorhanden), Schilde. Erst Werkzeug (Spitzhacken) und Schmiede, dann Rüstung.

## Alarmprozedur Run 5 (Hauptthread bei Gefahr)
1. Automatisch (watchdog 60 Ticks + mil guard): `gefahr.handle` -> Pause, alert.flag/siege.flag/pause.hold, civ_alert_idx=1, `schau say`; Zeitlupe fps 50 bei Bodenfeind <= 90 Kacheln.
2. Hauptthread: fps <= 50 oder Schrittbetrieb (`claude/advance N`); `claude/mil enemies`, `claude/mil status` (ALLE Bürger+Soldaten prüfen, nicht nur den Feind), Flags danach löschen.
3. Wache aktivieren: `claude/mil train 33 2 --apply` (Constant training = Uniform an, geht zur Kaserne); Kill-Befehl nur per `tools/killorder.lua` (danach entfernen, `sq.orders` prüfen).
4. Klasse A (Bestie/Megabestie) zu Fuß am Tor: alle Zivilisten in den Kern, Miner/Stollen heraufrufen, **P1 (101,99,z130) und P2 (100,94,z132) von innen bauen** (Konstruktionswand, Boulder >= 2 im Kern); nie öffnen bevor Entwarnung (`claude/gefahr status`: alarm 0 über 5 Zyklen).
5. Entwarnung: watchdog nimmt civ_alert nach 5 ruhigen Prüfungen (300 Ticks) zurück; Trupp zurück `mil train 33 0 --apply`, Befehle `mil release` (experimental) bzw. killorder --release.

## Offen / nächster Durchlauf
1. Prüfen, ob Kosoth+Kib die Streitäxte tragen (`claude/mil equip --squad 33`, `tabelle`); Wache bei Pop >= 15 aufstocken (nicht Miner/Mason/Brauer/Planter).
2. bau: Torhaus A (Oberfläche), P1/P2-Konzept bestätigen, Kaserne z128; Zone 1387 danach löschen. Eingetragen in `inbox-bau.md`.
3. Alarmprobe wiederholen, sobald jemand auf z133 ist (Fischer/Händler/Jagd) -> trennscharfer Test; echte Zeitlupe nur mit echtem Feind.
4. Käfigfallen (Mechanismen/Stein) im Torhaus-Vorfeld A + Q-Tür-Vorraum, wenn Mechaniker Mechanismen liefert (Mechaniker WN3 läuft: ConstructMechanisms).
5. Nach jedem Laden: `claude/mil guard start`, `claude/mil refuge` (idempotent), `claude/gefahr status`.

---
# Durchlauf 2 (01.10. 09:46, J101 Galena 4, Pop 15 = 15 Erwachsene, Migrantenwelle 09:40) – Gate Pop 15
| Was | Stand |
|---|---|
| **Wache 33 jetzt 5 Mitglieder** | Kosoth 3748 (Hauptmann, AXE2/MELEE6), Kib 3747, **neu:** Mafol 4080 (Metalcrafter, SPEAR2 SHIELD2 ARMOR2 MELEE2 DODGING2 = bester Rekrut), Eral 3473 (Fish Dissector, idle), Etur 3476 (Carpenter, idle, DODGING1). Nur Nichtkämpfer/Leerlauf, keine Miner/Mason/Schmied/Brauer/Planter/Peasants (Squad 32 unberührt). 5 Plätze frei. Uniform Vorlage 1 (Streitaxt + Metallrüstung) auf alle Positionen, **Routine 1 "Staggered training"** (Training Monate 3-5 + 9-11 = Hematite..Galena, Moonstone..Obsidian; sonst Zivilarbeit, damit Manager Kosoth Aufträge validiert). Barracks = temporäre Zone 1387 (HW-West), Mitglieder stehen/trainieren dort. |
| Waffen | Nur 3 Bronze-Streitäxte (187460, 187431, 187406): Kosoth hält 2 (weapon=2, assigned 4), Kib 1, die anderen 3 unbewaffnet. **187460 war foreign=true und wurde trotzdem aufgenommen -> keine weitere foreign-Ausnahme nötig.** Metall 0 Barren, Rüstung 0/45. Metalsmith ònul 4078 + Metalcrafter idle: Schmelzer/Schmiede (WS-Reihe) + Erz fehlen = Engpass für Wache UND Werkzeug. Anvil 1 liegt auf der Oberfläche (96,94,133). |
| **Alarmprobe mit Leuten draußen (09:44)** | Start: Såkzul 3744 auf z133 (106,92) und Peasant 414 im Torhaus-A-Ring (99,93,133) beim Wandbau (beide ohne Squad), Peasant 1029 noch als Migrant am Südrand (102,191,135). civ_alert 12 s: **3744 und 414 waren nach <= 150 Ticks im Burrow** (Treppe T1, Farmhalle/Kern), Arbeit im Kern lief weiter, nach Alarm sofort wieder normal. 1029 (85 Kacheln entfernt, neu angekommen) blieb draußen = Migranten auf dem Anmarsch reagieren nicht in 12 s (Annahme: ab Ankunft ok). **Probe bestanden.** Squad-Mitglieder waren schon im Kern, ob Soldaten dem civ-alert folgen, bleibt ungetestet (Run-3-Befund: Soldaten blieben draußen). |
| **Torhaus A (bau)** | Ring x97..101,y92..96 z133 + Tür (99,96) steht größtenteils (Konstruktionswände 97/101-Rand, (97..98,95..96),(100..101,96) fertig; (97..100,92),(97,92..94) im Bau). bau lässt P1 (101,99,z130) / P2 (100,94,z132) möbelfrei. Fallen im Vorfeld nur x97..107 (Depot-Freifläche x108..116,y94..102 muss frei bleiben). Meine Blueprint-Tests (mil5_test/r5m_torhausA) gelöscht, nichts doppelt. |
| Fallen-Material | 24 Mechanismen frei, 71 Boulder, 94 Blöcke, 6 Türen; **Käfige 0 und Holz 0 -> keine Käfigfallen**, nur Stein-/Waffenfallen (Steinfallen per Quickfort-Kürzel Ts). Ob Bürger eigene Steinfallen auslösen, ist hier nicht belegt (Annahme: nein; Run 3 Gang D hatte keine Eigenverluste) -> Fallenkachel nicht auf den einzigen Türanlauf (99,97) legen, wenn Bürger dort täglich laufen. |
| Kaserne | z128 x82..97,y96..102 designiert (bau), noch nicht gegraben (2 Kacheln offen) -> bau meldet; dann `claude/mil barracks 33 <Zone-Id>` und Zone 1387 löschen. |

## Nächste Schritte
1. Kaserne z128 + Barracks-Zone umhängen; Rüstungsständer/Waffenständer in der Kaserne (bau).
2. Schmelzer + Schmiede in WS-Reihe z130 (y103..105) JETZT bauen (Anvil, Metalsmith idle), erkundung liefert Erz (Magnetit z114..108, Haematit z107..104, Kohle z124); erst Spitzhacken, dann Wache.
3. Wache >= 25 % der Erwachsenen halten (Pop 15 -> 4-5 ok, Pop 40 -> 10); bei jedem Migrantenschub Idle-Kandidaten ergänzen, nie Fachkräfte.
4. Steinfallen im Vorfeld A (bau entscheidet Lage), Mechanismen stehen.
5. Nach jedem Laden: guard start, refuge, gefahr status.

---
# Durchlauf 3 (01.10. 10:38, J102 Slate 19, Pop 24 = 23 Erwachsene + 1 Baby) - NEUE VORGABE des Spielers: ~10 % Soldaten, QUALITAET vor Menge
Ziel: wenige, sehr gut trainierte Soldaten in voller Metallrüstung, dauerhaft Routine 2 (Constant training) in der Kaserne, kein Arbeitsdienst. Quote: Pop 20-30 -> 2-3, Pop 40 -> 4, Pop 60 -> 6+, danach 10 %.
| Was | Stand |
|---|---|
| **Elite-Wache (Squad 33), 3 Mann** | **Kosoth 3748 (Hauptmann, MELEE_COMBAT 9 / AXE 6 / DODGING 3, TOU 2313 = mit Abstand der Beste, vorher Manager)**, Mafol 4080 (MELEE 4, AXE/SPEAR/SHIELD/ARMOR 2, DODGING 3), Eral 3473 (STR 1773, TOU 1831; MELEE 3). **Raus:** Kib 3747 (Stonecrafter, METALCRAFT 5 = Schmiede-Stimmung) und Etur 3476 (Carpenter). Alle 3 Routine 2, 7 Plätze frei. |
| **Abweichung von der Vorgabe (begründet)** | Statt Kosoth aus der Wache zu nehmen, wurde das **Amt MANAGER an Rovod 4079 (Woodcrafter, schwach AGI 317/TOU 591, ohne Holz sinnlos) vergeben** (`claude/aemter assign MANAGER 4079`, `nolabors` -> 75 Labors aus). Bestehende Aufträge bleiben validiert, neue validiert Rovod. Kosoth hatte als Manager ohnehin keine Labors, der beste Kämpfer (MELEE 9) bleibt Soldat. Rollback: `claude/aemter assign MANAGER 3748` + `claude/mil remove 33 3748`. |
| **Kaserne z128** (bau, x82..97,y96..102 gegraben) | Zone **1591 Barracks** (Quickfort `r5m_kaserne_zone.csv`, Cursor 82,96,128) per `mil barracks 33 1591` zugewiesen; temporäre Zone 1387 gelöscht (Squad.rooms = nur 1591). **Alle 3 trainieren dort** (Position (90..91,101..102,z128)); Skill steigt sichtbar (Kosoth MEL 8->9, Mafol WRE 1->2, Eral MEL 2->3, DODGING 3). Ausstattung `r5m_kaserne_build.csv`: 4 Waffenständer (94..97,96), 4 Rüstungsständer (82..85,96); `r5m_kaserne_lager.csv`: Lager Rüstung (82..85,98) + Waffen (82..85,99). Stein-Ständer-Aufträge bei wirtschaft (stehen auf 1 je -> 4 je angefragt). Baseline-Skills: `tools/out/mil-skills.log` (Messung: `claude/mil tabelle`). |
| ZUFLUCHT | + F2 {99,91,109,97,131,131} (bau hat es eingetragen), `mil refuge` neu angelegt (40 Blöcke). |
| Waffen | 3 Bronze-Streitäxte, Kosoth hält 2 (weapon=2), Kibs 187431 liegt frei; Mafol/Eral unbewaffnet bis Schmied liefert. Keine direkte Item-Manipulation (Fair Play). Rüstung 0. |

## Zielausrüstung je Soldat (Qualität hoch)
Brustpanzer, Helm, Beinschienen, 2 Handschuhe, 2 Stiefel, Schild, Waffe (Axt/Schwert, bei Kosoth Axt). Material nach Verfügbarkeit: Bronze (Kupfer Tetrahedrit z107..104 + Zinn Cassiterit z124) oder Eisen (Magnetit z114..108 / Hämatit z107..104), später Stahl (Eisen + Kohle + Flussmittel Dolomit). **Qualität** kommt aus Schmiedeskill (ARMORSMITH/WEAPONSMITH) + Material + Werkstatt: ein fester Schmied (Kib 3747 hat METALCRAFT 5, Metalsmith-Migrant) fertigt zuerst Spitzhacken/Einfaches zum Üben, dann Rüstung; Mafol (Metalcrafter) schmiedet keine Rüstung. Bedarf (Schätzung ~12-15 Barren je Satz): 3 Soldaten ~40 Barren, 4 ~55, 6 ~80, danach 10 % der Pop (Pop 100: 10 Sätze ~130) + 1 Kohle je Barren/Teil.

## Essen/Trinken/Schlaf der Soldaten
Routine 2 hat sleep_mode 0 und keinen Stationsbefehl -> Soldaten gehen zum Essen/Trinken/Schlafen wie Zivilisten (Station = KEIN Essen, daher nie `mil station` bei Dauertraining). Messung `mil status`: Durst 6800-12000, Hunger 11000-19700 (Grenze 30000/40000 = ok). Getränke/Essen liegen in F1 z132 (weit von z128): Lager für Essen+Getränke nahe Kaserne/Kern an trinken/essen gemeldet. Betten fehlen (Holz 0): Schlaf am Boden.

## Offen
1. Waffen-/Rüstungsfertigung (material/Schmiede): Spitzhacken zuerst, dann 3 Sätze; festen Schmied bestimmen.
2. Quote nachführen: Pop 40 -> 4, Pop 60 -> 6 (beste Kampf-Kandidaten per `claude/mil tabelle` + Skill/Attribute, Leerlauf-Zwerge ohne Fachskill; Kandidaten jetzt: Avuz 4081 STR 1940, Tholtig 1029 TOU 2156, Sibrek 4156 END 1955).
3. Skill-Verlauf alle ~30 Min in `tools/out/mil-skills.log` messen; Sparring/Waffenübung läuft über die TRAIN-Order der Routine.
4. Gate Pop 60 unverändert: Torhaus A + 11 Steinfallen stehen (bau), P1/P2 möbelfrei, Zugang B im Bau.
