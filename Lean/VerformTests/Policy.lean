import Verform.Policy
import Verform.Runner
import Verform.Scaffold

namespace VerformTests.Policy

private def assert (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def gate (analysis : Verform.Policy.StaticAnalysis) (name : String) : Verform.Gate :=
  analysis.gates.find? (·.name == name) |>.getD {
    name := "missing"
    ok := false
    summary := "missing gate"
  }

def tests : IO Unit := do
  let temporary ← IO.FS.createTempDir
  try
    let target := temporary / "demo"
    let _ ← Verform.Scaffold.create target.toString "demo" (some "Demo") .pure .kernel
    let manifest ← Verform.Config.load target.toString
    let clean ← Verform.Policy.analyze manifest
    assert clean.ok "clean scaffold static policy"
    assert (clean.sources.size == 4) "source inventory"
    let implementation := target / "Demo/Impl.lean"
    let content ← IO.FS.readFile implementation
    IO.FS.writeFile implementation (content ++ "\n" ++ "ax" ++ "iom broken : False\n")
    let changed ← Verform.Policy.analyze manifest
    assert (!(gate changed "source policy").ok) "forbidden source spelling"
    IO.FS.writeFile implementation content
    let manifestPath := target / "verform.toml"
    let manifestText ← IO.FS.readFile manifestPath
    IO.FS.writeFile manifestPath (manifestText.replace "max_code_lines = 80" "max_code_lines = 1")
    let budgetManifest ← Verform.Config.load target.toString
    let budget ← Verform.Policy.analyze budgetManifest
    assert (!(gate budget "review surface").ok) "review budget"
    IO.FS.writeFile manifestPath manifestText
    IO.FS.writeFile (target / "lake-manifest.json") "[]"
    let failed ← try
      let _ ← Verform.Policy.analyze manifest
      pure false
    catch _ => pure true
    assert failed "malformed Lake lock"
  finally
    IO.FS.removeDirAll temporary

end VerformTests.Policy
