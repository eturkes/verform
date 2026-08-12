import Verform.Config
import Verform.Scaffold

namespace VerformTests.Scaffold

private def assert (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

def tests : IO Unit := do
  assert (Verform.Scaffold.defaultModule "verified-counter" == "VerifiedCounter") "default module"
  let temporary ← IO.FS.createTempDir
  let target := temporary / "demo"
  try
    let created ← Verform.Scaffold.create target.toString "demo" (some "Demo") .result .kernel
    assert (created == target) "created target"
    let manifest ← Verform.Config.load target.toString
    assert (manifest.project.name == "demo") "scaffold manifest"
    assert (← (target / "Demo/Proof.lean").pathExists) "scaffold proof"
  finally
    IO.FS.removeDirAll temporary

end VerformTests.Scaffold
