from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

from verform.runner import diagnostic, run


def test_runner_captures_success_and_failure(tmp_path: Path) -> None:
    success = run(
        (sys.executable, "-c", "print('ok')"),
        cwd=tmp_path,
        timeout_seconds=2,
    )
    assert success.ok
    assert success.stdout == "ok\n"

    failure = run(
        (sys.executable, "-c", "import sys; print('bad', file=sys.stderr); sys.exit(7)"),
        cwd=tmp_path,
        timeout_seconds=2,
    )
    assert not failure.ok
    assert failure.returncode == 7
    assert diagnostic(failure) == ("bad",)


def test_runner_reports_missing_command_and_timeout(tmp_path: Path) -> None:
    empty = run((), cwd=tmp_path, timeout_seconds=1)
    assert empty.returncode == 126
    assert "empty command" in empty.failure

    missing = run(("definitely-not-a-verform-command",), cwd=tmp_path, timeout_seconds=1)
    assert missing.returncode == 127
    assert "command not found" in missing.failure

    timeout = run(
        (sys.executable, "-c", "import time; time.sleep(2)"),
        cwd=tmp_path,
        timeout_seconds=1,
    )
    assert timeout.returncode == 124
    assert "timed out" in timeout.failure


def test_runner_bounds_configuration_and_stdin_bytes(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="output_limit_bytes"):
        run((sys.executable,), cwd=tmp_path, timeout_seconds=1, output_limit_bytes=0)

    result = run(
        (
            sys.executable,
            "-c",
            "import sys; data = sys.stdin.buffer.read(); sys.stdout.buffer.write(b'\\xff' + data)",
        ),
        cwd=tmp_path,
        timeout_seconds=2,
        stdin="bound input",
    )
    assert result.ok
    assert result.stdout == "�bound input"


def test_runner_reports_nonexecutable_file(tmp_path: Path) -> None:
    command = tmp_path / "not-executable"
    command.write_text("content", encoding="utf-8")

    result = run((str(command),), cwd=tmp_path, timeout_seconds=1)

    assert result.returncode == 126
    assert "cannot execute" in result.failure


@pytest.mark.skipif(sys.platform != "linux", reason="Linux process-state assertion")
def test_runner_timeout_kills_descendant_process_group(tmp_path: Path) -> None:
    child_pid_file = tmp_path / "child.pid"
    child_source = "import time; time.sleep(60)"
    parent_source = (
        "import pathlib, subprocess, sys, time; "
        f"child = subprocess.Popen([sys.executable, '-c', {child_source!r}]); "
        f"pathlib.Path({str(child_pid_file)!r}).write_text(str(child.pid)); "
        "time.sleep(60)"
    )

    result = run(
        (sys.executable, "-c", parent_source),
        cwd=tmp_path,
        timeout_seconds=1,
    )

    assert result.returncode == 124
    assert child_pid_file.is_file()
    child_pid = int(child_pid_file.read_text())
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline and _linux_process_is_active(child_pid):
        time.sleep(0.01)
    assert not _linux_process_is_active(child_pid)


def test_runner_fails_closed_when_combined_output_exceeds_limit(tmp_path: Path) -> None:
    result = run(
        (
            sys.executable,
            "-c",
            "import os; os.write(1, b'a' * 300); os.write(2, b'b' * 300)",
        ),
        cwd=tmp_path,
        timeout_seconds=2,
        output_limit_bytes=512,
    )

    assert not result.ok
    assert result.returncode == 125
    assert "exceeded 512-byte capture limit" in result.failure
    assert len(result.stdout.encode()) + len(result.stderr.encode()) == 512


def test_diagnostic_truncates_from_the_end(tmp_path: Path) -> None:
    result = run(
        (sys.executable, "-c", "print(*range(50), sep='\\n')"),
        cwd=tmp_path,
        timeout_seconds=2,
    )
    detail = diagnostic(result, max_lines=3)
    assert detail[0] == "… 47 earlier output line(s) omitted"
    assert detail[-1] == "49"


def test_runner_removes_prover_and_loader_override_environment(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    for key in ("LEAN_PATH", "LAKE_PKG_URL_MAP", "ELAN_TOOLCHAIN", "LD_PRELOAD"):
        monkeypatch.setenv(key, "hostile")
    result = run(
        (
            sys.executable,
            "-c",
            "import os; print(','.join(str(os.getenv(k)) for k in "
            "('LEAN_PATH','LAKE_PKG_URL_MAP','ELAN_TOOLCHAIN','LD_PRELOAD')))",
        ),
        cwd=tmp_path,
        timeout_seconds=2,
    )
    assert result.ok
    assert result.stdout.strip() == "None,None,None,None"


def _linux_process_is_active(pid: int) -> bool:
    try:
        state = Path(f"/proc/{pid}/stat").read_text().split()[2]
    except (FileNotFoundError, ProcessLookupError):
        return False
    return state != "Z"
