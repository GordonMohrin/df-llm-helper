"""`python -m df_llm_helper` (alias dfllm), DESIGN §7. Reads runtime files only; never calls DF.

bp (WP3), lint/hook (WP4) and supervise (WP10) are imported lazily, so they are optional.
"""
from __future__ import annotations

import argparse
import importlib
import sys
import time
from pathlib import Path

from . import paths


def _parser() -> argparse.ArgumentParser:
    from . import brief, cmd, doctor, events, plan, wake
    ap = argparse.ArgumentParser(prog="dfllm", description="df-llm-helper v2 (files only, 0 DF calls)")
    ap.add_argument("--runtime", help="runtime root (default <DF>/dfllm-runtime or $DFLLM_RUNTIME)")
    ap.add_argument("--save", help="save folder (default: ACTIVE, else the newest)")
    ap.add_argument("--df", help="DF folder (default $DFLLM_DF or the Steam path)")
    sub = ap.add_subparsers(dest="command", required=True)
    brief.add_parsers(sub)
    wake.add_parser(sub)
    events.add_parser(sub)
    plan.add_parser(sub)
    cmd.add_parser(sub)
    p = sub.add_parser("bp", help="blueprints: list | preview <tpl> | sites <tpl>")
    p.add_argument("action", choices=["list", "preview", "sites"])
    p.add_argument("tpl", nargs="?")
    p.add_argument("params", nargs="*", help="template params k=v")
    p.add_argument("--site", help="preview at a ranked site label (default: at the origin)")
    p.add_argument("--fresh", action="store_true", help="sites: request a new snapshot first and wait for it")
    p.add_argument("--timeout", type=float, default=60.0)
    doctor.add_parser(sub)
    p = sub.add_parser("supervise", help="liveness, backup, restart (WP10; other flags pass through)")
    p.add_argument("--once", action="store_true")
    p = sub.add_parser("lint", help="fair-play lint of Lua files or a command line (WP4); hook entry")
    p.add_argument("paths", nargs="*")
    p.add_argument("--cmd", help="check one command line")
    p.add_argument("--hook", action="store_true", help="read a PreToolUse hook payload from stdin")
    return ap


# ---------------------------------------------------------------- bp (WP3)
def _bp_site_origin() -> dict:
    return {"id": "S0", "anchor": [0, 0, 0], "rot": 0, "score": 0, "why": "preview at origin"}


def render_ascii(doc: dict, max_w: int = 60, max_h: int = 30) -> str:
    """Fallback preview: per z the union of all stage cells (later stages overwrite), relative to the anchor."""
    grid: dict[int, dict[tuple[int, int], str]] = {}
    ax, ay, az = doc.get("anchor", [0, 0, 0])
    for st in doc.get("stages", []):
        for ch in st.get("chunks", []):
            px, py, pz = ch["pos"]
            for dx, dy, dz, text in ch["cells"]:
                c = "." if st["mode"] == "dig" and text == "d" else (text[:1] or "?")
                grid.setdefault(pz + dz - az, {})[(px + dx - ax, py + dy - ay)] = c
    out = []
    for z in sorted(grid):
        cells = grid[z]
        xs, ys = [x for x, _ in cells], [y for _, y in cells]
        x0, y0 = min(xs), min(ys)
        out.append(f"z{z:+d} ({max(xs) - x0 + 1}x{max(ys) - y0 + 1})")
        for y in range(y0, min(max(ys), y0 + max_h - 1) + 1):
            out.append("".join(cells.get((x, y), " ") for x in range(x0, min(max(xs), x0 + max_w - 1) + 1)).rstrip())
    return "\n".join(out)


def _templates_listing() -> list[str]:
    from .cmd import load_bp, template_info
    load_bp("emit")                                    # raises BpUnavailable with the import error
    info = template_info()
    if info is None:
        raise RuntimeError("bp.emit publishes no template registry (list_templates()/TEMPLATES)")
    out = []
    for tpl in sorted(info):
        about, ps = info[tpl]["about"], info[tpl]["params"]
        out.append(f"{tpl}: {about}".rstrip(": ") + (" | " + " ".join(f"{k}={v}" for k, v in ps.items()) if ps else ""))
    return out


def _preview(save_dir: Path, tpl: str, params: dict, label: str | None) -> str:
    """bp.render.preview(tpl, params, site) (WP3) if present, else emit + the fallback renderer.
    With a label, at the site `bp.place site=<label>` would use now (the k-th free site)."""
    from .cmd import BpUnavailable, _call_bp, emit_at, load_bp, place
    doc = place(save_dir, tpl, params, label, "preview") if label else None
    site = {"id": label, "anchor": doc["anchor"], "rot": doc["rot"]} if doc else _bp_site_origin()
    try:
        prev = load_bp("render").preview
    except (BpUnavailable, AttributeError):
        prev = None
    if callable(prev):
        return _call_bp(f"bp.render.preview({tpl})", prev, tpl, params, site)
    doc = doc or emit_at(tpl, params, site, site["id"], "preview")
    n = sum(len(c["cells"]) for s in doc["stages"] for c in s["chunks"])
    return (render_ascii(doc) + f"\n{tpl} class {doc['class']} stages {len(doc['stages'])} cells {n} materials "
            + (" ".join(f"{k}={v}" for k, v in sorted(doc["materials"].items())) or "-"))


