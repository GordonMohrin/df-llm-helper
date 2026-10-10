"""Fair-play rules (v2, WP4): Gordon's decisions and the act.run command allowlist.

    get_decision('D-07') -> 'unchanged'        # config/decisions.yaml, defaults from schema.DECISIONS
    decisions.get(id) / decisions.all() / decisions.pending()
    allowlist() -> dict                         # config/allowlist.json (CONTRACTS §9.14)
    check_run(cmd, args) -> (ok, reason)        # exactly the act.run gate kern implements in Lua
    blocked_match(tokens) -> entry | None
    owned_match(tokens) -> (entry, owner) | None  # commands that only a dedicated act function may run

Normative: docs/v2/CONTRACTS.md §9.14 (allowlist), §9.16 (decisions), docs/v2/DECISIONS.md.
v1 names (ExceptionRegistry, check_command, ...) are forwarded to df_llm_helper._v1.fairplay until
the v1 code is removed from branch v2.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from . import schema

REPO = Path(__file__).resolve().parent.parent
DECISIONS_PATH = REPO / "config" / "decisions.yaml"
ALLOWLIST_PATH = REPO / "config" / "allowlist.json"

# Allowed answers per decision (DESIGN §15, docs/v2/DECISIONS.md). A str is a regex.
CHOICES: dict[str, list[str] | str] = {
    "D-01": ["A", "B"],
    "D-02": r"^[a-z0-9_.:/-]{1,40}$",          # free answer; kernel applies only values it knows
    "D-03": ["rule", "immediate", "off"],
    "D-04": ["off", "on"],
    "D-05": ["off", "on"],
    "D-06": ["off", "on"],
    "D-07": ["unchanged", "visitor30", "visitor30_noweather"],
    "D-08": ["dropped"],                        # the flags1.left edit is never offered again
    "D-09": ["no", "yes"],
    "D-10": ["off", "on"],
    "D-11": ["accepted", "rejected"],
    "D-12": r"^\d{1,2}/\d{1,2}$",
    "D-13": ["no", "yes"],
}

_DECISION_LINE = re.compile(r"^(D-\d\d)\s*:\s*([^#]*?)\s*(#.*)?$")   # CONTRACTS §9.16


def _valid(did: str, value: str) -> bool:
    c = CHOICES[did]
    return value in c if isinstance(c, list) else re.fullmatch(c, value) is not None


def _read(path: Path) -> str:
    try:
        return path.read_bytes().decode("utf-8-sig", errors="replace")
    except OSError:
        return ""


def parse_decision_lines(text: str) -> dict[str, tuple[str, str]]:
    """{id: (value, comment)} for every `D-NN: value  # comment` line."""
    out: dict[str, tuple[str, str]] = {}
    for line in text.splitlines():
        m = _DECISION_LINE.match(line.strip())
        if m and m.group(2):
            out[m.group(1)] = (m.group(2), (m.group(3) or "").lstrip("#").strip())
    return out


def decision_errors(path: str | Path | None = None) -> list[str]:
    errs = []
    for did, (val, _) in parse_decision_lines(_read(Path(path or DECISIONS_PATH))).items():
        if did not in schema.DECISIONS:
            errs.append(f"{did}: unknown decision id")
        elif not _valid(did, val):
            errs.append(f"{did}: invalid value {val!r} (default {schema.DECISIONS[did]!r} applies)")
    return errs


def load_decisions(path: str | Path | None = None) -> dict[str, str]:
    """All 13 decisions; missing or invalid values fall back to the default (off/unchanged)."""
    raw = schema.parse_decisions(_read(Path(path or DECISIONS_PATH)))
    return {did: (raw[did] if did in raw and _valid(did, raw[did]) else dflt)
            for did, dflt in schema.DECISIONS.items()}


def get_decision(did: str, path: str | Path | None = None) -> str:
    if did not in schema.DECISIONS:
        raise KeyError(f"unknown decision {did!r}")
    return load_decisions(path)[did]


def pending(path: str | Path | None = None) -> list[str]:
    """Decisions Gordon has not answered yet: line missing or its comment starts with 'default'."""
    lines = parse_decision_lines(_read(Path(path or DECISIONS_PATH)))
    return [d for d in schema.DECISIONS
            if d not in lines or lines[d][1].lower().startswith("default")]


class _Decisions:
    """`decisions.get(id)` with defaults (DESIGN §12 WP4 interface)."""

    def __init__(self, path: str | Path | None = None):
        self.path = path

    def get(self, did: str) -> str:
        return get_decision(did, self.path)

    def all(self) -> dict[str, str]:
        return load_decisions(self.path)

    def pending(self) -> list[str]:
        return pending(self.path)


decisions = _Decisions()


# ---------------------------------------------------------------- allowlist (CONTRACTS §9.14)
_AL_CACHE: dict[str, tuple[float, dict]] = {}


def allowlist(path: str | Path | None = None) -> dict:
    """Parsed and schema-checked config/allowlist.json (cached by mtime). Raises on an invalid file:
    a broken allowlist must never turn into 'allow everything'."""
    p = Path(path or ALLOWLIST_PATH)
    mt = p.stat().st_mtime
    hit = _AL_CACHE.get(str(p))
    if hit and hit[0] == mt:
        return hit[1]
    doc = json.loads(_read(p))
    schema.check("allowlist", doc)
    _AL_CACHE[str(p)] = (mt, doc)
    return doc


def _toks(s: str) -> list[str]:
    return s.split()


# blocked entries are also checked behind these wrappers: `enable fastdwarf` = fastdwarf
_ENABLERS = (["enable"], ["control-panel", "enable"], ["control-panel", "autostart"])


def blocked_match(tokens: list[str], al: dict | None = None) -> str | None:
    """The blocked entry hit by a command line (as tokens), or None. An entry that is a single flag
    (`--instant`) is blocked anywhere in the line (also as `--instant=x`); any other entry is a
    token prefix of the line, also after an enabling wrapper (`enable X`, `control-panel enable X`)."""
    al = al or allowlist()
    heads = [tokens]
    for w in _ENABLERS:
        if tokens[:len(w)] == w:                     # every listed name: `enable a fastdwarf`
            heads += [tokens[k:] for k in range(len(w), len(tokens))]
    for entry in al["blocked"]:
        et = _toks(entry)
        if not et:
            continue
        if len(et) == 1 and et[0].startswith("-"):
            if any(t == et[0] or t.startswith(et[0] + "=") for t in tokens):
                return entry
            continue
        if any(h[:len(et)] == et for h in heads):
            return entry
    return None


# Actuators with a dedicated act function and a sole owner (DESIGN §3, CONTRACTS §5). act.lua runs these
# commands itself (cmd_run, no allowlist), so they are not in config/allowlist.json, and the lint rule
# `owned-actuator` flags them in K.act.run literals. Token prefixes, also behind enable/disable wrappers.
OWNED = {
    "timestream": "act.timestream (arbiter)",
    "overlay enable": "act.overlay (arbiter)",
    "overlay disable": "act.overlay (arbiter)",
    "enable overlay": "act.overlay (arbiter)",
    "disable overlay": "act.overlay (arbiter)",
    "disable timestream": "act.timestream (arbiter)",
    "disable pop-control": "act.popcap (readiness)",
    "pop-control set max-pop": "act.popcap (readiness)",
    "quickfort": "act.quickfort (runner)",
    "orders": "act.orders_import / act.orders (economy)",
    "workorder": "act.workorder (economy, dfllm: tag)",
    "zone": "act.zone_assign (care)",
    "burrow": "act.quickfort burrow mode (runner) / act.alert_burrows (siege)",
    "gui/civ-alert": "act.civ_alert / act.alert_burrows (siege)",
}
# the R0 cap: baseline sets it only while readiness is not loaded (lua/dfllm/baseline.lua:198)
OWNED_EXEMPT = frozenset({"pop-control set max-pop 55"})
_WRAPPERS = (["enable"], ["disable"], ["control-panel", "enable"], ["control-panel", "disable"])


def owned_match(tokens: list[str]) -> tuple[str, str] | None:
    """(OWNED entry, owner) when a command line belongs to a dedicated act function, else None.
    `control-panel disable a timestream` counts like `disable timestream`."""
    if " ".join(tokens) in OWNED_EXEMPT:
        return None
    heads = [tokens]
    for w in _WRAPPERS:
        if tokens[:len(w)] == w:
            heads += [[w[-1], t] for t in tokens[len(w):]]
    for h in heads:
        for entry, owner in OWNED.items():
            et = entry.split()
            if h[:len(et)] == et:
                return entry, owner
    return None


def match_args(pattern: str, args: list[str]) -> bool:
    """One allowlist pattern against argument tokens: `*` = exactly one token, `**` = any rest
    (also none, last position only), `""` = no arguments, anything else = the literal token."""
    pt = _toks(pattern)
    for i, p in enumerate(pt):
        if p == "**":
            return True
        if i >= len(args) or (p != "*" and p != args[i]):
            return False
    return len(args) == len(pt)


def check_run(cmd: str, args: list[str] | tuple = (), al: dict | None = None) -> tuple[bool, str]:
    """The act.run gate: allowed iff cmd is in `commands`, no `blocked` entry matches and the joined
    args match one pattern (an empty pattern list allows only the bare command)."""
    al = al or allowlist()
    line = _toks(cmd) + _toks(" ".join(str(a) for a in args))
    if not line:
        return False, "empty command"
    b = blocked_match(line, al)
    if b:
        return False, f"blocked: {b}"
    entry = al["commands"].get(line[0])
    if entry is None:
        return False, f"{line[0]}: not in config/allowlist.json"
    rest = line[1:]
    pats = entry["args"] or [""]
    if any(match_args(p, rest) for p in pats):
        return True, "ok"
    return False, f"{line[0]}: arguments not allowed: {' '.join(rest) or '(none)'}"


def is_read_only(cmd: str, al: dict | None = None) -> bool:
    e = (al or allowlist())["commands"].get(cmd)
    return bool(e) and e["rw"] == "r"


def armok_problems(armok_cmds: set[str], al: dict | None = None) -> list[str]:
    """The boot cross-check (DESIGN §11.4) offline: allowlisted commands carrying the armok tag
    that are not listed in armok_exceptions."""
    al = al or allowlist()
    return sorted(c for c in al["commands"] if c in armok_cmds and c not in al["armok_exceptions"])


def __getattr__(name: str):
    """v1 compatibility: names of the archived v1 module (ExceptionRegistry, check_command, ...)."""
    if name.startswith("__"):
        raise AttributeError(name)
    from ._v1 import fairplay as _v1
    try:
        return getattr(_v1, name)
    except AttributeError:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}") from None
