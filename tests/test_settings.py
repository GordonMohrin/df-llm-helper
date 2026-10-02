"""Spec v3-09 settings manager: one-line change + backup, refusals, pending until verify after a (simulated)
restart, byte-identical revert, write boundary. Fixtures are SYNTHETIC (fixtures/v3/settings/README.md)."""
import hashlib
import shutil
from pathlib import Path

import pytest

from df_llm_helper.client import MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.config import HOME
from df_llm_helper.features import settings as st
from df_llm_helper.store import Store

FIX = HOME / "fixtures" / "v3" / "settings"


def tree(root: Path) -> dict:
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*")) if p.is_file()}


@pytest.fixture
def env(tmp_path):
    df = tmp_path / "df"
    (df / "prefs").mkdir(parents=True)
    shutil.copy(FIX / "d_init.txt", df / "prefs" / "d_init.txt")
    (df / "other.txt").write_text("do not touch", encoding="utf-8")
    clock = FakeClock(1_790_840_000.0)
    store = Store()
    uptime = {"ms": 10_000_000}
    client = MockClient({st.UPTIME_CMD: lambda c: str(uptime["ms"]),
                         "claude/status": '{"population": {"total": 141}}'}, clock=clock)
    s = st.Settings(store, clock, {"file": str(df / "prefs" / "d_init.txt")}, home=HOME, client=client)
    return s, df, clock, store, uptime


def test_set_changes_exactly_one_line_with_backup(env):
    """Acceptance 1."""
    s, df, clock, store, _ = env
    before = (df / "prefs" / "d_init.txt").read_bytes()
    out = s.set("POPULATION_CAP", "60", "player: 'limit population to 60'")
    after = (df / "prefs" / "d_init.txt").read_bytes()
    a, b = before.splitlines(keepends=True), after.splitlines(keepends=True)
    assert len(a) == len(b)
    diff = [i for i in range(len(a)) if a[i] != b[i]]
    assert diff == [24] and b[24] == b"[POPULATION_CAP:60]\r\n"
    backups = list((df / "prefs" / "backups").iterdir())
    assert len(backups) == 1 and backups[0].name.startswith("d_init.txt.bak-20")
    assert backups[0].read_bytes() == before
    assert "takes effect only after a restart: POPULATION_CAP 60" in out[1]
    act = store.actions()[-1]
    assert act["rule"] == "settings" and act["action"] == "set" and "player" in act["detail"]


@pytest.mark.parametrize("key,val", [("FOO_CAP", "5"), ("POPULATION_CAP", "-1"), ("POPULATION_CAP", "abc"),
                                     ("POPULATION_CAP", "5000"), ("BABY_CHILD_CAP", "10"), ("VISITOR_CAP", "1:2"),
                                     ("POPULATION_CAP", "7]\n[INVADERS:NO")])
def test_invalid_key_or_value_refused_nothing_written(env, key, val):
    """Acceptance 2."""
    s, df, *_ = env
    t0 = tree(df)
    with pytest.raises(st.SettingsError):
        s.set(key, val, "player: yes")
    assert tree(df) == t0 and s.pending() == {}


def test_reason_required(env):
    s, df, *_ = env
    t0 = tree(df)
    with pytest.raises(st.SettingsError):
        s.set("POPULATION_CAP", "60", "  ")
    assert tree(df) == t0


def test_pending_until_verify_after_simulated_restart(env):
    """Acceptance 3."""
    s, df, clock, store, uptime = env
    s.set("POPULATION_CAP", "60", "player: yes")
    assert s.pending_line() == "1 setting waiting for a restart (POPULATION_CAP 60)"
    clock.advance(600)
    uptime["ms"] = 3_600_000                     # DF running for 1 h: started BEFORE the change
    assert "restart needed" in s.verify()[0] and "POPULATION_CAP" in s.pending()
    uptime["ms"] = 120_000                       # simulated restart: DF up for 2 min (< 10 min since the change)
    out = s.verify()
    assert "verified" in out[0] and "population 141 >= 60" in out[0]
    assert s.pending() == {} and s.pending_line() == ""
    assert store.actions()[-1]["action"] == "verify"


def test_verify_keeps_pending_if_file_changed_or_df_unreachable(env):
    s, df, clock, _, uptime = env
    s.set("VISITOR_CAP", "50", "player: yes")
    p = df / "prefs" / "d_init.txt"
    p.write_bytes(p.read_bytes().replace(b"[VISITOR_CAP:50]", b"[VISITOR_CAP:51]"))
    assert "expected 50" in s.verify()[0]
    s2 = st.Settings(s.store, clock, s.cfg, home=HOME, client=None)
    p.write_bytes(p.read_bytes().replace(b"[VISITOR_CAP:51]", b"[VISITOR_CAP:50]"))
    assert "DF not reachable" in s2.verify()[0] and "VISITOR_CAP" in s2.pending()


