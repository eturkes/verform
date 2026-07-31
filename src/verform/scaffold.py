"""Safe Lean project scaffolding for reusable contract shapes."""

from __future__ import annotations

import os
import re
import shutil
import tempfile
from pathlib import Path

from verform.errors import ScaffoldError
from verform.model import Assurance

Shape = str
_PROJECT = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*\Z")
_MODULE = re.compile(r"[A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9]*)*\Z")


def default_module(name: str) -> str:
    words = re.findall(r"[A-Za-z0-9]+", name)
    candidate = "".join(word[:1].upper() + word[1:] for word in words)
    if not candidate or not candidate[0].isalpha():
        candidate = f"Verified{candidate}"
    return candidate


def _spec(module: str, shape: Shape) -> str:
    if shape == "pure":
        body = """namespace Spec

abbrev Program := Nat → Nat

/-- The entire human-reviewed behavioral contract. -/
def Contract (program : Program) : Prop :=
  ∀ input, program input = input + 1

/-- Formal non-vacuity witness: the contract is satisfiable. -/
theorem contract_inhabited : ∃ program, Contract program := by
  exact ⟨fun input => input + 1, by intro input; rfl⟩

end Spec"""
    elif shape == "result":
        body = """namespace Spec

inductive Error where
  | rejected
  deriving DecidableEq, Repr

abbrev Program := Nat → Except Error Nat

abbrev Pre (input : Nat) : Prop := input ≤ 100
def Post (input output : Nat) : Prop := output = input + 1
def ErrorAllowed (input : Nat) (error : Error) : Prop :=
  error = .rejected ∧ ¬ Pre input

/-- Success/error soundness + completeness; an always-error program cannot pass. -/
def Contract (program : Program) : Prop :=
  (∀ input output, program input = .ok output → Post input output) ∧
  (∀ input, Pre input → ∃ output, program input = .ok output) ∧
  (∀ input error, program input = .error error → ErrorAllowed input error) ∧
  (∀ input, ¬ Pre input → ∃ error, program input = .error error)

end Spec"""
    elif shape == "machine":
        body = """namespace Spec

inductive State where
  | idle
  | armed
  deriving DecidableEq, Repr

inductive Command where
  | toggle
  | reset
  deriving DecidableEq, Repr

def next : State → Command → State
  | .idle, .toggle => .armed
  | .armed, .toggle => .idle
  | _, .reset => .idle

abbrev Program := State → Command → State

/-- One-step refinement; induction lifts equality to every finite command trace. -/
def Contract (step : Program) : Prop :=
  ∀ state command, step state command = next state command

/-- The reference transition proves the contract is satisfiable. -/
theorem contract_inhabited : Contract next := by
  intro state command
  rfl

end Spec"""
    else:
        raise ScaffoldError(f"unknown contract shape: {shape}")
    return f"""/-!
Human-reviewed semantics. Keep this module independent of implementation/proof code.
-/

namespace {module}

{body}

end {module}
"""


def _definition(shape: Shape) -> str:
    definitions = {
        "pure": "def run : Spec.Program := fun input => input + 1",
        "result": """def run : Spec.Program := fun input =>
  if Spec.Pre input then .ok (input + 1) else .error .rejected""",
        "machine": """def step : Spec.Program
  | .idle, .toggle => .armed
  | .armed, .toggle => .idle
  | _, .reset => .idle""",
    }
    try:
        return definitions[shape]
    except KeyError as error:
        raise ScaffoldError(f"unknown contract shape: {shape}") from error


def _implementation(module: str, shape: Shape) -> str:
    definition = _definition(shape)
    return f"""import {module}.Spec

/-! AI-owned executable implementation. Human review is unnecessary for the formal claim. -/

namespace {module}
namespace Impl

{definition}

end Impl
end {module}
"""


