"""Spec v3-09: settings manager (`python -m df_llm_helper settings`).

Game settings that DF reads only at start (prefs/d_init.txt: POPULATION_CAP, STRICT_POPULATION_CAP, BABY_CHILD_CAP,
VISITOR_CAP) are changed safely, backed up and documented:
- get [KEY]          current value, default, effect time, description (data/settings.yaml)
- set KEY VALUE --reason "<player quote>"
                     backup d_init.txt.bak-<date> first, change exactly one line (rest byte-identical), log in state.db,
                     report 'takes effect only after a restart'
- pending            changes waiting for a restart (the check shows one line, at most every hint_every_s)
- verify             file still has the new value AND DF was restarted after the change (DF uptime via
                     dfhack.getTickCount() < age of the change) -> verified; plus a population hint
- revert KEY         puts the original line back (byte-identical file when it was the only change)
- restart-plan       the restart steps (pause, save, pause.hold, restart, python -m df_llm_helper reboot, settings verify)
Write boundary: ONLY the configured d_init file and the backup folder (enforced in _write; state.db aside).
Unknown keys and invalid values are refused before anything is written.
"""
from __future__ import annotations

import re
from pathlib import Path

from .. import yamlmini
from ..client import register_read

__all__ = ["KEY", "DEFAULTS", "UPTIME_CMD", "SettingsError", "Settings", "load_known", "parse_lines", "register",
           "check_hook"]

KEY = "settings"
DEFAULTS = {"file": None,            # None = <DF folder of dfhack_run>/prefs/d_init.txt (verify the path once)
            "backup_dir": None,      # None = <folder of file>/backups
            "known": "data/settings.yaml", "hint_every_s": 1800, "in_check": True}
UPTIME_CMD = 'lua "print(dfhack.getTickCount())"'      # ms since the DF process started (read only)
register_read(UPTIME_CMD)

_LINE = re.compile(rb"^(?P<pre>[ \t]*\[)(?P<key>[A-Z_0-9]+):(?P<val>[^\]\r\n]*)(?P<post>\].*?)(?P<eol>\r?\n?)\Z",
                   re.DOTALL)


class SettingsError(ValueError):
    pass


def load_known(path: Path) -> dict[str, dict]:
    d = yamlmini.load_file(path) or {}
    out = {}
    for e in d.get("settings") or []:
        if not isinstance(e, dict) or not e.get("key") or e.get("type") not in ("int", "int_pair"):
            raise SettingsError(f"{path}: invalid entry {e!r}")
        out[e["key"]] = e
    return out


def parse_lines(data: bytes) -> list[tuple[int, str, str]]:
    """[(line index, KEY, value)] of all '[KEY:value]' lines."""
    out = []
    for i, ln in enumerate(data.splitlines(keepends=True)):
        m = _LINE.match(ln)
        if m:
            out.append((i, m.group("key").decode("ascii"), m.group("val").decode("latin-1")))
    return out


