"""F3 Runbooks: symptom -> check -> fix -> verification, as YAML data (data/runbooks/*.yaml).

Schema (required: id, title, symptom.when, steps, verify.when; needs_player_approval: bool, i.e. "needs the player's
approval"; the key of older runbook files is still accepted as an alias, see LEGACY_APPROVAL_KEY):
  id, title, kb: [ids], needs_player_approval: bool, approval_action: FPxx (register rule for a fair-play exception)
  symptom: {when: expr, confidence: 0..1, signals: [{when, add, why}], explain: text}
  params: {name: {default: value|null, desc: text}}    (null = required parameter)
  preconditions: [{when: expr, msg: text}]
  steps: [{cmd: text} | {manual: text} | {wait_s: n} | {check: expr, msg: text} | {action: reset_report_id|delete_flag:<name>}]
  verify: {when: expr, timeout_s: n, poll_s: n}
  rollback: [steps]   notes: text
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from . import yamlmini
from .expr import ExprError, compile_expr, evaluate
from .fairplay import ExceptionRegistry, FairPlayError, check_command
from .rules import placeholders, render

__all__ = ["Runbook", "RunbookError", "load_runbooks", "validate_runbook", "Hit", "diagnose", "plan_commands",
           "RunResult", "run_runbook"]

STEP_KINDS = {"cmd", "manual", "wait_s", "check", "action"}
INTERNAL_ACTIONS = {"reset_report_id", "heartbeat"}
# legacy key of "needs_player_approval" in older runbook files (accepted as an alias)
LEGACY_APPROVAL_KEY = "needs_" "gor" "don_approval"


class RunbookError(ValueError):
    pass


@dataclass
class Runbook:
    id: str
    title: str
    symptom: dict
    steps: list
    verify: dict
    needs_player_approval: bool = False
    approval_action: str | None = None
    kb: list = field(default_factory=list)
    params: dict = field(default_factory=dict)
    preconditions: list = field(default_factory=list)
    rollback: list = field(default_factory=list)
    notes: str = ""
    source: str = ""


def _check_text_placeholders(text: Any, where: str) -> None:
    for ph in placeholders(text):
        try:
            compile_expr(ph)
        except ExprError as e:
            raise RunbookError(f"{where}: placeholder {{{ph}}}: {e}") from None


def _validate_steps(steps: Any, where: str) -> list:
    if not isinstance(steps, list) or not steps:
        raise RunbookError(f"{where}: must be a non-empty list")
    for i, st in enumerate(steps):
        w = f"{where}[{i}]"
        if not isinstance(st, dict):
            raise RunbookError(f"{w}: step must be a mapping")
        kinds = STEP_KINDS & set(st)
        if len(kinds) != 1:
            raise RunbookError(f"{w}: give exactly one kind out of {sorted(STEP_KINDS)}")
        k = kinds.pop()
        if k == "check":
            try:
                compile_expr(str(st["check"]))
            except ExprError as e:
                raise RunbookError(f"{w}: {e}") from None
        elif k == "wait_s" and not isinstance(st["wait_s"], (int, float)):
            raise RunbookError(f"{w}: wait_s must be a number")
        elif k == "action":
            a = str(st["action"])
            if a not in INTERNAL_ACTIONS and not a.startswith("delete_flag:"):
                raise RunbookError(f"{w}: unknown internal action {a!r}")
        else:
            _check_text_placeholders(st[k], w)
    return steps


def validate_runbook(d: Any, source: str = "") -> Runbook:
    if not isinstance(d, dict):
        raise RunbookError(f"{source}: runbook must be a mapping")
    rid = d.get("id") or "?"
    w = f"{source}:{rid}"
    for req in ("id", "title", "symptom", "steps", "verify"):
        if not d.get(req):
            raise RunbookError(f"{w}: required field '{req}' missing")
    if LEGACY_APPROVAL_KEY in d:                      # old key name -> alias
        d = dict(d)
        legacy = d.pop(LEGACY_APPROVAL_KEY)
        d.setdefault("needs_player_approval", legacy)
    if "needs_player_approval" not in d or not isinstance(d["needs_player_approval"], bool):
        raise RunbookError(f"{w}: required field 'needs_player_approval' (true/false) missing")
    known = {"id", "title", "symptom", "steps", "verify", "needs_player_approval", "approval_action", "kb", "params",
             "preconditions", "rollback", "notes"}
    if set(d) - known:
        raise RunbookError(f"{w}: unknown fields {sorted(set(d) - known)}")
    sym = d["symptom"]
    if not isinstance(sym, dict) or not sym.get("when"):
        raise RunbookError(f"{w}: symptom.when missing")
    try:
        compile_expr(str(sym["when"]))
        for s in sym.get("signals") or []:
            compile_expr(str(s["when"]))
            float(s.get("add", 0.1))
    except (ExprError, KeyError, TypeError, ValueError) as e:
        raise RunbookError(f"{w}: symptom: {e}") from None
    conf = sym.get("confidence", 0.5)
    if not isinstance(conf, (int, float)) or not 0 < conf <= 1:
        raise RunbookError(f"{w}: symptom.confidence must be in (0, 1]")
    _check_text_placeholders(sym.get("explain", ""), f"{w}: explain")
    steps = _validate_steps(d["steps"], f"{w}: steps")
    ver = d["verify"]
    if not isinstance(ver, dict) or not ver.get("when"):
        raise RunbookError(f"{w}: verify.when missing")
    try:
        compile_expr(str(ver["when"]))
    except ExprError as e:
        raise RunbookError(f"{w}: verify: {e}") from None
    for p in d.get("preconditions") or []:
        if not isinstance(p, dict) or "when" not in p:
            raise RunbookError(f"{w}: precondition needs 'when'")
        try:
            compile_expr(str(p["when"]))
        except ExprError as e:
            raise RunbookError(f"{w}: precondition: {e}") from None
    rollback = _validate_steps(d["rollback"], f"{w}: rollback") if d.get("rollback") else []
    params = d.get("params") or {}
    if not isinstance(params, dict):
        raise RunbookError(f"{w}: params must be a mapping")
    if d["needs_player_approval"] and not d.get("approval_action"):
        raise RunbookError(f"{w}: needs_player_approval=true requires approval_action (register rule, e.g. FP08)")
    return Runbook(id=str(d["id"]), title=str(d["title"]), symptom=sym, steps=steps, verify=ver,
                   needs_player_approval=d["needs_player_approval"], approval_action=d.get("approval_action"),
                   kb=list(d.get("kb") or []), params=params, preconditions=list(d.get("preconditions") or []),
                   rollback=rollback, notes=str(d.get("notes") or ""), source=source)


def load_runbooks(path: Path) -> list[Runbook]:
    files = sorted(path.glob("*.yaml")) if path.is_dir() else [path]
    out, seen = [], set()
    for f in files:
        rb = validate_runbook(yamlmini.load_file(f), f.name)
        if rb.id in seen:
            raise RunbookError(f"{f.name}: duplicate runbook id: {rb.id}")
        seen.add(rb.id)
        out.append(rb)
    return out


@dataclass
class Hit:
    runbook: Runbook
    confidence: float
    reasons: list

    def line(self) -> str:
        appr = " [player approval needed]" if self.runbook.needs_player_approval else ""
        why = ("; ".join(self.reasons))[:140]
        return (f"{self.runbook.id} ({self.confidence:.2f}){appr}: {self.runbook.title}"
                f"{' - ' + why if why else ''} -> dfpilot runbook run {self.runbook.id} --dry-run")


def diagnose(runbooks: list[Runbook], ctx: dict, min_conf: float = 0.3) -> list[Hit]:
    hits = []
    for rb in runbooks:
        try:
            if not evaluate(str(rb.symptom["when"]), ctx):
                continue
        except ExprError:
            continue
        conf = float(rb.symptom.get("confidence", 0.5))
        reasons = []
        if rb.symptom.get("explain"):
            try:
                reasons.append(render(rb.symptom["explain"], ctx))
            except ExprError:
                pass
        for s in rb.symptom.get("signals") or []:
            try:
                if evaluate(str(s["when"]), ctx):
                    conf += float(s.get("add", 0.1))
                    if s.get("why"):
                        reasons.append(str(s["why"]))
            except ExprError:
                continue
        conf = round(min(0.99, conf), 2)
        if conf >= min_conf:
            hits.append(Hit(rb, conf, reasons))
    hits.sort(key=lambda h: (-h.confidence, h.runbook.id))
    return hits


def _params(rb: Runbook, given: dict | None, ctx: dict) -> dict:
    vals = {}
    for name, spec in rb.params.items():
        spec = spec if isinstance(spec, dict) else {"default": spec}
        if given and name in given:
            vals[name] = given[name]
        elif spec.get("default") is not None:
            d = spec["default"]
            vals[name] = render(d, ctx) if isinstance(d, str) and "{" in d else d
        else:
            raise RunbookError(f"{rb.id}: required parameter missing: {name} ({spec.get('desc', '')}). "
                               f"Usage: dfpilot runbook run {rb.id} --param {name}=<value>")
    return vals


def plan_commands(rb: Runbook, ctx: dict, params: dict | None = None) -> list[str]:
    """Exact command list of a run (dry run). Manual steps appear as 'MANUAL: ...'."""
    lctx = dict(ctx)
    lctx.update(_params(rb, params, ctx))
    out = []
    for st in rb.steps:
        if "cmd" in st:
            out.append(render(st["cmd"], lctx))
        elif "manual" in st:
            out.append("MANUAL: " + render(st["manual"], lctx))
        elif "wait_s" in st:
            out.append(f"WAIT {st['wait_s']} s")
        elif "check" in st:
            out.append(f"CHECK: {st['check']}")
        elif "action" in st:
            out.append(f"DFPILOT: {st['action']}")
    out.append(f"VERIFY: {rb.verify['when']} (<= {rb.verify.get('timeout_s', 60)} s)")
    return out


@dataclass
class RunResult:
    runbook: str
    ok: bool
    status: str               # done | verify_failed | precondition | approval | manual | step_failed | dry
    log: list = field(default_factory=list)
    commands: list = field(default_factory=list)


def run_runbook(rb: Runbook, client, ctx_fn: Callable[[], dict], *, clock, dry_run: bool = True,
                params: dict | None = None, registry: ExceptionRegistry | None = None,
                internal: Callable[[str], str] | None = None, stop_at_manual: bool = True) -> RunResult:
    """Run a runbook. ctx_fn() returns a fresh context (new snapshot)."""
    ctx = ctx_fn()
    if rb.needs_player_approval:
        act = rb.approval_action or rb.id
        if registry is None or not registry.allows(act):
            return RunResult(rb.id, False, "approval", [f"refused: {rb.id} needs the player's yes in the exception register "
                                                        f"(action {act}). Without an entry it is not executed."])
    try:
        cmds = plan_commands(rb, ctx, params)
    except RunbookError as e:
        return RunResult(rb.id, False, "precondition", [str(e)])
    if dry_run:
        return RunResult(rb.id, True, "dry", ["dry-run: nothing executed"], cmds)
    for p in rb.preconditions:
        if not evaluate(str(p["when"]), ctx):
            return RunResult(rb.id, False, "precondition", [f"Precondition not met: {p.get('msg', p['when'])}"])
    lctx = dict(ctx)
    lctx.update(_params(rb, params, ctx))
    res = RunResult(rb.id, False, "running")
    for st in rb.steps:
        if "cmd" in st:
            c = render(st["cmd"], lctx)
            try:
                check_command(c, registry)
            except FairPlayError as e:
                res.status, res.log = "step_failed", res.log + [str(e)]
                return res
            r = client.run(c)
            res.commands.append(c)
            res.log.append(f"{'ok' if r.ok else 'ERROR'}: {c}" + ("" if r.ok else f" ({r.stderr.strip()[:80]})"))
            if not r.ok and not st.get("allow_fail"):
                res.status = "step_failed"
                res.log.append("Aborted. Check the rollback: dfpilot runbook show " + rb.id)
                return res
        elif "manual" in st:
            res.log.append("MANUAL: " + render(st["manual"], lctx))
            if stop_at_manual:
                res.status = "manual"
                res.log.append("Run stopped: do the manual step, then carry out the rest by hand.")
                return res
        elif "wait_s" in st:
            clock.sleep(float(st["wait_s"]))
            res.log.append(f"waited {st['wait_s']} s")
        elif "check" in st:
            lctx.update(ctx_fn())
            if not evaluate(str(st["check"]), lctx):
                res.status = "step_failed"
                res.log.append(f"Check failed: {st.get('msg', st['check'])}")
                return res
        elif "action" in st:
            res.log.append(internal(st["action"]) if internal else f"(internal action {st['action']} skipped)")
    timeout = float(rb.verify.get("timeout_s", 60))
    poll = max(1.0, float(rb.verify.get("poll_s", 15)))
    waited = 0.0
    while True:
        vctx = ctx_fn()
        vctx.update(_params(rb, params, vctx))
        if evaluate(str(rb.verify["when"]), vctx):
            res.ok, res.status = True, "done"
            res.log.append(f"verified after {waited:.0f} s: {rb.verify['when']}")
            return res
        if waited >= timeout:
            res.status = "verify_failed"
            res.log.append(f"Verification not met after {timeout:.0f} s: {rb.verify['when']}. "
                           f"Do not repeat blindly; investigate the cause (dfpilot kb get {rb.kb[0] if rb.kb else rb.id}).")
            return res
        clock.sleep(poll)
        waited += poll
