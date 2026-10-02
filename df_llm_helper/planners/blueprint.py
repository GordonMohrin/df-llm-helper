"""Blueprint validator for quickfort CSV (SPEC F11.5 / appendix C), pure function, no DF calls.

Format (simplified, see appendix C): section header ``#dig``, ``#build``, ``#place``, ``#zone`` (optionally followed by text,
e.g. ``#build label(x) workshops``), then rows = y, columns = x, cell = tile. Cells:
``<key>[{properties}][(WxH)]``, e.g. ``Cw``, ``D(5x5)``, ``m{location=hospital allow=residents}(7x7)``.
``#<`` / ``#>`` (optionally with a number) change the level. Passive headers (``#notes``, ``#meta``, ``#query``, ``#ignore``,
``#aliases``) are accepted and their content is not checked. A line ``# comment`` is NOT a valid header (E_HEAD).

Assumptions (verify live against quickfort):
- Cells with ``(WxH)`` occupy a rectangle with the cell as the top-left corner (negative values: to the left/up);
  ``(WxHxD)`` additionally occupies D levels. Without a size, workshops/furnaces (``w?``/``e?``) occupy 3x3 and the
  trade depot key ``D`` in #build 5x5, each centered on the cell, everything else 1x1.
- Zone keys: the full quickfort zone table (``hack/scripts/internal/quickfort/zone.lua``): m b h n p w j f s o D B a d t T g c;
  parameter ``zone_keys`` is extensible (BUG-109).
- Cells may be CSV-quoted (``"n{name=""Nest""}"``, needed when a cell contains ``"``); they are unquoted first.
- quickfort accepts a building key in EVERY tile of its footprint (``wj,wj,wj`` x 3): identical adjacent keys without a
  size are one building (their bounding box), not overlapping buildings.
- W_COLS only for a row with content beyond the width of the section's first row (ragged/filler rows are normal).
- Overlaps are checked per section (#build/#place: error, #zone: only identical keys as a warning).
- The lower map boundary is only checked against ``origin`` if ``origin`` is given.
"""
from __future__ import annotations

import re
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Iterable, Optional, Sequence

__all__ = ["Finding", "CODES", "ZONE_KEYS", "validate_blueprint", "has_errors"]

# quickfort zone keys (DFHack quickfort zone.lua): m Meeting area, b Bedroom, h Dining hall, n Pen/pasture, p Pit/pond,
# w Water source, j Dungeon, f Fishing, s Sand, o Office, D Dormitory, B Barracks, a Archery range, d Garbage dump,
# t Animal training, T Tomb, g Gather fruit, c Clay
ZONE_KEYS = frozenset("mbhnpwjfsoDBadtTgc")
ACTIVE_MODES = ("dig", "build", "place", "zone")
PASSIVE_MODES = ("notes", "meta", "query", "ignore", "aliases")
MAX_EXTENT = 10_000
MAX_DEPTH = 1_000

# code -> (level, description)
CODES: dict[str, tuple[str, str]] = {
    "E_EMPTY": ("error", "empty file"),
    "E_NOSECTION": ("error", "cells without a section header"),
    "E_HEAD": ("error", "unknown/broken section header"),
    "E_PAREN": ("error", "unbalanced round brackets"),
    "E_BRACE": ("error", "unbalanced curly brackets"),
    "E_QUOTE": ("error", "unbalanced quotation marks"),
    "E_SIZE": ("error", "broken size specification (WxH)"),
    "E_CELL": ("error", "invalid cell"),
    "E_ZONEKEY": ("error", "unknown zone key"),
    "E_OVERLAP": ("error", "footprints overlap"),
    "E_BOUNDS": ("error", "footprint outside the map"),
    "W_ORDER": ("warning", "#dig comes after #build: dig first"),
    "W_COLS": ("warning", "differing column counts"),
    "W_PROP": ("warning", "property without key=value"),
    "W_EMPTY_SECTION": ("warning", "section without cells"),
    "W_ZONE_OVERLAP": ("warning", "zones of the same type overlap"),
}

