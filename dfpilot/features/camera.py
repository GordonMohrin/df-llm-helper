"""Spec v3-10: camera director profiles (`dfpilot camera`).

Profiles (data/camera/*.yaml: ambient, combat, build, events, calm; `extends:` inherits from another profile) hold the
job weights, idle/soldier weights, variety factor, dwell time and the schau mode. Switching a profile writes
<paths.tools>/schau_profile.json (the same folder as util.home()/tools in Lua) and calls
`claude/schau profile reload` + `claude/schau mode <mode>`; lua/claude/schau.lua keeps its built-in weights when the
file is missing.
- profile <name>  switch (refused while pause.hold exists or the DF focus is not dwarfmode/Default)
- status          current profile, schau gate, category shares of the last 30 minutes
- stats           category shares (sum 100 %)
- watch [--loop]  attack (siege.flag/alert.flag) -> switch to 'combat' within one poll (1 s), back to the previous
                  profile when it is over; `check` does the same once per check
Safety as in schau: only camera and text lines; dfpilot never pauses or opens windows here.
"""
from __future__ import annotations

import json
import random
from pathlib import Path

from .. import yamlmini

__all__ = ["KEY", "DEFAULTS", "ProfileError", "load_profile", "profile_names", "weights_payload", "weight",
           "pick", "simulate", "shares", "Director", "register", "check_hook"]

KEY = "camera"
DEFAULTS = {"default_profile": "ambient", "dwell_s": [18, 24], "variety_factor": 0.3, "ignore_soldiers_idle": True,
            "profiles_dir": "data/camera", "weights_file": "schau_profile.json", "attack_profile": "combat",
            "attack_flags": ["siege", "alert"], "poll_s": 1.0, "max_switches_per_hour": 20, "in_check": True}
FOCUS_OK = "dwarfmode/Default"
MODES = ("auto", "follow", "events", "combat")


class ProfileError(ValueError):
    pass


def _dir(cfg: dict, home: Path) -> Path:
    p = Path(cfg.get("profiles_dir", DEFAULTS["profiles_dir"]))
    return p if p.is_absolute() else Path(home) / p


def profile_names(cfg: dict, home: Path) -> list[str]:
    return sorted(p.stem for p in _dir(cfg, home).glob("*.yaml"))


def load_profile(name: str, cfg: dict, home: Path, _seen: tuple = ()) -> dict:
    """Profile with inheritance (extends), config defaults and validation."""
    if not name or not all(c.isalnum() or c in "_-" for c in name):
        raise ProfileError(f"invalid profile name {name!r}")
    if name in _seen:
        raise ProfileError(f"profile cycle: {' -> '.join(_seen + (name,))}")
    path = _dir(cfg, home) / f"{name}.yaml"
    if not path.is_file():
        raise ProfileError(f"unknown profile {name} (known: {', '.join(profile_names(cfg, home))})")
    d = yamlmini.load_file(path) or {}
    base = load_profile(d["extends"], cfg, home, _seen + (name,)) if d.get("extends") else {}
    p = {**base, **{k: v for k, v in d.items() if k != "extends"}}
    p["name"] = name
    p.setdefault("dwell_s", list(cfg.get("dwell_s", DEFAULTS["dwell_s"])))
    p.setdefault("variety_factor", cfg.get("variety_factor", DEFAULTS["variety_factor"]))
    if cfg.get("ignore_soldiers_idle", True):
        p["soldier_idle_weight"] = min(float(p.get("soldier_idle_weight", 0.005)), 0.005)
    if p.get("mode") not in MODES:
        raise ProfileError(f"{name}: mode must be one of {MODES}")
    jw = p.get("job_weights")
    if not isinstance(jw, list) or not jw:
        raise ProfileError(f"{name}: job_weights missing")
    for e in jw:
        if not isinstance(e, dict) or not isinstance(e.get("p"), str) or not isinstance(e.get("w"), (int, float)) \
                or e["w"] < 0:
            raise ProfileError(f"{name}: invalid weight entry {e!r}")
    d1, d2 = p["dwell_s"]
    if not (0 < float(d1) <= float(d2) <= 600):
        raise ProfileError(f"{name}: dwell_s must be [min, max] seconds")
    return p


def weights_payload(p: dict) -> dict:
    """The JSON file read by schau.lua (load_profile)."""
    return {"name": p["name"], "mode": p["mode"],
            "job_weights": [{"p": e["p"], "w": e["w"], "cat": e.get("cat")} for e in p["job_weights"]],
            "default_weight": p.get("default_weight", 1), "idle_weight": p.get("idle_weight", 0.01),
            "soldier_idle_weight": p.get("soldier_idle_weight", 0.005),
            "variety_factor": p.get("variety_factor", 0.3), "recent_factor": p.get("recent_factor", 0.15),
            "dwell_min_s": p["dwell_s"][0], "dwell_max_s": p["dwell_s"][1], "pan_steps": p.get("pan_steps", 4)}


