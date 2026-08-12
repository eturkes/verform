import Lean.Data.Json
import Verform.Attestation

namespace VerformTests.Attestation

private def assert (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

def tests : IO Unit := do
  let manifest : Verform.Manifest := {
    root := "/tmp/demo"
    path := "/tmp/demo/verform.toml"
    project := {name := "demo"}
    review := {files := #["Spec.lean"]}
    lean := {}
    obligations := #[{
      name := "correct"
      moduleName := "Demo.Proof"
      declaration := "Demo.Proof.correct"
      contract := "Demo.Spec.Contract"
      implementation := "Demo.Impl.run"
    }]
  }
  let report : Verform.Report := {
    project := "demo"
    assurance := .kernel
    gates := #[{name := "proof", ok := true, summary := "passed"}]
    evidence := {
      toolchain := "Lean 4.32.2"
      reviewHashes := #[("Spec.lean", "abc")]
      inputHashes := #[("Spec.lean", "abc")]
    }
  }
  let .ok payload := Verform.Attestation.payload manifest report
    | throw <| IO.userError "attestation payload"
  assert ((Lean.Json.parse payload).isOk) "attestation JSON"
  assert (payload.contains "unsigned-local-drift-record") "record kind"
  assert ((Verform.Attestation.hashDiff (some #[("a", "1")])
    #[("a", "2"), ("b", "3")]).size == 2) "hash diff"

end VerformTests.Attestation
