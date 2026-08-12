import Lake.Toml
import Verform.Model
import Verform.Path

namespace Verform.Config

open Lean Lake Lake.Toml Verform

def defaultAxioms : Array String :=
  #["Classical.choice", "Quot.sound", "propext"]

def hardDeniedAxioms : Array String :=
  #["Lean.ofReduceBool", "Lean.trustCompiler", "sor" ++ "ryAx"]

private def fail (context message : String) : Except String α :=
  .error s!"{context}: {message}"

private def table (value : Value) (context : String) : Except String Table :=
  match value with
  | .table' _ result => .ok result
  | _ => fail context "expected a table"

private def only (value : Table) (allowed : Array String) (context : String) : Except String Unit := do
  let unknown := value.keys.map (·.toString) |>.filter fun key => !allowed.contains key
  unless unknown.isEmpty do
    fail context s!"unknown key(s): {String.intercalate ", " unknown.toList}"

private def requiredValue (value : Table) (key : String) (context : String) : Except String Value :=
  match value.find? key.toName with
  | some result => .ok result
  | none => fail s!"{context}.{key}" "missing required key"

private def stringValue (value : Value) (context : String) : Except String String :=
  match value with
  | .string _ result =>
      if result.isEmpty then fail context "expected a non-empty string" else .ok result
  | _ => fail context "expected a non-empty string"

private def stringField
    (value : Table)
    (key context : String)
    (default : Option String := none) : Except String String := do
  match value.find? key.toName, default with
  | some raw, _ => stringValue raw s!"{context}.{key}"
  | none, some fallback => .ok fallback
  | none, none => fail s!"{context}.{key}" "missing required key"

private def positiveNat
    (value : Table)
    (key context : String)
    (default : Nat) : Except String Nat := do
  let some raw := value.find? key.toName | return default
  match raw with
  | .integer _ (.ofNat result) =>
      if result > 0 then .ok result else fail s!"{context}.{key}" "expected a positive integer"
  | _ => fail s!"{context}.{key}" "expected a positive integer"

private def stringArrayValue
    (value : Value)
    (context : String)
    (allowEmpty := false) : Except String (Array String) := do
  let .array _ values := value | fail context "expected an array of non-empty strings"
  let mut result := #[]
  for raw in values do
    let item ← stringValue raw context
    if result.contains item then fail context "must not contain duplicates"
    result := result.push item
  if result.isEmpty && !allowEmpty then fail context "must contain at least one item"
  return result

private def stringArray
    (value : Table)
    (key context : String)
    (default : Option (Array String) := none)
    (allowEmpty := false) : Except String (Array String) := do
  match value.find? key.toName, default with
  | some raw, _ => stringArrayValue raw s!"{context}.{key}" allowEmpty
  | none, some fallback => .ok fallback
  | none, none => fail s!"{context}.{key}" "missing required key"

private def asciiLetter (character : Char) : Bool :=
  ('A' ≤ character && character ≤ 'Z') || ('a' ≤ character && character ≤ 'z')

private def asciiDigit (character : Char) : Bool :=
  '0' ≤ character && character ≤ '9'

private def qualified (value context : String) : Except String String := do
  let components := value.splitOn "."
  let valid := components.all fun component =>
    match component.toList with
    | [] => false
    | first :: rest => asciiLetter first && rest.all fun character =>
        asciiLetter character || asciiDigit character || character == '_' || character == '\''
  if valid then .ok value else fail context "expected an ASCII Lean qualified name"

private def projectName (value context : String) : Except String String := do
  match value.toList with
  | [] => fail context "expected letters, digits, '.', '_' or '-'"
  | first :: rest =>
      let allowed character := asciiLetter character || asciiDigit character ||
        character == '.' || character == '_' || character == '-'
      if (asciiLetter first || asciiDigit first) && rest.all allowed then .ok value
      else fail context "expected letters, digits, '.', '_' or '-'"

private def relative (value context : String) (allowDot := false) : Except String String :=
  Verform.Path.validateRelative value context allowDot

private def tableField (value : Table) (key context : String) : Except String Table := do
  table (← requiredValue value key context) key

private def tablesField
    (value : Table)
    (key context : String) : Except String (Array Table) := do
  let some raw := value.find? key.toName | return #[]
  let .array _ items := raw | fail context "expected an array of tables"
  items.mapM fun item => table item context

private def parseObligation (value : Table) (index : Nat) : Except String Obligation := do
  let context := s!"obligations[{index}]"
  only value #["name", "module", "declaration", "contract", "implementation",
    "allowed_axioms"] context
  let name ← projectName (← stringField value "name" context) s!"{context}.name"
  let moduleName ← qualified (← stringField value "module" context) s!"{context}.module"
  let declaration ← qualified (← stringField value "declaration" context) s!"{context}.declaration"
  let contract ← qualified (← stringField value "contract" context) s!"{context}.contract"
  let implementation ← qualified (← stringField value "implementation" context)
    s!"{context}.implementation"
  let allowedAxioms ← stringArray value "allowed_axioms" context (some defaultAxioms) true
  for item in allowedAxioms do
    let _ ← qualified item s!"{context}.allowed_axioms"
    if hardDeniedAxioms.contains item then
      fail s!"{context}.allowed_axioms" s!"cannot permit hard-denied logical assumption: {item}"
  return {name, moduleName, declaration, contract, implementation, allowedAxioms}