# ------------------------------------------------------------------ Python mirror of schau.lua pick_follow
_JOB_CATS = ("Dig", "Carve", "Construct", "Plant", "Harvest", "Gather", "PlaceItemInTomb", "GiveWater", "Brew",
             "Prepare", "Store", "Haul", "Make", "Engrave", "Eat", "Drink")


def _lua_find(name: str, pat: str) -> bool:
    """The profiles only use '^Prefix' patterns (plain text after the anchor)."""
    return name.startswith(pat[1:]) if pat.startswith("^") else pat in name


def weight(p: dict, job: str | None, soldier: bool) -> tuple[float, str | None]:
    if job is None:
        return (float(p.get("soldier_idle_weight", 0.005)), "soldier_idle") if soldier else \
            (float(p.get("idle_weight", 0.01)), "idle")
    for e in p["job_weights"]:
        if _lua_find(job, e["p"]):
            return float(e["w"]), e.get("cat")
    return float(p.get("default_weight", 1)), None


def _job_cat(job: str | None) -> str:
    if not job:
        return "none"
    for c in _JOB_CATS:
        if job.startswith(c):
            return c
    return job


def pick(units: list[dict], p: dict, state: dict, rng: random.Random) -> dict | None:
    """One ambient pick like schau.lua pick_follow (recent factor, variety factor). units: {id, job, soldier}."""
    cands, total = [], 0.0
    for u in units:
        w, _ = weight(p, u.get("job"), bool(u.get("soldier")))
        if w > 0:
            if u["id"] in state.get("recent", []):
                w *= float(p.get("recent_factor", 0.15))
            if state.get("last_cat") and _job_cat(u.get("job")) == state["last_cat"]:
                w *= float(p.get("variety_factor", 0.3))
            cands.append((u, w))
            total += w
    if total <= 0:
        return None
    r = rng.random() * total
    chosen = cands[-1][0]
    for u, w in cands:
        r -= w
        if r <= 0:
            chosen = u
            break
    state["last_cat"] = _job_cat(chosen.get("job"))
    state["recent"] = ([chosen["id"]] + [i for i in state.get("recent", []) if i != chosen["id"]])[:4]
    return chosen


def simulate(units: list[dict], p: dict, n: int = 1000, seed: int = 1) -> dict[str, int]:
    """Category counts over n picks (Monte Carlo)."""
    rng, state, out = random.Random(seed), {}, {}
    for _ in range(n):
        u = pick(units, p, state, rng)
        if u is None:
            continue
        _, cat = weight(p, u.get("job"), bool(u.get("soldier")))
        cat = cat or _job_cat(u.get("job"))
        out[cat] = out.get(cat, 0) + 1
    return out


def shares(counts: dict) -> list[tuple[str, int]]:
    """Percent per category (largest remainder: sums to exactly 100 if anything was counted)."""
    counts = {str(k): int(v) for k, v in (counts or {}).items() if int(v) > 0} if isinstance(counts, dict) else {}
    total = sum(counts.values())
    if total <= 0:
        return []
    raw = {k: v * 100.0 / total for k, v in counts.items()}
    base = {k: int(v) for k, v in raw.items()}
    rest = 100 - sum(base.values())
    for k in sorted(raw, key=lambda k: (-(raw[k] - base[k]), k))[:rest]:
        base[k] += 1
    return sorted(base.items(), key=lambda kv: (-kv[1], kv[0]))