def test_revert_restores_byte_identical(env):
    """Acceptance 4 (also after two changes of the same key)."""
    s, df, *_ = env
    p = df / "prefs" / "d_init.txt"
    orig = p.read_bytes()
    s.set("POPULATION_CAP", "60", "player: yes")
    s.set("POPULATION_CAP", "50", "player: even fewer")
    out = s.revert("POPULATION_CAP")
    assert p.read_bytes() == orig
    assert "byte-identical" in out[1] and s.pending() == {}
    with pytest.raises(st.SettingsError):
        s.revert("POPULATION_CAP")


def test_revert_of_one_key_keeps_the_other(env):
    s, df, *_ = env
    p = df / "prefs" / "d_init.txt"
    s.set("POPULATION_CAP", "60", "player: yes")
    s.set("BABY_CHILD_CAP", "5:10", "player: yes")
    s.revert("POPULATION_CAP")
    data = p.read_bytes()
    assert b"[POPULATION_CAP:75]\r\n" in data and b"[BABY_CHILD_CAP:5:10]\r\n" in data
    assert list(s.pending()) == ["BABY_CHILD_CAP"]


def test_write_boundary(env, tmp_path):
    """Acceptance 5: only the configured file and the backup folder; nothing else in the tree changes."""
    s, df, *_ = env
    t0 = tree(df)
    with pytest.raises(PermissionError):
        s._write(df / "other.txt", b"x")
    with pytest.raises(PermissionError):
        s._write(df / "prefs" / "backups" / ".." / "init.txt", b"x")
    s.set("STRICT_POPULATION_CAP", "90", "player: yes")
    s.revert("STRICT_POPULATION_CAP")
    t1 = tree(df)
    changed = {k for k in set(t0) | set(t1) if t0.get(k) != t1.get(k)}
    assert all(k.startswith("prefs/backups/") for k in changed) and changed


def test_same_value_and_duplicate_lines(env):
    s, df, *_ = env
    assert "nothing changed" in s.set("POPULATION_CAP", "75", "player: yes")[0]
    p = df / "prefs" / "d_init.txt"
    p.write_bytes(p.read_bytes() + b"[VISITOR_CAP:7]\r\n")
    with pytest.raises(st.SettingsError):
        s.set("VISITOR_CAP", "50", "player: yes")


def test_get_shows_default_effect_and_pending(env):
    s, *_ = env
    lines = s.get()
    assert lines[0].startswith("POPULATION_CAP = 75 (default 200, effect: after restart)")
    s.set("POPULATION_CAP", "60", "player: yes")
    assert "[pending restart: 75 -> 60]" in s.get("POPULATION_CAP")[0]
    with pytest.raises(st.SettingsError):
        s.get("NOPE")


def test_backup_fixture_matches_defaults():
    vals = dict((k, v) for _, k, v in st.parse_lines((FIX / "d_init.txt.bak-run5").read_bytes()))
    assert vals["POPULATION_CAP"] == "200" and vals["STRICT_POPULATION_CAP"] == "220"


def test_check_hook_shows_pending_line_rate_limited(env, cfg):
    s, df, clock, store, _ = env
    from df_llm_helper.pilot import Pilot
    s.set("POPULATION_CAP", "60", "player: yes")
    p = Pilot(cfg, MockClient(clock=clock), store=store, clock=clock)
    assert st.check_hook(p, None, False) == ["1 setting waiting for a restart (POPULATION_CAP 60)"]
    assert st.check_hook(p, None, False) == []
    clock.advance(1801)
    assert st.check_hook(p, None, False)


def test_cli_set_and_refusal(env, tmp_path, capsys, monkeypatch):
    import df_llm_helper.cli as cli
    s, df, *_ = env
    cfgf = tmp_path / "config.yaml"
    cfgf.write_text(f"settings:\n  file: '{df / 'prefs' / 'd_init.txt'}'\npaths:\n  state_db: '{tmp_path / 's.db'}'\n",
                    encoding="utf-8")
    assert cli.main(["--config", str(cfgf), "settings", "set", "POPULATION_CAP", "70", "--reason", "player: yes"]) == 0
    assert "takes effect only after a restart" in capsys.readouterr().out
    assert cli.main(["--config", str(cfgf), "settings", "set", "NOPE", "1", "--reason", "x"]) == 2
    assert "Refused" in capsys.readouterr().out
    assert cli.main(["--config", str(cfgf), "settings", "pending"]) == 0
    assert "POPULATION_CAP 70" in capsys.readouterr().out
    assert cli.main(["--config", str(cfgf), "settings", "restart-plan"]) == 0
