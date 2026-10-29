"""dfpilot.files: the atomic JSON writer (BUG-239)."""
import json
import os

import pytest

from dfpilot import files


def test_bug239_tmp_name_carries_the_pid(tmp_path, monkeypatch):
    """Run 15 Inkintense: two follow processes shared '..follow.json.tmp'; one replaced the other's temporary file away."""
    seen = []
    real = os.replace

    def rec(src, dst):
        seen.append(os.path.basename(str(src)))
        return real(src, dst)
    monkeypatch.setattr(files.os, "replace", rec)
    files.write_json_atomic(tmp_path / ".follow.json", {"a": 1})
    assert seen == [f"..follow.json.{os.getpid()}.tmp"]
    monkeypatch.setattr(files.os, "getpid", lambda: 4242)
    assert files.tmp_path(tmp_path / ".follow.json").name == "..follow.json.4242.tmp"
    assert json.loads((tmp_path / ".follow.json").read_text("utf-8")) == {"a": 1}
    assert not list(tmp_path.glob("*.tmp"))


def test_bug239_tmp_lost_once_is_written_again(tmp_path, monkeypatch):
    """WinError 2 '..follow.json.tmp -> .follow.json': the temporary file vanished before the replace."""
    real, calls = os.replace, []

    def flaky(src, dst):
        calls.append(1)
        if len(calls) == 1:
            os.unlink(src)                       # the racing writer took it
            raise FileNotFoundError(2, "The system cannot find the file specified", str(src))
        return real(src, dst)
    monkeypatch.setattr(files.os, "replace", flaky)
    files.write_json_atomic(tmp_path / ".follow.json", {"v": 2})
    assert len(calls) == 2 and json.loads((tmp_path / ".follow.json").read_text("utf-8")) == {"v": 2}


def test_bug239_tmp_lost_twice_raises_to_the_caller(tmp_path, monkeypatch):
    calls = []

    def gone(src, dst):
        calls.append(os.path.basename(str(src)))
        os.unlink(src)
        raise FileNotFoundError(2, "gone", str(src))
    monkeypatch.setattr(files.os, "replace", gone)
    with pytest.raises(FileNotFoundError):
        files.write_json_atomic(tmp_path / "x.json", {"v": 1})
    assert calls == [f".x.json.{os.getpid()}.tmp"] * 2              # one rewrite, then the caller logs it
    assert not (tmp_path / "x.json").exists()
