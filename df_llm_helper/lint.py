"""F9 fair-play linter for Lua files and lua commands (static, regex on code without comments).

Rule IDs L01..; an exception only if the rule ID is in the exception register (player consent).
Finding: file:line, rule ID, reason. Existing lua/claude/*.lua files are only reported, not repaired.
"""
from __future__ import annotations

import re
import shlex
import sys
from dataclasses import dataclass
from pathlib import Path

from .fairplay import ExceptionRegistry

__all__ = ["Rule", "RULES", "Finding", "lint_source", "lint_file", "lint_command", "gate_command", "lint_paths",
           "lint_dig"]

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
try:
    from luacheck_min import strip_code
except ImportError:  # pragma: no cover - only if tools/ is missing
    def strip_code(src, keep_strings=False):
        return re.sub(r"--[^\n]*", "", src), []


@dataclass(frozen=True)
class Rule:
    id: str
    pattern: re.Pattern
    reason: str
    level: str = "error"          # error = refuse, warn = report only
    needs: re.Pattern | None = None  # this pattern must additionally occur in the same line
    unless_file: re.Pattern | None = None  # file contains this pattern -> rule does not apply
    unless_line: re.Pattern | None = None  # line contains this pattern -> no finding (e.g. jobs/orders)
    unless_prev: re.Pattern | None = None  # one of the 3 previous lines contains this -> no finding
    unless_near: re.Pattern | None = None  # within NEAR_BEFORE lines before / NEAR_AFTER after -> no finding


NEAR_BEFORE, NEAR_AFTER = 30, 10

# command word used as a DFHack command (inside a string literal or as run_command/run_script argument), not as a
# Lua identifier: 'local tiletypes = {}' is harmless, dfhack.run_command('tiletypes ...') is not
def _cmd(words: str) -> str:
    return (rf"""['"\[][^'"\n]*(?<![\w-])(?:{words})(?![\w-])|run_(?:command|script)\w*\s*\([^)]*(?<![\w-])(?:{words})"""
            rf"""(?![\w-])|^\s*(?:{words})(?![\w-])(?!\s*[=.(\[:,])""")      # last: a bare command line (lint_command)


# "order"/"job" as a word (squad/manager order, job object) - not a substring of border/recorder/jobless
_JOBORDER = r"(?<![A-Za-z])(?:orders?|jobs?)(?![A-Za-z])"


def R(i, pat, reason, level="error", needs=None, unless_file=None, unless_line=None, unless_prev=None,
      unless_near=None):
    return Rule(i, re.compile(pat), reason, level, re.compile(needs) if needs else None,
                re.compile(unless_file) if unless_file else None, re.compile(unless_line) if unless_line else None,
                re.compile(unless_prev) if unless_prev else None, re.compile(unless_near) if unless_near else None)


