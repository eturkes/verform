import Std

namespace Verform.Path

def metadata? (path : System.FilePath) (follow := true) : IO (Option IO.FS.Metadata) := do
  try
    let metadata ← if follow then path.metadata else path.symlinkMetadata
    return some metadata
  catch _ =>
    return none

def pathExists (path : System.FilePath) : IO Bool :=
  return (← metadata? path).isSome

def isDirectory (path : System.FilePath) : IO Bool :=
  return (← metadata? path).any (·.type == .dir)

def isFile (path : System.FilePath) : IO Bool :=
  return (← metadata? path).any (·.type == .file)

def isLink (path : System.FilePath) : IO Bool :=
  return (← metadata? path false).any (·.type == .symlink)

def isInside (root path : System.FilePath) : Bool :=
  root.normalize.components.isPrefixOf path.normalize.components

def canonicalInside
    (root candidate : System.FilePath)
    (context : String) : IO System.FilePath := do
  let resolved ← try IO.FS.realPath candidate catch _ =>
    throw <| IO.userError s!"{context}: path not found: {candidate}"
  unless isInside root resolved do
    throw <| IO.userError s!"{context}: path escapes project root: {candidate}"
  return resolved

def rejectLinkComponents
    (root : System.FilePath)
    (relative : System.FilePath)
    (context : String) : IO Unit := do
  let rec visit (current : System.FilePath) : List String → IO Unit
    | [] => pure ()
    | component :: rest => do
      let next := current / component
      if ← isLink next then
        throw <| IO.userError s!"{context}: symbolic link components are not accepted: {relative}"
      visit next rest
  visit root relative.components

def regularFile
    (root : System.FilePath)
    (relative : String)
    (context : String) : IO System.FilePath := do
  let path := System.FilePath.mk relative
  rejectLinkComponents root path context
  let resolved ← canonicalInside root (root / path) context
  unless ← isFile resolved do
    throw <| IO.userError s!"{context}: expected a regular file: {relative}"
  return resolved

def relativeLabel (root path : System.FilePath) : String :=
  let rootParts := root.normalize.components
  let pathParts := path.normalize.components
  String.intercalate "/" (pathParts.drop rootParts.length)

def resolveManifest (location : String) : IO (System.FilePath × System.FilePath) := do
  let cwd ← IO.currentDir >>= IO.FS.realPath
  let supplied := System.FilePath.mk location
  let candidate := if supplied.isAbsolute then supplied else cwd / supplied
  let target := if ← isDirectory candidate then candidate / "verform.toml" else candidate
  if ← isLink target then
    throw <| IO.userError s!"manifest cannot be a symbolic link: {target}"
  let resolved ← try IO.FS.realPath target catch _ =>
    throw <| IO.userError s!"manifest not found: {target}"
  unless ← isFile resolved do
    throw <| IO.userError s!"manifest is not a file: {resolved}"
  let some parent := resolved.parent
    | throw <| IO.userError s!"manifest has no parent directory: {resolved}"
  return (parent, resolved)

def validateRelative (value context : String) (allowDot := false) : Except String String :=
  let path := System.FilePath.mk value
  if value.isEmpty || path.isAbsolute || (!allowDot && value == ".") then
    .error s!"{context}: must be a project-relative path without '..'"
  else if path.components.contains ".." then
    .error s!"{context}: must be a project-relative path without '..'"
  else if value.any fun character => character == '*' || character == '?' ||
      character == '[' || character == ']' then
    .error s!"{context}: globs are not allowed here"
  else
    .ok value

end Verform.Path
