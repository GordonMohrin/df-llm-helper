"""FR-91 / BUG-120: which saves may be loaded. Pure rules over the entries of supervise.scan_saves (no DF call, no file write).

A save folder that DF is writing or died writing is not a save: `autosave 3_tmp` (the temporary name of an autosave that was
cut off, Run 14 note 99), a folder without world.sav, an empty world.sav, a folder that lacks a file all its siblings have.
supervise.pick_save and the manual load (loadnow.py) skip those entries; the newest COMPLETE save is the candidate, never an
older one than that (no save scumming) and never a half-written one.
"""
from __future__ import annotations

import re

TMP_RE = re.compile(r"_tmp\s*$", re.I)       # DF's name of a save while it is written ("autosave 3_tmp")
TMP_FRESH_S = 300                            # files of a _tmp folder younger than this: DF is writing it right now
# files a complete save holds when its sibling saves do (observed offline: only world.sav; world.dat is the companion of
# note 99's wish; the rule fires only when at least COMPANION_MIN other saves all have the file)
COMPANIONS = ("world.dat",)
COMPANION_MIN = 2


def is_tmp(name: str) -> bool:
    return bool(TMP_RE.search(name or ""))


def mark(entries: list, now: float) -> list:
    """Set e["tmp"] (name ends in _tmp), e["bad"] ('' = complete, else why the save is not loadable) and e["writing"]
    (a _tmp folder whose files are younger than TMP_FRESH_S) on every entry. Entries carry name, ws (world.sav present), wss
    (its size), names (top-level file names) and newest (newest file mtime). Returns the list."""
    sib = [e for e in entries if e.get("ws") and not is_tmp(e["name"])]
    for e in entries:
        e["tmp"] = is_tmp(e["name"])
        e["writing"] = e["tmp"] and now - e.get("newest", 0.0) < TMP_FRESH_S
        why = ""
        if e["tmp"]:
            why = ("name ends in _tmp: DF is writing it" if e["writing"] else
                   "name ends in _tmp: DF died while writing it")
        elif not e.get("ws"):
            why = "no world.sav"
        elif e.get("wss", 1) <= 0:
            why = "world.sav is empty"
        else:
            others = [x for x in sib if x is not e]
            names = e.get("names") or []
            for c in COMPANIONS:
                if len(others) >= COMPANION_MIN and c not in names and all(c in (x.get("names") or []) for x in others):
                    why = f"lacks {c}, which the {len(others)} other saves have"
                    break
        e["bad"] = why
    return entries


def complete(entries: list) -> list:
    """The entries that may be loaded, in the order given (newest first)."""
    return [e for e in entries if not e.get("bad")]