_KEY_CHARS = re.compile(r"[A-Za-z0-9_~+\-]")
_EXT = re.compile(r"^\s*(-?\d+)\s*x\s*(-?\d+)(?:\s*x\s*(-?\d+))?\s*$")
_ZMARK = re.compile(r"^#\s*([<>])\s*(\d*)\s*$")
_FIXED_WE = re.compile(r"^[we][A-Za-z]$")


@dataclass(frozen=True)
class Finding:
    line: int      # 1-based file line
    col: int       # 1-based cell (x + 1) in the grid; 1 for header/line errors
    code: str
    msg: str
    level: str     # "error" | "warning"

    def __str__(self) -> str:
        return f"{self.line}:{self.col} {self.level} {self.code} {self.msg}"


def has_errors(findings: Iterable[Finding]) -> bool:
    return any(f.level == "error" for f in findings)


@dataclass
class _Rect:
    z: int
    x1: int
    y1: int
    x2: int
    y2: int
    key: str
    line: int
    col: int
    idx: int


@dataclass
class _Section:
    mode: str
    line: int
    y: int = 0
    z: int = 0
    ncols: Optional[int] = None
    cells: int = 0
    pending: list = field(default_factory=list)     # multi-tile build cells without size (filled footprints)


def _components(cells: list) -> list[list]:
    """Groups (key, x, y, z, line, col) cells: same key and level, 4-neighbours -> one group (input order kept)."""
    pos = {(c[0], c[3], c[1], c[2]): i for i, c in enumerate(cells)}
    seen: set = set()
    out = []
    for i, c in enumerate(cells):
        if i in seen:
            continue
        comp, stack = [], [i]
        seen.add(i)
        while stack:
            j = stack.pop()
            comp.append(cells[j])
            k, x, y, z = cells[j][0], cells[j][1], cells[j][2], cells[j][3]
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                n = pos.get((k, z, x + dx, y + dy))
                if n is not None and n not in seen:
                    seen.add(n)
                    stack.append(n)
        comp.sort(key=lambda t: (t[4], t[5]))
        out.append(comp)
    return out


def _split_cells(line: str) -> list[str]:
    """Splits at commas outside of {...} and quotation marks."""
    cells: list[str] = []
    buf: list[str] = []
    depth = 0
    quoted = False
    for ch in line:
        if ch == '"':
            quoted = not quoted
        elif not quoted:
            if ch == "{":
                depth += 1
            elif ch == "}" and depth > 0:
                depth -= 1
            elif ch == "," and depth == 0:
                cells.append("".join(buf))
                buf = []
                continue
        buf.append(ch)
    cells.append("".join(buf))
    return cells


def _find_close_brace(cell: str, start: int) -> int:
    quoted = False
    for i in range(start + 1, len(cell)):
        ch = cell[i]
        if ch == '"':
            quoted = not quoted
        elif ch == "}" and not quoted:
            return i
    return -1


def _balance_errors(text: str) -> list[tuple[str, str]]:
    """Bracket check for header text (without quotation-mark logic)."""
    errs = []
    if text.count("(") != text.count(")"):
        errs.append(("E_PAREN", f"round brackets unbalanced ({text.count('(')} open, {text.count(')')} closed)"))
    if text.count("{") != text.count("}"):
        errs.append(("E_BRACE", f"curly brackets unbalanced ({text.count('{')} open, {text.count('}')} closed)"))
    return errs


def _parse_extent(text: str) -> tuple[Optional[tuple[int, int, int]], Optional[str]]:
    m = _EXT.match(text)
    if not m:
        return None, f"size specification ({text}) is not (WidthxHeight)"
    w, h = int(m.group(1)), int(m.group(2))
    d = int(m.group(3)) if m.group(3) is not None else 1
    if w == 0 or h == 0 or d == 0:
        return None, f"size specification ({text}) contains 0"
    if abs(w) > MAX_EXTENT or abs(h) > MAX_EXTENT or abs(d) > MAX_DEPTH:
        return None, f"size specification ({text}) implausibly large"
    return (w, h, d), None


