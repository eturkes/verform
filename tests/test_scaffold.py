from __future__ import annotations

from pathlib import Path

import pytest

from verform.config import load_manifest
from verform.errors import ScaffoldError
from verform.policy import analyze
from verform.scaffold import create, default_module


@pytest.mark.parametrize("shape", ["pure", "result", "machine"])
@pytest.mark.parametrize("assurance", ["kernel", "comparator"])
def test_every_scaffold_shape_has_a_valid_static_boundary(
    tmp_path: Path, shape: str, assurance: str
) -> None:
    root = create(
        tmp_path / f"{assurance}-{shape}",
        name=f"{assurance}-{shape}",
        module="Verified.App",
        shape=shape,
        assurance=assurance,  # type: ignore[arg-type]
    )
    manifest = load_manifest(root)
    analysis = analyze(manifest)

    assert analysis.ok
    assert (root / "lean-toolchain").read_text(encoding="utf-8").strip().endswith("v4.32.2")
    assert (root / "Verified/App/Spec.lean").is_file()
    if assurance == "kernel":
        assert manifest.obligations
        assert (root / "Verified/App/Proof.lean").is_file()
    else:
        assert manifest.comparator is not None
        assert (root / "Verified/App/Challenge.lean").is_file()
        assert "by sorry" in (root / "Verified/App/Challenge.lean").read_text(encoding="utf-8")


@pytest.mark.parametrize(
    ("name", "expected"),
    [
        ("demo-project", "DemoProject"),
        ("mesh_3d", "Mesh3d"),
        ("42", "Verified42"),
    ],
)
def test_default_module_is_stable(name: str, expected: str) -> None:
    assert default_module(name) == expected


def test_scaffold_refuses_nonempty_or_invalid_destination(tmp_path: Path) -> None:
    occupied = tmp_path / "occupied"
    occupied.mkdir()
    (occupied / "mine.txt").write_text("preserve", encoding="utf-8")

    with pytest.raises(ScaffoldError, match="not empty"):
        create(occupied, name="demo")
    assert (occupied / "mine.txt").read_text(encoding="utf-8") == "preserve"

    regular = tmp_path / "regular-file"
    regular.write_text("preserve", encoding="utf-8")
    with pytest.raises(ScaffoldError, match="not a directory"):
        create(regular, name="demo")
    assert regular.read_text(encoding="utf-8") == "preserve"

    with pytest.raises(ScaffoldError, match="project name"):
        create(tmp_path / "bad-name", name="../bad")
    with pytest.raises(ScaffoldError, match="module"):
        create(tmp_path / "bad-module", name="good", module="lowercase")
    with pytest.raises(ScaffoldError, match="shape"):
        create(tmp_path / "bad-shape", name="good", shape="service")


def test_scaffold_publish_is_atomic_on_write_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    target = tmp_path / "atomic"
    original = Path.write_text
    writes = 0

    def failing_write(path: Path, data: str, *, encoding: str | None = None) -> int:
        nonlocal writes
        writes += 1
        if writes == 2:
            raise OSError("injected write failure")
        return original(path, data, encoding=encoding)

    monkeypatch.setattr(Path, "write_text", failing_write)

    with pytest.raises(ScaffoldError, match="cannot create scaffold"):
        create(target, name="atomic")
    assert not target.exists()
    assert not list(tmp_path.glob(".atomic.verform-init-*"))


def test_scaffold_atomically_replaces_an_existing_empty_directory(tmp_path: Path) -> None:
    target = tmp_path / "empty"
    target.mkdir()

    assert create(target, name="empty") == target
    assert (target / "verform.toml").is_file()


def test_scaffold_readme_states_unverified_boundary(tmp_path: Path) -> None:
    root = create(tmp_path / "demo", name="demo", assurance="comparator")
    readme = (root / "README.md").read_text(encoding="utf-8")
    assert "pure Lean kernel only" in readme
    assert "dedicated unprivileged identity" in readme
    assert "secret-free checker host" in readme
    assert "Demo/Challenge.lean" in readme
    assert "verform attest" in readme
