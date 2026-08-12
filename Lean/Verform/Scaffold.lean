import Verform.Model
import Verform.Path

namespace Verform.Scaffold

open Verform

inductive Shape where
  | pure
  | result
  | machine
  deriving Repr, BEq, DecidableEq

namespace Shape

def parse : String → Option Shape
  | "pure" => some .pure
  | "result" => some .result
  | "machine" => some .machine
  | _ => none

protected def toString : Shape → String
  | .pure => "pure"
  | .result => "result"
  | .machine => "machine"

instance : ToString Shape := ⟨Shape.toString⟩

end Shape

private def asciiLetter (character : Char) : Bool :=
  ('A' ≤ character && character ≤ 'Z') || ('a' ≤ character && character ≤ 'z')

private def asciiDigit (character : Char) : Bool :=
  '0' ≤ character && character ≤ '9'

private def capitalize (value : String) : String :=
  match value.toList with
  | [] => ""
  | first :: rest => String.ofList (first.toUpper :: rest)

def defaultModule (name : String) : String :=
  let words := name.toList.foldl (init := ([""] : List String)) fun values character =>
    if asciiLetter character || asciiDigit character then
      match values with
      | current :: rest => (current.push character) :: rest
      | [] => [String.singleton character]
    else "" :: values
  let candidate := String.join <| words.reverse.filter (!·.isEmpty) |>.map capitalize
  match candidate.toList with
  | first :: _ => if asciiLetter first then candidate else "Verified" ++ candidate
  | [] => "Verified"

private def validProject (name : String) : Bool :=
  match name.toList with
  | [] => false
  | first :: rest =>
      (asciiLetter first || asciiDigit first) && rest.all fun character =>
        asciiLetter character || asciiDigit character || character == '.' ||
        character == '_' || character == '-'

private def validModule (name : String) : Bool :=
  name.splitOn "." |>.all fun component => match component.toList with
    | [] => false
    | first :: rest =>
        ('A' ≤ first && first ≤ 'Z') && rest.all fun character =>
          asciiLetter character || asciiDigit character

private def specBody (shape : Shape) : String :=
  match shape with
  | .pure => r#"namespace Spec

abbrev Program := Nat → Nat

/-- The entire human-reviewed behavioral contract. -/
def Contract (program : Program) : Prop :=
  ∀ input, program input = input + 1

/-- Formal non-vacuity witness: the contract is satisfiable. -/
theorem contract_inhabited : ∃ program, Contract program := by
  exact ⟨fun input => input + 1, by intro input; rfl⟩

end Spec"#
  | .result => r#"namespace Spec

inductive Error where
  | rejected
  deriving DecidableEq, Repr

abbrev Program := Nat → Except Error Nat

abbrev Pre (input : Nat) : Prop := input ≤ 100
def Post (input output : Nat) : Prop := output = input + 1
def ErrorAllowed (input : Nat) (error : Error) : Prop :=
  error = .rejected ∧ ¬ Pre input

/-- Success/error soundness + completeness; an always-error program cannot pass. -/
def Contract (program : Program) : Prop :=
  (∀ input output, program input = .ok output → Post input output) ∧
  (∀ input, Pre input → ∃ output, program input = .ok output) ∧
  (∀ input error, program input = .error error → ErrorAllowed input error) ∧
  (∀ input, ¬ Pre input → ∃ error, program input = .error error)

end Spec"#
  | .machine => r#"namespace Spec

inductive State where
  | idle
  | armed
  deriving DecidableEq, Repr

inductive Command where
  | toggle
  | reset
  deriving DecidableEq, Repr

def next : State → Command → State
  | .idle, .toggle => .armed
  | .armed, .toggle => .idle
  | _, .reset => .idle

abbrev Program := State → Command → State

/-- One-step refinement; induction lifts equality to every finite command trace. -/
def Contract (step : Program) : Prop :=
  ∀ state command, step state command = next state command

/-- The reference transition proves the contract is satisfiable. -/
theorem contract_inhabited : Contract next := by
  intro state command
  rfl

end Spec"#

private def spec (moduleName : String) (shape : Shape) : String :=
  "/-!\nHuman-reviewed semantics. Keep this module independent of implementation/proof code.\n-/\n\n" ++
  s!"namespace {moduleName}\n\n" ++ specBody shape ++ s!"\n\nend {moduleName}\n"

