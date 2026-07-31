from __future__ import annotations

import json
import os
import shutil
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

import verform.verifier as verifier
from tests.helpers import comparator_project, kernel_project
from verform.config import load_manifest
from verform.runner import CommandResult

RunFake = Callable[..., CommandResult]


def successful_runner(*, axioms: str = "") -> RunFake:
    def fake(
        command: tuple[str, ...],
        *,
        cwd: Path,
        timeout_seconds: int,
        stdin: str | None = None,
    ) -> CommandResult:
        del cwd, timeout_seconds
        if "--version" in command:
            return CommandResult(command, 0, "Lean (version 4.32.2, test)\n", "")
        if stdin is not None and "collectAxioms" in stdin:
            values = [item.strip() for item in axioms.split(",") if item.strip()]
            output = f"VERFORM_AXIOMS={json.dumps(values)}\n"
            return CommandResult(command, 0, output, "")
        return CommandResult(command, 0, "ok\n", "")

    return fake


def test_kernel_pipeline_checks_contract_axioms_and_replay(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = kernel_project(tmp_path)
    calls: list[tuple[tuple[str, ...], str | None]] = []
    base = successful_runner()

    def recording_run(
        command: tuple[str, ...],
        *,
        cwd: Path,
        timeout_seconds: int,
        stdin: str | None = None,
    ) -> CommandResult:
        calls.append((command, stdin))
        return base(command, cwd=cwd, timeout_seconds=timeout_seconds, stdin=stdin)

    monkeypatch.setattr(verifier, "run", recording_run)
    report = verifier.verify(manifest)

    assert report.ok
    assert report.evidence.toolchain == "Lean (version 4.32.2, test)"
    assert report.evidence.obligations[0].axioms == ()
    assert any(command[-2:] == ("--fresh", "Demo.Proof") for command, _ in calls)
    obligation_stdin = next(stdin for _, stdin in calls if stdin and "collectAxioms" in stdin)
    assert "Demo.Spec.Contract" in obligation_stdin
    assert "Demo.Impl.run" in obligation_stdin
    assert "getImplementedBy?" in obligation_stdin
    assert "isNoncomputable" in obligation_stdin
    assert calls[0][0] == ("lake", "env", "lean", "--version")
    assert calls[1][0] == ("lake", "env", "lean", "--stdin")
    assert report.gates[-1].name == "input stability"


def test_disallowed_axiom_rejects_and_skips_replay(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = kernel_project(tmp_path)
    calls: list[tuple[str, ...]] = []
    base = successful_runner(axioms="propext, Evil.unsound")

    def fake(
        command: tuple[str, ...],
        *,
        cwd: Path,
        timeout_seconds: int,
        stdin: str | None = None,
    ) -> CommandResult:
        calls.append(command)
        return base(command, cwd=cwd, timeout_seconds=timeout_seconds, stdin=stdin)

    monkeypatch.setattr(verifier, "run", fake)
    report = verifier.verify(manifest)

    assert not report.ok
    obligation = next(gate for gate in report.gates if gate.name.startswith("obligation:"))
    assert "Evil.unsound" in obligation.summary
    assert not any("leanchecker" in command for command in calls)


@pytest.mark.parametrize(
    "output",
    ["unexpected output", "'x' is an axiom", "depends on axioms: malformed"],
)
def test_unparseable_axiom_output_rejects(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    output: str,
) -> None:
    manifest = kernel_project(tmp_path)

    def fake(
        command: tuple[str, ...],
        *,
        cwd: Path,
        timeout_seconds: int,
        stdin: str | None = None,
    ) -> CommandResult:
        del cwd, timeout_seconds
        if "--version" in command:
            return CommandResult(command, 0, "Lean (version 4.32.2, test)\n", "")
        if stdin is not None and "collectAxioms" in stdin:
            return CommandResult(command, 0, output, "")
        return CommandResult(command, 0, "", "")

    monkeypatch.setattr(verifier, "run", fake)
    report = verifier.verify(manifest)
    assert not report.ok
    assert "parse" in report.gates[-1].summary


def test_build_failure_stops_formal_checks(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    manifest = kernel_project(tmp_path)

    def fake(
        command: tuple[str, ...],
        *,
        cwd: Path,
        timeout_seconds: int,
        stdin: str | None = None,
    ) -> CommandResult:
        del cwd, timeout_seconds
        if "--version" in command:
            return CommandResult(command, 0, "Lean (version 4.32.2, test)\n", "")
        if stdin is not None:
            return CommandResult(command, 0, "audited\n", "")
        return CommandResult(command, 1, "", "compile error")

    monkeypatch.setattr(verifier, "run", fake)
    report = verifier.verify(manifest)

    assert not report.ok
    assert report.gates[-1].name == "fresh build"
    assert "compile error" in report.gates[-1].detail


def test_toolchain_failure_stops_before_build(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = kernel_project(tmp_path)
    calls = 0

    def fake(
        command: tuple[str, ...],
        *,
        cwd: Path,
        timeout_seconds: int,
        stdin: str | None = None,
    ) -> CommandResult:
        nonlocal calls
        del cwd, timeout_seconds, stdin
        calls += 1
        return CommandResult(command, 127, "", "", "command not found: lake")

    monkeypatch.setattr(verifier, "run", fake)
    report = verifier.verify(manifest)
    assert not report.ok
    assert calls == 1
    assert report.gates[-1].name == "toolchain"


@pytest.mark.parametrize(
    "version",
    [
        "",
        "Lean (version 4.31.0, test)\n",
        "Lean (version 4.32.20, test)\n",
        "Lean (version 4.32.2-rc1, test)\n",
    ],
)
def test_wrong_or_empty_toolchain_version_fails_closed(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    version: str,
) -> None:
    manifest = kernel_project(tmp_path)

    def fake(
        command: tuple[str, ...],
        *,
        cwd: Path,
        timeout_seconds: int,
        stdin: str | None = None,
    ) -> CommandResult:
        del cwd, timeout_seconds, stdin
        return CommandResult(command, 0, version, "")

    monkeypatch.setattr(verifier, "run", fake)
    report = verifier.verify(manifest)
    assert not report.ok
    assert report.gates[-1].name == "toolchain"


def test_trusted_header_parser_failure_stops_before_build(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = kernel_project(tmp_path)

    def fake(
        command: tuple[str, ...],
        *,
        cwd: Path,
        timeout_seconds: int,
        stdin: str | None = None,
    ) -> CommandResult:
        del cwd, timeout_seconds
        if "--version" in command:
            return CommandResult(command, 0, "Lean (version 4.32.2, test)\n", "")
        assert stdin is not None
        return CommandResult(command, 1, "", "untrusted import")

    monkeypatch.setattr(verifier, "run", fake)
    report = verifier.verify(manifest)
    assert not report.ok
    assert report.gates[-1].name == "trusted imports"
    assert "untrusted import" in report.gates[-1].detail


def test_static_failure_runs_no_commands(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    manifest = kernel_project(tmp_path)
    proof = manifest.root / "Demo/Proof.lean"
    proof.write_text(proof.read_text(encoding="utf-8") + "\nsorry\n", encoding="utf-8")

    def forbidden_run(*args: Any, **kwargs: Any) -> CommandResult:
        raise AssertionError((args, kwargs))

    monkeypatch.setattr(verifier, "run", forbidden_run)
    report = verifier.verify(manifest)
    assert not report.ok
    source_policy = next(gate for gate in report.gates if gate.name == "source policy")
    assert not source_policy.ok


def test_input_mutation_during_build_rejects_attestation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = kernel_project(tmp_path)
    base = successful_runner()
    mutated = False

    def fake(
        command: tuple[str, ...],
        *,
        cwd: Path,
        timeout_seconds: int,
        stdin: str | None = None,
    ) -> CommandResult:
        nonlocal mutated
        result = base(command, cwd=cwd, timeout_seconds=timeout_seconds, stdin=stdin)
        if "build" in command and not mutated:
            proof = manifest.root / "Demo/Proof.lean"
            proof.write_text(
                proof.read_text(encoding="utf-8") + "\n-- mutation\n", encoding="utf-8"
            )
            mutated = True
        return result

    monkeypatch.setattr(verifier, "run", fake)
    report = verifier.verify(manifest)
    assert not report.ok
    assert report.gates[-1].name == "input stability"
    assert "Demo/Proof.lean" in report.gates[-1].detail[0]


def test_input_mutation_during_snapshot_is_rejected_before_tools(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = kernel_project(tmp_path)
    original_copy = shutil.copy2
    mutated = False

    def mutating_copy(source: Path, destination: Path) -> Path:
        nonlocal mutated
        if not mutated and source.name == "Proof.lean":
            source.write_text(
                source.read_text(encoding="utf-8") + "\n-- changed\n", encoding="utf-8"
            )
            mutated = True
        return Path(original_copy(source, destination))

    monkeypatch.setattr(shutil, "copy2", mutating_copy)
    monkeypatch.setattr(
        verifier,
        "run",
        lambda *args, **kwargs: pytest.fail("tools must not run after a snapshot hash mismatch"),
    )

    report = verifier.verify(manifest)

    assert not report.ok
    assert report.gates[-1].name == "isolated snapshot"
    assert "input changed while snapshotting" in report.gates[-1].summary


def test_comparator_pipeline_writes_exact_ephemeral_configuration(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = comparator_project(tmp_path)
    seen_payload: dict[str, object] = {}
    temporary_path: Path | None = None
    seen_command: tuple[str, ...] = ()

    def fake(
        command: tuple[str, ...],
        *,
        cwd: Path,
        timeout_seconds: int,
        stdin: str | None = None,
    ) -> CommandResult:
        nonlocal seen_command, temporary_path
        del timeout_seconds
        if "--version" in command:
            return CommandResult(command, 0, "Lean (version 4.32.2, comparator-test)\n", "")
        if "build" in command:
            return CommandResult(command, 0, "built\n", "")
        if stdin is not None:
            return CommandResult(command, 0, "audited\n", "")
        seen_command = command
        temporary_path = Path(command[-1])
        assert temporary_path.parent == cwd
        seen_payload.update(json.loads(temporary_path.read_text(encoding="utf-8")))
        return CommandResult(command, 0, "accepted\n", "")

    monkeypatch.setattr(verifier, "run", fake)
    monkeypatch.setattr(
        shutil,
        "which",
        lambda name: (
            f"/trusted/bin/{name}" if name in {"systemd-run", "comparator", "env", "lake"} else None
        ),
    )
    report = verifier.verify(manifest)

    assert report.ok
    assert seen_payload["challenge_module"] == "Demo.Challenge"
    assert seen_payload["definition_names"] == ["Demo.run"]
    assert seen_payload["enable_nanoda"] is True
    assert temporary_path is not None and not temporary_path.exists()
    assert not any(gate.name == "build" for gate in report.gates)
    assert "--property=RestrictAddressFamilies=~AF_UNIX" in seen_command
    assert "--property=RuntimeMaxSec=1200s" in seen_command
    assert "--property=TimeoutStopSec=5s" in seen_command
    assert seen_command[-4:-1] == (
        "/trusted/bin/lake",
        "env",
        "/trusted/bin/comparator",
    )


def test_comparator_requires_installed_trusted_orchestrator(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = comparator_project(tmp_path)
    monkeypatch.setattr(verifier, "run", successful_runner())
    monkeypatch.setattr(shutil, "which", lambda _: None)

    report = verifier.verify(manifest)
    assert not report.ok
    comparator = next(gate for gate in report.gates if gate.name == "comparator")
    assert "systemd-run" in comparator.summary
    assert "comparator" in comparator.summary


def test_comparator_rejects_privileged_execution(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = comparator_project(tmp_path)
    monkeypatch.setattr(verifier, "run", successful_runner())
    monkeypatch.setattr(os, "geteuid", lambda: 0)

    report = verifier.verify(manifest)

    assert not report.ok
    comparator = next(gate for gate in report.gates if gate.name == "comparator")
    assert "unprivileged user" in comparator.summary


@pytest.mark.parametrize(
    ("output", "expected"),
    [
        ('VERFORM_AXIOMS=["propext","Classical.choice"]', ("Classical.choice", "propext")),
        ("VERFORM_AXIOMS=[]", ()),
        ('VERFORM_AXIOMS=["sorryAx"]', ("sorryAx",)),
    ],
)
def test_axiom_output_compatibility_parsing(output: str, expected: tuple[str, ...]) -> None:
    assert verifier._parse_axioms(output) == expected


@pytest.mark.parametrize(
    "output",
    [
        "VERFORM_AXIOMS=not-json",
        'VERFORM_AXIOMS=["propext"]\nVERFORM_AXIOMS=[]',
        'VERFORM_AXIOMS=["propext","propext"]',
        "VERFORM_AXIOMS=[1]",
        "'x' does not depend on any axioms",
    ],
)
def test_axiom_protocol_rejects_malformed_or_ambiguous_markers(output: str) -> None:
    assert verifier._parse_axioms(output) is None


def test_raw_lean_string_chooses_a_noncolliding_delimiter() -> None:
    rendered = verifier._lean_string('path/with"and"# delimiters')
    assert rendered.startswith("r#")
    assert rendered.endswith("#")


def test_extra_checks_run_only_after_formal_gates(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = kernel_project(tmp_path)
    with manifest.path.open("a", encoding="utf-8") as stream:
        stream.write('\n[[checks]]\nname = "smoke"\ncommand = ["smoke-test"]\n')
    manifest = load_manifest(manifest.root)
    calls: list[tuple[str, ...]] = []
    base = successful_runner()

    def fake(
        command: tuple[str, ...],
        *,
        cwd: Path,
        timeout_seconds: int,
        stdin: str | None = None,
    ) -> CommandResult:
        calls.append(command)
        return base(command, cwd=cwd, timeout_seconds=timeout_seconds, stdin=stdin)

    monkeypatch.setattr(verifier, "run", fake)
    report = verifier.verify(manifest)
    assert report.ok
    assert report.gates[-2].name == "check:smoke"
    assert calls[-1] == ("smoke-test",)