private def parseComparator (value : Table) : Except String Comparator := do
  only value #["challenge_module", "solution_module", "theorem_names", "definition_names",
    "permitted_axioms"] "comparator"
  let challengeModule ← qualified (← stringField value "challenge_module" "comparator")
    "comparator.challenge_module"
  let solutionModule ← qualified (← stringField value "solution_module" "comparator")
    "comparator.solution_module"
  let theoremNames ← stringArray value "theorem_names" "comparator"
  let definitionNames ← stringArray value "definition_names" "comparator"
  for item in theoremNames do let _ ← qualified item "comparator.theorem_names"
  for item in definitionNames do let _ ← qualified item "comparator.definition_names"
  let permittedAxioms ← stringArray value "permitted_axioms" "comparator"
    (some defaultAxioms) true
  for item in permittedAxioms do
    let _ ← qualified item "comparator.permitted_axioms"
    if hardDeniedAxioms.contains item then
      fail "comparator.permitted_axioms" s!"cannot permit hard-denied logical assumption: {item}"
  let missing := defaultAxioms.filter fun item => !permittedAxioms.contains item
  unless missing.isEmpty do
    fail "comparator.permitted_axioms"
      s!"mandatory nanoda replay requires the prelude allowance(s): {String.intercalate ", " missing.toList}"
  return {challengeModule, solutionModule, theoremNames, definitionNames, permittedAxioms}

private def parseCheck (value : Table) (index : Nat) : Except String ExtraCheck := do
  let context := s!"checks[{index}]"
  only value #["name", "command", "timeout_seconds"] context
  return {
    name := ← stringField value "name" context
    command := ← stringArray value "command" context
    timeoutSeconds := ← positiveNat value "timeout_seconds" context 300
  }

def parse (root path : System.FilePath) (raw : Table) : Except String Manifest := do
  only raw #["manifest_version", "project", "review", "lean", "obligations", "comparator",
    "checks"] "manifest"
  match raw.find? `manifest_version with
  | some (.integer _ (.ofNat 1)) => pure ()
  | _ => fail "manifest.manifest_version" "expected 1"

  let projectRaw ← tableField raw "project" "project"
  only projectRaw #["name", "prover"] "project"
  let project : Project := {
    name := ← projectName (← stringField projectRaw "name" "project") "project.name"
    prover := ← stringField projectRaw "prover" "project" (some "lean4")
  }
  unless project.prover == "lean4" do fail "project.prover" "only 'lean4' is supported"

  let reviewRaw ← tableField raw "review" "review"
  only reviewRaw #["files", "max_code_lines"] "review"
  let reviewFiles ← stringArray reviewRaw "files" "review"
  for index in *...reviewFiles.size do
    let _ ← relative reviewFiles[index]! s!"review.files[{index}]"
  let review : Review := {
    files := reviewFiles
    maxCodeLines := ← positiveNat reviewRaw "max_code_lines" "review" 200
  }

  let leanRaw ← tableField raw "lean" "lean"
  only leanRaw #["assurance", "module_root", "evidence_files", "timeout_seconds"] "lean"
  let assuranceName ← stringField leanRaw "assurance" "lean" (some "kernel")
  let some assurance := Assurance.parse assuranceName
    | fail "lean.assurance" "expected 'kernel' or 'comparator'"
  let moduleRoot ← stringField leanRaw "module_root" "lean" (some ".")
  if moduleRoot != "." then let _ ← relative moduleRoot "lean.module_root"
  let evidenceFiles ← stringArray leanRaw "evidence_files" "lean" (some #[]) true
  for index in *...evidenceFiles.size do
    let _ ← relative evidenceFiles[index]! s!"lean.evidence_files[{index}]"
  let lean : LeanConfig := {
    assurance
    moduleRoot
    evidenceFiles
    timeoutSeconds := ← positiveNat leanRaw "timeout_seconds" "lean" 600
  }

  let obligationTables ← tablesField raw "obligations" "obligations"
  let obligations ← obligationTables.mapIdxM fun index value => parseObligation value index
  let obligationNames := obligations.map (·.name)
  unless obligationNames.toList.eraseDups.length == obligationNames.size do
    fail "obligations" "names must be unique"

  let comparator ← match raw.find? `comparator with
    | none => .ok none
    | some value => some <$> (table value "comparator" >>= parseComparator)
  let checkTables ← tablesField raw "checks" "checks"
  let checks ← checkTables.mapIdxM fun index value => parseCheck value index
  let checkNames := checks.map (·.name)
  unless checkNames.toList.eraseDups.length == checkNames.size do fail "checks" "names must be unique"

  match assurance with
  | .kernel =>
      if obligations.isEmpty then fail "obligations" "kernel assurance requires at least one obligation"
      if comparator.isSome then fail "comparator" "allowed only when lean.assurance = 'comparator'"
  | .comparator =>
      if comparator.isNone then fail "comparator" "required when lean.assurance = 'comparator'"
      if !obligations.isEmpty then fail "obligations" "use comparator.theorem_names in comparator assurance mode"
      if !checks.isEmpty then
        fail "checks" "comparator assurance forbids unsandboxed supplementary commands"
  return {root, path, project, review, lean, obligations, comparator, checks}

def load (location := ".") : IO Manifest := do
  let (root, path) ← Verform.Path.resolveManifest location
  let content ← IO.FS.readFile path
  let parsed ← (loadToml <| Parser.mkInputContext content path.toString).toBaseIO
  let table ← match parsed with
    | .ok result => pure result
    | .error messages =>
        let details ← messages.toList.mapM (·.toString)
        throw <| IO.userError s!"cannot read {path}: {String.intercalate "; " details}"
  match parse root path table with
  | .ok manifest => return manifest
  | .error message => throw <| IO.userError message

end Verform.Config
