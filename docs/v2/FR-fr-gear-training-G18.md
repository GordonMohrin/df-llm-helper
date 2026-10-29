# FR-100 / FR-101: every soldier armor + weapon, sparring with wooden weapons (G18)

Gordon's goal G18 (runs/GOALS-VORLAGE.md): every soldier has an armor and a weapon uniform; training and sparring always
with wooden training weapons where possible. Before: the FR-89 training policy existed only behind the verb
`squad.uniform kind=training`, classes without a training raw (hammer, mace, no skill) kept their metal weapon, an armor
slot specced for metal stayed empty when only leather or bone pieces existed (Earthboat `body 0/5 ... worn 37%`), and no line
said how many soldiers were fully equipped.

## What the kernel does now

| Part | Where | Rule |
|---|---|---|
| training by default (FR-100) | `military.train_default`, upkeep | every melee squad military makes or adopts goes on the FR-89 policy (`sq.<key>.tr = 1`, `td = 1`). Wooden weapons only in PEACE and DRILL; in ALERT, SIEGE, BREACH, RECOVERY the wooden positions get individual choice (a real weapon) back, PEACE puts the wooden ones on again (FR-89 logic, unchanged). Crossbow squads: no training crossbow exists, untouched. |
| player override | verb `squad.uniform` | `kind=melee` sets `tr = 0`: off for that squad for good (persisted, the default never turns it on again); `kind=training` on again. |
| switch | config `military.training.on`, plan `military.training` | the plan's boolean wins over the config. Off withdraws only what the default set (`td = 1`); the wooden positions get their real weapons back (`un = 1` until none is left). |
| fallback class (FR-101) | `military.train_token`, `dfllm.kit.ALT` | pike -> spear, dagger -> sword, every other class without a raw (hammer, mace, whip, no skill) -> `military.training.fallback` (SPEAR; `none` = keep the weapon as before). `training_need` follows, so economy's `plan_training` orders the right wooden weapons at the Carpenter's. |
| armor material refit (FR-100) | `military.refit`, `dfllm.kit.refit_plan` | PEACE, no danger (`military.danger`), at most every `refit_days` (7) per squad, the first look only starts the clock: an armor slot specced metal (or leather) that stays empty while pieces of that category in another material lie free is re-specced to any material (the squads screen's material choice), beyond the positions the free pieces of its own material cover; a slot worn with a non-metal piece in an any-material spec goes back to metal once free metal pieces cover all of them. |
| orders | `economy` gear items (config/baseline.json + economy.lua defaults) | metal > leather > bone: helm, gauntlets and greaves get a bone route at the Craftsdwarf's (`MakeHelm/MakeGloves/MakePants`, bone, after the existing metal and leather routes); shields keep metal > wood. The missing-workshop request is fix6-econ-supply's (f). |
| KPI | `military.kit_stats`, state `mil.kit {n, full, armor, weapon, wood, tr}` | full = every armor category (body, head, pants, gloves, shoes) has a spec and each spec holds a worn item, and a weapon in hand; wood = a training weapon in hand. Cached one game day. |
| status / brief | `brief.def_parts` | `gear: 3/5 soldiers fully equipped (armor 3, weapon 5, wood 4)` (defense detail). |
| plan | `plan propose/check`, `plans/year1.json` | propose drafts `military.training: true` (keeps a player's false); check warns on `training false` from P2 and on soldiers short of kit from P5; P6 has the deliverable `{"k": "kit", "pct": 80}` (runner `CHECK.kit`, owner military). |

## Fair play and safety
All writes are the squads screen's equip actions (`act.squad_uniform`: uniform specs per position and category); DF hands out
the items. No item is moved, no hidden tile is read (free stock = the item vectors' free flags, as `stock_mats` already did).
The kernel's siege/lockdown logic wins: the wooden weapons are a PEACE/DRILL policy only and the refit never runs outside PEACE
or with a hostile in sight.

## Limits
- In PEACE a sudden ambush meets wooden weapons until the next upkeep (600 ticks outside PEACE) re-specs and DF lets the
  soldiers fetch their real weapons; DRILL keeps the wooden ones on purpose.
- A real weapon for every soldier is not reserved while he trains; the melee fill still follows the gear sets (Run 11).
- worn % counts the weapon slot: until the Carpenter's has made the training weapons (and for the hours the soldiers need to
  fetch the real ones in an alert) one slot of seven reads empty, so worn can sit ~14 points lower (drill needs 90, intake 80).
- The refit judges metal by `material.flags.IS_METAL` of the worn piece; bone or shell armor counts as soft (upgraded to metal
  once enough free metal exists).
- The bone routes assume the Craftsdwarf's accepts `MakeHelm/MakeGloves/MakePants` with material category bone (live check).

## Live checks
1. A new fort at P2: kern.log `squad A: training policy on by default`; squads screen: the weapon slot of every position names a
   training axe/sword/spear; economy orders `dfllm:train_spear` etc. at the Carpenter's; a day later the soldiers hold them.
2. `dfllm status`: `gear: N/M soldiers fully equipped (armor a, weapon w, wood k)`.
3. An ALERT: within one upkeep the weapon slots show individual choice, the soldiers swap to their metal weapons; PEACE: wooden again.
4. A metal body spec with no metal and free leather armor: after 7 days kern.log `squad A: body of N positions to any material`,
   the soldier wears the leather armor.
5. A fort with bones and a Craftsdwarf's but no leatherworks/metal: orders `dfllm:gear_head` with bone material appear and finish.
