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
