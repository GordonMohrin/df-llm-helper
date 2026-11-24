# NEU1 P9 Pflege (Entscheidung E8): Hospital als Zone plus ein Bett, Grabplatten vor dem Geist, Stimmungs-Werkstatt eindaemmen

Neuausrichtung 1, Paket P9 (offline, live-untested). Erfolg laut Plan: **Geister unter 5; Hospital in Jahr 1 nutzbar.**

## Befund (Run 16, read-only)

- **Hospital:** In i1 Basementflew stand von y423 bis y558 kein Hospital. Jedes `bp.place hospital` endete `build_lost`
  ("missing b x4", Traktionsbank, Mechanismen, Kisten): ein Paket aus neun Teilen, dessen Zone erst *nach* den Moebeln
  gezogen wird. Ein fehlendes Teil = keine Zone = kein Hospital. Gleichzeitig standen Betten im Fort.
- **Patientendurst:** Patienten starben in i1/i2/i4 an Durst, teils "no GiveWater job, no hospital zone", teils mit
  laufenden GiveWater-Jobs. `water.carers` wollte 0 Traeger, solange kein Patient lag (Traeger erst *nachdem* jemand
  im Bett liegt); Eimer und Quelle waren keine sichtbare Vorbedingung des Hospitals.
- **Geister:** i1 hatte 42 Geister (74 Leichen `no_coffin`, kein Holz). Grabplatten gab es nur fuer schon erschienene
  Geister und fuer unerreichbare Leichen (BUG-518). Saerge: Holz zuerst, Vorrat nur fuer platzierte Reihen.
- **Stimmungen:** i3/i4 hatten 9 bzw. 24 Stimmungs-Durst-Tote; die Kette MOOD_RISK / MOOD_CRITICAL / mood_thirst /
  mood_deadline meldete viel, `mood_deadline` sagte selbst "no verb confines one dwarf". Ein gescheiterter Fell/Macabre
  wird Berserker; nichts hielt ihn von den anderen fern.

## Alte Entscheidung -> neues Verhalten

| Teil | Alt | Neu | Schalter (Default an) |
|---|---|---|---|
| (a) Hospital | Hospital = bp-Paket (4 Betten, Bank, Tisch, Kisten, Brunnen), Zone zuletzt | **Kernel zieht selbst eine Hospital-Zone (1x1, Ort "Hospital") ueber EIN vorhandenes freies Bett**, das erreichbar ist und hoechstens `water.near` Felder von akzeptiertem Wasser liegt. Kein Bett -> Luecke `no_bed` (das bp-Paket baut es). bp `hospital`: Default `beds=1`, `bench=0`; die Zone kommt **vor** den Moebeln; Tisch, Kisten, Bank und Brunnen sind optional (blockieren nie) (BUG-822) | `care.hosp_min` |
| (d) Patienten | Traeger erst bei Patient; Eimer/Quelle nur im Water-Audit | Hospital-Vorbedingungen stehen dauerhaft im State `care.hosp` (`ok`, `gaps`: `no_zone`, `no_bed`, `no_water`, `no_bucket`, `no_carer`); HOSPITAL_MIN (B) bei jeder Aenderung. `water.carers` haelt `carers_min` Traeger, sobald eine Hospital-Zone steht, auch ohne Patient (BUG-821); ueberzaehlige eigene gehen nach `carers_hold_days` seit dem letzten Patienten einzeln bis auf `carers_min` | `care.hosp_min`, `water.carers_standing` |
| (b) Grabplatten | Platte nur fuer Geist oder unerreichbare Leiche | Platte (Stein, kein Holz) auch **vor** dem Geist fuer jeden toten Buerger, dessen Leiche fehlt (`no_body`), in einer anderen Laufgruppe liegt (`corpse_far`) oder `mem_wait_days` (7) ohne Sarg liegt (`no_coffin`/`no_zone`/`zone_locked`). Derselbe Weg wie BUG-518: `care.unreach_ids` -> economy bestellt Rohling + Gravur -> care stellt die Platte auf | `care.mem_early`, `care.mem_wait_days` |
| (b) Saerge | Holz zuerst; Vorrat nur fuer platzierte Reihen | **Stein zuerst**, Holz nur fuer den Rest; `coffin_spare` (3) fertige Saerge in Stein auf Lager, auch wenn niemand wartet | `care.coffin_stone_first`, `care.coffin_spare` |
| (c) Stimmungen | Melden und retten (Nook, Karawane, Werkstatt, Steingrube, Entscheidungen) | Meldung unveraendert (Materialklasse aus dem Job gelesen, nicht geraten; die billigen Wege laufen weiter). **Neu: eindaemmen.** Hat der Zwerg eine Werkstatt, fehlt Material und sind es noch <= `mood_contain_days` (3) Tage bis zum Wahnsinn (oder ist er nach der Stimmung Berserker), werden die Tueren des Raums um die Werkstatt verschlossen (forbid + close), wenn der Raum geschlossen ist (nur Waende und Tueren, keine Treppe/Rampe/offene Luft, <= 200 Felder) und kein anderer Buerger darin steht. Entsperrt wird genau, was care verschlossen hat, sobald der Zwerg tot ist oder weder in Stimmung noch Berserker. MOOD_CONTAIN (B) sagt `locked`/`sealed`/`open`/`busy`/`released` | `care.mood_contain`, `care.mood_contain_days` |

## Nachbesserung nach der Verifikation (BUG-823, BUG-824)

