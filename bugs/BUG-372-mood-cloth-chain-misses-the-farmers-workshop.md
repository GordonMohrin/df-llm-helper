# BUG-372 a mood that needs cloth or thread asks the Loom only, and the caravan request is not in MOOD_CRITICAL
Status: fixed (offline, live-untested); open: yarn/silk need animals, webs or a caravan, the kernel cannot make them from nothing
Severity: high
Found: 2026-11-04, Run 16d (i4 Plankscale y375-y377 'moods missed cloth,gems'; i2 leather/yarn/bars), main 2fcd6e0
Module: `lua/dfllm/mood.lua` (CHAIN, EXTRA), `lua/dfllm/care.lua` (mood_emergency)

## Actual
i4 Plankscale: MOOD_CRITICAL unit 26490 needs cloth(yarn) x1 'none in the fort [0/0/0 of 11, thread 5]'; 26531 cloth(silk) x2;
26274 cloth(silk) x1 + gems x1: 'moods missed cloth,gems'. kern.log: `workshops: 8 order(s) wait ... asking for Clothiers,Leatherworks,
Loom,Quern` at tick 150143014; the Loom (project c1a1a6b1bad1bd0001) was built at 150971284, before the moods. The cloth was the
wrong kind (11 plant cloth, no yarn, no silk): the chain the mood asked for had no Farmer's workshop (it spins yarn/silk thread and
processes plants into thread), there were no animals for yarn, `webs_near` was 0, and the request to the caravan ('cloth:silk' in
state `mood` buy) was never named in the MOOD_CRITICAL text, which only said 'kernel asked Loom first'.

## Root causes
- mood.lua `MD.CHAIN`: cloth and thread -> {'Loom'} only; the Farmers workshop (non-moodable, `MD.EXTRA` adds it like the
  Butchers) was no part of the chain.
- care.lua `mood_emergency`: `caravans asked: <tokens>` appeared only for items out of the dwarf's reach (BUG-341 `mood_reach_text`).

## Fix
- `CHAIN`: cloth = {Loom, Farmers}, thread = {Farmers}; `EXTRA` = {Butchers, Farmers}: a Farmers workshop is asked (workshops
  `why=mood`, placed through `add`, wake.py generic for EXTRA_TYPES) while none stands; a standing Loom/Farmers is not asked again.
- `mood_emergency`: a material none in the fort with buy tokens says 'caravans asked: cloth:silk' in MOOD_CRITICAL right after
  the line that carries the days left (the tokens already flowed into `plan propose` trade.want, BUG-284).

## Tests
`tests/lua/test_bug371_373_moods.lua` (chain, typed request with/without Farmers, MOOD_CRITICAL text); fail on 2fcd6e0.