class Settings:
    def __init__(self, store, clock, cfg: dict | None = None, *, home: Path, dfhack_run: str | None = None,
                 client=None):
        self.store, self.clock, self.client = store, clock, client
        self.cfg = {**DEFAULTS, **(cfg or {})}
        self.home = Path(home)
        f = self.cfg.get("file")
        if not f:
            base = Path(str(dfhack_run or "").replace("\\", "/")).parent.parent
            f = base / "prefs" / "d_init.txt"
        self.file = Path(f)
        self.backup_dir = Path(self.cfg.get("backup_dir") or (self.file.parent / "backups"))
        kp = Path(self.cfg["known"])
        self.known = load_known(kp if kp.is_absolute() else self.home / kp)

    # ---------------------------------------------------------------- write boundary (acceptance 5)
    def _allowed(self, path: Path) -> bool:
        p = Path(path).resolve()
        bd = self.backup_dir.resolve()
        return p == self.file.resolve() or bd in p.parents

    def _write(self, path: Path, data: bytes) -> None:
        if not self._allowed(path):
            raise PermissionError(f"settings: write refused: {path} is neither {self.file} nor below {self.backup_dir}")
        path = Path(path)
        if path != self.file and not self.backup_dir.exists():
            self.backup_dir.mkdir(parents=True, exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)

    # ---------------------------------------------------------------- reading
    def read(self) -> bytes:
        if not self.file.is_file():
            raise SettingsError(f"settings file not found: {self.file} (set settings.file in config.yaml)")
        return self.file.read_bytes()

    def values(self) -> dict[str, str]:
        return {k: v for _, k, v in parse_lines(self.read())}

    def get(self, key: str | None = None) -> list[str]:
        vals = self.values()
        keys = [key] if key else list(self.known)
        out = []
        for k in keys:
            if k not in self.known:
                raise SettingsError(f"unknown key {k} (known: {', '.join(self.known)})")
            e = self.known[k]
            pend = self.pending().get(k)
            out.append(f"{k} = {vals.get(k, '(missing)')} (default {e.get('default')}, effect: "
                       f"{'after restart' if e.get('effect') == 'restart' else 'immediate'})"
                       + (f" [pending restart: {pend['old']} -> {pend['new']}]" if pend else "")
                       + f" - {e.get('description', '')}")
        return out

    def validate(self, key: str, value: str) -> str:
        e = self.known.get(key)
        if e is None:
            raise SettingsError(f"unknown key {key} (known: {', '.join(self.known)})")
        parts = str(value).strip().split(":")
        want = 2 if e["type"] == "int_pair" else 1
        if len(parts) != want or not all(re.fullmatch(r"\d{1,6}", p) for p in parts):
            raise SettingsError(f"invalid value {value!r} for {key} ({'a:b' if want == 2 else 'whole number'})")
        nums = [int(p) for p in parts]
        lo, hi = int(e.get("min", 0)), int(e.get("max", 1000000))
        if any(n < lo or n > hi for n in nums):
            raise SettingsError(f"invalid value {value!r} for {key} (allowed {lo}..{hi})")
        return ":".join(str(n) for n in nums)

    # ---------------------------------------------------------------- state
    def pending(self) -> dict:
        return dict(self.store.get("settings.pending") or {})

    def _save_pending(self, d: dict) -> None:
        self.store.set("settings.pending", d)

    def _backup(self, data: bytes) -> Path:
        day = self.clock.now().local().strftime("%Y-%m-%d")
        base = self.backup_dir / f"{self.file.name}.bak-{day}"
        cand, n = base, 1
        while cand.exists():
            if cand.read_bytes() == data:
                return cand
            n += 1
            cand = base.with_name(f"{base.name}-{n}")
        self._write(cand, data)
        return cand

    # ---------------------------------------------------------------- actions
    def set(self, key: str, value: str, reason: str) -> list[str]:
        new = self.validate(key, value)                 # before anything is read or written
        if not (reason or "").strip():
            raise SettingsError("--reason is required (the player's words; settings change only on the player's word)")
        data = self.read()
        lines = data.splitlines(keepends=True)
        hits = [(i, v) for i, k, v in parse_lines(data) if k == key]
        if len(hits) != 1:
            raise SettingsError(f"{key}: expected exactly one line '[{key}:...]' in {self.file}, found {len(hits)}")
        idx, old = hits[0]
        if old == new:
            return [f"{key} is already {new}: nothing changed"]
        backup = self._backup(data)
        m = _LINE.match(lines[idx])
        new_line = m.group("pre") + key.encode("ascii") + b":" + new.encode("ascii") + m.group("post") + m.group("eol")
        out_data = b"".join(lines[:idx] + [new_line] + lines[idx + 1:])
        self._write(self.file, out_data)
        check = self.file.read_bytes().splitlines(keepends=True)
        diff = [i for i, (a, b) in enumerate(zip(lines, check)) if a != b]
        if len(check) != len(lines) or diff != [idx]:
            self._write(self.file, data)                 # roll back: something unexpected happened
            raise SettingsError(f"{key}: verification after the write failed, original restored")
        now = self.clock.now().epoch
        pend = self.pending()
        first = pend.get(key)
        pend[key] = {"old": first["old"] if first else old, "new": new, "ts": now,
                 "backup": first["backup"] if first else str(backup),
                     "line": (first["line"] if first else lines[idx].decode("latin-1")), "reason": reason.strip()}
        self._save_pending(pend)
        self.store.log_action(now, "settings", "settings", "set", key, f"{key} {old} -> {new}", False, True,
                              f"reason: {reason.strip()}"[:200])
        eff = self.known[key].get("effect")
        return [f"{key}: {old} -> {new} (backup {backup.name})",
                f"takes effect only after a restart: {key} {new}" if eff == "restart" else f"{key} is effective now"]

    def revert(self, key: str) -> list[str]:
        if key not in self.known:
            raise SettingsError(f"unknown key {key}")
        pend = self.pending()
        e = pend.get(key) or (self.store.get("settings.history") or {}).get(key)
        if not e:
            raise SettingsError(f"{key}: no recorded change to revert")
        data = self.read()
        lines = data.splitlines(keepends=True)
        hits = [i for i, k, _ in parse_lines(data) if k == key]
        if len(hits) != 1:
            raise SettingsError(f"{key}: expected exactly one line in {self.file}, found {len(hits)}")
        lines[hits[0]] = e["line"].encode("latin-1")
        out_data = b"".join(lines)
        self._write(self.file, out_data)
        pend.pop(key, None)
        self._save_pending(pend)
        hist = self.store.get("settings.history") or {}
        hist.pop(key, None)
        self.store.set("settings.history", hist)
        now = self.clock.now().epoch
        self.store.log_action(now, "settings", "settings", "revert", key, f"{key} -> {e['old']}", False, True,
                              f"backup {Path(e['backup']).name}")
        out = [f"{key}: back to {e['old']}"]
        bk = Path(e["backup"])
        if not pend and bk.is_file():
            out.append("file byte-identical to the backup" if bk.read_bytes() == out_data
                       else "NOTE: file differs from the backup in other lines (edited by hand?)")
        if self.known[key].get("effect") == "restart":
            out.append("takes effect only after a restart")
        return out

    def uptime_s(self) -> float | None:
        if self.client is None:
            return None
        r = self.client.run(UPTIME_CMD)
        m = re.search(r"-?\d+", r.stdout or "") if r.ok else None
        return int(m.group(0)) / 1000.0 if m else None

    def verify(self) -> list[str]:
        pend = self.pending()
        if not pend:
            return ["no setting waits for a restart"]
        vals = self.values()
        up = self.uptime_s()
        now = self.clock.now().epoch
        out, hist = [], self.store.get("settings.history") or {}
        for key, e in sorted(pend.items()):
            cur = vals.get(key)
            if cur != e["new"]:
                out.append(f"{key}: file now has {cur!r}, expected {e['new']} (changed by hand?) - still pending")
                continue
            if up is None:
                out.append(f"{key}: DF not reachable - cannot tell whether DF was restarted; still pending")
                continue
            if up >= now - float(e["ts"]):
                out.append(f"{key} {e['new']}: DF has been running since before the change "
                           f"({up / 60:.0f} min) - restart needed; still pending")
                continue
            hist[key] = {**e, "verified": now}
            pend.pop(key)
            self.store.log_action(now, "settings", "settings", "verify", key, f"{key} {e['new']}", False, True,
                                  f"DF restarted {up / 60:.0f} min ago")
            out.append(f"{key} {e['new']}: verified (DF restarted after the change)" + self._effect_hint(key, e))
        self._save_pending(pend)
        self.store.set("settings.history", hist)
        return out

    def _effect_hint(self, key: str, e: dict) -> str:
        if key not in ("POPULATION_CAP", "STRICT_POPULATION_CAP") or self.client is None:
            return ""
        r = self.client.run("claude/status")
        pop = None
        if r.ok and isinstance(r.json, dict):
            pop = (r.json.get("population") or {}).get("total")
        if pop is None:
            return ""
        cap = int(e["new"])
        return (f"; population {pop} >= {cap}: no more migrants expected (watch migranten.flag)" if pop >= cap
                else f"; population {pop} < {cap}: migrants still possible")

    def pending_line(self) -> str:
        pend = self.pending()
        if not pend:
            return ""
        items = ", ".join(f"{k} {e['new']}" for k, e in sorted(pend.items()))
        n = len(pend)
        return f"{n} setting{'s' if n > 1 else ''} waiting for a restart ({items})"[:140]


