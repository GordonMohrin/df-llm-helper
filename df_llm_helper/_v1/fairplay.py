"""(v1, archived by WP4; reached through df_llm_helper.fairplay until v1 is removed)
Fair play (SPEC 3): technically block forbidden commands; exceptions only via the exception register.

Register: data/exceptions.jsonl, one JSON line per exception:
  {"ts": "...", "action": "<rule ID or action>", "objects": [ids], "reason": "...", "player_consent": "<quote>",
   "expires": "<ISO, optional>", "max_uses": <int, optional>}
Without a valid entry (including a non-empty 'player_consent') the command is refused.
An older field name for this value is still accepted as an alias when loading (see LEGACY_CONSENT_KEY).
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

# legacy name of the "player_consent" field in old register files (accepted as an alias when loading)
LEGACY_CONSENT_KEY = "gor" "don_ja"

__all__ = ["FairPlayError", "FORBIDDEN_COMMANDS", "CONSENT_ACTIONS", "check_command", "ExceptionRegistry", "Exception_"]


class FairPlayError(PermissionError):
    def __init__(self, rule: str, msg: str):
        super().__init__(f"[{rule}] {msg}")
        self.rule = rule


# (rule ID, pattern, reason) - checked against the whole command (including lua -e/inline code)
FORBIDDEN_COMMANDS: list[tuple[str, re.Pattern, str]] = [
    ("FP01", re.compile(r"(^|[\s'\"(;])createitem\b"), "createitem creates items out of nothing"),
    ("FP02", re.compile(r"(^|[\s'\"(;])dig-?now\b"), "dig-now digs instantly (not a player route)"),
    ("FP03", re.compile(r"(^|[\s'\"(;])build-?now\b"), "build-now builds instantly"),
    ("FP04", re.compile(r"(^|[\s'\"(;])reveal\b"), "reveal uncovers the map"),
    ("FP05", re.compile(r"(^|[\s'\"(;])prospect\s+all\b"), "prospect all shows hidden ore deposits"),
    ("FP06", re.compile(r"(^|[\s'\"(;])(gui/)?gm-(editor|unit)\b"), "gm-editor/gm-unit = direct data manipulation"),
    ("FP07", re.compile(r"(^|[\s'\"(;])(teleport|cleaners?|fastdwarf|tiletypes|changelayer|changevein|"
                        r"changeitem|full-heal|exterminate|plants\s+create|regrass|liquids|"
                        r"modtools/create-unit|gui/liquids|gui/create-item)\b"), "cheat/editor tool"),
    ("FP08", re.compile(r"flags\d?\.foreign\s*=\s*(false|true)"), "changing the item flag foreign (player exception required)"),
    ("FP09", re.compile(r"flags\d?\.left\s*=\s*true"), "setting unit 'left' (player exception required)"),
    ("FP10", re.compile(r"\.pos\.[xyz]\s*=(?!=)"), "setting position directly (teleport)"),
    ("FP11", re.compile(r"designation\.hidden\s*=(?!=)|\.hidden\s*=\s*false"), "uncovering hidden tiles"),
    ("FP12", re.compile(r"work_weapons[^=\n]*=(?!=)|work_weapons:insert"), "writing work_weapons directly"),
    ("FP13", re.compile(r"\.owner\s*=(?!=)|setOwner\s*\("), "changing the owner directly"),
    # FEATURE-002: the bin planner's writes (one manager order, a stockpile's max_bins) only with the player's consent
    ("FP14", re.compile(r"pilot_hygiene\s+(?:bins_order|max_bins)\b[^\n]*--apply"),
     "bin planner order/stockpile setting (player exception required)"),
]


def check_command(cmd: str, registry: "ExceptionRegistry | None" = None, *, objects: list | None = None) -> None:
    """Raises FairPlayError if the command hits a forbidden rule and no exception exists."""
    for rule, pat, why in FORBIDDEN_COMMANDS:
        if pat.search(cmd):
            if registry is not None and registry.allows(rule, objects=objects, cmd=cmd):
                registry.consume(rule)
                continue
            raise FairPlayError(rule, f"{why}. Refused. An exception requires the player's consent in the register "
                                      f"(python -m df_llm_helper exception add {rule} ...).")


@dataclass
class Exception_:
    action: str
    reason: str
    player_consent: str
    objects: list = field(default_factory=list)
    ts: str = ""
    expires: str | None = None
    max_uses: int | None = None
    cmd_contains: str | None = None


# consent gates that are no command pattern: the feature asks the register before it writes (FEATURE-001/004)
CONSENT_ACTIONS = {
    "OFFICES": "offices --apply: appoint successors via claude/aemter (nobles menu)",
    "HOSPITAL": "hospital staff --apply: fill hospital location posts (location menu) + care labors",
}


def known_rule_ids() -> set[str]:
    """Rule ids an exception can name: the command rules FPnn above, the lint rules Lnn (incl. L31 water) and the
    consent actions (OFFICES, HOSPITAL)."""
    from .lint import RULES          # lazy: lint imports this module
    return {r for r, _, _ in FORBIDDEN_COMMANDS} | {r.id for r in RULES} | {"L31"} | set(CONSENT_ACTIONS)


def _rule_sort(r: str) -> tuple:
    d = r.lstrip("FPL")
    return (not d.isdigit(), r[0], int(d) if d.isdigit() else 0, r)


def parse_expires(value) -> datetime | None:
    """ISO date or timestamp -> the first moment the exception is no longer valid (UTC).
    A date-only value is valid through the END of that day. None if not a real calendar date/time."""
    s = str(value).strip()
    try:
        if re.fullmatch(r"\d{4}-\d\d-\d\d", s):
            d = date.fromisoformat(s)
            return datetime(d.year, d.month, d.day, tzinfo=timezone.utc) + timedelta(days=1)
        if not re.fullmatch(r"\d{4}-\d\d-\d\dT[\d:.]+(?:Z|[+-]\d\d:\d\d)?", s):
            return None
        t = datetime.fromisoformat(s[:-1] + "+00:00" if s.endswith("Z") else s)
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def _objects(raw) -> list[str] | None:
    """Register/CLI objects -> list of numeric id strings; None if invalid (string, junk ids)."""
    if raw is None:
        return []
    if not isinstance(raw, list):
        return None
    out = [str(o).strip() for o in raw]
    if any(not re.fullmatch(r"\d+", o) for o in out):
        return None
    return out


class ExceptionRegistry:
    def __init__(self, path: str | Path | None, now_iso: str | None = None):
        self.path = Path(path) if path else None
        self.entries: list[Exception_] = []
        self.errors: list[str] = []
        self.uses: dict[str, int] = {}
        self._now = now_iso
        self.load()

    @property
    def local_path(self) -> Path:
        return self.path.with_name(self.path.stem + ".local" + self.path.suffix)

    def load(self) -> None:
        self.entries.clear()
        self.errors.clear()
        if not self.path:
            return
        # Shared register + optional local, git-ignored register next to it (exceptions.local.jsonl):
        # player consents for one installation that must not ship with the public repository.
        # A bad line is reported in self.errors and skipped (fail closed: it never grants anything), but it never takes
        # the client down (every command builds this registry).
        lines: list[tuple[str, int, str]] = []
        for f in (self.path, self.local_path):
            if f.is_file():
                try:
                    text = f.read_bytes().decode("utf-8-sig", errors="replace")     # BOM from Notepad/PowerShell
                except OSError as e:
                    self.errors.append(f"{f.name}: not readable ({e.strerror or e})")
                    continue
                lines += [(f.name, no, ln) for no, ln in enumerate(text.splitlines(), 1)]
        prefix = len({n for n, _, _ in lines}) > 1
        for fname, no, line in lines:
            where = f"{fname} line {no}" if prefix else f"line {no}"
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError as e:
                self.errors.append(f"{where}: not JSON ({e.msg})")
                continue
            if not isinstance(d, dict):
                self.errors.append(f"{where}: not a JSON object")
                continue
            if d.get("example"):
                continue
            if "player_consent" not in d and LEGACY_CONSENT_KEY in d:      # old field name (alias)
                d["player_consent"] = d[LEGACY_CONSENT_KEY]
            missing = [k for k in ("action", "reason", "player_consent") if not str(d.get(k, "")).strip()]
            if missing:
                self.errors.append(f"{where}: required field missing: {', '.join(missing)}")
                continue
            objs = _objects(d.get("objects"))
            if objs is None:
                self.errors.append(f"{where}: objects must be a list of numeric ids, got {d.get('objects')!r}")
                continue
            mu = d.get("max_uses")
            if mu is not None and (isinstance(mu, bool) or not isinstance(mu, int) or mu < 1):
                self.errors.append(f"{where}: max_uses must be an integer >= 1, got {mu!r}")
                continue
            exp = d.get("expires")
            if exp is not None and parse_expires(exp) is None:
                self.errors.append(f"{where}: expires is not a real ISO date/time: {exp!r}")
                continue
            self.entries.append(Exception_(action=str(d["action"]), reason=str(d["reason"]),
                                           player_consent=str(d["player_consent"]), objects=objs,
                                           ts=str(d.get("ts", "")), expires=exp, max_uses=mu,
                                           cmd_contains=d.get("cmd_contains")))

    def _now_iso(self) -> str:
        return self._now or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def _expired(self, expires) -> bool:
        end = parse_expires(expires)
        now = parse_expires(self._now_iso())
        return end is None or now is None or now >= end           # unparsable: expired (fail closed)

    def find(self, action: str, *, objects: list | None = None, cmd: str | None = None) -> Exception_ | None:
        for e in self.entries:
            if e.action != action:
                continue
            if e.expires and self._expired(e.expires):
                continue
            if e.max_uses is not None and self.uses.get(action, 0) >= e.max_uses:
                continue
            if objects and e.objects and not set(map(str, objects)) <= set(map(str, e.objects)):
                continue
            if e.objects and cmd is not None and not objects:
                # the exception is bound to objects: all numbers in the command must be allowed
                ids = set(re.findall(r"\b\d{3,}\b", cmd))
                if not ids or not ids <= set(map(str, e.objects)):
                    continue
            if e.cmd_contains and cmd is not None and e.cmd_contains not in cmd:
                continue
            return e
        return None

    def allows(self, action: str, *, objects: list | None = None, cmd: str | None = None) -> bool:
        return self.find(action, objects=objects, cmd=cmd) is not None

    def consume(self, action: str) -> None:
        self.uses[action] = self.uses.get(action, 0) + 1

    def add(self, action: str, reason: str, player_consent: str, objects: list | None = None, *, local: bool = False,
            **extra) -> Exception_:
        """local=True writes to the git-ignored exceptions.local.jsonl (a consent of this player for this installation,
        BUG-418); otherwise to the shared register."""
        if not player_consent.strip():
            raise FairPlayError(action, "an entry without the player's consent is not allowed")
        known = known_rule_ids()
        if action not in known:                                     # a typo would silently never match any rule
            raise FairPlayError(str(action), "unknown rule id (expected one of "
                                             f"{', '.join(sorted(known, key=_rule_sort))})")
        exp = extra.get("expires")
        if exp is not None and parse_expires(exp) is None:
            raise FairPlayError(action, f"expires must be a real ISO date (YYYY-MM-DD, valid through the end of that "
                                        f"day) or timestamp (YYYY-MM-DDTHH:MM:SSZ), got {exp!r}")
        mu = extra.get("max_uses")
        if mu is not None and (isinstance(mu, bool) or not isinstance(mu, int) or mu < 1):
            raise FairPlayError(action, "max_uses must be an integer >= 1")
        objs = _objects(list(objects or []))
        if objs is None:
            raise FairPlayError(action, f"objects must be numeric ids (e.g. 187405,187429), got {objects!r}")
        if not self.path:
            raise FairPlayError(action, "no register path configured")
        d = {"ts": self._now_iso(), "action": action, "objects": objs, "reason": reason,
             "player_consent": player_consent, **{k: v for k, v in extra.items() if v is not None}}
        target = self.local_path if local else self.path
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("a", encoding="utf-8") as f:
            f.write(json.dumps(d, ensure_ascii=False) + "\n")
        self.load()
        # the entry just written (not entries[-1]: the local register is merged after the shared one)
        return Exception_(action=action, reason=reason, player_consent=player_consent, objects=objs, ts=d["ts"],
                          expires=d.get("expires"), max_uses=d.get("max_uses"), cmd_contains=d.get("cmd_contains"))
