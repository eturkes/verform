import VerformTests.Attestation
import VerformTests.Config
import VerformTests.Codex
import VerformTests.Plan
import VerformTests.Path
import VerformTests.Policy
import VerformTests.Runner
import VerformTests.Scaffold
import VerformTests.Sha256

def main : IO UInt32 := do
  try
    VerformTests.Attestation.tests
    VerformTests.Config.tests
    VerformTests.Codex.tests
    VerformTests.Plan.tests
    VerformTests.Path.tests
    VerformTests.Policy.tests
    VerformTests.Runner.tests
    VerformTests.Scaffold.tests
    VerformTests.Sha256.tests
    IO.println "PASS  all Lean tests"
    return 0
  catch error =>
    IO.eprintln s!"FAIL  {error}"
    return 1