private def definition : Shape → String
  | .pure => "def run : Spec.Program := fun input => input + 1"
  | .result => "def run : Spec.Program := fun input =>\n  if Spec.Pre input then .ok (input + 1) else .error .rejected"
  | .machine => "def step : Spec.Program\n  | .idle, .toggle => .armed\n  | .armed, .toggle => .idle\n  | _, .reset => .idle"

private def implementation (moduleName : String) (shape : Shape) : String :=
  s!"import {moduleName}.Spec\n\n/-! AI-owned executable implementation. -/\n\n" ++
  s!"namespace {moduleName}\nnamespace Impl\n\n{definition shape}\n\nend Impl\nend {moduleName}\n"

private def resultProof (root : String) : String :=
  "by\n  constructor\n  · intro input output hrun\n    unfold " ++ root ++ " at hrun\n" ++
  "    split at hrun\n    · cases hrun\n      rfl\n    · contradiction\n  constructor\n" ++
  "  · intro input hpre\n    exact ⟨input + 1, if_pos hpre⟩\n  constructor\n" ++
  "  · intro input error hrun\n    unfold " ++ root ++ " at hrun\n    split at hrun\n" ++
  "    · contradiction\n    · rename_i hpre\n      cases hrun\n      exact ⟨rfl, hpre⟩\n" ++
  "  · intro input hpre\n    exact ⟨Spec.Error.rejected, if_neg hpre⟩"

private def proofText (shape : Shape) (root := "Impl.run") : String :=
  match shape with
  | .result => resultProof root
  | .machine => "by\n  intro state command\n  rfl"
  | .pure => "by\n  intro input\n  rfl"

private def proof (moduleName : String) (shape : Shape) : String :=
  let root := if shape == .machine then "step" else "run"
  s!"import {moduleName}.Impl\n\n/-! AI-owned exact executable proof. -/\n\n" ++
  s!"namespace {moduleName}.Proof\n\ntheorem implementation_correct : " ++
  s!"{moduleName}.Spec.Contract {moduleName}.Impl.{root} := {proofText shape}\n\n" ++
  s!"end {moduleName}.Proof\n"

private def manifest (name moduleName : String) (assurance : Assurance) (shape : Shape) : String :=
  let moduleDirectory := String.intercalate "/" (moduleName.splitOn ".")
  let root := if shape == .machine then "step" else "run"
  let base := s!"manifest_version = 1\n\n[project]\nname = \"{name}\"\nprover = \"lean4\"\n\n"
  match assurance with
  | .kernel => base ++
      s!"[review]\nfiles = [\"{moduleDirectory}/Spec.lean\", \"lakefile.toml\", \"lean-toolchain\", \"lake-manifest.json\"]\nmax_code_lines = 80\n\n" ++
      "[lean]\nassurance = \"kernel\"\nmodule_root = \".\"\nevidence_files = [\"lean-toolchain\", \"lakefile.toml\"]\ntimeout_seconds = 600\n\n" ++
      s!"[[obligations]]\nname = \"implementation-correct\"\nmodule = \"{moduleName}.Proof\"\n" ++
      s!"declaration = \"{moduleName}.Proof.implementation_correct\"\ncontract = \"{moduleName}.Spec.Contract\"\n" ++
      s!"implementation = \"{moduleName}.Impl.{root}\"\nallowed_axioms = []\n"
  | .comparator => base ++
      s!"[review]\nfiles = [\n  \"{moduleDirectory}/Spec.lean\",\n  \"{moduleDirectory}/Challenge.lean\",\n  \"lakefile.toml\",\n  \"lean-toolchain\",\n  \"lake-manifest.json\",\n]\nmax_code_lines = 100\n\n" ++
      "[lean]\nassurance = \"comparator\"\nmodule_root = \".\"\nevidence_files = [\"lean-toolchain\", \"lakefile.toml\"]\ntimeout_seconds = 1200\n\n" ++
      s!"[comparator]\nchallenge_module = \"{moduleName}.Challenge\"\nsolution_module = \"{moduleName}.Solution\"\n" ++
      s!"theorem_names = [\"{moduleName}.implementation_correct\"]\ndefinition_names = [\"{moduleName}.{root}\"]\n" ++
      "permitted_axioms = [\"Classical.choice\", \"Quot.sound\", \"propext\"]\n"

