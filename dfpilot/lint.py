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


def R(i, pat, reason, level="error", needs=None, unless_file=None, unless_line=None):
    return Rule(i, re.compile(pat), reason, level, re.compile(needs) if needs else None,
                re.compile(unless_file) if unless_file else None, re.compile(unless_line) if unless_line else None)


RULES: list[Rule] = [
    R("L01", r"\bcreateitem\b|gui/create-item", "createitem creates items out of nothing"),
    R("L02", r"\bdig-?now\b", "dig-now digs instantly"),
    R("L03", r"\bbuild-?now\b", "build-now builds instantly"),
    R("L04", r"['\"]reveal['\"]|run_command\([^)]*\breveal\b|\brevflood\b", "reveal/revflood uncovers the map"),
    R("L05", r"prospect['\",\s]+all|prospect\s+all", "prospect all shows hidden ore deposits"),
    R("L06", r"flags\d?\.foreign\s*=(?!=)", "changing the foreign flag (exception FP08/L06 required)"),
    R("L07", r"flags\d?\.left\s*=\s*true", "setting unit 'left' (stuck traders, exception required)"),
    R("L08", r"\.pos\.[xyz]\s*=(?!=)|setPos\s*\(|teleport", "setting position directly (teleport)",
      unless_line=r"order|\bjob\b|job_item"),
    R("L09", r"\.hidden\s*=\s*false|designation\.hidden\s*=(?!=)", "uncovering hidden tiles"),
    R("L10", r"getTileType\s*\(", "reading a tile without checking 'discovered' (designation.hidden)", "warn",
      unless_file=r"\.hidden\b|isTileVisible|hidden\s*\("),
    R("L11", r"(?<![\w.])(?:[\w.]*equipment\.)?work_weapons\s*(\[[^\]]*\])?\s*=(?![=%])|work_weapons:insert|work_weapons:erase",
      "writing work_weapons directly"),
    R("L12", r"\.owner\s*=(?!=)|setOwner\s*\(|\.owner_id\s*=(?!=)", "changing the owner directly"),
    R("L13", r"flags\.forbid\s*=(?!=)", "forbidding foreign goods (traders/foreign)", needs=r"trader|foreign|caravan"),
    R("L14", r"\.body\.[\w.\[\]]+\s*=(?!=)|wounds:erase|\.wounds\s*=", "changing body/wounds directly"),
    R("L15", r"\.counters2?\.\w+\s*=(?!=)", "setting hunger/thirst/sleep counters directly"),
    R("L16", r"\.rating\s*=(?!=)|\.experience\s*=(?!=)|soul[\w.]*\.skills\[[^]]*\]\s*=(?!=)",
      "setting skills directly"),
    R("L17", r"setTileType\s*\(|\.tiletype\s*=(?!=)|tiletypes\b|changelayer|changevein", "changing terrain"),
    R("L18", r"\.flow_size\s*=(?!=)|\.liquid_type\s*=(?!=)|\bliquids\b", "setting liquids"),
    R("L19", r"df\.global\.world\.raws[\w.\[\]]*\s*=(?!=)", "changing raws at runtime"),
    R("L20", r"\.quality\s*=(?!=)|setQuality\s*\(", "setting item quality"),
    R("L21", r"\b(item|it|itm)\.mat_(type|index)\s*=(?!=)|setMaterial\s*\(", "changing item material"),
    R("L22", r"\.stack_size\s*=(?!=)|setStackSize\s*\(", "changing stack size (quantity)"),
    R("L23", r"flags1\.(caged|inactive|dead)\s*=(?!=)|flags2\.killed\s*=(?!=)", "setting unit state directly"),
    R("L24", r"units\.kill\s*\(|\bexterminate\b|\bslayrace\b", "killing units directly"),
    R("L25", r"\bfastdwarf\b|\bfull-heal\b|\bcleaners?\b|\bregrass\b|\bdeathcause\b|\bgaydar\b",
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
                    not (rule.unless_line and rule.unless_line.search(ln)):
                out.append(Finding(name, no, rule.id, rule.reason, rule.level))
    out.sort(key=lambda f: (f.file, f.line, f.rule))
    return out


def lint_file(path: Path, registry: ExceptionRegistry | None = None) -> list[Finding]:
    return lint_source(Path(path).read_text(encoding="utf-8", errors="replace"), str(path), registry)


def lint_command(cmd: str, registry: ExceptionRegistry | None = None) -> list[Finding]:
    """Check lua "<code>" / lua -e "<code>" / lua -f <file>; check other commands as a line of code."""
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
        files = sorted(p.rglob("*.lua")) if p.is_dir() else [p]
        for f in files:
            try:
                out += lint_file(f, registry)
            except OSError as e:
                out.append(Finding(str(f), 0, "IO", f"not readable: {e}", "warn"))
    return out
