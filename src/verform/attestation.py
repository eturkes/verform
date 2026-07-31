"""Checked-state attestations and offline drift detection."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any

from verform import __version__
from verform.errors import ConfigError
from verform.model import Gate, Manifest, Report
from verform.policy import analyze
from verform.presentation import gate_dict
from verform.verifier import verify

LOCK_NAME = "verform.lock.json"
POLICY_PROFILE = "VERFORM-LAKE-CLOSURE-v1"
RECORD_KIND = "unsigned-local-drift-record"


def payload(manifest: Manifest, report: Report) -> dict[str, Any]:
    if not report.ok:
        raise ConfigError("cannot attest a failed verification")
    comparator: dict[str, Any] | None = None
    if manifest.comparator is not None:
        comparator = {
            "challenge_module": manifest.comparator.challenge_module,
            "solution_module": manifest.comparator.solution_module,
            "theorem_names": list(manifest.comparator.theorem_names),
            "definition_names": list(manifest.comparator.definition_names),
            "permitted_axioms": list(manifest.comparator.permitted_axioms),
            "enable_nanoda": True,
        }
    return {
        "format_version": 1,
        "record_kind": RECORD_KIND,
        "policy_profile": POLICY_PROFILE,
        "verform_version": __version__,
        "project": manifest.project.name,
        "prover": manifest.project.prover,
        "assurance": manifest.lean.assurance,
        "toolchain": report.evidence.toolchain,
        "review": {
            "code_lines": report.evidence.review_code_lines,
            "max_code_lines": manifest.review.max_code_lines,
            "files": report.evidence.review_hashes,
        },
        "verification_inputs": report.evidence.input_hashes,
        "obligations": [
            {
                "name": item.name,
                "module": item.module,
                "declaration": item.declaration,
                "statement": item.statement,
                "axioms": list(item.axioms),
            }
            for item in report.evidence.obligations
        ],
        "comparator": comparator,
        "gates": [gate_dict(gate) for gate in report.gates],
    }


def _project_path(manifest: Manifest, requested: str | Path) -> Path:
    requested_path = Path(requested)
    if requested_path.is_absolute():
        raise ConfigError(f"output path must be project-relative: {requested}")
    candidate = manifest.root / requested_path
    try:
        parent = candidate.parent.resolve(strict=True)
    except FileNotFoundError as error:
        raise ConfigError(f"output parent does not exist: {requested}") from error
    if not parent.is_relative_to(manifest.root):
        raise ConfigError(f"attestation output escapes project root: {requested}")
    if candidate.is_symlink():
        raise ConfigError(f"attestation output cannot be a symbolic link: {requested}")
    if candidate.exists() and not candidate.is_file():
        raise ConfigError(f"output destination is not a regular file: {requested}")
    return parent / candidate.name


def output_path(manifest: Manifest, requested: str | Path) -> Path:
    """Resolve a writable project path that cannot alias a verification input."""
    destination = _project_path(manifest, requested)
    inputs = analyze(manifest).evidence.input_hashes
    try:
        destination_stat = destination.stat()
    except FileNotFoundError:
        destination_stat = None
    for relative in inputs:
        protected = manifest.root / relative
        aliases_input = destination == protected
        if destination_stat is not None:
            aliases_input = aliases_input or os.path.samestat(destination_stat, protected.stat())
        if aliases_input:
            raise ConfigError(f"output cannot overwrite verification input: {relative}")
    return destination


def write_output(manifest: Manifest, requested: str | Path, data: str) -> Path:
    """Atomically write checked output without following a replaced destination symlink."""
    destination = output_path(manifest, requested)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=destination.parent,
            prefix=f".{destination.name}.",
            delete=False,
        ) as stream:
            temporary = stream.name
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)
    return destination


def _write_verified(manifest: Manifest, report: Report, requested: str | Path) -> Path:
    data = json.dumps(payload(manifest, report), indent=2, sort_keys=True) + "\n"
    return write_output(manifest, requested, data)


def attest(manifest: Manifest, requested: str | Path = LOCK_NAME) -> tuple[Report, Path | None]:
    """Run every gate, then write the attestation only for that exact successful report."""
    report = verify(manifest)
    if not report.ok:
        return report, None
    current = analyze(manifest).evidence
    stable = (
        current.input_hashes == report.evidence.input_hashes
        and current.review_hashes == report.evidence.review_hashes
    )
    if not stable:
        report = Report(
            report.project,
            report.assurance,
            (
                *report.gates,
                Gate("pre-attestation stability", False, "inputs changed after checks"),
            ),
            report.evidence,
        )
        return report, None
    return report, _write_verified(manifest, report, requested)


def _load(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ConfigError(f"attestation not found: {path}") from error
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ConfigError(f"cannot read attestation {path}: {error}") from error
    if not isinstance(value, dict) or value.get("format_version") != 1:
        raise ConfigError(f"unsupported attestation format: {path}")
    return value


def status(manifest: Manifest, requested: str | Path = LOCK_NAME) -> tuple[Gate, ...]:
    lock_path = _project_path(manifest, requested)
    locked = _load(lock_path)
    current = analyze(manifest)
    gates = list(current.gates)

    identity_ok = (
        locked.get("project") == manifest.project.name
        and locked.get("prover") == manifest.project.prover
        and locked.get("assurance") == manifest.lean.assurance
        and locked.get("verform_version") == __version__
        and locked.get("record_kind") == RECORD_KIND
        and locked.get("policy_profile") == POLICY_PROFILE
    )
    gates.append(
        Gate(
            "attestation identity",
            identity_ok,
            "project, prover, assurance, verifier version, and policy profile match"
            if identity_ok
            else "project, prover, assurance, verifier version, or policy profile drifted",
        )
    )

    locked_review = locked.get("review")
    locked_review_files = locked_review.get("files") if isinstance(locked_review, dict) else None
    review_ok = locked_review_files == current.evidence.review_hashes
    gates.append(
        Gate(
            "review drift",
            review_ok,
            "trusted review surface is unchanged"
            if review_ok
            else "trusted review surface differs from attestation",
            _hash_diff(locked_review_files, current.evidence.review_hashes),
        )
    )

    locked_inputs = locked.get("verification_inputs")
    inputs_ok = locked_inputs == current.evidence.input_hashes
    gates.append(
        Gate(
            "verification drift",
            inputs_ok,
            "all verification inputs are unchanged"
            if inputs_ok
            else "verification inputs differ; rerun `verform attest`",
            _hash_diff(locked_inputs, current.evidence.input_hashes),
        )
    )
    return tuple(gates)


def _hash_diff(locked: object, current: dict[str, str]) -> tuple[str, ...]:
    if not isinstance(locked, dict) or any(
        not isinstance(key, str) or not isinstance(value, str) for key, value in locked.items()
    ):
        return ("attestation contains an invalid hash map",)
    locked_map: dict[str, str] = locked
    old_keys = set(locked_map)
    new_keys = set(current)
    changed = sorted(key for key in old_keys & new_keys if locked_map[key] != current[key])
    return tuple(
        item
        for group in (
            (f"changed: {item}" for item in changed),
            (f"added: {item}" for item in sorted(new_keys - old_keys)),
            (f"removed: {item}" for item in sorted(old_keys - new_keys)),
        )
        for item in group
    )
