# Post-Mortem Run 13 (Koletes "Wheelsblows", region2-site84) - gefallen y525

Reclaim der Wheelsblows-Ruine, Start y504 spät im Sommer mit 12 Bürgern, Höchststand 59 (y509). Ende: ein Hinterhalt plus Snatcher und Eindringling im Sommer y525 töteten 48 Bürger (21 getötet, 18 verblutet, alle Soldaten). Ende y525 lebte noch 1 Bürger.

## Verlauf
- y504-y506: Fortcore S1 gebaut, Pop 12 auf 47 gewachsen, Trinken früh kritisch (3 Tage), danach gelöst. 93 Library-Orders (basic, rockstock, smelting) von Hand importiert.
- y507-y509: Pop über 55. Brücke B2 (y507) und O1 (y509) verschwinden im Frieden. Viele Bauten "stalled" wegen fehlender Türen und Särge, mehrfach Holztüren und -särge von Hand bestellt.
- y510-y513: Hungersnot (Essen bis 10 Tage). Ursachen: Autofarm leerte den Slot der laufenden Jahreszeit; Oberflächen-Crops auf unterirdischen Plots; kein FISH-Labor; Planters-Arbeitsdetail leer. Pop 59 auf 38. Stimmungstode und Amok.
- y514-y519: Eisen oberste Priorität (Gordon). 9 Erkundungsschächte ohne Erz. Essen erholt sich bis 453 Tage.
- y520-y524: Krankenhaus ohne Wasserquelle, Patienten bis über 35.000 Durst. Entdeckt: 31 EngraveSlab-Orders blockierten alle Stein-Jobs der Steinmetze seit Jahren (Türen, Särge, Tische, Platten). 15 alte Geister nie beruhigt. Tiefschacht von Hand unter eine Wasserzone markiert: geflutet, 2 Tote.
- y525: Drill erst jetzt dauerhaft gestartet, Rüstung 23 %. Sommer d75: Snatcher, Eindringling und Hinterhalt kommen über das offene O1. Die Zuflucht Tiefe+ war schon von Feinden besetzt (REFUGE_FAIL "hostile inside"). Werkstätten zerstört (Wächter: Gebäudezerstörung ohne Abriss-Jobs, Angreifer im Fort).

## Ursachen des Falls
1. **Offene Verteidigung über Jahre:** B1, B2, O1 zerstört und nie neu gebaut (bridge.rebuild meldete "nothing waits"). Audit FAIL seit y507, Readiness R0 bis zum Ende.
2. **Militär untrainiert:** Drill lief nie automatisch (Phase P0 < P5, "merchants on the map"), Rüstung 9-23 %, kein Metall außer Bismutbronze und 9 Stahlbarren.
3. **Zuflucht unsicher:** Tiefe+ war für Feinde erreichbar; beim Alarm fanden die Bürger sie besetzt.
4. **Wirtschaft verstopft:** EngraveSlab-Stau (alle Stein-Jobs tot), leere Arbeitsdetails (Farmer, Fischer), Autofarm gegen den Kernel. Folge: Hunger, Stress, fehlende Möbel und Türen.
5. **Meine Steuerung:** nur reaktiv per 15-Minuten-Loop, ohne Zieldatei bis y524; Probleme wiederholt behoben statt die Ursache zu finden; Regelverstoß (verdeckte Felder gelesen) und tödlicher Schachtfehler.

## Lehren
- Zerstörte Tore/Brücken sofort ersetzen oder durch Wand + Tür ersetzen; Audit-FAIL ist ein Stopp-Signal, kein Dauerzustand.
- Drill ab Tag 1 von Hand, wenn der Kernel ihn nicht startet; Händler-Sperre umgehen, sobald die Karawane weg ist.
- Bei "stalled" zuerst die Werkstatt-Jobliste ansehen (Stau durch abbrechende Jobs), nicht nur Material bestellen.
- Arbeitsdetails statt roher Labor-Flags benutzen; Autofarm aus, wenn der Kernel die Slots verwaltet.
- Zieldatei mit Kennzahlen von Beginn an (GOALS-run13.md kam zu spät).
- Nie unter oder neben Wasser graben; Felder darüber prüfen.
- Zuflucht muss von außen abgeschnitten sein, bevor man darauf vertraut.

## Offene Bugs/FR aus Run 13
Siehe `bugs/RUN11-offene-bugs-und-FR.md` Punkte 38-47 (u. a. Quicksave scheitert, Popup-Pausen, EngraveSlab-Stau, leere Arbeitsdetails, verschwundene Brücken, Autofarm-Konflikt, Dig-Designation nach Alarm verloren).