def _proof(module: str, shape: Shape) -> str:
    root = "step" if shape == "machine" else "run"
    if shape == "result":
        proof = """by
  constructor
  · intro input output hrun
    unfold Impl.run at hrun
    split at hrun
    · cases hrun
      rfl
    · contradiction
  constructor
  · intro input hpre
    exact ⟨input + 1, if_pos hpre⟩
  constructor
  · intro input error hrun
    unfold Impl.run at hrun
    split at hrun
    · contradiction
    · rename_i hpre
      cases hrun
      exact ⟨rfl, hpre⟩
  · intro input hpre
    exact ⟨Spec.Error.rejected, if_neg hpre⟩"""
    else:
        proof = (
            "by\n  intro state command\n  rfl" if shape == "machine" else "by\n  intro input\n  rfl"
        )
    return f"""import {module}.Impl

/-! AI-owned proof connecting the exact executable root to the reviewed contract. -/

namespace {module}.Proof

theorem implementation_correct : {module}.Spec.Contract {module}.Impl.{root} := {proof}

end {module}.Proof
"""


def _manifest(name: str, module: str, assurance: Assurance, shape: Shape) -> str:
    module_dir = module.replace(".", "/")
    if assurance == "kernel":
        root = "step" if shape == "machine" else "run"
        return f"""manifest_version = 1

[project]
name = "{name}"
prover = "lean4"

[review]
files = ["{module_dir}/Spec.lean", "lakefile.toml", "lean-toolchain", "lake-manifest.json"]
max_code_lines = 80

[lean]
assurance = "kernel"
module_root = "."
evidence_files = ["lean-toolchain", "lakefile.toml"]
timeout_seconds = 600

[[obligations]]
name = "implementation-correct"
module = "{module}.Proof"
declaration = "{module}.Proof.implementation_correct"
contract = "{module}.Spec.Contract"
implementation = "{module}.Impl.{root}"
allowed_axioms = []
"""
    root = "step" if shape == "machine" else "run"
    return f"""manifest_version = 1

[project]
name = "{name}"
prover = "lean4"

[review]
files = [
  "{module_dir}/Spec.lean",
  "{module_dir}/Challenge.lean",
  "lakefile.toml",
  "lean-toolchain",
  "lake-manifest.json",
]
max_code_lines = 100

[lean]
assurance = "comparator"
module_root = "."
evidence_files = ["lean-toolchain", "lakefile.toml"]
timeout_seconds = 1200

[comparator]
challenge_module = "{module}.Challenge"
solution_module = "{module}.Solution"
theorem_names = ["{module}.implementation_correct"]
definition_names = ["{module}.{root}"]
permitted_axioms = ["Classical.choice", "Quot.sound", "propext"]
"""


def _comparator_modules(module: str, shape: Shape) -> tuple[str, str]:
    root = "step" if shape == "machine" else "run"
    challenge = f"""import {module}.Spec

/-! Trusted challenge holes. Comparator matches their exact types against Solution. -/

namespace {module}

def {root} : Spec.Program := by sorry

theorem implementation_correct : Spec.Contract {root} := by sorry

end {module}
"""
    definition = _definition(shape)
    if shape == "result":
        proof = """by
  constructor
  · intro input output hrun
    unfold run at hrun
    split at hrun
    · cases hrun
      rfl
    · contradiction
  constructor
  · intro input hpre
    exact ⟨input + 1, if_pos hpre⟩
  constructor
  · intro input error hrun
    unfold run at hrun
    split at hrun
    · contradiction
    · rename_i hpre
      cases hrun
      exact ⟨rfl, hpre⟩
  · intro input hpre
    exact ⟨Spec.Error.rejected, if_neg hpre⟩"""
    elif shape == "machine":
        proof = "by\n  intro state command\n  rfl"
    else:
        proof = "by\n  intro input\n  rfl"
    solution = f"""import {module}.Spec

/-! AI-owned solution. Comparator checks it against Challenge in a separate environment. -/

namespace {module}

{definition}

theorem implementation_correct : Spec.Contract {root} := {proof}

end {module}
"""
    return challenge, solution


