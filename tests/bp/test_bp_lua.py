"""WP3 documents are consumable by the Lua side: decode with dfllm.util.json on DFHack's lua53.dll, build the
quickfort `data[dz][dy][dx]` map per chunk exactly as CONTRACTS §9.8 tells the runner, re-encode losslessly."""
import json
import sys
from pathlib import Path

import pytest

from df_llm_helper import bp

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

pytestmark = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")

LUA = r"""
local json = require('dfllm.util.json')
local f = assert(io.open(arg[1], 'rb')); local text = f:read('a'); f:close()
local docs = json.decode(text)
local cells, chunks, maxw = 0, 0, 0
for _, doc in ipairs(docs) do
  for _, st in ipairs(doc.stages) do
    for _, ch in ipairs(st.chunks) do
      chunks = chunks + 1
      local data, n = {}, 0
      for _, c in ipairs(ch.cells) do
        local dx, dy, dz, t = c[1], c[2], c[3], c[4]
        assert(math.type(dx) == 'integer' and math.type(dz) == 'integer', 'integer offsets')
        data[dz] = data[dz] or {}; data[dz][dy] = data[dz][dy] or {}
        assert(data[dz][dy][dx] == nil, 'duplicate cell in chunk')
        data[dz][dy][dx] = t; n = n + 1
      end
      cells = cells + n
      if n > maxw then maxw = n end
      assert(math.type(ch.pos[1]) == 'integer')
    end
  end
end
io.write(string.format('%d %d %d\n', chunks, cells, maxw))
io.write(json.encode(docs))
"""


@pytest.mark.parametrize("tpl", sorted(bp.TEMPLATES))
def test_lua_decodes_and_builds_quickfort_data(tmp_path, tpl):
    docs = bp.emit_all(tpl, {}, {"id": "S1", "anchor": [60, 40, 100], "rot": 1})
    src = tmp_path / "docs.json"
    src.write_text(json.dumps(docs), encoding="utf-8")
    script = tmp_path / "read_bp.lua"
    script.write_text(LUA, encoding="utf-8")
    r = luahost.run_file(script, [str(src)], timeout=30)
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    head, body = r.out.split("\n", 1)
    chunks, cells, maxw = map(int, head.split())
    assert chunks == sum(len(s["chunks"]) for d in docs for s in d["stages"])
    assert cells == sum(len(c["cells"]) for d in docs for s in d["stages"] for c in s["chunks"])
    assert maxw <= 40
    assert json.loads(body) == docs                       # lossless round trip through the Lua codec
