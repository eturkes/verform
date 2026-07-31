"""Immutable configuration and result values."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

Assurance = Literal["kernel", "comparator"]

DEFAULT_FORBIDDEN = (
    "admit",
    "axiom",
    "constant",
    "csimp",
    "extern",
    "implemented_by",
    "opaque",
    "partial",
    "partial_fixpoint",
    "skipKernelTC",
    "sorry",
    "unsafe",
)
DEFAULT_AXIOMS = ("Classical.choice", "Quot.sound", "propext")
HARD_DENIED_AXIOMS = ("Lean.ofReduceBool", "Lean.trustCompiler", "sorryAx")


@dataclass(frozen=True)
class Project:
    name: str
    prover: str


@dataclass(frozen=True)
class Review:
    files: tuple[str, ...]
    max_code_lines: int


@dataclass(frozen=True)
class Lean:
    assurance: Assurance
    module_root: str
    evidence_files: tuple[str, ...]
    timeout_seconds: int


@dataclass(frozen=True)
class Obligation:
    name: str
    module: str
    declaration: str
    contract: str
    implementation: str
    allowed_axioms: tuple[str, ...]

    @property
    def statement(self) -> str:
        """Exact contract application checked by Lean."""
        return f"{self.contract} {self.implementation}"


@dataclass(frozen=True)
class Comparator:
    challenge_module: str
    solution_module: str
    theorem_names: tuple[str, ...]
    definition_names: tuple[str, ...]
    permitted_axioms: tuple[str, ...]


@dataclass(frozen=True)
class ExtraCheck:
    name: str
    command: tuple[str, ...]
    timeout_seconds: int


@dataclass(frozen=True)
class Manifest:
    root: Path
    path: Path
    project: Project
    review: Review
    lean: Lean
    obligations: tuple[Obligation, ...]
    comparator: Comparator | None
    checks: tuple[ExtraCheck, ...]


@dataclass(frozen=True)
class Gate:
    name: str
    ok: bool
    summary: str
    detail: tuple[str, ...] = ()


@dataclass(frozen=True)
class ObligationEvidence:
    name: str
    module: str
    declaration: str
    statement: str
    axioms: tuple[str, ...]


@dataclass(frozen=True)
class Evidence:
    toolchain: str = ""
    review_code_lines: int = 0
    review_hashes: dict[str, str] = field(default_factory=dict)
    input_hashes: dict[str, str] = field(default_factory=dict)
    obligations: tuple[ObligationEvidence, ...] = ()


@dataclass(frozen=True)
class Report:
    project: str
    assurance: Assurance
    gates: tuple[Gate, ...]
    evidence: Evidence

    @property
    def ok(self) -> bool:
        return bool(self.gates) and all(gate.ok for gate in self.gates)
