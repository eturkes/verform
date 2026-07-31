"""Shell-free, resource-bounded subprocess execution."""

from __future__ import annotations

import os
import signal
import subprocess
import threading
import time
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Literal, cast

_BLOCKED_ENV = {
    "BASH_ENV",
    "ENV",
    "ELAN_TOOLCHAIN",
    "LD_AUDIT",
    "LD_LIBRARY_PATH",
    "LD_PRELOAD",
}
_MAX_OUTPUT_BYTES = 8 * 1024 * 1024
_READ_BYTES = 64 * 1024
_POLL_SECONDS = 0.02
_REAP_SECONDS = 2.0
_OUTPUT_LIMIT_EXIT = 125


def _controlled_environment() -> dict[str, str]:
    """Preserve ordinary credentials/tool lookup while removing proof/build overrides."""
    return {
        key: value
        for key, value in os.environ.items()
        if key not in _BLOCKED_ENV
        and not key.startswith("LAKE_")
        and not key.startswith("LEAN_")
        and not key.startswith("DYLD_")
    }


@dataclass(frozen=True)
class CommandResult:
    command: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str
    failure: str = ""

    @property
    def ok(self) -> bool:
        return self.returncode == 0 and not self.failure


class _BoundedCapture:
    """Keep at most ``limit`` bytes across both output streams."""

    def __init__(self, limit: int) -> None:
        self._limit = limit
        self._used = 0
        self._stdout = bytearray()
        self._stderr = bytearray()
        self._lock = threading.Lock()
        self.overflow = threading.Event()
        self.failed = threading.Event()
        self.changed = threading.Event()
        self.error = ""

    def append(self, stream: Literal["stdout", "stderr"], data: bytes) -> None:
        with self._lock:
            remaining = self._limit - self._used
            retained = data[:remaining]
            target = self._stdout if stream == "stdout" else self._stderr
            target.extend(retained)
            self._used += len(retained)
            if len(retained) != len(data):
                self.overflow.set()
                self.changed.set()

    def record_error(self, error: OSError) -> None:
        with self._lock:
            if not self.error:
                self.error = str(error)
        self.failed.set()
        self.changed.set()

    def text(self) -> tuple[str, str]:
        with self._lock:
            stdout = bytes(self._stdout)
            stderr = bytes(self._stderr)
        return stdout.decode("utf-8", errors="replace"), stderr.decode("utf-8", errors="replace")


def _read_stream(
    stream: BinaryIO,
    name: Literal["stdout", "stderr"],
    capture: _BoundedCapture,
    done: threading.Event,
) -> None:
    try:
        while chunk := stream.read(_READ_BYTES):
            capture.append(name, chunk)
    except OSError as error:
        capture.record_error(error)
    finally:
        done.set()
        capture.changed.set()


def _write_stdin(stream: BinaryIO, content: bytes) -> None:
    try:
        stream.write(content)
        stream.flush()
    except (BrokenPipeError, OSError):
        pass
    finally:
        stream.close()


def _kill_windows_tree(process: subprocess.Popen[bytes]) -> None:  # pragma: no cover
    system_root = Path(os.environ.get("SYSTEMROOT", r"C:\Windows"))
    taskkill = system_root / "System32" / "taskkill.exe"
    if taskkill.is_file():
        with suppress(OSError, subprocess.TimeoutExpired):
            subprocess.run(
                (str(taskkill), "/PID", str(process.pid), "/T", "/F"),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=_controlled_environment(),
                timeout=_REAP_SECONDS,
                check=False,
            )
    if process.poll() is None:
        process.kill()


def _kill_process_tree(process: subprocess.Popen[bytes]) -> None:
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal.SIGKILL)
            return
        except ProcessLookupError:
            return
        except OSError:
            pass
    elif os.name == "nt":
        _kill_windows_tree(process)
        return
    if process.poll() is None:
        process.kill()