def _wait_snapshot(save_dir: Path, cid: str, timeout: float) -> dict | None:
    from . import files
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        for p in [save_dir / "snap" / f"{cid}.json", *sorted((save_dir / "snap").glob(f"{cid}-*.json"))]:
            doc = files.read_snapshot(p) if p.exists() else None
            if doc:
                return doc
        time.sleep(0.5)
    return None


def run_bp(args, save_dir: Path) -> int:
    from . import files
    from .cmd import BpError, BpUnavailable, fmt_params, free_sites, parse_kv, send
    try:
        if args.action == "list":
            for line in _templates_listing():
                print(line)
            return 0
        if not args.tpl:
            print(f"bp {args.action} needs a template name")
            return 2
        params = parse_kv(args.params)
        if args.action == "preview":
            print(_preview(save_dir, args.tpl, params, args.site))
            return 0
        snap = None
        if args.fresh:
            cid, reply = send(save_dir, "snapshot", {"purpose": "sites"}, by="cli", wait_s=min(10.0, args.timeout))
            if reply is not None and not reply.get("ok"):
                print(f"snapshot refused: {reply.get('msg')}")
                return 1
            snap = _wait_snapshot(save_dir, cid, args.timeout)
            if snap is None:
                print(f"no snapshot {cid} within {args.timeout:.0f}s")
                return 3
        sites, snap_id, ranked = free_sites(save_dir, args.tpl, params, snap)
        print(f"free sites for {args.tpl}{fmt_params(params)} on snapshot {snap_id} ({ranked} ranked; place: "
              f"dfllm cmd bp.place tpl={args.tpl} site=S1{fmt_params(params)} --by llm):")
        for s in sites:
            print(f"  {s.get('id')} anchor {s.get('anchor')} rot {s.get('rot')} score {s.get('score')}: {s.get('why', '')}")
        if not sites:
            print("  none (taken by other projects or no valid site): try --fresh")
        return 0
    except (BpError, BpUnavailable, RuntimeError, ValueError) as e:
        print(f"bp: {e}")
        files.log_cli(save_dir, "cli", f"bp.{args.action}", {"tpl": args.tpl}, f"ERR {e}")
        return 1


# ---------------------------------------------------------------- delegations (WP10, WP4)
def run_supervise(args) -> int:
    from . import files
    try:
        sup = importlib.import_module("df_llm_helper.supervise")
    except ImportError as e:
        print(f"supervise not available ({e})")
        return 2
    if callable(getattr(sup, "main", None)):
        return sup.main((["--once"] if args.once else []) + args.extra) or 0
    while True:
        print(files.dumps(sup.once()), flush=True)
        if args.once:
            return 0
        time.sleep(60)


def run_lint(args) -> int:
    try:
        lint = importlib.import_module("df_llm_helper.lint")
    except ImportError as e:
        print(f"lint not available ({e})")
        return 2
    if args.hook:
        hook = importlib.import_module("df_llm_helper.hook")
        f = getattr(hook, "main", None) or getattr(hook, "run", None)
        if not callable(f):
            print("hook.main not available")
            return 2
        return f() or 0
    if callable(getattr(lint, "main", None)):            # WP4's own CLI (same flags)
        return lint.main((["--cmd", args.cmd] if args.cmd is not None else []) + list(args.paths)) or 0
    if args.cmd is not None:
        if not callable(getattr(lint, "cmd", None)):
            print("lint.cmd not available (WP4)")
            return 2
        ok, reason = lint.cmd(args.cmd)
        print(("allowed" if ok else "blocked") + (f": {reason}" if reason else ""))
        return 0 if ok else 2
    if not callable(getattr(lint, "lua", None)):
        print("lint.lua not available (WP4)")
        return 2
    targets = args.paths or [str(paths.repo_dir() / "lua" / "dfllm")]
    findings = lint.lua(targets)
    for f in findings:
        print(f"{f.get('file')}:{f.get('line')}: {f.get('rule')} {f.get('msg')}")
    print(f"{len(findings)} finding(s)")
    return 1 if findings else 0


# ---------------------------------------------------------------- main
def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except (OSError, ValueError):
            pass
    ap = _parser()
    args, extra = ap.parse_known_args(argv)
    if extra and args.command != "supervise":
        ap.error(f"unrecognized arguments: {' '.join(extra)}")
    args.extra = extra
    paths.set_overrides(df=args.df, runtime=args.runtime, save=args.save)
    args.save_pin = args.save
    c = args.command
    if c == "follow":
        from . import wake
        return wake.run(args)
    if c == "supervise":
        return run_supervise(args)
    if c == "lint":
        return run_lint(args)
    try:
        save_dir = paths.save_dir()
    except paths.NoSave as e:
        print(f"dfllm: {e}")
        return 2
    if c == "status":
        from .brief import run_status
        return run_status(args, save_dir)
    if c == "brief":
        from .brief import run_brief
        return run_brief(args, save_dir)
    if c == "events":
        from .events import run
        return run(args, save_dir)
    if c == "plan":
        from .plan import run
        return run(args, save_dir)
    if c == "cmd":
        from .cmd import run
        return run(args, save_dir)
    if c == "doctor":
        from .doctor import run
        return run(args, save_dir)
    if c == "bp":
        return run_bp(args, save_dir)
    return 2


if __name__ == "__main__":
    sys.exit(main())