def create(
    destination: str | Path,
    *,
    name: str,
    module: str | None = None,
    shape: Shape = "pure",
    assurance: Assurance = "kernel",
) -> Path:
    if not _PROJECT.fullmatch(name):
        raise ScaffoldError("project name must use letters, digits, '.', '_' or '-'")
    module = module or default_module(name)
    if not _MODULE.fullmatch(module):
        raise ScaffoldError("module must be dot-separated ASCII names beginning with capitals")
    if shape not in {"pure", "result", "machine"}:
        raise ScaffoldError("shape must be pure, result, or machine")
    if assurance not in {"kernel", "comparator"}:
        raise ScaffoldError("assurance must be kernel or comparator")

    target = Path(destination).expanduser().resolve(strict=False)
    if target.exists():
        if not target.is_dir():
            raise ScaffoldError(f"destination is not a directory: {target}")
        if any(target.iterdir()):
            raise ScaffoldError(f"destination is not empty: {target}")
    module_path = Path(*module.split("."))
    library = module.split(".")[0]
    files: dict[Path, str] = {
        Path("lean-toolchain"): "leanprover/lean4:v4.32.2\n",
        Path("lakefile.toml"): (
            f'name = "{name}"\nversion = "0.1.0"\n'
            f'defaultTargets = ["{library}"]\n\n[[lean_lib]]\nname = "{library}"\n'
            f'roots = ["{module}"]\n'
        ),
        Path("lake-manifest.json"): (
            "{\n"
            '  "version": "1.2.0",\n'
            '  "fixedToolchain": false,\n'
            f'  "name": "«{name}»",\n'
            '  "lakeDir": ".lake",\n'
            '  "packagesDir": ".lake/packages",\n'
            '  "packages": []\n'
            "}\n"
        ),
        Path("verform.toml"): _manifest(name, module, assurance, shape),
        module_path / "Spec.lean": _spec(module, shape),
        Path(f"{module_path}.lean"): (
            f"import {module}.Proof\n" if assurance == "kernel" else f"import {module}.Spec\n"
        ),
        Path(".gitignore"): ".lake/\n",
        Path("README.md"): _readme(name, module, shape, assurance),
    }
    if assurance == "kernel":
        files[module_path / "Impl.lean"] = _implementation(module, shape)
        files[module_path / "Proof.lean"] = _proof(module, shape)
    else:
        challenge, solution = _comparator_modules(module, shape)
        files[module_path / "Challenge.lean"] = challenge
        files[module_path / "Solution.lean"] = solution

    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(prefix=f".{target.name}.verform-init-", dir=target.parent))
    except OSError as error:
        raise ScaffoldError(f"cannot prepare destination {target}: {error}") from error
    try:
        for relative, content in files.items():
            path = staging / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        os.replace(staging, target)
    except OSError as error:
        raise ScaffoldError(f"cannot create scaffold at {target}: {error}") from error
    finally:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
    return target


def _readme(name: str, module: str, shape: Shape, assurance: Assurance) -> str:
    module_path = module.replace(".", "/")
    extra = ""
    if assurance == "comparator":
        extra = (
            "Comparator mode additionally requires `comparator`, `landrun`, `lean4export`, and "
            "current `nanoda_bin` on `PATH` (or `COMPARATOR_*` overrides). Run certification "
            "under a dedicated unprivileged identity on a clean, secret-free checker host.\n\n"
        )
    return f"""# {name}

Lean {shape} kernel generated by Verform with `{assurance}` assurance.

{extra}## Workflow

1. Edit and review `{module_path}/Spec.lean` (and
   `{module_path}/Challenge.lean` in comparator mode).
2. Keep implementation/proof work outside the trusted review surface.
3. Run `verform review .`, then `verform check .`.
4. Run `verform attest .` and commit `verform.lock.json` with the verified sources.
5. Use `verform status .` for a prover-free drift check.

The formal claim covers the pure Lean kernel only. IO, foreign code, resource use, and compiled
artifact correctness require separate modeling or validation.
"""
