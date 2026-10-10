-- act.trade for the click-level UI tests (tests/lua/test_trade_act.lua, trade_scenario.lua).
-- The code lives in lua/dfllm/act.lua (A.install_trade, between BEGIN and END act.trade); this file
-- only re-exports it so the tests can install it on a fake `I` with a fake gui.
local A = require('dfllm.act')
return {install = A.install_trade}
