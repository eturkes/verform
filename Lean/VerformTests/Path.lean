import Verform.Path

namespace VerformTests.Path

private def assert (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def isError : Except α β → Bool
  | .error _ => true
  | .ok _ => false

def tests : IO Unit := do
  assert ((Verform.Path.validateRelative "Demo/Spec.lean" "path").isOk) "relative path"
  assert (isError <| Verform.Path.validateRelative "../Spec.lean" "path") "parent path"
  assert (isError <| Verform.Path.validateRelative "/tmp/Spec.lean" "path") "absolute path"
  assert (isError <| Verform.Path.validateRelative "Demo/*.lean" "path") "glob path"

end VerformTests.Path