RULES: list[Rule] = [
    R("L01", r"\bcreateitem\b|gui/create-item", "createitem creates items out of nothing"),
    R("L02", r"\bdig-?now\b", "dig-now digs instantly"),
    R("L03", r"\bbuild-?now\b", "build-now builds instantly"),
    R("L04", r"['\"]\s*reveal\b|run_command\([^)]*\breveal\b|\brevflood\b", "reveal/revflood uncovers the map"),
    R("L05", r"prospect['\",\s]+all|prospect\s+all", "prospect all shows hidden ore deposits"),
    R("L06", r"flags\d?\.foreign\s*=(?!=)", "changing the foreign flag (exception FP08/L06 required)"),
    R("L07", r"flags\d?\.left\s*=\s*true", "setting unit 'left' (stuck traders, exception required)"),
    R("L08", r"\.pos\.[xyz]\s*=(?!=)|\.pos\s*=(?!=)|setPos\s*\(|" + _cmd("teleport") + r"|\bteleport\s*\(",
      "setting position directly (teleport)",
      unless_line=_JOBORDER + r"|job_item",
      unless_prev=r"squad_order_\w+:new\(|\bjob_item\b"),   # target position of a squad order/job object, not a unit
    R("L09", r"\.hidden\s*=\s*false|designation\.hidden\s*=(?!=)", "uncovering hidden tiles"),
    R("L10", r"getTileType\s*\(", "reading a tile without checking 'discovered' (designation.hidden)", "warn",
      unless_near=r"\.hidden\b|isTileVisible|hidden\s*\("),
    R("L11", r"(?<![\w.])(?:[\w.]*equipment\.)?work_weapons\s*(\[[^\]]*\])?\s*=(?![=%])|work_weapons:insert|work_weapons:erase",
      "writing work_weapons directly"),
    R("L12", r"\.owner\s*=(?!=)|setOwner\s*\(|\.owner_id\s*=(?!=)", "changing the owner directly"),
    R("L13", r"flags\.forbid\s*=(?!=)", "forbidding foreign goods (traders/foreign)", needs=r"trader|foreign|caravan"),
    R("L14", r"\.body\.[\w.\[\]]+\s*=(?!=)|wounds:erase|\.wounds\s*=", "changing body/wounds directly"),
    R("L15", r"\.counters2?\.\w+\s*=(?!=)", "setting hunger/thirst/sleep counters directly"),
    R("L16", r"\.rating\s*=(?!=)|\.experience\s*=(?!=)|soul[\w.]*\.skills\[[^]]*\]\s*=(?!=)",
      "setting skills directly"),
    R("L17", r"setTileType\s*\(|\.tiletype\s*(?:\[[^\]]*\]\s*)*=(?!=)|" + _cmd("tiletypes[\w-]*|changelayer|changevein"),
      "changing terrain"),
    R("L18", r"\.flow_size\s*=(?!=)|\.liquid_type\s*=(?!=)|" + _cmd("liquids|gui/liquids"), "setting liquids"),
    R("L19", r"df\.global\.world\.raws[\w.\[\]]*\s*=(?!=)", "changing raws at runtime"),
    R("L20", r"\.quality\s*=(?!=)|setQuality\s*\(", "setting item quality"),
    R("L21", r"\.mat_(?:type|index)\s*=(?!=)|setMaterial\s*\(", "changing item material",
      unless_line=_JOBORDER + r"|job_item|item_filter|reaction",        # material of a job/order/filter = a request
      unless_prev=r"job_item:new\(|job_item_filter|manager_order"),
    R("L22", r"\.stack_size\s*=(?!=)|setStackSize\s*\(", "changing stack size (quantity)"),
    R("L23", r"flags1\.(caged|inactive|dead)\s*=(?!=)|flags2\.killed\s*=(?!=)", "setting unit state directly"),
    R("L24", r"units\.kill\s*\(|\bexterminate\b|\bslayrace\b", "killing units directly"),
    R("L25", _cmd("fastdwarf|full-heal|cleaners?|regrass|deathcause|gaydar") + r"|\bfastdwarf\b|\bfull-heal\b",
      "cheat tool"),
    R("L26", r"gm-editor|gm-unit|gui/gm-", "data editor (direct manipulation)"),
    R("L27", r"\.civ_id\s*=(?!=)|\.population_id\s*=(?!=)|\.hist_figure_id\s*=(?!=)", "changing affiliation"),
    R("L28", r"world\.features|feature_map|underground_region|cavern_layer", "reading cavern/underworld data",
      "warn"),
    R("L29", r"modtools/create-unit|create-unit\b", "creating units"),
    R("L30", r"\bchangeitem\b|\bchangetype\b", "converting items"),
]


@dataclass
class Finding:
    file: str
    line: int
    rule: str
    reason: str
    level: str

    def __str__(self) -> str:
        return f"{self.file}:{self.line}: {self.rule} {self.reason}" + (" (warning)" if self.level == "warn" else "")


def lint_source(src: str, name: str = "<lua>", registry: ExceptionRegistry | None = None,
                rules: list[Rule] | None = None) -> list[Finding]:
    code, _ = strip_code(src, keep_strings=True)
    out: list[Finding] = []
    lines = code.split("\n")
    for rule in rules or RULES:
        if rule.unless_file and rule.unless_file.search(code):
            continue
        if registry is not None and registry.allows(rule.id):
            continue
        for no, ln in enumerate(lines, 1):
            if rule.pattern.search(ln) and (rule.needs is None or rule.needs.search(ln)) and \
                    not (rule.unless_line and rule.unless_line.search(ln)) and \
                    not (rule.unless_prev and rule.unless_prev.search("\n".join(lines[max(0, no - 4):no - 1]))) and \
                    not (rule.unless_near and rule.unless_near.search(
                        "\n".join(lines[max(0, no - 1 - NEAR_BEFORE):no + NEAR_AFTER]))):
                out.append(Finding(name, no, rule.id, rule.reason, rule.level))
    out.sort(key=lambda f: (f.file, f.line, f.rule))
    return out