# ------------------------------------------------------------------ director
class Director:
    def __init__(self, client, store, clock, tools, cfg: dict | None = None, *, home: Path):
        self.client, self.store, self.clock, self.tools = client, store, clock, tools
        self.cfg = {**DEFAULTS, **(cfg or {})}
        self.home = Path(home)

    @property
    def weights_file(self) -> Path:
        return Path(self.tools.path) / self.cfg["weights_file"]

    def current(self) -> str:
        return self.store.get("camera.profile") or self.cfg["default_profile"]

    def schau_status(self) -> dict | None:
        r = self.client.run("claude/schau status")
        return r.json if r.ok and isinstance(r.json, dict) else None

    def gate(self) -> tuple[bool, str, dict | None]:
        """(allowed, reason, schau status). Never act with pause.hold or a non-default focus."""
        if self.tools.flag("pause.hold").exists:
            return False, "pause.hold present (main thread works)", None
        st = self.schau_status()
        if st is None:
            return False, "claude/schau status not readable", None
        focus = str(st.get("focus") or "")
        if focus != FOCUS_OK:
            return False, f"focus {focus or '?'} (menu open)", st
        return True, "ok", st

    def switch(self, name: str, *, reason: str = "manual", require_running: bool = False) -> list[str]:
        """require_running: automatic switches never start a stopped director ('schau mode' would start it)."""
        p = load_profile(name, self.cfg, self.home)
        ok, why, st = self.gate()
        if ok and require_running and not (st or {}).get("running"):
            ok, why = False, "director not running"
        if not ok:
            return [f"Camera: no action ({why}); profile stays {self.current()}"]
        now = self.clock.now().epoch
        if self.store.count_actions("camera", "profile", now - 3600) >= int(self.cfg["max_switches_per_hour"]):
            self.store.warn(now, "camera", "camera:loop", "camera profile switched too often - loop protection", "warn")
            return [f"Camera: loop protection ({self.cfg['max_switches_per_hour']} switches/hour)"]
        payload = json.dumps(weights_payload(p), ensure_ascii=False, sort_keys=True, indent=1)
        self.weights_file.parent.mkdir(parents=True, exist_ok=True)
        self.weights_file.write_text(payload + "\n", encoding="utf-8")
        cmds = ["claude/schau profile reload", f"claude/schau mode {p['mode']}"]
        res = [self.client.run(c) for c in cmds]
        good = all(r.ok for r in res) and all((r.json or {}).get("ok", True) for r in res if isinstance(r.json, dict))
        prev = self.current()
        self.store.set("camera.profile", name)
        self.store.log_action(now, "camera", "camera", "profile", name, " ; ".join(cmds), False, good,
                              f"{prev} -> {name} ({reason})")
        out = [f"Camera: profile {prev} -> {name} (mode {p['mode']}, {reason})" + ("" if good else " - schau error")]
        if st and int(st.get("hold_s") or 0) > 0:
            out.append(f"Camera: director paused {st.get('hold_s')} s (the player moved the view)")
        return out

    def attack(self) -> bool:
        return any(self.tools.flag(f).exists for f in self.cfg["attack_flags"])

    def tick(self) -> list[str]:
        """Attack -> combat profile; afterwards back to the previous profile."""
        target = self.cfg["attack_profile"]
        prev = self.store.get("camera.auto_prev")
        if self.attack():
            if self.current() != target:
                before = self.current()
                out = self.switch(target, reason="attack", require_running=True)
                if self.current() == target:
                    self.store.set("camera.auto_prev", before)
                return out
            return []
        if prev:
            out = self.switch(prev, reason="attack over", require_running=True)
            if self.current() == prev:
                self.store.set("camera.auto_prev", None)
            return out
        return []

    def watch(self, *, iterations: int | None = None) -> list[str]:
        out, i = [], 0
        while iterations is None or i < iterations:
            out += self.tick()
            i += 1
            self.clock.sleep(float(self.cfg["poll_s"]))
        return out

    def status(self) -> list[str]:
        st = self.schau_status()
        out = [f"Camera profile: {self.current()}" + (f" (auto, back to {self.store.get('camera.auto_prev')})"
                                                      if self.store.get("camera.auto_prev") else "")]
        if st is None:
            return out + ["schau: status not readable"]
        out.append(f"schau: mode {st.get('mode')}, profile {st.get('profile', 'builtin')}, gate {st.get('gate_reason')}"
                   + (f", director paused {st.get('hold_s')} s" if int(st.get("hold_s") or 0) > 0 else ""))
        sh = shares(st.get("cats") or {})
        out.append("last 30 min: " + (", ".join(f"{k} {v} %" for k, v in sh) if sh else "no picks yet"))
        return out


# ------------------------------------------------------------------ CLI + check
def _cmd(args) -> int:
    from ..cli import _pilot          # lazy: no cli import at module level
    from ..config import HOME
    p = _pilot(args)
    d = Director(p.client, p.store, p.clock, p.tools, p.cfg.get(KEY, {}), home=HOME)
    try:
        if args.action == "profile":
            if not args.name:
                print("profiles: " + ", ".join(profile_names(d.cfg, HOME)) + f" (current {d.current()})")
                return 0
            lines = d.switch(args.name, reason="manual")
        elif args.action == "stats":
            st = d.schau_status() or {}
            sh = shares(st.get("cats") or {})
            lines = [f"{k}: {v} %" for k, v in sh] or ["no picks in the last 30 minutes"]
        elif args.action == "watch":
            lines = d.watch(iterations=None if args.loop else 1)
            lines = lines or ["Camera: no change"]
        else:
            lines = d.status()
    except ProfileError as e:
        print(f"Refused: {e}")
        return 2
    print("\n".join(lines))
    return 0


def register(sub) -> None:
    s = sub.add_parser("camera", help="camera director profiles (ambient, combat, build, events, calm)")
    s.add_argument("action", nargs="?", default="status", choices=["status", "profile", "stats", "watch"])
    s.add_argument("name", nargs="?")
    s.add_argument("--loop", action="store_true", help="watch: poll every camera.poll_s seconds (attack -> combat)")
    s.set_defaults(fn=_cmd)


def check_hook(pilot, report, dry: bool) -> list[str]:
    if dry:
        return []
    from ..config import HOME
    d = Director(pilot.client, pilot.store, pilot.clock, pilot.tools, pilot.cfg.get(KEY, {}), home=HOME)
    if not d.attack() and not pilot.store.get("camera.auto_prev"):
        return []                       # nothing to do: no DF call at all
    return [ln for ln in d.tick() if ln.startswith("Camera: profile")]
