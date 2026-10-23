# BUG-077 Doctors who still hold posts at an orphaned hospital location are never put on the live hospital's posts
Status: fixed in 6afe3c7 (offline, live-untested): holders are the living citizens with a post anywhere except a hospital
post of a zoneless location; those doctors take the live location's vacant posts; the orphan posts count nowhere
Severity: high (wrong decision: the live hospital stood without doctors, "with no hospital post filled the game posts no
care jobs")
Found: 2026-10-23, Run 14 Trussroads (note 68 of `bugs/RUN11-offene-bugs-und-FR.md`), kernel of 9bcb14f
Module: `lua/dfllm/care.lua` (`hospital_posts`, `phase_doctors_run`)

## Actual
The hospital zone moved (new zone 24422, location 27). Locations 0 and 16 were the old hospital locations: no zone linked
any more, their posts still held by the four doctors (DOCTOR, DIAGNOSTICIAN, SURGEON, BONE_DOCTOR). Location 27 had four
vacant posts (`unit_id` -1) although four citizens with all three doctor labors existed. No post was ever filled; the
game session filled the four by hand with the logic of `act.hospital_post`.

## Cause (base 9bcb14f, proved from the code)
- `care.lua:2126` (base, `hospital_posts`, 2113-2136): the loop over `world.occupations.all` set `holders[uid] = true` for EVERY
  living holder of ANY occupation, before it looked at the occupation's location. BUG-056 (3713b78) only restricted which
  VACANT posts are listed (`live[o.location_id]`), not who counts as a holder.
- `phase_doctors_run` (`care.lua:2183`, base): `if not holders[d.id]` guards every candidate. A doctor holding a post at
  location 0 is `holders[d.id] == true`, so each of the four docs is skipped for each of the four posts of location 27,
  on every run. Reproduced by `tests/lua/test_care_fr.lua` (three locations 0, 16, 27; 0 held by four doctors, 16 vacant, 27
  live and empty): base made no `hospital_post` act.
- The note's other idea (remove the orphan locations) cannot be done by a player: the locations screen offers no delete
  that a script can press (BUG-056).

## Fix
- `hospital_posts` returns holders only for living citizens with a post that is NOT a hospital post of a location without a
  zone (`orphan_post`, the same `locs`/`live` sets BUG-056 built: no second helper). Those doctors are collected in
  `orphans`; the new fifth return value counts the ones that hold no other post (`waiting`).
- The post change itself is unchanged: `K.act.hospital_post(post, unit)` (act.lua:1744, the location sheet's occupation
  assignment). The old posts at the orphaned location are left as they are (no unit or location field is written by care);
  the doctor then holds the new post as well, which makes him a holder, so he is not placed twice.
- `r.doctors.orphan_held` (care state, `inspect tombs`) = doctors who hold posts at orphaned locations only; 0 once they are
  placed. `posts`, `filled` and `stale` count live posts and vacant orphan posts as before; held orphan posts count in no
  post number.
- Safe at every pop: no new act, no bound needed (at most `care.posts_per_run` fills a run, as before); a fort of 7 has no
  hospital location, nothing changes; a reload rebuilds everything from the occupation vector (no kernel state).

## Not decided offline
Whether DF keeps working when a unit holds two occupations (the old orphan post and the new one). The game session's manual
fill left the old posts in place and the new ones held "after 20 s / several hundred ticks" (note 68), which says yes.
Live read: `inspect tombs` (`doctors.orphan_held` 0, `filled`), kern.log `hospital post ... filled`, and the units' sheet.

## Tests
`tests/lua/test_care_fr.lua`: "BUG-077 (Run 14 note 68)" (the three-location case, the second run places nobody, nobody waits)
and "a doctor with a non-hospital post stays a holder; a doctor at a live location is not placed twice". Both fail on 9bcb14f.

Related: BUG-056, FR-48; note 68
