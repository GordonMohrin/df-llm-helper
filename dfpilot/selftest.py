"""Self-test without DF: python -m dfpilot.selftest [--cov] [--quick]

1. quick checks (load rules/runbooks/KB/scenarios, digest/briefing token targets on fixtures/run5)
2. the complete pytest suite (if pytest is installed)
3. optional line coverage of the core modules (coverage, otherwise an own sys.settrace counter)
"""
from __future__ import annotations

import argparse
import ast
import sys
import threading
import time
from pathlib import Path

from .config import HOME

CORE = ["digest", "rules", "runbooks", "kb", "brief", "guard", "bus", "lint", "transport", "planners"]


def quick_checks() -> list[tuple[str, bool, str]]:
    from .brief import SCOPES, build_brief, load_scopes
    from .client import MockClient
    from .config import DEFAULTS
    from .digest import DigestState, build_digest, tokens
    from .kb import KB
    from .rules import build_context, find_conflicts, load_rules
    from .runbooks import diagnose, load_runbooks
    from .scenario import check_expectations, run_scenario
    from .snapshot import fixture_snapshot
    res = []
    fix = HOME / "fixtures" / "run5"
    s = fixture_snapshot(fix)
    t1, st = build_digest(s, DigestState(), th=DEFAULTS["thresholds"])
    t2, _ = build_digest(s, st, th=DEFAULTS["thresholds"])
    res.append(("Digest fixtures/run5 <= 600 tokens", tokens(t1) <= 600, f"{tokens(t1)} tokens"))
    res.append(("Digest without change <= 30 tokens", tokens(t2) <= 30, f"{tokens(t2)} tokens"))
    rules = load_rules(HOME / "data" / "rules")
    bad = [c for c in find_conflicts(rules) if c.startswith("CONFLICT")]
    res.append(("Load rules, no conflicts", not bad, f"{len(rules)} rules"))
    rbs = load_runbooks(HOME / "data" / "runbooks")
    res.append(("Runbooks valid (>= 12)", len(rbs) >= 12, f"{len(rbs)} runbooks"))
    ctx = build_context(s, cfg=DEFAULTS)
    res.append(("Diagnosis on fixtures", True, ", ".join(h.runbook.id for h in diagnose(rbs, ctx)[:4])))
    kb = KB.load_dir(HOME / "data" / "kb")
    res.append(("Load KB", len(kb.entries) > 30, f"{len(kb.entries)} entries"))
    sd = load_scopes(HOME / "data" / "scopes.yaml")
    worst = max(tokens(build_brief(sc, scopes_def=sd, ctx=ctx, snap=s, kb=kb, memory_text=None, inbox_lines=None,
                                   th=DEFAULTS["thresholds"])) for sc in SCOPES)
    res.append(("Briefings <= 1500 tokens (12 scopes)", worst <= 1500, f"max {worst} tokens"))
    scen = sorted((HOME / "scenarios").glob("*.jsonl"))
    fails = [p.stem for p in scen if check_expectations(run_scenario(p))]
    res.append((f"Scenarios ({len(scen)})", not fails and len(scen) >= 8, "all ok" if not fails else ",".join(fails)))
    mc = MockClient({})
    try:
        mc.run("createitem PICK")
        res.append(("Fair-play block", False, "createitem not blocked!"))
    except PermissionError:
        res.append(("Fair-play block", True, "createitem blocked"))
    return res


class LineTracer:
    """Own line counter (if 'coverage' is missing)."""

    def __init__(self, files: list[Path]):
        self.files = {str(f.resolve()): f for f in files}
        self.hit: dict[str, set] = {k: set() for k in self.files}

    def _trace(self, frame, event, arg):
        fn = frame.f_code.co_filename
        if fn not in self.hit:
            return None
        if event == "line":
            self.hit[fn].add(frame.f_lineno)
        return self._trace

    def __enter__(self):
        self._old = sys.gettrace()            # remember a foreign tracer (e.g. coverage)
        sys.settrace(self._trace)
        threading.settrace(self._trace)
        return self

    def __exit__(self, *a):
        sys.settrace(self._old)
        threading.settrace(self._old)

    @staticmethod
    def executable(path: Path) -> set:
        tree = ast.parse(path.read_text(encoding="utf-8"))
        lines = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.stmt) and not isinstance(node, (ast.FunctionDef, ast.ClassDef, ast.AsyncFunctionDef)):
                if isinstance(node, ast.Expr) and isinstance(getattr(node, "value", None), ast.Constant):
                    continue        # docstrings
                lines.add(node.lineno)
            elif isinstance(node, (ast.FunctionDef, ast.ClassDef)):
                lines.add(node.lineno)
        return lines

    def report(self) -> dict[str, float]:
        out = {}
        for fn, path in self.files.items():
            ex = self.executable(path)
            hit = self.hit[fn] | {ln for ln in ex if ln in self._def_lines(path)}
            out[path.stem] = 100.0 * len(ex & hit) / max(1, len(ex))
        return out

    @staticmethod
    def _def_lines(path: Path) -> set:
        # definitions/imports run at import time (before the tracer) -> count them as executed
        tree = ast.parse(path.read_text(encoding="utf-8"))
        return {n.lineno for n in tree.body}


def core_files() -> list[Path]:
    pkg = HOME / "dfpilot"
    out = []
    for name in CORE:
        p = pkg / f"{name}.py"
        if p.exists():
            out.append(p)
        elif (pkg / name).is_dir():
            out += sorted((pkg / name).glob("*.py"))
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="dfpilot.selftest")
    ap.add_argument("--cov", action="store_true", help="measure line coverage of the core modules (target >= 90 %%)")
    ap.add_argument("--quick", action="store_true", help="quick checks only, no pytest")
    args = ap.parse_args(argv)
    t0 = time.time()
    ok = True
    cov = None
    tracer = None
    if args.cov and not args.quick:        # start before all imports, otherwise module lines are missing
        try:
            import coverage
            cov = coverage.Coverage(source=[str(HOME / "dfpilot")], data_file=None)
            cov.start()
        except ImportError:
            tracer = LineTracer(core_files())
            tracer.__enter__()
    print("dfpilot self-test (without DF)")
    for name, good, info in quick_checks():
        print(f"  [{'ok' if good else 'FAIL'}] {name}: {info}")
        ok &= good
    if not args.quick:
        try:
            import pytest
        except ImportError:
            print("  [!] pytest not installed - only quick checks ran (pip install pytest after confirming with the player)")
            return 0 if ok else 1
        rc = pytest.main(["-q", "-p", "no:cacheprovider", str(HOME / "tests")])
        if cov is not None:
            cov.stop()
            print("\nCoverage (coverage) of the core modules:")
            for f in core_files():
                try:
                    _, stmts, _, missing, _ = cov.analysis2(str(f))
                    pct = 100.0 * (len(stmts) - len(missing)) / max(1, len(stmts))
                except Exception:
                    pct = 0.0
                print(f"  {f.stem:10s} {pct:5.1f} %")
                ok &= pct >= 90
        if tracer is not None:
            tracer.__exit__()
            print("\nCoverage (own counter, sys.settrace) of the core modules:")
            for name, pct in tracer.report().items():
                print(f"  {name:10s} {pct:5.1f} %")
                ok &= pct >= 90
        ok &= rc == 0
    dt = time.time() - t0
    print(f"\nSelf-test {'GREEN' if ok else 'RED'} in {dt:.1f} s")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