def _parse_cell(cell: str):
    """Splits a cell. Returns (key, props, extent, errors[(code, msg)])."""
    errs: list[tuple[str, str]] = []
    n = len(cell)
    i = 0
    while i < n and cell[i] not in "({":
        i += 1
    key = cell[:i]
    for ch in key:
        if ch == ")":
            errs.append(("E_PAREN", "closing bracket ')' without an opening one"))
            return key, None, None, errs
        if ch == "}":
            errs.append(("E_BRACE", "closing bracket '}' without an opening one"))
            return key, None, None, errs
        if not _KEY_CHARS.match(ch):
            errs.append(("E_CELL", f"invalid character {ch!r} in key {key!r}"))
            return key, None, None, errs
    if not key:
        errs.append(("E_CELL", "cell without a key"))
        return key, None, None, errs
    props: Optional[str] = None
    ext: Optional[tuple[int, int, int]] = None
    seen_ext = False
    while i < n:
        ch = cell[i]
        if ch == "{":
            j = _find_close_brace(cell, i)
            if j < 0:
                code = "E_QUOTE" if cell[i:].count('"') % 2 else "E_BRACE"
                msg = "quotation mark not closed" if code == "E_QUOTE" else "'{' without a closing '}'"
                errs.append((code, msg))
                break
            if props is not None:
                errs.append(("E_CELL", "several {..} groups in one cell"))
                break
            props = cell[i + 1:j]
            i = j + 1
        elif ch == "(":
            j = cell.find(")", i)
            if j < 0:
                errs.append(("E_PAREN", "'(' without a closing ')'"))
                break
            if seen_ext:
                errs.append(("E_CELL", "several (WxH) groups in one cell"))
                break
            seen_ext = True
            ext, err = _parse_extent(cell[i + 1:j])
            if err:
                errs.append(("E_SIZE", err))
                break
            i = j + 1
        elif ch == ")":
            errs.append(("E_PAREN", "closing bracket ')' without an opening one"))
            break
        elif ch == "}":
            errs.append(("E_BRACE", "closing bracket '}' without an opening one"))
            break
        else:
            errs.append(("E_CELL", f"unexpected character {ch!r} after the group"))
            break
    return key, props, ext, errs


def _prop_problems(props: str) -> list[str]:
    bad = []
    for tok in re.findall(r'(?:[^\s"]|"[^"]*")+', props):
        name, eq, _ = tok.partition("=")
        if not eq or not name:
            bad.append(tok)
    return bad


def _fixed_size(mode: str, key: str) -> tuple[int, int]:
    if mode == "build":
        if key == "D":
            return 5, 5
        if _FIXED_WE.match(key):
            return 3, 3
    return 1, 1


def _rects(mode: str, key: str, ext, x: int, y: int, z: int, line: int, col: int, idx0: int) -> list[_Rect]:
    if ext is not None:
        w, h, d = ext
        x1 = x if w > 0 else x + w + 1
        y1 = y if h > 0 else y + h + 1
        x2, y2 = x1 + abs(w) - 1, y1 + abs(h) - 1
        zs = range(z, z + d) if d > 0 else range(z + d + 1, z + 1)
    else:
        w, h = _fixed_size(mode, key)
        x1, y1 = x - w // 2, y - h // 2
        x2, y2 = x1 + w - 1, y1 + h - 1
        zs = range(z, z + 1)
    return [_Rect(zz, x1, y1, x2, y2, key, line, col, idx0 + k) for k, zz in enumerate(zs)]