RESTART_PLAN = [
    "1. python -m df_llm_helper settings pending (what waits for the restart)",
    "2. pause the game (claude/advance 0), save (quicksave), set tools/pause.hold",
    "3. quit DF and start it again, load the save",
    "4. python -m df_llm_helper reboot (services), then delete pause.hold",
    "5. python -m df_llm_helper settings verify (value in the file + DF restarted after the change)",
    "6. watch the population trend (migranten.flag, births) for a game month",
]


# ---------------------------------------------------------------- CLI + check
def _make(args) -> Settings:
    from ..cli import _client          # lazy: no cli import at module level
    from ..clock import SystemClock
    from ..config import HOME, load_config
    from ..store import Store
    cfg = load_config(args.config)
    clock = SystemClock()
    client = _client(args, cfg, clock) if args.action == "verify" else None
    return Settings(Store(cfg.path("state_db")), clock, cfg.get(KEY, {}), home=HOME,
                    dfhack_run=cfg.get("dfhack_run"), client=client)


def _cmd(args) -> int:
    if args.action == "restart-plan":
        print("\n".join(RESTART_PLAN))
        return 0
    s = _make(args)
    try:
        if args.action == "get":
            lines = s.get(args.key)
        elif args.action == "set":
            if not args.key or args.value is None:
                raise SettingsError("usage: settings set KEY VALUE --reason \"<player quote>\"")
            lines = s.set(args.key, args.value, args.reason or "")
        elif args.action == "revert":
            if not args.key:
                raise SettingsError("usage: settings revert KEY")
            lines = s.revert(args.key)
        elif args.action == "verify":
            lines = s.verify()
        else:
            lines = [s.pending_line() or "no setting waits for a restart"]
            for k, e in sorted(s.pending().items()):
                lines.append(f"- {k}: {e['old']} -> {e['new']} (reason: {e['reason']}; backup {Path(e['backup']).name})")
    except SettingsError as e:
        print(f"Refused: {e}")
        return 2
    print("\n".join(lines))
    return 0


def register(sub) -> None:
    s = sub.add_parser("settings", help="d_init.txt settings: get/set/pending/verify/revert (backup, restart planner)")
    s.add_argument("action", nargs="?", default="get", choices=["get", "set", "pending", "verify", "revert",
                                                                "restart-plan"])
    s.add_argument("key", nargs="?")
    s.add_argument("value", nargs="?")
    s.add_argument("--reason", default="", help="set: the player's words (required, logged in state.db)")
    s.set_defaults(fn=_cmd)


def check_hook(pilot, report, dry: bool) -> list[str]:
    pend = pilot.store.get("settings.pending") or {}
    if not pend:
        return []
    cfg = {**DEFAULTS, **(pilot.cfg.get(KEY, {}) or {})}
    now = pilot.clock.now().epoch
    last = pilot.store.get("settings.last_hint")
    if last is not None and now - float(last) < float(cfg["hint_every_s"]):
        return []
    if not dry:
        pilot.store.set("settings.last_hint", now)
    items = ", ".join(f"{k} {e['new']}" for k, e in sorted(pend.items()))
    n = len(pend)
    return [f"{n} setting{'s' if n > 1 else ''} waiting for a restart ({items})"[:140]]
