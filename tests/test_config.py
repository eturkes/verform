from __future__ import annotations

from pathlib import Path

import pytest

from tests.helpers import comparator_project, kernel_project
from verform.config import load_manifest, resolve_manifest
from verform.errors import ConfigError
from verform.model import DEFAULT_AXIOMS


def test_load_kernel_defaults_and_explicit_values(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)

    assert manifest.project.name == "kernel-pure"
    assert manifest.project.prover == "lean4"
    assert manifest.lean.assurance == "kernel"
    assert manifest.obligations[0].allowed_axioms == ()
    assert manifest.obligations[0].contract == "Demo.Spec.Contract"
    assert manifest.obligations[0].implementation == "Demo.Impl.run"
    assert manifest.comparator is None
    assert resolve_manifest(manifest.root) == manifest.path
    assert resolve_manifest(manifest.path) == manifest.path


def test_load_comparator_configuration(tmp_path: Path) -> None:
    manifest = comparator_project(tmp_path)

    assert manifest.lean.assurance == "comparator"
    assert not manifest.obligations
    assert manifest.comparator is not None
    assert manifest.comparator.permitted_axioms == DEFAULT_AXIOMS
    assert manifest.comparator.definition_names == ("Demo.run",)


@pytest.mark.parametrize(
    ("needle", "replacement", "message"),
    [
        ('name = "kernel-pure"', 'name = "kernel-pure"\nunknown = true', "unknown key"),
        ('prover = "lean4"', 'prover = "dafny"', "only 'lean4'"),
        ("manifest_version = 1", "manifest_version = 2", "expected 1"),
        ("manifest_version = 1", "manifest_version = true", "expected 1"),
        (
            'contract = "Demo.Spec.Contract"',
            'contract = "Demo.Spec.Contract\\n#check"',
            "qualified name",
        ),
        (
            'contract = "Demo.Spec.Contract"',
            'contract = "Demo..Contract"',
            "qualified name",
        ),
        (
            'files = ["Demo/Spec.lean", "lakefile.toml", "lean-toolchain", "lake-manifest.json"]',
            'files = ["../Spec.lean"]',
            "project-relative",
        ),
        ("max_code_lines = 80", "max_code_lines = 0", "positive integer"),
        (
            'module_root = "."',
            'module_root = "."\nsource_globs = ["Demo/**/*.lean"]',
            "unknown key",
        ),
    ],
)
def test_rejects_invalid_manifest_values(
    tmp_path: Path, needle: str, replacement: str, message: str
) -> None:
    manifest = kernel_project(tmp_path)
    text = manifest.path.read_text(encoding="utf-8")
    manifest.path.write_text(text.replace(needle, replacement), encoding="utf-8")

    with pytest.raises(ConfigError, match=message):
        load_manifest(manifest.root)


def test_rejects_missing_or_wrong_manifest_location(tmp_path: Path) -> None:
    with pytest.raises(ConfigError, match="manifest not found"):
        load_manifest(tmp_path)

    file = tmp_path / "not-a-directory"
    file.write_text("x", encoding="utf-8")
    with pytest.raises(ConfigError, match="cannot read"):
        load_manifest(file)


def test_rejects_comparator_table_in_kernel_mode(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    with manifest.path.open("a", encoding="utf-8") as stream:
        stream.write(
            """
[comparator]
challenge_module = "Demo.Challenge"
solution_module = "Demo.Solution"
theorem_names = ["Demo.ok"]
definition_names = ["Demo.run"]
"""
        )
    with pytest.raises(ConfigError, match="allowed only"):
        load_manifest(manifest.root)


def test_rejects_unsandboxed_checks_in_comparator_mode(tmp_path: Path) -> None:
    manifest = comparator_project(tmp_path)
    with manifest.path.open("a", encoding="utf-8") as stream:
        stream.write('\n[[checks]]\nname = "runtime"\ncommand = ["true"]\n')
    with pytest.raises(ConfigError, match="unsandboxed"):
        load_manifest(manifest.root)


def test_standard_axiom_defaults_when_field_removed(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    text = manifest.path.read_text(encoding="utf-8")
    manifest.path.write_text(text.replace("allowed_axioms = []\n", ""), encoding="utf-8")

    assert load_manifest(manifest.root).obligations[0].allowed_axioms == DEFAULT_AXIOMS


@pytest.mark.parametrize("axiom", ["sorryAx", "Lean.trustCompiler", "Lean.ofReduceBool"])
def test_hard_denied_axioms_cannot_be_allowlisted(tmp_path: Path, axiom: str) -> None:
    manifest = kernel_project(tmp_path)
    text = manifest.path.read_text(encoding="utf-8")
    manifest.path.write_text(
        text.replace("allowed_axioms = []", f'allowed_axioms = ["{axiom}"]'),
        encoding="utf-8",
    )

    with pytest.raises(ConfigError, match="hard-denied"):
        load_manifest(manifest.root)


def test_comparator_nanoda_cannot_be_disabled(tmp_path: Path) -> None:
    manifest = comparator_project(tmp_path)
    with manifest.path.open("a", encoding="utf-8") as stream:
        stream.write("enable_nanoda = false\n")

    with pytest.raises(ConfigError, match="unknown key"):
        load_manifest(manifest.root)


def test_comparator_requires_nanoda_prelude_axiom_allowances(tmp_path: Path) -> None:
    manifest = comparator_project(tmp_path)
    text = manifest.path.read_text(encoding="utf-8")
    manifest.path.write_text(
        text.replace(
            'permitted_axioms = ["Classical.choice", "Quot.sound", "propext"]',
            'permitted_axioms = ["propext"]',
        ),
        encoding="utf-8",
    )

    with pytest.raises(ConfigError, match="mandatory nanoda replay"):
        load_manifest(manifest.root)
