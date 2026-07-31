from __future__ import annotations

import json
from pathlib import Path

import pytest

from tests.helpers import kernel_project, passing_report
from verform.attestation import _write_verified, attest, output_path, payload, status
from verform.errors import ConfigError
from verform.model import Evidence, Gate, Report


def test_attestation_is_deterministic_and_status_is_current(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    report = passing_report(manifest)

    destination = _write_verified(manifest, report, "verform.lock.json")
    first = destination.read_bytes()
    _write_verified(manifest, report, "verform.lock.json")
    second = destination.read_bytes()

    assert first == second
    parsed = json.loads(first)
    assert parsed["project"] == "kernel-pure"
    assert parsed["review"]["files"] == report.evidence.review_hashes
    assert all(gate.ok for gate in status(manifest))


def test_status_distinguishes_review_and_verification_drift(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    _write_verified(manifest, passing_report(manifest), "verform.lock.json")

    proof = manifest.root / "Demo/Proof.lean"
    proof.write_text(proof.read_text(encoding="utf-8") + "\n-- changed\n", encoding="utf-8")
    gates = status(manifest)
    assert next(gate for gate in gates if gate.name == "review drift").ok
    verification = next(gate for gate in gates if gate.name == "verification drift")
    assert not verification.ok
    assert verification.detail == ("changed: Demo/Proof.lean",)

    spec = manifest.root / "Demo/Spec.lean"
    spec.write_text(spec.read_text(encoding="utf-8") + "\n-- reviewed change\n", encoding="utf-8")
    review = next(gate for gate in status(manifest) if gate.name == "review drift")
    assert not review.ok
    assert review.detail == ("changed: Demo/Spec.lean",)


def test_status_detects_manifest_and_verifier_identity_drift(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    destination = _write_verified(manifest, passing_report(manifest), "verform.lock.json")
    data = json.loads(destination.read_text(encoding="utf-8"))
    data["verform_version"] = "0.0.0"
    destination.write_text(json.dumps(data), encoding="utf-8")

    gates = status(manifest)
    assert not next(gate for gate in gates if gate.name == "attestation identity").ok


def test_attestation_refuses_failed_report_and_escaping_output(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    failed = Report(
        manifest.project.name,
        manifest.lean.assurance,
        (Gate("proof", False, "failed"),),
        Evidence(),
    )
    with pytest.raises(ConfigError, match="failed verification"):
        payload(manifest, failed)
    with pytest.raises(ConfigError, match="escapes project root"):
        output_path(manifest, "../outside.json")
    with pytest.raises(ConfigError, match="project-relative"):
        output_path(manifest, manifest.root / "inside.json")
    with pytest.raises(ConfigError, match="parent does not exist"):
        output_path(manifest, "missing/output.json")
    directory = manifest.root / "output-directory"
    directory.mkdir()
    with pytest.raises(ConfigError, match="not a regular file"):
        output_path(manifest, directory.name)


@pytest.mark.parametrize(
    "relative",
    [
        "verform.toml",
        "Demo/Spec.lean",
        "Demo/Impl.lean",
        "Demo/Proof.lean",
        "lakefile.toml",
        "lean-toolchain",
        "lake-manifest.json",
    ],
)
def test_attestation_output_cannot_overwrite_verification_input(
    tmp_path: Path, relative: str
) -> None:
    manifest = kernel_project(tmp_path)
    protected = manifest.root / relative
    before = protected.read_bytes()

    with pytest.raises(ConfigError, match=f"verification input: {relative}"):
        _write_verified(manifest, passing_report(manifest), relative)

    assert protected.read_bytes() == before


def test_output_cannot_alias_verification_input_through_hard_link(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    protected = manifest.root / "Demo/Spec.lean"
    alias = manifest.root / "review.md"
    alias.hardlink_to(protected)

    with pytest.raises(ConfigError, match=r"verification input: Demo/Spec\.lean"):
        _write_verified(manifest, passing_report(manifest), alias.name)

    assert alias.read_bytes() == protected.read_bytes()


def test_status_rejects_missing_and_malformed_locks(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    with pytest.raises(ConfigError, match="attestation not found"):
        status(manifest)

    lock = manifest.root / "verform.lock.json"
    lock.write_text("not json", encoding="utf-8")
    with pytest.raises(ConfigError, match="cannot read attestation"):
        status(manifest)
    lock.write_text('{"format_version": 99}', encoding="utf-8")
    with pytest.raises(ConfigError, match="unsupported"):
        status(manifest)


def test_invalid_hash_map_is_reported_as_drift(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    destination = _write_verified(manifest, passing_report(manifest), "verform.lock.json")
    data = json.loads(destination.read_text(encoding="utf-8"))
    data["verification_inputs"] = ["invalid"]
    destination.write_text(json.dumps(data), encoding="utf-8")

    gate = next(item for item in status(manifest) if item.name == "verification drift")
    assert not gate.ok
    assert gate.detail == ("attestation contains an invalid hash map",)


def test_public_attest_runs_verifier_and_writes_only_on_success(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = kernel_project(tmp_path)
    passed = passing_report(manifest)
    monkeypatch.setattr("verform.attestation.verify", lambda _: passed)

    report, destination = attest(manifest)
    assert report is passed
    assert destination == manifest.root / "verform.lock.json"

    failed = Report(
        manifest.project.name,
        "kernel",
        (Gate("proof", False, "failed"),),
        Evidence(),
    )
    monkeypatch.setattr("verform.attestation.verify", lambda _: failed)
    report, destination = attest(manifest, "failed.json")
    assert report is failed
    assert destination is None
    assert not (manifest.root / "failed.json").exists()


def test_public_attest_rechecks_inputs_immediately_before_write(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = kernel_project(tmp_path)
    passed = passing_report(manifest)

    def mutate_after_verification(_: object) -> Report:
        proof = manifest.root / "Demo/Proof.lean"
        proof.write_text(proof.read_text(encoding="utf-8") + "\n-- race\n", encoding="utf-8")
        return passed

    monkeypatch.setattr("verform.attestation.verify", mutate_after_verification)
    report, destination = attest(manifest)

    assert not report.ok
    assert report.gates[-1].name == "pre-attestation stability"
    assert destination is None
