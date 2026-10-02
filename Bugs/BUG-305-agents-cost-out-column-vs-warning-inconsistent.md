# BUG-305: `agents cost`: the `Out~` column and the "stuck?" warning quote different output numbers (up to 2.6x apart)

- **Status:** open
- **Severity:** S3
- **Area:** `agents cost` (`df_llm_helper/agents.py:parse_transcript`, `cost_report`)
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
python -m df_llm_helper agents cost            # on the player's machine, default ~/.claude/projects
python -m df_llm_helper agents cost --compare
```
(The cloud session has no transcripts; the statistics below were produced locally with the snippet in the evidence file.)

## Expected
The warning line uses the same output figure as the table column (one definition of "output").

## Actual
```
$ python -c "parse every ~/.claude/projects/**/subagents/*.jsonl with agents.parse_transcript; compare .output vs .out_est" (run on the player's machine)
transcripts: 128 | usage.output_tokens sum > estimated output (Out~ column): 11
ratio output_tokens/out_est: median 0.13, min 0.00, max 2.64
agent-ad6d14a276abd0141    calls= 93  Out~(table)= 167271  usage.output_tokens= 441146
agent-a188cd1838d632f23    calls= 75  Out~(table)= 172448  usage.output_tokens= 429239
agent-ac1c73c60c861b2f9    calls= 85  Out~(table)= 169877  usage.output_tokens= 398507
agent-afb46eca3b184e041    calls=130  Out~(table)= 190088  usage.output_tokens= 398288
agent-a1e41bff1d78c9641    calls=147  Out~(table)= 180463  usage.output_tokens= 392333
[exit 0]
```

Example from the real `agents cost` run: table row `agent-a188cd1838d632f23  75  25142478  1515525  172448  1361.2m  Build v3.9 Alchemie`
(Out~ = 172448) but warning `agent-a188cd1838d632f23: 75 calls/~429239 output - stuck? ...`.

## Evidence
`Bugs/evidence/BUG-305/stats.txt` (local statistics).

## Analysis (reporter's hypothesis)
`agents.py:172-173`: the warning uses `max(ac.output, ac.out_est)` while the table prints `out_est` only (`agents.py:181`). For most transcripts the documented statement holds (`usage.output_tokens` is far below the estimate, median ratio 0.13), but for the 11 longest agents the summed `usage.output_tokens` is 2-2.6x larger than the estimate (probably thinking blocks that are empty in the transcript), so `max()` silently switches the basis and the table and the warning disagree.

## Suggested fix (optional)
Print the same figure in the table and in the warning (e.g. an extra column `Ausg(usage)` next to `Ausg~`), and mention in docs/MANUAL.md 9.10 that the estimate can undercount thinking tokens.

## Info needed
Info for the player (local test): please run `python -m df_llm_helper agents cost --dir <folder with ONE recent transcript>` and compare `Out~` with the value shown in the Claude Code UI for that agent. Is `usage.output_tokens` the real total?
