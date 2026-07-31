from __future__ import annotations

import json
from pathlib import Path

import pytest

import verform.cli as cli
import verform.review as review
from tests.helpers import comparator_project, kernel_project, passing_report
from verform.attestation import _write_verified
from verform.config import load_manifest
from verform.errors import ConfigError
from verform.model import Evidence, Gate, Report
from verform.policy import analyze
from verform.review import packet


def test_cli_init_review_and_errors(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    destination = tmp_path / "new"
    assert cli.main(["init", str(destination), "--name", "new", "--shape", "machine"]) == 0
    assert "CREATED" in capsys.readouterr().out

    assert cli.main(["review", str(destination)]) == 0
    output = capsys.readouterr().out
    assert "# Verform review — new" in output
    assert "generated proofs are deliberately absent" in output
    assert "AI-owned proof" not in output

    assert cli.main(["init", str(destination), "--name", "new"]) == 2
    assert "not empty" in capsys.readouterr().err


def test_cli_check_text_and_json(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    manifest = kernel_project(tmp_path)
    report = passing_report(manifest)
    monkeypatch.setattr(cli, "verify", lambda _: report)

    assert cli.main(["check", str(manifest.root)]) == 0
    assert "ACCEPTED[kernel]" in capsys.readouterr().out

    assert cli.main(["check", str(manifest.root), "--json"]) == 0
    parsed = json.loads(capsys.readouterr().out)
    assert parsed["ok"] is True
    assert parsed["assurance"] == "kernel"


def test_cli_failed_check_does_not_attest(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    manifest = kernel_project(tmp_path)
    failed = Report(
        manifest.project.name,
        "kernel",
        (Gate("proof", False, "bad"),),
        Evidence(),
    )
    monkeypatch.setattr(cli, "attest", lambda *_: (failed, None))

    assert cli.main(["attest", str(manifest.root)]) == 1
    assert "REJECTED" in capsys.readouterr().out
    assert not (manifest.root / "verform.lock.json").exists()


def test_cli_attest_then_status(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    manifest = kernel_project(tmp_path)
    report = passing_report(manifest)
    destination = _write_verified(manifest, report, "verform.lock.json")
    monkeypatch.setattr(cli, "attest", lambda *_: (report, destination))

    assert cli.main(["attest", str(manifest.root)]) == 0
    assert "ATTESTED verform.lock.json" in capsys.readouterr().out

    assert cli.main(["attest", str(manifest.root), "--json"]) == 0
    captured = capsys.readouterr()
    parsed = json.loads(captured.out)
    assert parsed["ok"] is True
    assert parsed["attestation"] == "verform.lock.json"
    assert captured.err == ""

    assert cli.main(["status", str(manifest.root)]) == 0
    assert "CURRENT" in capsys.readouterr().out

    proof = manifest.root / "Demo/Proof.lean"
    proof.write_text(proof.read_text(encoding="utf-8") + "\n-- drift\n", encoding="utf-8")
    assert cli.main(["status", str(manifest.root), "--json"]) == 1
    parsed = json.loads(capsys.readouterr().out)
    assert parsed["ok"] is False


def test_review_packet_contains_only_manifest_and_trusted_sources(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    rendered = packet(manifest)

    assert "Demo/Spec.lean" in rendered
    assert "Demo/Proof.lean" not in rendered
    assert "SHA-256" in rendered
    assert "implementation-correct" in rendered


def test_review_packet_rejects_incomplete_boundary_but_allows_proof_iteration(
    tmp_path: Path,
) -> None:
    manifest = kernel_project(tmp_path)
    proof = manifest.root / "Demo/Proof.lean"
    proof.write_text(proof.read_text(encoding="utf-8") + "\nsorry\n", encoding="utf-8")

    rendered = packet(manifest)
    assert "Full-tree source-policy failures" in rendered
    assert "forbidden `sorry`" in rendered

    text = manifest.path.read_text(encoding="utf-8")
    manifest.path.write_text(
        text.replace("max_code_lines = 80", "max_code_lines = 1"), encoding="utf-8"
    )
    with pytest.raises(ConfigError, match="cannot render a complete review packet"):
        packet(load_manifest(manifest.root))


def test_comparator_review_packet_and_dynamic_fence(tmp_path: Path) -> None:
    manifest = comparator_project(tmp_path)
    rendered = packet(manifest)
    assert "Independent nanoda replay" in rendered
    assert "Demo.Challenge" in rendered

    manifest = kernel_project(tmp_path / "fence")
    note = manifest.root / "notes.txt"
    note.write_text("review text with ```` fence\n", encoding="utf-8")
    text = manifest.path.read_text(encoding="utf-8")
    text = text.replace('files = ["', 'files = ["notes.txt", "')
    text = text.replace(
        'evidence_files = ["lean-toolchain"',
        'evidence_files = ["notes.txt", "lean-toolchain"',
    )
    manifest.path.write_text(text, encoding="utf-8")

    rendered = packet(load_manifest(manifest.root))
    assert "`````text\nreview text with ```` fence\n`````" in rendered


def test_review_packet_rejects_changed_or_nontext_input(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = kernel_project(tmp_path)
    analysis = analyze(manifest)
    spec = manifest.root / "Demo/Spec.lean"
    spec.write_text(spec.read_text(encoding="utf-8") + "\n-- raced\n", encoding="utf-8")
    monkeypatch.setattr(review, "analyze", lambda _: analysis)
    with pytest.raises(ConfigError, match="changed while rendering"):
        packet(manifest)

    monkeypatch.undo()
    manifest = kernel_project(tmp_path / "binary")
    note = manifest.root / "notes.bin"
    note.write_bytes(b"\xff")
    text = manifest.path.read_text(encoding="utf-8")
    text = text.replace('files = ["', 'files = ["notes.bin", "')
    text = text.replace(
        'evidence_files = ["lean-toolchain"',
        'evidence_files = ["notes.bin", "lean-toolchain"',
    )
    manifest.path.write_text(text, encoding="utf-8")
    with pytest.raises(ConfigError, match="not UTF-8"):
        packet(load_manifest(manifest.root))


def test_review_output_must_stay_in_project(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    manifest = kernel_project(tmp_path)
    assert cli.main(["review", str(manifest.root), "--output", "review.md"]) == 0
    assert (manifest.root / "review.md").is_file()
    assert "WROTE review.md" in capsys.readouterr().out

    assert cli.main(["review", str(manifest.root), "--output", "../escape.md"]) == 2
    assert "escapes project root" in capsys.readouterr().err

    spec = manifest.root / "Demo/Spec.lean"
    before = spec.read_bytes()
    assert cli.main(["review", str(manifest.root), "--output", "Demo/Spec.lean"]) == 2
    assert "verification input" in capsys.readouterr().err
    assert spec.read_bytes() == before
