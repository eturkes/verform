import Verform.Agent.Plan
import Verform.Spec

namespace Verform.Proof

theorem codexInvocation_correct :
    Verform.Spec.Contract Verform.Agent.Plan.codexInvocation := by
  intro workspaceRoot request
  rfl

end Verform.Proof
