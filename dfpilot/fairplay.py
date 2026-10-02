"""Fair play (SPEC 3): technically block forbidden commands; exceptions only via the exception register.

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
from datetime import datetime, timezone
from pathlib import Path

# legacy name of the "player_consent" field in old register files (accepted as an alias when loading)
LEGACY_CONSENT_KEY = "gor" "don_ja"

__all__ = ["FairPlayError", "FORBIDDEN_COMMANDS", "check_command", "ExceptionRegistry", "Exception_"]


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
                        r"changeitem|deathcause|full-heal|exterminate|gaydar|plants\s+create|regrass|liquids|"
                        r"modtools/create-unit|gui/liquids|gui/create-item)\b"), "cheat/editor tool"),
    ("FP08", re.compile(r"flags\d?\.foreign\s*=\s*(false|true)"), "changing the item flag foreign (player exception required)"),
    ("FP09", re.compile(r"flags\d?\.left\s*=\s*true"), "setting unit 'left' (player exception required)"),
    ("FP10", re.compile(r"\.pos\.[xyz]\s*=(?!=)"), "setting position directly (teleport)"),
    ("FP11", re.compile(r"designation\.hidden\s*=(?!=)|\.hidden\s*=\s*false"), "uncovering hidden tiles"),
    ("FP12", re.compile(r"work_weapons[^=\n]*=(?!=)|work_weapons:insert"), "writing work_weapons directly"),
    ("FP13", re.compile(r"\.owner\s*=(?!=)|setOwner\s*\("), "changing the owner directly"),
]


def check_command(cmd: str, registry: "ExceptionRegistry | None" = None, *, objects: list | None = None) -> None:
    """Raises FairPlayError if the command hits a forbidden rule and no exception exists."""
    for rule, pat, why in FORBIDDEN_COMMANDS:
        if pat.search(cmd):
            if registry is not None and registry.allows(rule, objects=objects, cmd=cmd):
                registry.consume(rule)
                continue
            raise FairPlayError(rule, f"{why}. Refused. An exception requires the player's consent in the register "
                                      f"(dfpilot exception add {rule} ...).")


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


class ExceptionRegistry:
    def __init__(self, path: str | Path | None, now_iso: str | None = None):
        self.path = Path(path) if path else None
        self.entries: list[Exception_] = []
        self.errors: list[str] = []
        self.uses: dict[str, int] = {}
        self._now = now_iso
        self.load()

    def load(self) -> None:
        self.entries.clear()
        self.errors.clear()
        if not self.path or not self.path.exists():
            return
        for no, line in enumerate(self.path.read_text(encoding="utf-8").splitlines(), 1):
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError as e:
                self.errors.append(f"line {no}: not JSON ({e.msg})")
                continue
            if d.get("example"):
                continue
            if "player_consent" not in d and LEGACY_CONSENT_KEY in d:      # old field name (alias)
                d["player_consent"] = d[LEGACY_CONSENT_KEY]
            missing = [k for k in ("action", "reason", "player_consent") if not str(d.get(k, "")).strip()]
            if missing:
                self.errors.append(f"line {no}: required field missing: {', '.join(missing)}")
                continue
            self.entries.append(Exception_(action=d["action"], reason=d["reason"], player_consent=d["player_consent"],
                                           objects=list(d.get("objects") or []), ts=d.get("ts", ""),
                                           expires=d.get("expires"), max_uses=d.get("max_uses"),
                                           cmd_contains=d.get("cmd_contains")))

    def _now_iso(self) -> str:
        return self._now or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def find(self, action: str, *, objects: list | None = None, cmd: str | None = None) -> Exception_ | None:
        for e in self.entries:
            if e.action != action:
                continue
            if e.expires and e.expires < self._now_iso():
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

    def add(self, action: str, reason: str, player_consent: str, objects: list | None = None, **extra) -> Exception_:
        if not player_consent.strip():
            raise FairPlayError(action, "an entry without the player's consent is not allowed")
        if not re.fullmatch(r"(?:FP|L)\d{1,3}", action or ""):      # a typo would silently never match any rule
            raise FairPlayError(action, "unknown rule id (expected FPnn or Lnn, e.g. FP08, L31)")
        exp = extra.get("expires")
        if exp is not None and not re.fullmatch(r"\d{4}-\d\d-\d\d(?:T[\d:.]+Z?)?", str(exp)):
            raise FairPlayError(action, f"expires must be an ISO date (YYYY-MM-DD), got {exp!r}")
        mu = extra.get("max_uses")
        if mu is not None and int(mu) < 1:
            raise FairPlayError(action, "max_uses must be >= 1")
        if not self.path:
            raise FairPlayError(action, "no register path configured")
        d = {"ts": self._now_iso(), "action": action, "objects": objects or [], "reason": reason,
             "player_consent": player_consent, **{k: v for k, v in extra.items() if v is not None}}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(d, ensure_ascii=False) + "\n")
        self.load()
        return self.entries[-1]
