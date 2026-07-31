import VerifiedCounter.Impl

/-! AI-owned proof connecting the exact executable root to the reviewed contract. -/

namespace VerifiedCounter.Proof

theorem implementation_correct : VerifiedCounter.Spec.Contract VerifiedCounter.Impl.run := by
  constructor
  · intro input output hrun
    unfold VerifiedCounter.Impl.run at hrun
    split at hrun
    · cases hrun
      rfl
    · contradiction
  constructor
  · intro input hpre
    exact ⟨input + 1, if_pos hpre⟩
  constructor
  · intro input error hrun
    unfold VerifiedCounter.Impl.run at hrun
    split at hrun
    · contradiction
    · rename_i hpre
      cases hrun
      exact ⟨rfl, hpre⟩
  · intro input hpre
    exact ⟨VerifiedCounter.Spec.Error.rejected, if_neg hpre⟩

end VerifiedCounter.Proof
