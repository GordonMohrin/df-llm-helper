"""Cross-package integration checks for the v2 tree (static and offline; see docs/v2/STATUS.md).

- every inbox verb has a handler (kern or a module's M.verbs), every K.call target exists,
- every event type a module emits is registered with that module (or 'any') as emitter,
- every act function of contract.ACT is implemented in act.lua (known [S2] stubs listed),
- the config files and plans/year1.json validate,
- reader/hook rules added at integration: state pruning, trust rules, file-tool guard, cmd origins.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

from df_llm_helper import files, hook, lint, schema

ROOT = Path(__file__).resolve().parent.parent
LUA = ROOT / "lua" / "dfllm"
KERN_VERBS = {"plan.reload", "inspect", "module.enable"}
S2_STUBS = {"squad_leader", "squad_uniform", "order_suspend"}   # need live spikes (STATUS.md)


def lua_modules() -> dict[str, str]:
    return {p.stem: p.read_text(encoding="utf-8") for p in LUA.glob("*.lua")}


def test_every_inbox_verb_has_a_handler():
    mods = lua_modules()
    contract = (LUA / "util" / "contract.lua").read_text(encoding="utf-8")
    spec = dict(re.findall(r"\['([a-z.]+)'\]\s*=\s*\{mod = '([a-z]+)'", contract))
    assert set(spec) == set(schema.VERBS)
    kern = mods["kern"]
    for verb, mod in spec.items():
        if mod == "kern":
            assert verb in KERN_VERBS and "local function kern_verb" in kern, verb
            continue
        src = mods.get(mod)
        assert src is not None, f"{verb}: module {mod}.lua missing"
        pat = rf"M\.verbs(\.{re.escape(verb)}\b|\['{re.escape(verb)}'\])|\['{re.escape(verb)}'\]\s*=\s*function"
        assert re.search(pat, src), f"{verb}: no handler in {mod}.lua"


def test_every_kcall_target_exists():
    mods = lua_modules()
    for name, src in mods.items():
        for tgt, fn in re.findall(r"K\.call\(\s*'([a-z_]+)'\s*,\s*'([A-Za-z_]+)'", src):
            if fn == "?":
                continue
            assert tgt in mods, f"{name}: K.call('{tgt}', ...) but {tgt}.lua is missing"
            assert re.search(rf"function M\.{fn}\b|M\.{fn}\s*=", mods[tgt]), f"{name}: {tgt}.{fn} missing"


def test_emitted_events_are_registered_with_their_emitter():
    reg = {t: (cls, by) for t, (cls, by, *_rest) in schema.EVENTS.items()}
    for name, src in lua_modules().items():
        for t in re.findall(r"\bK\.emit\(\s*'([A-Z_0-9]+)'", src) + re.findall(r"emit_as\('kern',\s*'([A-Z_0-9]+)'", src):
            assert t in reg, f"{name}: unregistered event {t}"
            assert reg[t][1] in ("any", name), f"{name} emits {t}, registry says {reg[t][1]}"


def test_act_functions_are_implemented():
    act = (LUA / "act.lua").read_text(encoding="utf-8")
    impl = set(re.findall(r"function I\.([a-z_]+)\(", act))
    for fn in schema.ACT:
        assert fn in impl, f"act.{fn} has no implementation"
    for fn in S2_STUBS:
        body = act.split(f"function I.{fn}(")[1].split("\n  end")[0]
        assert "return false" in body, fn


def test_config_and_plans_validate():
    al = json.loads((ROOT / "config" / "allowlist.json").read_text(encoding="utf-8"))
    assert schema.validate("allowlist", al) == []
    base = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert base.get("v") == 2
    dec = schema.parse_decisions((ROOT / "config" / "decisions.yaml").read_text(encoding="utf-8"))
    assert all(re.fullmatch(r"D-\d\d", k) for k in dec)
    phases = json.loads((ROOT / "plans" / "year1.json").read_text(encoding="utf-8"))
    assert schema.validate("phases", phases) == []


# ---------------------------------------------------------------- reader rule (CONTRACTS §9.3, R1)
def test_read_state_drops_only_invalid_optional_keys(tmp_path):
    good = json.loads(json.dumps(schema.EXAMPLES["state"])) if hasattr(schema, "EXAMPLES") else None
    if good is None:
        good = {"v": 2, "seq": 7, "t": {"y": 3, "tick": 10, "season": 0, "tps": 400, "paused": False},
                "mode": "PEACE", "k": {"ms_s": 3, "gap_max_ms": 40, "slow": [], "faults": 0}, "ev": 5}
    bad = dict(good, seq=good["seq"] + 1, bridges={"O1": "sideways"})
    (tmp_path / "state.a.json").write_text(json.dumps(good), encoding="utf-8")
    (tmp_path / "state.b.json").write_text(json.dumps(bad), encoding="utf-8")
    doc, info = files.read_state_ex(tmp_path)
    assert doc["seq"] == bad["seq"], "the newer slot is used, not discarded"
    assert "bridges" not in doc and info["dropped"] == {"b": ["bridges"]}
    broken = dict(good, seq=good["seq"] + 2, mode="PARTY")
    (tmp_path / "state.a.json").write_text(json.dumps(broken), encoding="utf-8")
    doc, info = files.read_state_ex(tmp_path)
    assert doc["seq"] == bad["seq"], "a slot with an invalid required key is discarded"


# ---------------------------------------------------------------- trust rules (CONTRACTS §13, R6)
@pytest.mark.parametrize("text,ok", [
    ("python -m df_llm_helper cmd lever bridge=O1 want=up --by llm", True),
    ("python -m df_llm_helper cmd lever bridge=O1 want=up", True),
    ("python -m df_llm_helper cmd unpause --by gordon", False),
    ("dfllm --save region1 cmd drill --by=follow", False),
    ("python -m df_llm_helper cmd audit snap=c1", False),
    ("bash -c \"dfllm cmd pause ttl_s=60 --by supervise\"", False),
    ("echo '{\"id\":\"a\",\"verb\":\"unpause\",\"args\":{},\"by\":\"gordon\"}' > 'E:/DF/dfllm-runtime/r1/inbox/1-a.json'", False),
    ("git commit -m \"refuse dfllm cmd --by follow\"", True),
    ("grep -rn -- '--by follow' df_llm_helper", True),
])
def test_trust_rules(text, ok):
    assert lint.cmd(text, shell=True)[0] is ok


@pytest.mark.parametrize("tool,path,code", [
    ("Write", r"E:\Steam\Dwarf Fortress\dfllm-runtime\region1\inbox\1-x.json", 2),
    ("Edit", "C:/repo/dfpilot-public/config/decisions.yaml", 2),
    ("MultiEdit", "/x/dfllm-runtime/region1/plan.json", 2),
    ("Write", "C:/repo/dfpilot-public/docs/v2/STATUS.md", 0),
    ("Edit", "C:/repo/dfpilot-public/config/allowlist.json", 0),
])
def test_hook_guards_file_tools(tool, path, code, tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_HOOK_LOG", str(tmp_path / "hook.log"))
    assert hook.decide({"tool_name": tool, "tool_input": {"file_path": path}})[0] == code


def test_settings_matcher_covers_file_tools():
    s = json.loads((ROOT / ".claude" / "settings.json").read_text(encoding="utf-8"))
    m = s["hooks"]["PreToolUse"][0]["matcher"]
    for tool in hook.TOOLS + hook.FILE_TOOLS:
        assert re.fullmatch(m, tool), tool


def test_cmd_cli_refuses_foreign_origins_and_audit(tmp_path):
    save = tmp_path / "rt" / "region1"
    (save / "inbox").mkdir(parents=True)
    (tmp_path / "rt" / "ACTIVE").write_text("region1", encoding="utf-8")
    base = [sys.executable, "-m", "df_llm_helper", "--runtime", str(tmp_path / "rt")]
    r = subprocess.run(base + ["cmd", "drill", "--by", "follow", "--wait", "0"], capture_output=True, cwd=ROOT,
                       timeout=60)
    assert r.returncode == 2 and b"invalid choice" in r.stderr
    audit = '{"snap":"c1","ok":true,"fails":[],"min_traps":0,"bypass":false,"refuge_sep":true,"civ_sep":true,"caverns":true}'
    r = subprocess.run(base + ["cmd", "audit", audit, "--wait", "0"], capture_output=True, cwd=ROOT, timeout=60)
    assert r.returncode != 0 and b"refused" in r.stdout
    assert not list((save / "inbox").glob("*.json"))
