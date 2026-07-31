# Verform review — verified-counter

- Assurance: `kernel`
- Trusted Lean surface: 21/80 nonblank lines
- Review the manifest and every trusted file below; generated proofs are deliberately absent.

## Declared obligations

- `implementation-correct`: `VerifiedCounter.Proof.implementation_correct` proves `VerifiedCounter.Spec.Contract VerifiedCounter.Impl.run`; allowed axioms = `(none)`

## Manifest

SHA-256 `72582568fdc20697ae79ee8ecada671d58fd19cda8b451b6adaaff8c2801a9c7`

````toml
manifest_version = 1

[project]
name = "verified-counter"
prover = "lean4"

[review]
files = ["VerifiedCounter/Spec.lean", "lakefile.toml", "lean-toolchain", "lake-manifest.json"]
max_code_lines = 80

[lean]
assurance = "kernel"
module_root = "."
evidence_files = ["lean-toolchain", "lakefile.toml"]
timeout_seconds = 600

[[obligations]]
name = "implementation-correct"
module = "VerifiedCounter.Proof"
declaration = "VerifiedCounter.Proof.implementation_correct"
contract = "VerifiedCounter.Spec.Contract"
implementation = "VerifiedCounter.Impl.run"
allowed_axioms = []
````

## `VerifiedCounter/Spec.lean`

SHA-256 `85034901b7a6a4661fffd40b43cd37e5bf2e35abf287f69f242bccc28be8b3fe` · 21 nonblank lines

````lean
/-!
Human-reviewed semantics. Keep this module independent of implementation/proof code.
-/

namespace VerifiedCounter

namespace Spec

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

end Spec

end VerifiedCounter
````

## `lake-manifest.json`

SHA-256 `131c5b15c283f89580ebe302a8dcab091e9b5c6245593078791889897b2f1fe6` · 6 nonblank lines

````text
{"version": "1.2.0",
 "packagesDir": ".lake/packages",
 "packages": [],
 "name": "«verified-counter»",
 "lakeDir": ".lake",
 "fixedToolchain": false}
````

## `lakefile.toml`

SHA-256 `69a7b55c618fa7ba70c3e08c4cda1a3ebce47538feafa214a4a5291007cc3c8e` · 6 nonblank lines

````toml
name = "verified-counter"
version = "0.1.0"
defaultTargets = ["VerifiedCounter"]

[[lean_lib]]
name = "VerifiedCounter"
roots = ["VerifiedCounter"]
````

## `lean-toolchain`

SHA-256 `2bdc48adfa58d0017e538a0ad117c5d73d35deec879978f909406a80c8037273` · 1 nonblank lines

````text
leanprover/lean4:v4.32.2
````
