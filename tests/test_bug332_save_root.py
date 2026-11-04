"""BUG-332 (Run 15 i2 'autosave 1' 20:21 / i4 'autosave 2' 20:24, 29.10.: `dfllm save` said QUICKSAVE_FAILED 'the newest
save is a-run15-guildcleans' while DF in portable mode (<DF>/prefs/portable.txt) had saved to <DF>/save; the scan read
%APPDATA%/Bay 12 Games/Dwarf Fortress/save): the save folder comes from DF's own path."""
from pathlib import Path

import pytest

from dfpilot import paths, supervise


@pytest.fixture
def df(tmp_path, monkeypatch):
    monkeypatch.delenv("DFLLM_SAVES", raising=False)
    monkeypatch.setenv("APPDATA", str(tmp_path / "appdata"))
    d = tmp_path / "DF"
    (d / "prefs").mkdir(parents=True)
    (d / "save").mkdir()
    (d / "dfllm-runtime").mkdir()
    return d


def test_bug332_portable_mode_saves_below_df(df):
    (df / "prefs" / "portable.txt").write_text("This file's presence indicates that this is a portable copy", "utf-8")
    root, src = supervise.saves_root(df, df / "dfllm-runtime")
    assert root == df / "save" and "portable" in src


def test_bug332_appdata_without_portable(df, tmp_path):
    root, src = supervise.saves_root(df, df / "dfllm-runtime")
    assert root == tmp_path / "appdata" / "Bay 12 Games" / "Dwarf Fortress" / "save" and src == "%APPDATA%"


def test_bug332_kernel_savedir_wins_and_relative_is_below_df(df, tmp_path):
    (df / "prefs" / "portable.txt").write_text("x", "utf-8")
    other = tmp_path / "elsewhere" / "save"
    other.mkdir(parents=True)
    (df / "dfllm-runtime" / "SAVEDIR").write_text(str(other), "utf-8")
    assert supervise.saves_root(df, df / "dfllm-runtime") == (other, "kernel SAVEDIR")
    (df / "dfllm-runtime" / "SAVEDIR").write_text("save", "utf-8")                     # relative: below <df>
    assert supervise.saves_root(df, df / "dfllm-runtime")[0] == df / "save"
    (df / "dfllm-runtime" / "SAVEDIR").write_text(str(tmp_path / "gone"), "utf-8")    # a folder that is gone: next rule
    assert supervise.saves_root(df, df / "dfllm-runtime") == (df / "save", "portable mode (prefs/portable.txt)")


def test_bug332_env_override_first(df, monkeypatch, tmp_path):
    (df / "prefs" / "portable.txt").write_text("x", "utf-8")
    monkeypatch.setenv("DFLLM_SAVES", str(tmp_path / "mine"))
    assert supervise.saves_root(df, df / "dfllm-runtime") == (Path(tmp_path / "mine"), "DFLLM_SAVES")


def test_bug332_default_env_uses_it(df, monkeypatch):
    (df / "prefs" / "portable.txt").write_text("x", "utf-8")
    monkeypatch.setenv("DFLLM_DF", str(df))
    monkeypatch.delenv("DFLLM_RUNTIME", raising=False)
    paths.set_overrides()
    env = supervise.default_env()
    assert env.saves == df / "save" and env.runtime == df / "dfllm-runtime"
