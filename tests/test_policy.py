from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path

import pytest

from tests.helpers import comparator_project, kernel_project
from verform.config import load_manifest
from verform.errors import ConfigError
from verform.policy import analyze


def gate(manifest_path: Path, name: str):  # type: ignore[no-untyped-def]
    analysis = analyze(load_manifest(manifest_path))
    return next(item for item in analysis.gates if item.name == name)


def test_clean_scaffold_passes_all_static_gates(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    analysis = analyze(manifest)

    assert analysis.ok
    assert len(analysis.sources) == 4
    assert analysis.modules["Demo.Spec"] == manifest.root / "Demo/Spec.lean"
    assert set(analysis.evidence.review_hashes) == {
        "Demo/Spec.lean",
        "lake-manifest.json",
        "lakefile.toml",
        "lean-toolchain",
        "verform.toml",
    }
    assert "verform.toml" in analysis.evidence.input_hashes


def test_forbidden_tokens_are_exact_and_report_lines(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    proof = manifest.root / "Demo/Proof.lean"
    proof.write_text(
        proof.read_text(encoding="utf-8")
        + '\ndef unsafeName := "safe text"\naxiom broken : False\n',
        encoding="utf-8",
    )

    result = gate(manifest.root, "source policy")
    assert not result.ok
    assert len(result.detail) == 1
    assert "forbidden `axiom`" in result.detail[0]


@pytest.mark.parametrize(
    "prefix",
    [
        "def quote : Char := '\"'\n",
        'def payload := r"\\"\n',
        'def text := "safe"\n',
    ],
)
def test_literal_syntax_cannot_hide_forbidden_spellings(tmp_path: Path, prefix: str) -> None:
    manifest = kernel_project(tmp_path)
    proof = manifest.root / "Demo/Proof.lean"
    proof.write_text(prefix + "axiom hidden : False\n", encoding="utf-8")

    result = gate(manifest.root, "source policy")
    assert not result.ok
    assert any("forbidden `axiom`" in item for item in result.detail)


def test_symbol_boundary_requires_reviewed_contract_owner(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    text = manifest.path.read_text(encoding="utf-8")
    manifest.path.write_text(text.replace("Demo/Spec.lean", "Demo/Impl.lean"), encoding="utf-8")

    result = gate(manifest.root, "symbol boundary")
    assert not result.ok
    assert any("contract owner" in item for item in result.detail)


def test_review_budget_is_enforced(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    text = manifest.path.read_text(encoding="utf-8")
    manifest.path.write_text(
        text.replace("max_code_lines = 80", "max_code_lines = 1"), encoding="utf-8"
    )
    assert not gate(manifest.root, "review surface").ok


def test_source_discovery_cannot_omit_local_module(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    evil = manifest.root / "Evil.lean"
    evil.write_text("axiom hidden : False\n", encoding="utf-8")

    analysis = analyze(manifest)
    assert "Evil" in analysis.modules
    assert not next(item for item in analysis.gates if item.name == "source policy").ok


def test_comparator_challenge_is_only_sorry_exemption(tmp_path: Path) -> None:
    manifest = comparator_project(tmp_path)
    assert analyze(manifest).ok

    challenge = manifest.root / "Demo/Challenge.lean"
    challenge.write_text(
        challenge.read_text(encoding="utf-8") + "\naxiom exploit : False\n",
        encoding="utf-8",
    )
    result = gate(manifest.root, "source policy")
    assert not result.ok
    assert all("forbidden `sorry`" not in item for item in result.detail)
    assert any("axiom" in item for item in result.detail)


def test_rejects_symlinked_review_file(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    spec = manifest.root / "Demo/Spec.lean"
    target = manifest.root / "Demo/Actual.lean"
    spec.rename(target)
    spec.symlink_to(target.name)

    with pytest.raises(ConfigError, match="symbolic links"):
        analyze(manifest)


def test_rejects_symlinked_input_ancestors_and_module_root(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    real = manifest.root / "real-inputs"
    real.mkdir()
    (real / "notes.txt").write_text("reviewed\n", encoding="utf-8")
    (manifest.root / "linked-inputs").symlink_to(real.name, target_is_directory=True)
    text = manifest.path.read_text(encoding="utf-8")
    text = text.replace('files = ["', 'files = ["linked-inputs/notes.txt", "')
    text = text.replace(
        'evidence_files = ["lean-toolchain"',
        'evidence_files = ["linked-inputs/notes.txt", "lean-toolchain"',
    )
    manifest.path.write_text(text, encoding="utf-8")

    with pytest.raises(ConfigError, match="symbolic link components"):
        analyze(load_manifest(manifest.root))

    manifest = kernel_project(tmp_path / "module-root")
    actual_root = manifest.root / "ActualSources"
    actual_root.mkdir()
    (manifest.root / "Sources").symlink_to(actual_root.name, target_is_directory=True)
    text = manifest.path.read_text(encoding="utf-8")
    manifest.path.write_text(
        text.replace('module_root = "."', 'module_root = "Sources"'), encoding="utf-8"
    )

    with pytest.raises(ConfigError, match="symbolic link components"):
        analyze(load_manifest(manifest.root))


def test_rejects_missing_or_empty_module_root(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    text = manifest.path.read_text(encoding="utf-8")
    manifest.path.write_text(
        text.replace('module_root = "."', 'module_root = "missing"'),
        encoding="utf-8",
    )
    with pytest.raises(ConfigError, match="path not found"):
        analyze(load_manifest(manifest.root))

    empty = manifest.root / "empty"
    empty.mkdir()
    manifest.path.write_text(
        manifest.path.read_text(encoding="utf-8").replace(
            'module_root = "missing"', 'module_root = "empty"'
        ),
        encoding="utf-8",
    )
    with pytest.raises(ConfigError, match="no Lean sources"):
        analyze(load_manifest(manifest.root))


def test_build_configuration_is_complete_reviewed_and_unambiguous(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    (manifest.root / "lakefile.lean").write_text("import Lake\n", encoding="utf-8")
    with pytest.raises(ConfigError, match=r"lakefile\.lean"):
        analyze(manifest)

    (manifest.root / "lakefile.lean").unlink()
    text = manifest.path.read_text(encoding="utf-8")
    manifest.path.write_text(text.replace(', "lake-manifest.json"', ""), encoding="utf-8")
    result = gate(manifest.root, "review surface")
    assert not result.ok
    assert any("lake-manifest.json" in item for item in result.detail)


def test_lake_lock_rejects_duplicate_names_and_unpinned_git(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    lock = manifest.root / "lake-manifest.json"
    package = {
        "type": "git",
        "name": "dep",
        "scope": "",
        "inherited": False,
        "configFile": "lakefile.toml",
        "manifestFile": "lake-manifest.json",
        "url": "https://example.invalid/dep",
        "rev": "not-pinned",
        "inputRev": "main",
        "subDir": None,
    }
    data = {
        "version": "1.2.0",
        "fixedToolchain": False,
        "name": "kernel-pure",
        "lakeDir": ".lake",
        "packagesDir": ".lake/packages",
        "packages": [package, dict(package)],
    }
    lock.write_text(json.dumps(data), encoding="utf-8")

    result = gate(manifest.root, "build closure")
    assert not result.ok
    assert any("duplicate package" in item for item in result.detail)
    assert any("40-hex" in item for item in result.detail)


def test_lake_lock_accepts_unscoped_git_with_no_nested_manifest(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    lock = manifest.root / "lake-manifest.json"
    data = json.loads(lock.read_text(encoding="utf-8"))
    data["packages"] = [
        {
            "type": "git",
            "name": "dep",
            "scope": "",
            "inherited": False,
            "configFile": "lakefile.toml",
            "manifestFile": None,
            "url": "https://example.invalid/dep",
            "rev": "0123456789abcdef0123456789abcdef01234567",
            "inputRev": None,
            "subDir": None,
        }
    ]
    lock.write_text(json.dumps(data), encoding="utf-8")

    assert gate(manifest.root, "build closure").ok


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        (lambda data: data.update(version="1.1.0"), "version"),
        (lambda data: data.update(fixedToolchain="no"), "fixedToolchain"),
        (lambda data: data.update(lakeDir="outside"), "directories"),
        (lambda data: data.update(name="different"), "package name"),
        (lambda data: data.update(name=[]), "package name"),
        (lambda data: data.update(packages="wrong"), "packages must"),
        (lambda data: data.update(extra=True), "unknown root key"),
        (lambda data: data.pop("packages"), "missing root key"),
    ],
)
def test_lake_lock_rejects_noncanonical_root_schema(
    tmp_path: Path, mutation: Callable[[dict[str, object]], object], message: str
) -> None:
    manifest = kernel_project(tmp_path)
    lock = manifest.root / "lake-manifest.json"
    data = json.loads(lock.read_text(encoding="utf-8"))
    mutation(data)
    lock.write_text(json.dumps(data), encoding="utf-8")

    with pytest.raises(ConfigError, match=message):
        analyze(manifest)


def test_lake_lock_rejects_malformed_files_and_override_channels(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    lock = manifest.root / "lake-manifest.json"
    lock.write_text("[]", encoding="utf-8")
    with pytest.raises(ConfigError, match="object"):
        analyze(manifest)
    lock.write_text("{", encoding="utf-8")
    with pytest.raises(ConfigError, match="invalid lake-manifest"):
        analyze(manifest)

    manifest = kernel_project(tmp_path / "lakefile")
    (manifest.root / "lakefile.toml").write_text("not = [toml", encoding="utf-8")
    with pytest.raises(ConfigError, match="invalid lakefile"):
        analyze(manifest)

    manifest = kernel_project(tmp_path / "toolchain")
    (manifest.root / "lean-toolchain").write_text("leanprover/lean4:nightly\n", encoding="utf-8")
    with pytest.raises(ConfigError, match=r"v4\.32\.2"):
        analyze(manifest)

    manifest = kernel_project(tmp_path / "override")
    override = manifest.root / ".lake/package-overrides.json"
    override.parent.mkdir()
    override.write_text("{}", encoding="utf-8")
    with pytest.raises(ConfigError, match="override"):
        analyze(manifest)


def test_lake_lock_reports_every_malformed_package_field(tmp_path: Path) -> None:
    manifest = kernel_project(tmp_path)
    lock = manifest.root / "lake-manifest.json"
    data = json.loads(lock.read_text(encoding="utf-8"))
    malformed = {
        "type": "path",
        "name": "",
        "scope": 4,
        "inherited": "no",
        "configFile": "../lakefile.toml",
        "manifestFile": "",
        "url": None,
        "rev": "A" * 40,
        "inputRev": 3,
        "subDir": "/absolute",
    }
    data["packages"] = [42, {"name": "incomplete"}, malformed]
    lock.write_text(json.dumps(data), encoding="utf-8")

    result = gate(manifest.root, "build closure")
    assert not result.ok
    joined = "\n".join(result.detail)
    for expected in (
        "expected an object",
        "missing key",
        "only pinned git",
        "expected a non-empty string",
        "expected a boolean",
        "40-hex",
        "string or null",
        "inside its package",
    ):
        assert expected in joined
