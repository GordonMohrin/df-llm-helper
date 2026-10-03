"""`install-lua`: copy the bundled Lua scripts into the game (hack/scripts/claude/) and keep the fort's own values.

- `lua/claude/*.lua` and `lua/pilot_*.lua` -> `<DF>/hack/scripts/claude/` (and every extra `claude/` folder listed in
  `dfhack-config/script-paths.txt`, because DFHack searches those first; BUG-420).
- `stages.lua` is never overwritten when the game already has one (fort-specific dig stages).
- `config.lua` is merged: the repo file (new keys, new functions, fixed logic) gets the live values of every top-level
  `KEY = <literal>` assignment the live file has (map coordinates, boxes, tuning numbers). Computed assignments (that
  refer to other names, e.g. `FORT_BOX = { x1 = FORT_X - ... }`) stay as in the repo. Live-only literal keys are kept
  in a block at the end of the map section.
- Every file that is replaced is first copied to `<backup>/<folder name>/` (default `tools/out/lua-backup-<time>/`).
- BUG-226: the Lua runtime folder `<DF>/df-llm-helper-runtime` (util.home() without DF_LLM_HELPER_HOME in the game's
  environment) gets `tools/out` + `tools/scopes`, and the trade rules template `data/trade/handel-regeln.md` is copied
  to `tools/scopes/handel-regeln.md` when no rules file exists there (an existing one is never touched).
Without `--apply` only the plan is printed.
"""
from __future__ import annotations

import re
import shutil
import time
from dataclasses import dataclass, field
from pathlib import Path

__all__ = ["InstallPlan", "plan_install", "apply_install", "merge_config", "assignments", "is_literal", "target_dirs"]

_ASSIGN = re.compile(r"^([A-Z][A-Z0-9_]*(?:\s*,\s*[A-Z][A-Z0-9_]*)*)\s*=(?!=)")   # also FORT_X, FORT_Y = ...
_KEEP_MARK = "-- kept from the live config (keys the repo does not have)"
_DEFAULTS_MARK = re.compile(r"^--[-\s]*DEFAULTS\b", re.M)
_LITERAL_WORDS = {"nil", "true", "false"}
RUNTIME_DIR = "df-llm-helper-runtime"         # util.home() default inside the DF folder


def _strip_strings_comments(text: str) -> str:
    text = re.sub(r"--\[(=*)\[.*?\]\1\]", " ", text, flags=re.S)
    text = re.sub(r"\[(=*)\[.*?\]\1\]", '""', text, flags=re.S)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    text = re.sub(r"'(?:\\.|[^'\\\n])*'", '""', text)
    return re.sub(r"--[^\n]*", " ", text)


def _norm(stmt: str) -> str:
    """Statement without comments and whitespace (a changed comment is no changed value)."""
    return re.sub(r"\s+", "", _strip_strings_comments(stmt)) + "|" + "|".join(re.findall(r'"[^"\n]*"|'
                                                                                       r"'[^'\n]*'", stmt))


def _depth(text: str) -> int:
    t = _strip_strings_comments(text)
    return t.count("{") + t.count("(") - t.count("}") - t.count(")")


def assignments(text: str) -> dict[str, tuple[int, int, str]]:
    """Top-level `KEY = ...` statements: name -> (first line, last line exclusive, text). Multi-line tables are followed
    until their braces are balanced. Only statements that start in column 0 count (no locals, nothing inside blocks)."""
    lines = text.splitlines(keepends=True)
    out: dict[str, tuple[int, int, str]] = {}
    i = 0
    while i < len(lines):
        m = _ASSIGN.match(lines[i])
        if not m:
            i += 1
            continue
        j, depth = i + 1, _depth(lines[i])
        while depth > 0 and j < len(lines):
            depth += _depth(lines[j])
            j += 1
        out.setdefault(re.sub(r"\s+", "", m.group(1)), (i, j, "".join(lines[i:j])))
        i = j
    return out


def is_literal(stmt: str) -> bool:
    """True when the value only consists of numbers, strings, nil/true/false and tables of those (table keys allowed)."""
    value = _strip_strings_comments(stmt.split("=", 1)[1])
    value = re.sub(r"\[\s*-?\d+\s*\]\s*=(?!=)", " ", value)                 # [3] = ...
    value = re.sub(r"\b[A-Za-z_]\w*\s*=(?!=)", " ", value)                   # name = ... inside tables
    value = re.sub(r"\b\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\b|0x[0-9a-fA-F]+", " ", value)
    words = set(re.findall(r"[A-Za-z_]\w*", value))
    return words <= _LITERAL_WORDS and not re.search(r"[.:]\s*[A-Za-z_]|\.\.", value)


def merge_config(repo_text: str, live_text: str) -> tuple[str, list[str]]:
    """Repo config with the live literal values. Returns (merged text, notes)."""
    repo, live = assignments(repo_text), assignments(live_text)
    lines = repo_text.splitlines(keepends=True)
    notes: list[str] = []
    replace: dict[int, tuple[int, str]] = {}
    for name, (a, b, stmt) in repo.items():
        if name not in live:
            notes.append(f"new key {name} (repo default)")
            continue
        lstmt = live[name][2]
        if not is_literal(lstmt):
            if _norm(lstmt) != _norm(stmt):
                notes.append(f"{name}: live value is computed - repo version kept")
            continue
        if _norm(lstmt) != _norm(stmt):
            replace[a] = (b, lstmt if lstmt.endswith("\n") else lstmt + "\n")
            notes.append(f"{name}: live value kept")
    extra = [live[n][2] for n in live if n not in repo and is_literal(live[n][2])]
    dropped = [n for n in live if n not in repo and not is_literal(live[n][2])]
    notes += [f"{n}: live-only computed key dropped" for n in dropped]
    out, i = [], 0
    while i < len(lines):
        if i in replace:
            b, txt = replace[i]
            out.append(txt)
            i = b
        else:
            out.append(lines[i])
            i += 1
    merged = "".join(out)
    if extra:
        block = _KEEP_MARK + "\n" + "".join(s if s.endswith("\n") else s + "\n" for s in extra) + "\n"
        m = _DEFAULTS_MARK.search(merged)
        merged = merged[:m.start()] + block + merged[m.start():] if m else merged + "\n" + block
        notes += [f"{_ASSIGN.match(s).group(1)}: live-only key kept" for s in extra]
    return merged, notes