def run(
    command: tuple[str, ...],
    *,
    cwd: Path,
    timeout_seconds: int,
    stdin: str | None = None,
    output_limit_bytes: int = _MAX_OUTPUT_BYTES,
) -> CommandResult:
    """Run one argv command with a deadline and a hard combined-output ceiling."""
    if not command:
        return CommandResult(command, 126, "", "", "cannot execute an empty command")
    if not 1 <= output_limit_bytes <= _MAX_OUTPUT_BYTES:
        raise ValueError(f"output_limit_bytes must be between 1 and {_MAX_OUTPUT_BYTES}")

    creationflags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0) if os.name == "nt" else 0
    try:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=_controlled_environment(),
            stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=False,
            start_new_session=os.name == "posix",
            creationflags=creationflags,
        )
    except FileNotFoundError:
        return CommandResult(command, 127, "", "", f"command not found: {command[0]}")
    except OSError as error:
        return CommandResult(command, 126, "", "", f"cannot execute {command[0]}: {error}")

    assert process.stdout is not None
    assert process.stderr is not None
    stdout_stream = cast(BinaryIO, process.stdout)
    stderr_stream = cast(BinaryIO, process.stderr)
    capture = _BoundedCapture(output_limit_bytes)
    stdout_done = threading.Event()
    stderr_done = threading.Event()
    readers = (
        threading.Thread(
            target=_read_stream,
            args=(stdout_stream, "stdout", capture, stdout_done),
            daemon=True,
        ),
        threading.Thread(
            target=_read_stream,
            args=(stderr_stream, "stderr", capture, stderr_done),
            daemon=True,
        ),
    )
    for reader in readers:
        reader.start()

    writer: threading.Thread | None = None
    if stdin is not None:
        assert process.stdin is not None
        stdin_stream = cast(BinaryIO, process.stdin)
        writer = threading.Thread(
            target=_write_stdin,
            args=(stdin_stream, stdin.encode("utf-8")),
            daemon=True,
        )
        writer.start()

    deadline = time.monotonic() + timeout_seconds
    failure = ""
    failure_code = 0
    while True:
        completed = process.poll() is not None and stdout_done.is_set() and stderr_done.is_set()
        if capture.overflow.is_set():
            failure = f"combined stdout/stderr exceeded {output_limit_bytes}-byte capture limit"
            failure_code = _OUTPUT_LIMIT_EXIT
            break
        if capture.failed.is_set():
            failure = f"output capture failed: {capture.error}"
            failure_code = _OUTPUT_LIMIT_EXIT
            break
        if completed:
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            failure = f"timed out after {timeout_seconds}s"
            failure_code = 124
            break
        capture.changed.wait(min(_POLL_SECONDS, remaining))
        capture.changed.clear()

    if failure:
        _kill_process_tree(process)
    try:
        process.wait(timeout=_REAP_SECONDS)
    except subprocess.TimeoutExpired:
        _kill_process_tree(process)
        try:
            process.wait(timeout=_REAP_SECONDS)
        except subprocess.TimeoutExpired:
            failure = failure or "could not terminate command process tree"
            failure_code = failure_code or 126

    for reader in readers:
        reader.join(timeout=_REAP_SECONDS)
    if writer is not None:
        writer.join(timeout=_REAP_SECONDS)
    stdout, stderr = capture.text()
    return CommandResult(
        command,
        failure_code if failure else (process.returncode or 0),
        stdout,
        stderr,
        failure,
    )


def diagnostic(result: CommandResult, *, max_lines: int = 40) -> tuple[str, ...]:
    lines: list[str] = []
    if result.failure:
        lines.append(result.failure)
    combined = "\n".join(part.rstrip() for part in (result.stdout, result.stderr) if part.strip())
    output_lines = combined.splitlines()
    if len(output_lines) > max_lines:
        omitted = len(output_lines) - max_lines
        lines.append(f"… {omitted} earlier output line(s) omitted")
        output_lines = output_lines[-max_lines:]
    lines.extend(output_lines)
    return tuple(lines)
