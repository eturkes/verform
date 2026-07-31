from __future__ import annotations

from pathlib import Path

from verform.config import load_manifest
from verform.model import Evidence, Gate, Manifest, Report
from verform.policy import analyze
from verform.scaffold import create


def kernel_project(tmp_path: Path, *, shape: str = "pure") -> Manifest:
    root = tmp_path / f"kernel-{shape}"
    create(root, name=f"kernel-{shape}", module="Demo", shape=shape, assurance="kernel")
    return load_manifest(root)


def comparator_project(tmp_path: Path, *, shape: str = "pure") -> Manifest:
    root = tmp_path / f"comparator-{shape}"
    create(
        root,
        name=f"comparator-{shape}",
        module="Demo",
        shape=shape,
        assurance="comparator",
    )
    return load_manifest(root)


def passing_report(manifest: Manifest) -> Report:
    evidence = analyze(manifest).evidence
    return Report(
        manifest.project.name,
        manifest.lean.assurance,
        (Gate("proof", True, "passed"),),
        Evidence(
            toolchain="Lean (version test)",
            review_code_lines=evidence.review_code_lines,
            review_hashes=evidence.review_hashes,
            input_hashes=evidence.input_hashes,
        ),
    )
