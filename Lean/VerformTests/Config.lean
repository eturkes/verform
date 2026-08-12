import Verform.Config

namespace VerformTests.Config

open Lean Lake Lake.Toml

private def assert (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def parseText (content : String) : IO (Except String Verform.Manifest) := do
  match ← (loadToml <| Parser.mkInputContext content "test.toml").toBaseIO with
  | .error _ => return .error "syntax"
  | .ok table => return Verform.Config.parse "/tmp/project" "/tmp/project/verform.toml" table

private def minimal :=
  "manifest_version = 1\n" ++
  "[project]\nname = \"demo\"\n" ++
  "[review]\nfiles = [\"Demo/Spec.lean\", \"lakefile.toml\", " ++
    "\"lean-toolchain\", \"lake-manifest.json\"]\n" ++
  "[lean]\nassurance = \"kernel\"\nmodule_root = \".\"\n" ++
  "[[obligations]]\nname = \"correct\"\nmodule = \"Demo.Proof\"\n" ++
  "declaration = \"Demo.Proof.correct\"\ncontract = \"Demo.Spec.Contract\"\n" ++
  "implementation = \"Demo.Impl.run\"\nallowed_axioms = []\n"

private def isError : Except α β → Bool
  | .error _ => true
  | .ok _ => false

def tests : IO Unit := do
  let parsed ← parseText minimal
  let .ok manifest := parsed | throw <| IO.userError "minimal manifest"
  assert (manifest.project.name == "demo") "project name"
  assert (manifest.obligations.size == 1) "obligation count"
  let some obligation := manifest.obligations[0]? | throw <| IO.userError "missing obligation"
  assert obligation.allowedAxioms.isEmpty "empty logical allowance"
  assert (isError <| ← parseText (minimal.replace "manifest_version = 1"
    "manifest_version = 1\nunknown = true")) "unknown root key"
  assert (isError <| ← parseText (minimal.replace "name = \"demo\"" "name = \"bad name\""))
    "invalid project name"
  assert (isError <| ← parseText (minimal.replace "Demo/Spec.lean" "../Spec.lean"))
    "escaping review path"
  assert (isError <| ← parseText (minimal.replace "allowed_axioms = []"
    "allowed_axioms = [\"sor" ++ "ryAx\"]")) "hard denied logical assumption"

end VerformTests.Config