def _overlaps(rects: Sequence[_Rect]) -> dict[int, _Rect]:
    """For each later rectangle index the first earlier overlapping rectangle (sweep per level)."""
    found: dict[int, _Rect] = {}
    by_z: dict[int, list[_Rect]] = defaultdict(list)
    for r in rects:
        by_z[r.z].append(r)
    for rs in by_z.values():
        rs = sorted(rs, key=lambda r: (r.x1, r.y1, r.idx))
        active: list[_Rect] = []
        for r in rs:
            active = [a for a in active if a.x2 >= r.x1]
            for a in active:
                if a.y1 <= r.y2 and r.y1 <= a.y2:
                    early, late = (a, r) if a.idx < r.idx else (r, a)
                    if late.idx not in found or early.idx < found[late.idx].idx:
                        found[late.idx] = early
            active.append(r)
    return found


def validate_blueprint(text: str, map_size: Optional[Sequence[int]] = None, origin: Optional[tuple[int, int]] = None,
                       zone_keys: Iterable[str] = ZONE_KEYS) -> list[Finding]:
    """Checks quickfort CSV text; result sorted by (line, column). See the module docs and ``CODES``."""
    findings: list[Finding] = []

    def add(line: int, col: int, code: str, msg: str) -> None:
        findings.append(Finding(line, col, code, msg, CODES[code][0]))

    zones = frozenset(zone_keys)
    text = text.lstrip("﻿")
    if not text.strip(" \t\r\n,"):
        add(1, 1, "E_EMPTY", "File is empty (no section, no cells)")
        return findings

    sec: Optional[_Section] = None
    passive = False
    nosection_reported = False
    first_build: Optional[int] = None
    sec_rects: list[_Rect] = []
    rect_idx = 0
    mx = my = None
    if map_size is not None:
        mx, my = int(map_size[0]), int(map_size[1])

    def check_bounds(rs: Sequence[_Rect], ln: int, col: int) -> None:
        if mx is None or my is None:
            return
        for r in rs:
            ox, oy = origin if origin is not None else (0, 0)
            low = origin is not None and (r.x1 + ox < 0 or r.y1 + oy < 0)
            if r.x2 + ox >= mx or r.y2 + oy >= my or low:
                add(ln, col, "E_BOUNDS",
                    f"footprint x{r.x1 + ox}..{r.x2 + ox} y{r.y1 + oy}..{r.y2 + oy} lies outside the map {mx}x{my}")

    def flush() -> None:
        nonlocal sec, sec_rects, rect_idx
        if sec is None:
            return
        for comp in _components(sec.pending):
            key, x, y, z, ln0, col0 = comp[0]
            if len(comp) == 1:
                rs = _rects(sec.mode, key, None, x, y, z, ln0, col0, rect_idx)
            else:                                  # identical adjacent keys = one building filling its footprint
                xs, ys = [c[1] for c in comp], [c[2] for c in comp]
                rs = [_Rect(z, min(xs), min(ys), max(xs), max(ys), key, ln0, col0, rect_idx)]
            rect_idx += len(rs)
            check_bounds(rs, ln0, col0)
            sec_rects.extend(rs)
        if sec.cells == 0:
            add(sec.line, 1, "W_EMPTY_SECTION", f"#{sec.mode} without cells")
        if sec.mode in ("build", "place"):
            for late_idx, early in _overlaps(sec_rects).items():
                late = next(r for r in sec_rects if r.idx == late_idx)
                add(late.line, late.col, "E_OVERLAP",
                    f"{late.key!r} overlaps {early.key!r} (line {early.line}, column {early.col}) on level {late.z}")
        elif sec.mode == "zone":
            by_key: dict[str, list[_Rect]] = defaultdict(list)
            for r in sec_rects:
                by_key[r.key].append(r)
            for key, rs in by_key.items():
                for late_idx, early in _overlaps(rs).items():
                    late = next(r for r in rs if r.idx == late_idx)
                    add(late.line, late.col, "W_ZONE_OVERLAP",
                        f"Zone {key!r} overlaps a zone of the same type (line {early.line}, column {early.col})")
        sec = None
        sec_rects = []

    for ln, raw in enumerate(text.splitlines(), 1):
        stripped = raw.strip()
        if stripped.startswith("#"):
            zm = _ZMARK.match(stripped.rstrip(", \t") or "#")
            if zm:
                if sec is None:
                    if not passive and not nosection_reported:
                        add(ln, 1, "E_NOSECTION", "level marker without a preceding section header")
                        nosection_reported = True
                else:
                    steps = int(zm.group(2) or 1)
                    sec.z += steps if zm.group(1) == ">" else -steps
                    sec.y = 0
                    sec.ncols = None
                continue
            head = stripped.rstrip(", \t")
            if len(head) < 2 or not head[1].isalpha():
                add(ln, 1, "E_HEAD", f"header line without a mode: {head[:30]!r} (comment lines are not allowed in quickfort)")
                continue
            flush()
            passive = False
            token = head[1:].split(None, 1)[0]
            mode = token.lower()
            rest = head[1 + len(token):]
            for code, msg in _balance_errors(rest):
                add(ln, 1, code, f"in header: {msg}")
            if mode in ACTIVE_MODES:
                if mode == "dig" and first_build is not None:
                    add(ln, 1, "W_ORDER", f"#dig after #build (line {first_build}): dig first")
                if mode == "build" and first_build is None:
                    first_build = ln
                sec = _Section(mode, ln)
            elif mode in PASSIVE_MODES:
                passive = True
            else:
                add(ln, 1, "E_HEAD", f"unknown header '#{token}' (allowed: {', '.join(ACTIVE_MODES + PASSIVE_MODES)})")
                sec = _Section("?", ln)   # still check the cells syntactically
            continue

        if passive:
            continue
        if sec is None:
            if stripped.strip(","):
                if not nosection_reported:
                    add(ln, 1, "E_NOSECTION", "cells before the first section header")
                    nosection_reported = True
            continue
        if not stripped:                      # genuine blank line = empty row of the grid
            sec.y += 1
            continue

        cells = _split_cells(raw.rstrip("\r\n"))
        used = len(cells)
        while used and not cells[used - 1].strip():
            used -= 1
        if sec.ncols is None:
            sec.ncols = len(cells)
        elif used > sec.ncols:
            add(ln, 1, "W_COLS", f"content in {used} columns, the section's first row has {sec.ncols}")
        for x, cell in enumerate(cells):
            cell = cell.strip()
            if len(cell) >= 2 and cell[0] == '"' and cell[-1] == '"':      # CSV quoting (BUG-109)
                cell = cell[1:-1].replace('""', '"').strip()
            if not cell:
                continue
            col = x + 1
            sec.cells += 1
            key, props, ext, errs = _parse_cell(cell)
            for code, msg in errs:
                add(ln, col, code, f"{msg} (cell {cell[:30]!r})")
            if errs:
                continue
            if sec.mode == "zone" and key not in zones:
                add(ln, col, "E_ZONEKEY", f"unknown zone key {key!r} (allowed: {''.join(sorted(zones))})")
                continue
            if props:
                for tok in _prop_problems(props):
                    add(ln, col, "W_PROP", f"property {tok!r} without key=value")
            if ext is None and sec.mode == "build" and _fixed_size(sec.mode, key) != (1, 1):
                sec.pending.append((key, x, sec.y, sec.z, ln, col))   # maybe a filled footprint: decided in flush()
                continue
            rects = _rects(sec.mode, key, ext, x, sec.y, sec.z, ln, col, rect_idx)
            rect_idx += len(rects)
            check_bounds(rects[:1], ln, col)
            if sec.mode in ("build", "place", "zone"):
                sec_rects.extend(rects)
        sec.y += 1
    flush()
    findings.sort(key=lambda f: (f.line, f.col, f.code))
    return findings