def target_dirs(df_dir: Path) -> list[Path]:
    """hack/scripts/claude plus every '<path>/claude' folder of dfhack-config/script-paths.txt that exists."""
    dirs = [df_dir / "hack" / "scripts" / "claude"]
    sp = df_dir / "dfhack-config" / "script-paths.txt"
    if sp.is_file():
        for line in sp.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            p = Path(line.lstrip("+-").strip())
            if not p.is_absolute():
                p = df_dir / p
            if (p / "claude").is_dir() and (p / "claude").resolve() not in [d.resolve() for d in dirs if d.exists()]:
                dirs.append(p / "claude")
    return dirs


@dataclass
class InstallPlan:
    df_dir: Path
    targets: list[Path]
    copies: list[tuple[Path, Path, str]] = field(default_factory=list)   # (source, destination, what)
    config: list[tuple[Path, str, list[str]]] = field(default_factory=list)  # (destination, merged text, notes)
    skipped: list[str] = field(default_factory=list)
    runtime: list[tuple[Path, Path, str]] = field(default_factory=list)  # (source, destination, new|kept)

    def lines(self) -> list[str]:
        out = [f"Install into: " + ", ".join(str(t) for t in self.targets)]
        new = sum(1 for c in self.copies if c[2] == "new")
        upd = sum(1 for c in self.copies if c[2] == "update")
        same = sum(1 for c in self.copies if c[2] == "same")
        out.append(f"Scripts: {upd} replaced, {new} new, {same} unchanged")
        for dst, _, notes in self.config:
            out.append(f"config.lua merged ({dst}): " + ("; ".join(notes[:12]) or "no differences")
                       + (f" (+{len(notes) - 12} more)" if len(notes) > 12 else ""))
        for _, dst, what in self.runtime:
            out.append(f"Trade rules {dst}: " + ("new (template data/trade/handel-regeln.md)" if what == "new" else
                                                 "kept (existing rules file)"))
        out += self.skipped
        return out


def plan_install(repo: Path, df_dir: Path) -> InstallPlan:
    if not (df_dir / "hack").is_dir():
        raise ValueError(f"not a Dwarf Fortress folder with DFHack (no hack/): {df_dir}")
    plan = InstallPlan(df_dir, target_dirs(df_dir))
    srcs = sorted((repo / "lua" / "claude").glob("*.lua")) + sorted((repo / "lua").glob("pilot_*.lua"))
    for tgt in plan.targets:
        for src in srcs:
            dst = tgt / src.name
            if src.name == "stages.lua" and dst.exists():
                plan.skipped.append(f"{dst}: kept (fort-specific dig stages, example in examples/)")
                continue
            if src.name == "config.lua" and dst.exists():
                merged, notes = merge_config(src.read_text(encoding="utf-8"),
                                             dst.read_text(encoding="utf-8", errors="replace"))
                plan.config.append((dst, merged, notes))
                continue
            what = "new" if not dst.exists() else ("same" if dst.read_bytes() == src.read_bytes() else "update")
            plan.copies.append((src, dst, what))
    rules = repo / "data" / "trade" / "handel-regeln.md"
    if rules.is_file():
        dst = df_dir / RUNTIME_DIR / "tools" / "scopes" / "handel-regeln.md"
        plan.runtime.append((rules, dst, "kept" if dst.exists() else "new"))
    return plan


def apply_install(plan: InstallPlan, backup_root: Path) -> list[str]:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = backup_root / f"lua-backup-{stamp}"
    done = 0
    for i, tgt in enumerate(plan.targets):
        tgt.mkdir(parents=True, exist_ok=True)
        (backup / f"{i}_{tgt.parent.name}_{tgt.name}").mkdir(parents=True, exist_ok=True)

    def save(dst: Path) -> None:
        i = next(k for k, t in enumerate(plan.targets) if dst.parent == t)
        shutil.copy2(dst, backup / f"{i}_{plan.targets[i].parent.name}_{plan.targets[i].name}" / dst.name)

    for src, dst, what in plan.copies:
        if what == "same":
            continue
        if dst.exists():
            save(dst)
        shutil.copy2(src, dst)
        done += 1
    for dst, merged, _ in plan.config:
        save(dst)
        dst.write_text(merged, encoding="utf-8", newline="\n")
        done += 1
    for src, dst, what in plan.runtime:                  # BUG-226: runtime folder + rules template
        (dst.parent.parent / "out").mkdir(parents=True, exist_ok=True)
        dst.parent.mkdir(parents=True, exist_ok=True)
        if what == "new" and not dst.exists():
            shutil.copy2(src, dst)
            done += 1
    return [f"{done} files written; backup of the replaced files: {backup}",
            "Next: dfhack-run claude/config and python -m df_llm_helper check - reqscript reloads changed scripts, "
            "running repeat jobs (watchdog, mil guard, ...) pick them up on their next call or after `claude/tempo load`"]
