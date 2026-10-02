# BUG-307: `memory compact` on a non-UTF-8 (cp1252) memory file replaces all umlauts by U+FFFD and reports a wrong size; `brief`/`agents prompt` show the same replacement characters

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S2
- **Area:** `memory compact` (`df_llm_helper/memory.py:compact_file`), `brief` (`cli.py:cmd_brief`), `agents prompt`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-307/cfg.yaml tmp_bug/cfg.yaml
mkdir tmp_bug/scopes tmp_bug/tools && cp Bugs/evidence/BUG-307/inputs/essen.md tmp_bug/scopes/essen.md     # cp1252 file (Windows PowerShell 5.1 Set-Content default)
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 memory compact essen
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 brief essen
```

## Expected
Memory files written by Windows tools in cp1252 are read tolerantly (like `toolsfs.read_text_tolerant` does for inboxes) or the command refuses; umlauts survive; the printed `A -> B bytes` equals the real file size afterwards.

## Actual
```
$ wc -c tmp_bug/scopes/essen.md
1244 bytes  tmp_bug/scopes/essen.md
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 memory compact essen
essen.md: 1244 -> 1526 bytes, archive essen.20261002T123223.md
[exit 0]

$ python -c "print size/U+FFFD/first lines of tmp_bug/scopes/essen.md"
1586 bytes after compact (the command reported the size above)
contains U+FFFD: True
['# Kopf', '## Offen', '- F�sser pr�fen', '## Durchlauf 1 (short)', 'Zeile � � � � text', 'Zeile � � � � text']
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 brief essen
# Briefing essen
## Mission
Farming, kitchen, mill + bags, hunting/fishing, livestock, winter stock. Never ban-cooking all/seeds or seedwatch.
## Situation Y102 Hematite 12
Food days 189 (target >= 60 (red < 60)); Meals 52 (target > 150 before winter); Fish/meat 20/0 (target -); Hungry >40k 2 (target 0)
## Alerts
- !! Hunger>40k: Tekkud414=47k, Eral3473=40k
## Open (memory)
- F�sser pr�fen
## Last state
- (Durchlauf 11)
- Zeile � � � � text
[... 15 more lines cut]
[... 1 more lines, see evidence]
```

Second symptom, on a normal UTF-8 file (see also `Bugs/evidence/BUG-306/compact.txt`): `militaer.md: 16738 -> 5687 bytes` is printed, the file on disk is 5745 bytes (the reported size is computed from the text before the final write; `write_text` adds CRLF on Windows).
The same happens with LF-only input: Windows `Path.write_text` translates every `\n` into `\r\n`, so the compacted file gets CRLF line endings even though the input had LF.

## Evidence
`Bugs/evidence/BUG-307/` (input file, outputs).

## Analysis (reporter's hypothesis)
`memory.py:147` `raw.decode("utf-8", errors="replace")` then `path.write_text(new, encoding="utf-8")` (line 160): invalid bytes become U+FFFD permanently in the working file (the archive keeps the original, so it is recoverable, but the agent works on the damaged text).
`res["after"] = len(new.encode("utf-8"))` (line 149) is not the size written on Windows (newline translation). `cli.py:cmd_brief` / `agents prompt` read the memory with `errors="replace"` too (`cli.py:378`, `cli.py:844`).

## Suggested fix (optional)
Decode with the tolerant reader (utf-8-sig, then cp1252), write back with `newline=""` and the original line ending style, and compute `after` from the bytes actually written.

## Info needed
Question: are the real memory files (`dwarf-fortress/tools/scopes/*.md`) UTF-8 or cp1252? (They were all UTF-8 in this test run; agents on Windows may write cp1252 via PowerShell.)

## Fix
`compact_file` decodes tolerantly (UTF-8/BOM, UTF-16, cp1252), writes UTF-8 bytes with the original line endings and reports the bytes really written; `brief`/`agents prompt` read memory with `read_text_tolerant`.
