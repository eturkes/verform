import VerifiedCounter.Spec

/-! AI-owned executable implementation. Human review is unnecessary for the formal claim. -/

namespace VerifiedCounter
namespace Impl

def run : Spec.Program := fun input =>
  if Spec.Pre input then .ok (input + 1) else .error .rejected

end Impl
end VerifiedCounter
