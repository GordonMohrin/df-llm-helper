"""Shared helpers for tests/test_cli_*.py (v2 CLI, WP2): fixture runtime copy, fake kern, fake bp modules."""
from __future__ import annotations

import importlib
import json
import os
import shutil
import sys
import threading
import time
import types
from pathlib import Path

from df_llm_helper import files, paths

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "tests" / "fixtures" / "v2"
RUNTIME = FIX / "runtime"
SAVE = "region7"


def make_runtime(tmp_path: Path) -> Path:
    """Copy the fixture runtime, point paths at it, make the heartbeat fresh. Returns the save dir."""
    rt = tmp_path / "rt"
    shutil.copytree(RUNTIME, rt)
    paths.set_overrides(runtime=str(rt))
    d = rt / SAVE
    now = time.time()
    os.utime(d / "heartbeat", (now, now))
    return d


def reset_paths() -> None:
    paths.set_overrides()


def append_events(save_dir: Path, evs: list[dict], partial: str = "") -> None:
    """Append complete event lines (replacing a torn tail first, like kern's next append completes it)."""
    p = Path(save_dir) / "events.jsonl"
    data = p.read_bytes()
    if data and not data.endswith(b"\n"):
        data = data[:data.rfind(b"\n") + 1]
    data += "".join(files.dumps(e) + "\n" for e in evs).encode() + partial.encode()
    p.write_bytes(data)


def ev(n: int, typ: str, msg: str = "", d: dict | None = None, tick: int = 3 * 403200 + 124000) -> dict:
    from df_llm_helper import schema
    return {"n": n, "tick": tick, "type": typ, "cls": schema.EVENTS[typ][0], "msg": msg, "d": d or {}}


def inbox_docs(save_dir: Path) -> list[dict]:
    return [json.loads(p.read_text(encoding="utf-8")) for p in sorted((Path(save_dir) / "inbox").glob("*.json"))]


class FakeKern:
    """Thread that answers inbox files like kern: reply(doc) -> (ok, msg, data); deletes the inbox file."""

    def __init__(self, save_dir: Path, reply=None):
        self.dir = Path(save_dir)
        self.reply = reply or (lambda doc: (True, "ok", None))
        self.seen: list[dict] = []
        self._stop = threading.Event()
        self._t = threading.Thread(target=self._loop, daemon=True)

    def __enter__(self):
        self._t.start()
        return self

    def __exit__(self, *a):
        self._stop.set()
        self._t.join(2)

    def _loop(self):
        while not self._stop.is_set():
            for p in sorted((self.dir / "inbox").glob("*.json")) if (self.dir / "inbox").is_dir() else []:
                try:
                    doc = json.loads(p.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    continue
                ok, msg, data = self.reply(doc)
                out = {"id": doc["id"], "ok": ok, "msg": msg, "verb": doc["verb"], "tick": 1333100}
                if data is not None:
                    out["data"] = data
                files.write_json_atomic(self.dir / "outbox" / f"{doc['id']}.json", out)
                self.seen.append(doc)
                p.unlink()
            time.sleep(0.02)


def bp_doc(tpl: str, site: dict, params: dict) -> dict:
    """A small valid §9.8 document (without id), like bp.emit returns."""
    x, y, z = site["anchor"]
    return {"v": 2, "tpl": tpl, "site": site["id"], "class": "living", "params": dict(params),
            "anchor": [x, y, z], "rot": site.get("rot", 0),
            "stages": [{"label": "s1.dig", "mode": "dig", "orders": 0, "defense": 0,
                        "chunks": [{"pos": [x, y, z], "cells": [[0, 0, 0, "d"], [1, 0, 0, "d"], [2, 0, 0, "d"]]}]},
                       {"label": "s1.build", "mode": "build", "orders": 1, "defense": 0,
                        "chunks": [{"pos": [x, y, z], "cells": [[1, 0, 0, "b"]]}]}],
            "manifest": {"v": 2}, "materials": {"bed": 1}}


def install_fake_bp(monkeypatch, audit_result=None, audit_exc=None, sites=None, templates=("bedrooms", "tombs",
                                                                                              "temple", "fortcore",
                                                                                              "dining", "hospital",
                                                                                              "tavern", "workshops")):
    """Fake df_llm_helper.bp.{emit,sites,topo,render} in sys.modules; returns a dict of recorded calls."""
    try:                                       # import the real package first, so its __init__ never sees fakes
        importlib.import_module("df_llm_helper.bp")
    except Exception:                          # noqa: BLE001 - WP3 missing or broken: the fakes stand alone
        pass
    calls: dict[str, list] = {"emit": [], "rank": [], "audit": []}
    emit = types.ModuleType("df_llm_helper.bp.emit")

    def _emit(tpl, params, site):
        calls["emit"].append((tpl, params, site))
        return bp_doc(tpl, site, params)
    emit.emit = _emit
    emit.list_templates = lambda: [{"tpl": t, "params": {"stage": 1} if t == "fortcore" else {"n": 10},
                                    "about": f"{t} template"} for t in sorted(templates)]
    st = types.ModuleType("df_llm_helper.bp.sites")

    def _rank(snap, tpl, params=None, n=3):
        """Sites 5 tiles apart on one row (the fake emit digs 3 tiles from the anchor: no clash)."""
        calls["rank"].append((snap["id"], tpl, params))
        if callable(sites):
            return sites(snap, tpl, params, n)
        return sites if sites is not None else [
            {"id": f"S{i}", "anchor": [40 + 5 * i, 32, 120], "rot": 0, "score": 100 - i, "why": f"site {i}"}
            for i in range(1, n + 1)]
    st.rank = _rank
    topo = types.ModuleType("df_llm_helper.bp.topo")

    def _audit(snap, manifest):
        calls["audit"].append((snap["id"], manifest))
        if audit_exc:
            raise audit_exc
        return audit_result or {"ok": False, "fails": ["traps<30"], "min_traps": 22, "bypass": False,
                                "refuge_sep": True, "civ_sep": True, "caverns": True}
    topo.audit = _audit
    render = types.ModuleType("df_llm_helper.bp.render")    # no preview(): the CLI fallback renderer is used
    for name, mod in (("emit", emit), ("sites", st), ("topo", topo), ("render", render)):
        monkeypatch.setitem(sys.modules, f"df_llm_helper.bp.{name}", mod)
    return calls