private def comparatorModules (moduleName : String) (shape : Shape) : String × String :=
  let root := if shape == .machine then "step" else "run"
  let hole := "sor" ++ "ry"
  let challenge := s!"import {moduleName}.Spec\n\n/-! Trusted challenge holes. -/\n\n" ++
    s!"namespace {moduleName}\n\ndef {root} : Spec.Program := by {hole}\n\n" ++
    s!"theorem implementation_correct : Spec.Contract {root} := by {hole}\n\nend {moduleName}\n"
  let solution := s!"import {moduleName}.Spec\n\n/-! AI-owned Comparator solution. -/\n\n" ++
    s!"namespace {moduleName}\n\n{definition shape}\n\n" ++
    s!"theorem implementation_correct : Spec.Contract {root} := {proofText shape root}\n\nend {moduleName}\n"
  (challenge, solution)

private def readme (name moduleName : String) (shape : Shape) (assurance : Assurance) : String :=
  let modulePath := String.intercalate "/" (moduleName.splitOn ".")
  s!"# {name}\n\nLean {shape} kernel generated by Verform with `{assurance}` assurance.\n\n" ++
  "## Workflow\n\n" ++
  s!"1. Edit and review `{modulePath}/Spec.lean`" ++
  (if assurance == .comparator then s!" and `{modulePath}/Challenge.lean" else "") ++ ".\n" ++
  "2. Keep implementation/proof work outside the trusted review surface.\n" ++
  "3. Run `verform review .`, then `verform check .`.\n" ++
  "4. Run `verform attest .` and commit `verform.lock.json`.\n" ++
  "5. Use `verform status .` for a prover-free drift check.\n\n" ++
  "The formal claim covers the pure Lean kernel only. IO, foreign code, resources, and native artifacts require separate validation.\n"

def create
    (destination name : String)
    (moduleName : Option String := none)
    (shape : Shape := .pure)
    (assurance : Assurance := .kernel) : IO System.FilePath := do
  unless validProject name do
    throw <| IO.userError "project name must use letters, digits, '.', '_' or '-'"
  let moduleName := moduleName.getD (defaultModule name)
  unless validModule moduleName do
    throw <| IO.userError "module must be dot-separated ASCII names beginning with capitals"
  let cwd ← IO.currentDir >>= IO.FS.realPath
  let supplied := System.FilePath.mk destination
  let target := if supplied.isAbsolute then supplied.normalize else (cwd / supplied).normalize
  if ← target.pathExists then
    unless ← Path.isDirectory target do throw <| IO.userError s!"destination is not a directory: {target}"
    unless (← target.readDir).isEmpty do throw <| IO.userError s!"destination is not empty: {target}"
  let some parent := target.parent | throw <| IO.userError s!"destination has no parent: {target}"
  IO.FS.createDirAll parent
  let nonce ← IO.monoNanosNow
  let staging := parent / s!".{target.fileName.getD "project"}.verform-init-{nonce}"
  let modulePath := String.intercalate "/" (moduleName.splitOn ".")
  let library := (moduleName.splitOn ".").head?.getD moduleName
  let mut files : Array (String × String) := #[
    ("lean-toolchain", "leanprover/lean4:v4.32.2\n"),
    ("lakefile.toml", s!"name = \"{name}\"\nversion = \"0.1.0\"\ndefaultTargets = [\"{library}\"]\n\n[[lean_lib]]\nname = \"{library}\"\nroots = [\"{moduleName}\"]\n"),
    ("lake-manifest.json", "{\n  \"version\": \"1.2.0\",\n  \"fixedToolchain\": false,\n" ++
      s!"  \"name\": \"«{name}»\",\n  \"lakeDir\": \".lake\",\n  \"packagesDir\": \".lake/packages\",\n  \"packages\": []" ++ "\n}\n"),
    ("verform.toml", manifest name moduleName assurance shape),
    (s!"{modulePath}/Spec.lean", spec moduleName shape),
    (modulePath ++ ".lean", if assurance == .kernel then s!"import {moduleName}.Proof\n" else s!"import {moduleName}.Spec\n"),
    (".gitignore", ".lake/\n"),
    ("README.md", readme name moduleName shape assurance)
  ]
  if assurance == .kernel then
    files := files.push (s!"{modulePath}/Impl.lean", implementation moduleName shape)
    files := files.push (s!"{modulePath}/Proof.lean", proof moduleName shape)
  else
    let (challenge, solution) := comparatorModules moduleName shape
    files := files.push (s!"{modulePath}/Challenge.lean", challenge)
    files := files.push (s!"{modulePath}/Solution.lean", solution)
  try
    for (relative, content) in files do
      let path := staging / relative
      if let some directory := path.parent then IO.FS.createDirAll directory
      IO.FS.writeFile path content
    IO.FS.rename staging target
  finally
    if ← staging.pathExists then IO.FS.removeDirAll staging
  return target

end Verform.Scaffold