def lint_file(path: Path, registry: ExceptionRegistry | None = None) -> list[Finding]:
    from .toolsfs import read_text_tolerant
    text = read_text_tolerant(Path(path))         # UTF-8/BOM/UTF-16 (PowerShell)/cp1252: a violation never hides
    if "\x00" in text:                            # UTF-16 without BOM or a binary file: cannot be checked
        return [Finding(str(path), 0, "IO", "not a text file (NUL bytes; save it as UTF-8)", "error")]
    return lint_source(text, str(path), registry)


def lint_command(cmd: str, registry: ExceptionRegistry | None = None) -> list[Finding]:
    """Check lua "<code>" / lua -e "<code>" / lua -f <file>; check other commands as a line of code."""
    mf = re.match(r'\s*lua\s+-f\s+(?:"([^"]+)"|\'([^\']+)\'|(\S+))', cmd)
    if mf:                       # Windows paths (C:\dir\x.lua) must not go through posix shlex: it eats the backslashes
        p = Path(mf.group(1) or mf.group(2) or mf.group(3))
        if not p.exists() and mf.group(3):      # unquoted path with blanks (C:\My Games\x.lua): try the whole rest
            p = Path(cmd[mf.start(3):].strip())
        return lint_file(p, registry) if p.exists() else []
    try:
        parts = shlex.split(cmd, posix=True)
    except ValueError:
        parts = cmd.split()
    if parts and parts[0] == "lua":
        if len(parts) >= 3 and parts[1] == "-f":
            p = Path(parts[2])
            return lint_file(p, registry) if p.exists() else []
        code = " ".join(parts[2:] if len(parts) > 2 and parts[1] == "-e" else parts[1:])
        return lint_source(code, "lua-command", registry)
    return lint_source(cmd, "command", registry)


_DIG = re.compile(r"^claude/dig\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)(?:\s+(\w))?")
_QF = re.compile(r"^quickfort\s+(?:run|orders)\s+(\S+).*?(?:-c|--cursor)[\s=]+(-?\d+),(-?\d+),(-?\d+)")


def _overlap(a, b) -> bool:
    return all(min(a[i], a[i + 3]) <= max(b[i], b[i + 3]) and min(b[i], b[i + 3]) <= max(a[i], a[i + 3])
               for i in range(3))


def lint_dig(cmd: str, boxes: list | None, registry: ExceptionRegistry | None = None) -> list[Finding]:
    """Spec 08 (L31): refuse dig orders in water exclusion boxes (water.forbid_dig).
    claude/dig z x1 y1 x2 y2 [mode] (mode x = removing an order is allowed); quickfort run <dig grid> -c x,y,z
    (cursor inside the box; conservative, grid extent unknown)."""
    if not boxes or (registry is not None and registry.allows("L31")):
        return []
    c = " ".join(cmd.strip().split())
    area = None
    m = _DIG.match(c)
    if m and (m.group(6) or "d") != "x":
        z, x1, y1, x2, y2 = (int(m.group(i)) for i in range(1, 6))
        area = (x1, y1, z, x2, y2, z)
    q = _QF.match(c)
    if q and "dig" in q.group(1).lower():
        x, y, z = int(q.group(2)), int(q.group(3)), int(q.group(4))
        area = (x, y, z, x, y, z)
    if area is None:
        return []
    return [Finding("command", 1, "L31", f"Dig order in water exclusion box {list(b)} (flood risk, water.forbid_dig)",
                    "error") for b in boxes if _overlap(area, b)][:1]


def gate_command(registry: ExceptionRegistry | None, forbid_dig: list | None = None):
    """For RealClient: returns findings (error level only) that prevent execution."""
    def gate(cmd: str) -> list[Finding]:
        return [f for f in lint_command(cmd, registry) if f.level == "error"] + lint_dig(cmd, forbid_dig, registry)
    return gate


def lint_paths(paths: list[Path], registry: ExceptionRegistry | None = None) -> list[Finding]:
    out: list[Finding] = []
    for p in paths:
        p = Path(p)
        if not p.exists():                         # a typo in a gate 'lint <path>' must not pass
            out.append(Finding(str(p), 0, "IO", "no such file or directory", "error"))
            continue
        files = sorted(p.rglob("*.lua")) if p.is_dir() else [p]
        for f in files:
            try:
                out += lint_file(f, registry)
            except OSError as e:
                out.append(Finding(str(f), 0, "IO", f"not readable: {e}", "error"))
    return out