| Punkt | Vorher | Jetzt | Schalter |
|---|---|---|---|
| care gegen water (BUG-823) | `HM.phase` zog binnen eines Tages wieder eine Zone, auch wenn water sie gerade fuer einen verdurstenden Patienten entfernt hatte (BUG-034/541, `p.hrm`) | neues water-Verb `hosp_hold`: Grund-String solange ein `p.hrm`-Eintrag oder `p.rm` juenger als `hrm_expire` ist, ein Patient ueber `patient_thirst` liegt oder water noch keinen Lauf hat. Dann zieht care **keine** Zone, Luecke `held_by_water`; antwortet water nicht: ebenfalls gehalten (fail closed). Die Rueckkehr der alten Zone bleibt allein `hospital.restore` | `care.hosp_min` |
| Wasser-Urteil (BUG-823) | `water.src_dist` (ohne den `outer()`-Filter der Abriegelung, BUG-708) | neues water-Verb `would_serve(x,y,z)` = derselbe `served()`-Test, den `remove_dry` anwendet; care zieht nie eine Zone, die water als trocken entfernen wuerde; auch die Luecke `no_water` einer stehenden Zone kommt daher | - |
| Bett-Kandidaten (BUG-823) | jedes freie Bett | kein Bett, auf dessen Feld eine lebende Einheit steht/liegt, und keins mit DF-`users` | - |
| Raum teilt das Fort (BUG-824) | jeder geschlossene Raum <= 200 Felder wurde verschlossen, auch ein Gangstueck zwischen zwei Tueren | `CT.split`: die begehbaren Felder hinter den Tueren muessen sich auf der Ebene des Raums ohne den Raum erreichen (Flutfuellung, <= `mood_contain_reach` Felder). Nicht gezeigt oder Feld unlesbar: `op=open`, nichts verschlossen (fail closed; eine Verbindung nur ueber Treppen zaehlt bewusst nicht) | `care.mood_contain_reach` (1500) |
| Berserker-Wiederholung (BUG-824) | ein Versuch im Frame, in dem der Stimmungs-Eintrag faellt | `p.bzk[sid]`: solange er Berserker ist und kein `p.cont` hat, alle `CT.RETRY` (1/4 Tag) neu versucht | `care.mood_contain` |
| Tueren halten (BUG-824) | eine Tuer, die ein anderer (reflex `open_doors`) aufhob, blieb offen | solange eingedaemmt, wird eine nicht mehr verbotene Tuer wieder verboten und zaehlt dann als care's (wird beim Release geoeffnet) | - |
| mood_deadline (BUG-824) | "send these" auch nach dem Verschliessen | ist der Raum verschlossen: "his room is locked (doors ..), deliveries cannot reach him: nothing to send", ohne cmds/opts/auto | - |

Bewusst so gelassen: care entsperrt beim Release seine Tueren auch in einer Belagerung; reflex zaehlt eine schon verbotene Tuer nicht als seine und verbietet eine Eingangstuer beim naechsten Durchlauf wieder (selbstheilend, kein Tuer-Arbiter gebaut). Material, das nach dem Verschliessen kommt, erreicht den Zwerg nicht: das ist die Entscheidung "eindaemmen statt retten" (3 Tage vor dem Wahnsinn).

## Bewusst nicht getan

- Keine Moebel-Platzierung durch den Kernel (kein Bett-Bau ausser ueber das bp-Paket); kein Bett aus einem zugewiesenen
  Schlafzimmer, kein Bett ausserhalb der Wasser-Reichweite (sonst entfernt `water.remove_dry` die Zone wieder).
- Keine Burrow-Umlenkung der anderen Buerger (zu breit, kollidiert mit Alarm-Burrows); offene Werkstaetten (Hallen ohne Tuer)
  werden nur gemeldet (`open`), nicht ummauert.
- Die Drink-Nook, `mood_thirst`- und `mood_deadline`-Entscheidungen bleiben (Live-Versuch "trinkt ein Stimmungszwerg?" steht aus);
  keine neue Eskalation. Der Text von `mood_deadline` nennt jetzt die Eindaemmung.
- Die Ursache "GiveWater laeuft, Patient verdurstet trotzdem" (i4 y384) ist offline nicht beweisbar; hier nur die Vorbedingungen.
- Manager-Validierung der Platten/Sarg-Auftraege (i1: Buero ohne Tisch) und Steinmangel sind nicht Teil von P9.

## Live-Erwartung

1. In einem Fort mit mindestens einem freien Bett nahe akzeptiertem Wasser erscheint binnen eines Spieltags ein
   `HOSPITAL_MIN` mit `op=zone` und `care.hosp.ok=1` (oder eine benannte Luecke); `inspect what=hospital` zeigt eine Zone
   statt `no_zone` - in Jahr 1, ohne bp-Projekt.
2. Nach Toden ohne Sarg erscheinen in kern.log `EngraveSlab`/`ConstructSlab`-Auftraege fuer diese Einheiten, bevor
   GHOSTS sie nennt; der Geisterzaehler (`care.ghosts`) eines neuen Forts bleibt unter 5.
3. Bei einer scheiternden Stimmung mit Werkstatt in einem Raum mit Tuer: MOOD_CONTAIN `op=locked` mit Tuer-ids
   3 Tage vor dem Wahnsinn, spaeter `op=released`; keine Toten durch den Berserker ausserhalb des Raums.
4. Nach `HOSPITAL_REMOVED` (water) folgt binnen `hrm_expire` (20 Tage) **kein** `HOSPITAL_MIN op=zone`; `care.hosp.gaps` enthaelt `held_by_water`. Kein Tages-Wechsel HOSPITAL_REMOVED/HOSPITAL_MIN in einer Abriegelung.
5. MOOD_CONTAIN `op=open` mit `why` "locking would split the fort" bei Werkstaetten in Gangstuecken; nie ein verschlossener Raum, hinter dem Buerger von Wasser/Essen abgeschnitten sind.
