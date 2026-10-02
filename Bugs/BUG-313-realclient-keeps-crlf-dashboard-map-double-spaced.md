# BUG-313: `RealClient` returns `dfhack-run` output with CRLF while `MockClient` always yields LF; the dashboard map block gets `\r\r\n` and renders double-spaced; other text consumers see stray `\r`

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S3
- **Area:** `df_llm_helper/client.py:RealClient._run`, `dashboard map`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack, fort Y118 Granite 27) but PAUSED and untouched; read-only observation of `claude/area`, reproduction with a replay recording

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp Bugs/evidence/BUG-313/cfg.yaml tmp_bug/cfg.yaml && cp Bugs/evidence/BUG-313/inputs/rep.jsonl tmp_bug/rep.jsonl && mkdir tmp_bug/scopes tmp_bug/tools
python -m df_llm_helper --config tmp_bug/cfg.yaml --replay-file tmp_bug/rep.jsonl dashboard map Test 85 96 130 10 3
python -m df_llm_helper --config tmp_bug/cfg.yaml --replay-file tmp_bug/rep.jsonl dashboard --offline --out tmp_bug/d.html
python -c "t=open('tmp_bug/d.html','rb').read(); print(t.count(b'\r\r\n'))"
```
`rep.jsonl` is a small synthetic recording whose stdout uses CRLF like the real answers of `dfhack-run.exe` (proof from the live game: `Bugs/evidence/BUG-313/live_area_raw.txt` / `.bin`, 7 CRLF and no bare LF; also visible in the recordings under `fixtures/run5_live/*.jsonl`).
Live observation (game paused, read only): `python -m df_llm_helper dashboard map Test 85 96 130 10 6` followed by `dashboard --offline --out <file>` gave the same double spacing in the real page.

## Expected
The map block in `dashboard.html` has one line break per row; `Result.stdout` is normalised to `\n` at the client boundary (mock and real behave the same).

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --replay-file tmp_bug/rep.jsonl dashboard map Test 85 96 130 10 3
Map 'Test' saved (6 lines)
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --replay-file tmp_bug/rep.jsonl dashboard --offline --out tmp_bug/d.html
tmp_bug\d.html (1 KB, newly written)
[exit 0]

$ python -c "show the first bytes of the <pre> block and count b'\\r\\r\\n' in tmp_bug/d.html"
b'<pre>z=130  x=85..94  y=96..98\r\r\n          9    \r\r\n     5678901234\r\r\n  96 ##########\r\r\n  97 WWWWWWWWWW\r\r\n  98 '
\r\r\n sequences: 5
[exit 0]

$ python -c "print(repr(stdout[:60])) of the first record of fixtures/run5_live/trade_step1.jsonl (a recording of the real dfhack-run)"
'{\r\n\t"caravans": [ {\r\n\t\t"entity": 35,\r\n\t\t"idx": 0,\r\n\t\t"mood":'
[exit 0]

$ python -c "print(chr(13) in MockClient.from_fixture_dir('fixtures/run5').responses['claude/area 130 80 90 40 28'])"
MockClient response for claude/area contains a CR character: False
[exit 0]
```

## Evidence
`Bugs/evidence/BUG-313/` (replay recording, outputs, `live_area_raw.txt`/`.bin` = raw bytes of the live `claude/area` answer).

## Analysis (reporter's hypothesis)
`client.py:216`: `p.stdout.decode("utf-8", errors="replace")` on raw bytes keeps `\r\n`; `MockClient.from_fixture_dir` reads fixtures with `read_text` (universal newlines -> LF even if the checked-out file has CRLF), so the mock-based test-suite never sees CR. `cli.py:889` stores `r.stdout.rstrip("\n")` (leaves `\r`), `dashboard.py:253` writes with `write_text` (Windows adds another `\r`) -> `\r\r\n`. Other places that print or compare raw `stdout` may be affected the same way (not investigated).

## Suggested fix (optional)
Normalise in `RealClient._run`: `out.replace("\r\n", "\n")`; make the mock fixtures reader do the same through one helper; add a replay test with CRLF.

## Info needed
None.

## Fix
Dashboard symptom fixed: stored maps and the rendering normalise CRLF, the page is written as bytes. Normalising `Result.stdout` for all consumers belongs to `client.py:RealClient` (core agent, not changed here).
