# BUG-879 Reserve's 'free boulders' did not match what DF can use
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 i1 Diedplank: census boulders 47-83, reserve line '0 free boulders'; `dfraw items:BOULDER` '12 free, 30 in buildings, 5 forbid'.
Module: `lua/dfllm/economy.lua` (`M.reserve_stone`, `M.reserve_mat`)

## Root cause
`reserve_mat` used `stone_free(c, r)` = usable boulders minus `floor_of(rock)` (the stone kept back for open needs and holders) minus planned and open-order use: with a floor of 30 the 12 usable boulders read 0. The census `boulders` is the total item vector (boulders in buildings, forbidden, dumped, held by jobs and out of reach included); `rock` is the free part.

## Fix
`M.reserve_stone`: free = usable (ore / flux / economic / soft stone and a DF refusal out) minus what planned and open rock orders hold; the stone floor is NOT kept back (the drink is the emergency, DF takes those boulders for a barrel job). The log lines ('ordered' and 'nothing to make them of') carry the count in words: '47 boulders in the census: N out of reach, N held by jobs, N in buildings / forbidden / dumped, N ore, flux, economic or soft; N usable, N held by open rock orders -> N free'.

## Tests
`tests/lua/test_bug878_880_stein.lua` (BUG-879: floor 30, 14 free, 2 not usable, 4 held -> 8 free, the line names every step).

## Live-Erwartung
i1: the reserve line shows the staged boulder count and orders rock barrels whenever DF-usable boulders remain. NOT promised: boulders DF itself refuses for a job (the hard-stone denial) are still 0.
