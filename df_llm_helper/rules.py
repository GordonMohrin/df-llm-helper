"""F2 Autopilot: deterministic rules (YAML) when -> do -> verify, with dry run, cooldown, rate limit,
infinite-loop protection and conflict detection at load time.

Rule schema (data/rules/*.yaml, list of rules):
  id: str (required)           why: str (required, reason taken from real failures)
  class: maintenance|safety|game (default maintenance; classes that are not allowed -> only a proposal in the digest)
  when: expression (required)  for_each: expression -> list (binds 'item')
  do: [action, ...] (required) verify: expression (optional, evaluated with a fresh snapshot after execution)
  cooldown_s: int (default 300)   max_per_hour: int (default from config)   enabled: bool
  mutex_with: [ids]  (deliberately opposing rules with mutually exclusive conditions)
Actions: {cmd: "..."} {service: {name, op}} {set_fps: N|"{ausdruck}"} {tempo: off|suspend} {alert: on|off}
          {delete_flag: name} {write_flag: {name, text}} {warn: text} {propose: text} {say: text}
Texts may contain {expression} placeholders (evaluated safely).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from . import yamlmini
from .client import DFClient
from .expr import ExprError, compile_expr, evaluate

__all__ = ["Rule", "Action", "RuleError", "load_rules", "validate_rule", "find_conflicts", "Engine",
           "ActionRecord", "SET_FPS_CMD", "render", "build_context"]

SET_FPS_CMD = 'lua "df.global.enabler.fps={n}"'
ACTION_KINDS = {"cmd", "service", "set_fps", "tempo", "alert", "delete_flag", "write_flag", "warn", "propose", "say"}
CLASSES = {"maintenance", "safety", "game"}


class RuleError(ValueError):
    pass


_PLACE = re.compile(r"\{([^{}]+)\}")


def _split_template(s: str) -> list[tuple[bool, str]]:
    """Splits 'a {x} {{lit}}' into [(False,'a '), (True,'x'), (False,' {lit}')]. '{{'/'}}' outside a placeholder = literal."""
    out: list[tuple[bool, str]] = []
    buf, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "{" and s.startswith("{{", i) and not s.startswith("{{{", i):
            buf.append("{")
            i += 2
        elif c == "{":
            if s.startswith("{{{", i):     # '{{' literal + placeholder
                buf.append("{")
                i += 2
            j = s.find("}", i + 1)
            if j < 0:
                buf.append(s[i:])
                break
            if buf:
                out.append((False, "".join(buf)))
                buf = []
            out.append((True, s[i + 1:j]))
            i = j + 1
        elif c == "}" and s.startswith("}}", i):
            buf.append("}")
            i += 2
        else:
            buf.append(c)
            i += 1
    if buf:
        out.append((False, "".join(buf)))
    return out


def render(template: Any, ctx: dict) -> str:
    """Evaluate '{expression}' placeholders safely; '{{' and '}}' are literals."""
    parts = []
    for is_ph, txt in _split_template(str(template)):
        if not is_ph:
            parts.append(txt)
            continue
        v = evaluate(txt, ctx)
        if isinstance(v, float) and v.is_integer():
            v = int(v)
        if isinstance(v, (list, tuple)):
            v = ",".join(str(x) for x in v)
        parts.append("" if v is None else str(v))
    return "".join(parts)


def placeholders(template) -> list[str]:
    return [t for is_ph, t in _split_template(str(template)) if is_ph]


@dataclass
class Action:
    kind: str
    arg: Any

    def resolve(self, ctx: dict) -> tuple[str, str, str | None]:
        """-> (resource, value, dfhack command|None)."""
        k, a = self.kind, self.arg
        if k == "cmd":
            c = render(a, ctx)
            return f"cmd:{c}", "run", c
        if k == "service":
            name, op = render(a["name"], ctx), render(a.get("op", "start"), ctx)
            return f"service:{name}", op, f"claude/{name} {op}"
        if k == "set_fps":
            n = render(a, ctx)
            return "fps", n, SET_FPS_CMD.format(n=n)
        if k == "tempo":
            v = render(a, ctx)
            return "tempo", v, f"claude/tempo {v}"
        if k == "alert":
            v = render(a, ctx)
            return "civ_alert", v, f"claude/alert {v}"
        if k == "delete_flag":
            return f"flag:{render(a, ctx)}", "delete", None
        if k == "write_flag":
            return f"flag:{render(a['name'], ctx)}", "write", None
        if k == "say":
            t = render(a, ctx).replace('"', "'")
            return "overlay", t, f'claude/schau say "{t}"'
        if k in ("warn", "propose"):
            return f"{k}:{render(a, ctx)[:40]}", "text", None
        raise RuleError(f"unknown action {k}")

    def static_resource(self) -> tuple[str, str] | None:
        """Resource/value without context (for conflict detection); None if dynamic."""
        k, a = self.kind, self.arg
        if k == "service":
            return f"service:{a.get('name')}", str(a.get("op", "start"))
        if k == "set_fps":
            return "fps", str(a)
        if k == "tempo":
            return "tempo", str(a)
        if k == "alert":
            return "civ_alert", str(a)
        if k == "delete_flag":
            return f"flag:{a}", "delete"
        if k == "write_flag":
            return f"flag:{a.get('name')}", "write"
        return None


@dataclass
class Rule:
    id: str
    why: str
    when: str
    do: list
    klass: str = "maintenance"
    for_each: str | None = None
    verify: str | None = None
    cooldown_s: float = 300
    max_per_hour: int | None = None
    enabled: bool = True
    mutex_with: list = field(default_factory=list)
    source: str = ""


def validate_rule(d: Any, source: str = "") -> Rule:
    if not isinstance(d, dict):
        raise RuleError(f"{source}: rule must be a mapping")
    rid = d.get("id")
    for req in ("id", "why", "when", "do"):
        if not d.get(req):
            raise RuleError(f"{source}: rule {rid or '?'}: required field '{req}' missing")
    known = {"id", "why", "when", "do", "class", "for_each", "verify", "cooldown_s", "max_per_hour", "enabled",
             "mutex_with"}
    extra = set(d) - known
    if extra:
        raise RuleError(f"{source}: rule {rid}: unknown fields {sorted(extra)}")
    klass = d.get("class", "maintenance")
    if klass not in CLASSES:
        raise RuleError(f"{source}: rule {rid}: class must be one of {sorted(CLASSES)}")
    for key in ("when", "for_each", "verify"):
        if d.get(key):
            try:
                compile_expr(str(d[key]))
            except ExprError as e:
                raise RuleError(f"{source}: rule {rid}: {key}: {e}") from None
    acts = []
    if not isinstance(d["do"], list):
        raise RuleError(f"{source}: rule {rid}: 'do' must be a list")
    for a in d["do"]:
        if not isinstance(a, dict) or len(a) != 1:
            raise RuleError(f"{source}: rule {rid}: an action must have exactly one key: {a!r}")
        (k, v), = a.items()
        if k not in ACTION_KINDS:
            raise RuleError(f"{source}: rule {rid}: unknown action '{k}' (allowed: {sorted(ACTION_KINDS)})")
        if k == "service" and (not isinstance(v, dict) or "name" not in v):
            raise RuleError(f"{source}: rule {rid}: service needs name/op")
        if k == "write_flag" and (not isinstance(v, dict) or "name" not in v):
            raise RuleError(f"{source}: rule {rid}: write_flag needs name/text")
        for txt in ([v] if not isinstance(v, dict) else list(v.values())):
            for ph in placeholders(txt):
                try:
                    compile_expr(ph)
                except ExprError as e:
                    raise RuleError(f"{source}: rule {rid}: placeholder: {e}") from None
        acts.append(Action(k, v))
    return Rule(id=str(rid), why=str(d["why"]), when=str(d["when"]), do=acts, klass=klass,
                for_each=d.get("for_each"), verify=d.get("verify"), cooldown_s=float(d.get("cooldown_s", 300)),
                max_per_hour=d.get("max_per_hour"), enabled=bool(d.get("enabled", True)),
                mutex_with=list(d.get("mutex_with") or []), source=source)


def load_rules(paths: list[Path] | Path) -> list[Rule]:
    if isinstance(paths, Path):
        paths = sorted(paths.glob("*.yaml")) if paths.is_dir() else [paths]
    rules: list[Rule] = []
    seen: set = set()
    for p in paths:
        data = yamlmini.load_file(p)
        if data is None:
            continue
        if not isinstance(data, list):
            raise RuleError(f"{p}: file must be a list of rules")
        for d in data:
            r = validate_rule(d, p.name)
            if r.id in seen:
                raise RuleError(f"{p.name}: duplicate rule id: {r.id}")
            seen.add(r.id)
            rules.append(r)
    return rules


def find_conflicts(rules: list[Rule]) -> list[str]:
    """Opposing actions on the same resource (e.g. service start vs. stop, fps 30 vs. 250)."""
    out = []
    for i, a in enumerate(rules):
        for b in rules[i + 1:]:
            if not (a.enabled and b.enabled):
                continue
            for x in a.do:
                for y in b.do:
                    rx, ry = x.static_resource(), y.static_resource()
                    if rx and ry and rx[0] == ry[0] and rx[1] != ry[1]:
                        declared = b.id in a.mutex_with and a.id in b.mutex_with
                        tag = "declared (mutex_with)" if declared else "CONFLICT"
                        out.append(f"{tag}: {a.id} ({rx[0]}={rx[1]}) vs {b.id} ({ry[0]}={ry[1]})")
    return out


@dataclass
class ActionRecord:
    rule: str
    kind: str
    resource: str
    value: str
    cmd: str | None
    dry_run: bool
    ok: bool
    detail: str = ""

    def line(self) -> str:
        # BUG-117 D: verify lines say whether the check passed; warn/propose lines without the internal key
        if self.kind == "verify":
            return f"{self.rule}: verify {'ok' if self.ok else 'FAILED'} ({self.detail})"
        what = self.cmd or (self.kind if self.kind in ("warn", "propose") else f"{self.kind} {self.resource}")
        fail = " FAILED" if not self.ok and not self.dry_run else ""
        return (f"{'[dry] ' if self.dry_run else ''}{self.rule}: {what}{fail}"
                f"{' -> ' + self.detail if self.detail else ''}")


def build_context(snap, *, flags: dict | None = None, services: dict | None = None, guard: dict | None = None,
                  cfg: dict | None = None, cancels: list | None = None, files: dict | None = None) -> dict:
    """Expression context for rules/runbooks."""
    from .toolsfs import FlagInfo
    cfg = cfg or {}
    names = set((cfg.get("flags") or {}).get("names") or [])
    fl = dict(flags or {})
    for n in names:
        fl.setdefault(n, FlagInfo(n, False))
    svc = dict(snap.services)
    svc.update(services or {})
    f = snap.facts()
    ctx = dict(f)
    ctx.update({
        "snap": snap, "s": snap, "flags": fl, "flag_list": [x for x in fl.values() if x.exists],
        "services": svc, "service_list": [{"name": k, **(v if isinstance(v, dict) else {})} for k, v in sorted(svc.items())],
        "guard": guard or {}, "cfg": cfg, "th": cfg.get("thresholds", {}),
        "danger": snap.danger, "caravan_active": snap.caravan_active, "caravans": snap.alerts.caravans,
        "citizens": snap.citizens, "squads": snap.squads, "workdetails": snap.workdetails,
        "normal_fps": snap.normal_fps, "slowmo": snap.slowmo, "danger_alarm": snap.alerts.danger_alarm,
        "pick_holders": snap.pick_holders, "mood_gaps": snap.stocks.mood_gaps, "fish": snap.stocks.fish,
        "meat": snap.stocks.meat, "barrels_empty": snap.stocks.barrels_empty, "jobs": snap.jobs,
        "miners": snap.miners, "injured": snap.injured, "aquifer_z": snap.aquifer_z,
        "full_stockpiles": snap.full_stockpiles, "orders_unvalidated": snap.orders_unvalidated,
        "orders_total": snap.orders_total, "broker": snap.broker, "max_report_id": snap.max_report_id,
        "cancels": [{"job": c.job, "reason": c.reason, "count": c.count, "who": c.who} for c in (cancels or [])],
        "wd": snap.workdetail, "citizen": snap.citizen,
        "job_count": lambda name: snap.jobs.by_type.get(name, 0),
        "cancel": lambda sub: sum(c.count for c in (cancels or []) if str(sub).lower() in (c.job + " " + c.reason).lower()),
        "stopped_services": sorted(k for k, v in svc.items() if isinstance(v, dict) and v.get("running") is False),
    })
    ctx.update(files or {})
    return ctx


class Engine:
    def __init__(self, rules: list[Rule], client: DFClient, store, tools, clock, *, cfg: dict,
                 dry_run: bool = False):
        self.rules = rules
        self.client = client
        self.store = store
        self.tools = tools
        self.clock = clock
        self.cfg = cfg
        self.dry_run = dry_run
        ap = cfg.get("autopilot", {})
        self.max_same = int(ap.get("max_same_action_per_hour", 6))
        self.allowed = set(ap.get("allow_classes", ["maintenance"]))
        self.disabled_cfg = set(ap.get("disabled_rules", []) or [])
        self.conflicts = find_conflicts(rules)

    def cycle(self, ctx: dict, refresh: Callable[[], dict] | None = None) -> list[ActionRecord]:
        now = self.clock.now().epoch
        records: list[ActionRecord] = []
        for rule in self.rules:
            if not rule.enabled or rule.id in self.disabled_cfg:
                continue
            st = self.store.rule_state(rule.id)
            if st["disabled"]:
                continue
            if st["last_fire"] is not None and now - st["last_fire"] < rule.cooldown_s:
                continue
            try:
                items = evaluate(rule.for_each, ctx) if rule.for_each else [None]
            except ExprError as e:
                self.store.warn(now, "autopilot", f"rule_err:{rule.id}", f"rule {rule.id}: {e}")
                continue
            fired = False
            for item in list(items or []):
                lctx = dict(ctx)
                if item is not None:
                    lctx["item"] = item
                try:
                    if not evaluate(rule.when, lctx):
                        continue
                except ExprError as e:
                    self.store.warn(now, "autopilot", f"rule_err:{rule.id}", f"rule {rule.id}: {e}")
                    continue
                recs = self._execute(rule, lctx, now)
                records.extend(recs)
                fired = fired or any(r.ok for r in recs)
                if fired and rule.verify and not self.dry_run and refresh is not None:
                    vctx = refresh()
                    if item is not None:
                        vctx["item"] = item
                    ok = bool(evaluate(rule.verify, vctx))
                    if not ok:
                        st2 = self.store.rule_state(rule.id)
                        self.store.update_rule(rule.id, verify_fail=st2["verify_fail"] + 1)
                        self.store.warn(now, "autopilot", f"verify:{rule.id}",
                                        f"rule {rule.id}: check '{rule.verify}' not satisfied after the action "
                                        f"({st2['verify_fail'] + 1}x). Investigate the cause: python -m df_llm_helper runbook diagnose")
                        records.append(ActionRecord(rule.id, "verify", "-", "fail", None, False, False, rule.verify))
                    else:
                        records.append(ActionRecord(rule.id, "verify", "-", "ok", None, False, True, rule.verify))
            if fired and not self.dry_run:
                self.store.update_rule(rule.id, last_fire=now)
        return records

    def _execute(self, rule: Rule, ctx: dict, now: float) -> list[ActionRecord]:
        out: list[ActionRecord] = []
        limit = int(rule.max_per_hour or self.max_same)
        as_proposal = rule.klass not in self.allowed
        for act in rule.do:
            try:
                resource, value, cmd = act.resolve(ctx)
            except ExprError as e:
                self.store.warn(now, "autopilot", f"rule_err:{rule.id}", f"rule {rule.id}: placeholder: {e}")
                continue
            key = f"{act.kind}:{resource}={value}"
            if as_proposal and act.kind not in ("warn", "propose"):
                text = f"Proposal ({rule.klass}, not enabled): {rule.id}: {cmd or act.kind + ' ' + resource} - {rule.why}"
                if not self.dry_run:
                    self.store.warn(now, "autopilot", f"propose:{rule.id}:{resource}", text[:220], "warn")
                out.append(ActionRecord(rule.id, "propose", resource, value, cmd, self.dry_run, True, "proposal only"))
                continue
            if not self.dry_run and act.kind not in ("warn", "propose"):
                n = self.store.count_actions(rule.id, key, now - 3600)
                if n >= limit:
                    self.store.update_rule(rule.id, disabled=1, reason=f"{key} {n}x/h")
                    self.store.warn(now, "autopilot", f"loop:{rule.id}",
                                    f"rule {rule.id} disabled: '{key}' {n}x in 1 h (infinite loop?). "
                                    f"Investigate the cause, then 'python -m df_llm_helper autopilot enable {rule.id}'.", "crit")
                    out.append(ActionRecord(rule.id, act.kind, resource, value, cmd, False, False, "rate limit"))
                    break
            rec = self._do(rule, act, resource, value, cmd, ctx, now)
            self.store.log_action(now, "autopilot", rule.id, key, resource, cmd or "", self.dry_run, rec.ok, rec.detail)
            out.append(rec)
        return out

    def _do(self, rule, act, resource, value, cmd, ctx, now) -> ActionRecord:
        if act.kind in ("warn", "propose"):
            text = render(act.arg, ctx)
            if not self.dry_run:
                lvl = "warn"
                self.store.warn(now, "autopilot", f"{act.kind}:{rule.id}:{text[:30]}",
                                (("Proposal: " if act.kind == "propose" else "") + text)[:220], lvl)
            return ActionRecord(rule.id, act.kind, resource, value, None, self.dry_run, True, text[:80])
        if self.dry_run:
            return ActionRecord(rule.id, act.kind, resource, value, cmd, True, True, "dry-run")
        if act.kind == "delete_flag":
            name = resource.split(":", 1)[1]
            ok = self.tools.delete_flag(name)
            return ActionRecord(rule.id, act.kind, resource, value, None, False, True,
                                "deleted" if ok else "already gone")
        if act.kind == "write_flag":
            self.tools.write_flag(resource.split(":", 1)[1], render(act.arg.get("text", rule.id), ctx))
            return ActionRecord(rule.id, act.kind, resource, value, None, False, True, "written")
        res = self.client.run(cmd)
        return ActionRecord(rule.id, act.kind, resource, value, cmd, False, res.ok,
                            "" if res.ok else (res.stderr or "error")[:80])
