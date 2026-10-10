"""WP2 <-> kernel files across languages: Lua (k_mock + dfllm.util.json on lua53.dll) writes state/events,
Python reads them; Python writes inbox files, Lua decodes them and routes them like kern (W.inbox)."""
import sys
from pathlib import Path

import pytest

from df_llm_helper import files

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

pytestmark = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")

WRITER = r"""
local json = require('dfllm.util.json')
local kmock = require('dfllm.util.k_mock')
local dir = arg[1]
local W = kmock.new{year = 3, ytick = 100000, save = 'region7', globals = true}
W.run(1200, {skip = 9})                      -- crosses the season boundary: SEASON event
local function put(name, s) local f = assert(io.open(dir .. '/' .. name, 'wb')); f:write(s); f:close() end
local a, b = W.state(), W.state()            -- two consecutive writes; the newer one is torn
put('state.a.json', json.encode(a))
put('state.b.json', string.sub(json.encode(b), 1, 30))   -- torn write of the newer slot
local lines = {}
for _, e in ipairs(W.events) do lines[#lines + 1] = json.encode(e) .. '\n' end
put('events.jsonl', table.concat(lines))
print(#W.events, a.seq, b.seq)
"""

READER = r"""
local json = require('dfllm.util.json')
local kmock = require('dfllm.util.k_mock')
local f = assert(io.open(arg[1], 'rb')); local doc = json.decode(f:read('a')); f:close()
local W = kmock.new{year = 3, ytick = 0, save = 'region7', globals = true}
local r = W.inbox(doc.verb, doc.args, {id = doc.id, by = doc.by})
print(doc.id, doc.verb, doc.by, r.id, tostring(r.ok), r.msg)
"""


def _run(tmp_path, src, *args):
    p = tmp_path / "t.lua"
    p.write_text(src, encoding="utf-8")
    r = luahost.run_file(p, list(args), timeout=30)
    assert r.ok, f"{r.code}\n{r.out}\n{r.err}"
    return r.out.split()


def test_lua_written_state_and_events_read_by_python(tmp_path):
    out = _run(tmp_path, WRITER, str(tmp_path).replace("\\", "/"))
    n_events, seq_a, seq_b = map(int, out[:3])
    doc, info = files.read_state_ex(tmp_path, sleep=lambda s: None)
    assert seq_b == seq_a + 1                                  # the torn newer slot loses
    assert doc is not None and doc["seq"] == seq_a and info["slot"] == "a" and "b" in info["errors"]
    assert doc["save"] == "region7" and doc["t"]["season"] in (0, 1)
    evs = files.tail_events(tmp_path, 0, limit=0)
    assert len(evs) == n_events >= 1 and any(e["type"] == "SEASON" for e in evs)


def test_python_inbox_routed_by_lua(tmp_path):
    cid = files.write_inbox(tmp_path, "inspect", {"what": "mode"}, by="llm")
    (p,) = (tmp_path / "inbox").glob(f"*-{cid}.json")
    out = _run(tmp_path, READER, str(p).replace("\\", "/"))
    assert out[:6] == [cid, "inspect", "llm", cid, "true", "PEACE"]
