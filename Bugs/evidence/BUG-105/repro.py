"""BUG-105: one failed `claude/config` query is treated as "NEW GAME": guard acknowledgements, rule loop-protection state,
unread warnings and digest/guard state are wiped, and everything is wiped again when config answers the next time.
Run: python Bugs/evidence/BUG-105/repro.py   (mock + temp folder)"""
import shutil, sqlite3, sys, pathlib, json
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *

base = tmp(); cfg = mkcfg(base)
ok_fx = REPO / "fixtures" / "run5"
bad_fx = base / "fx_config_fails"                       # identical, but `claude/config` has no answer (= a timeout/error live)
shutil.copytree(ok_fx, bad_fx); (bad_fx / "config.txt").unlink()

def state(label):
    c = sqlite3.connect(base / "state.db")
    gs = c.execute("select value from kv where key='guard.state'").fetchone()
    gid = c.execute("select value from kv where key='game_id'").fetchone()
    rs = c.execute("select rule, disabled from rule_state").fetchall()
    print(f"   [state.db {label}] game_id={gid[0] if gid else None}  guard.state gates_acked={json.loads(gs[0])['gates_acked'] if gs else '<<deleted>>'}  rule_state={rs}")

run(["--mock", str(ok_fx), "--config", str(cfg), "digest"])
run(["--mock", str(ok_fx), "--config", str(cfg), "guard", "ack-gate", "60"])
run(["--mock", str(ok_fx), "--config", str(cfg), "guard"])        # creates guard.state
c = sqlite3.connect(base / "state.db")
c.execute("insert into rule_state(rule, disabled, reason) values('drink_low_trinken', 1, 'service:trinken=start 6x/h')"); c.commit(); c.close()
state("before")
section("config query fails once")
run(["--mock", str(bad_fx), "--config", str(cfg), "digest"])
state("after the failed config query")
section("config answers again")
run(["--mock", str(ok_fx), "--config", str(cfg), "digest"])
state("after config is back")
