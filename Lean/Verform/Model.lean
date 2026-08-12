import Std

namespace Verform

inductive Assurance where
  | kernel
  | comparator
  deriving Repr, DecidableEq, BEq

namespace Assurance

def parse : String → Option Assurance
  | "kernel" => some .kernel
  | "comparator" => some .comparator
  | _ => none

protected def toString : Assurance → String
  | .kernel => "kernel"
  | .comparator => "comparator"

instance : ToString Assurance := ⟨Assurance.toString⟩

end Assurance

structure Project where
  name : String
  prover : String := "lean4"
  deriving Repr, BEq

structure Review where
  files : Array String
  maxCodeLines : Nat := 200
  deriving Repr, BEq

structure LeanConfig where
  assurance : Assurance := .kernel
  moduleRoot : System.FilePath := "."
  evidenceFiles : Array String := #[]
  timeoutSeconds : Nat := 600
  deriving Repr, BEq

structure Obligation where
  name : String
  moduleName : String
  declaration : String
  contract : String
  implementation : String
  allowedAxioms : Array String := #[]
  deriving Repr, BEq

def Obligation.statement (value : Obligation) : String :=
  s!"{value.contract} {value.implementation}"

structure Comparator where
  challengeModule : String
  solutionModule : String
  theoremNames : Array String
  definitionNames : Array String
  permittedAxioms : Array String
  deriving Repr, BEq

structure ExtraCheck where
  name : String
  command : Array String
  timeoutSeconds : Nat := 300
  deriving Repr, BEq

structure Manifest where
  root : System.FilePath
  path : System.FilePath
  project : Project
  review : Review
  lean : LeanConfig
  obligations : Array Obligation := #[]
  comparator : Option Comparator := none
  checks : Array ExtraCheck := #[]
  deriving Repr, BEq

structure Gate where
  name : String
  ok : Bool
  summary : String
  detail : Array String := #[]
  deriving Repr, BEq

structure ObligationEvidence where
  name : String
  moduleName : String
  declaration : String
  statement : String
  axioms : Array String := #[]
  deriving Repr, BEq

structure Evidence where
  toolchain : String := ""
  reviewCodeLines : Nat := 0
  reviewHashes : Array (String × String) := #[]
  inputHashes : Array (String × String) := #[]
  obligations : Array ObligationEvidence := #[]
  deriving Repr, BEq

structure Report where
  project : String
  assurance : Assurance
  gates : Array Gate
  evidence : Evidence := {}
  deriving Repr, BEq

def Report.ok (report : Report) : Bool :=
  !report.gates.isEmpty && report.gates.all (·.ok)

namespace Codex

structure Invocation where
  executable : String
  arguments : Array String
  workingDirectory : System.FilePath
  stdinChunks : Array String
  deriving Repr, BEq

def Invocation.command (invocation : Invocation) : Array String :=
  #[invocation.executable] ++ invocation.arguments

def Invocation.stdinText (invocation : Invocation) : String :=
  String.join invocation.stdinChunks.toList

end Codex

end Verform
