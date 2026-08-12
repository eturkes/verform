import Verform.Model
import Verform.Policy

namespace Verform.AuditSource

open Verform

def leanString (value : String) : String :=
  let rec choose : Nat → String
    | 0 => ""
    | count + 1 => "#" ++ choose count
  let hashes := choose (value.toUTF8.size + 1)
  s!"r{hashes}\"{value}\"{hashes}"

def nameArray (names : Array String) : String :=
  "#[" ++ String.intercalate ", " (names.map ("`" ++ ·)).toList ++ "]"

def trustedHeaders
    (sourceRoot : System.FilePath)
    (analysis : Policy.StaticAnalysis) : String :=
  let calls := analysis.reviewedModules.map fun moduleName =>
    match analysis.modules.find? (·.1 == moduleName) with
    | some item => s!"  auditHeader {leanString (Path.relativeLabel sourceRoot item.2)} localModules trustedModules"
    | none => ""
  r#"import Lean.Parser.Module
import Lean.Elab.Command

open Lean Elab Command

private def auditHeader
    (path : String) (localModules trustedModules : Array Name) : CommandElabM Unit := do
  let input ← IO.FS.readFile path
  let context := Parser.mkInputContext input path
  let (header, _, messages) ← Parser.parseHeader context
  if messages.hasErrors then throwError m!"cannot parse trusted header {path}"
  if let `(Parser.Module.header| $[module%$moduleTk?]? $[prelude]? $importsStx*) := header then
    for importStx in importsStx do
      if let `(Parser.Module.import|
          $[public%$pubTk?]? $[meta%$metaTk?]? import
          $[all%$allTk?]? $moduleName) := importStx then
        let imported := moduleName.getId
        if localModules.contains imported && !trustedModules.contains imported then
          throwError m!"trusted file {path} imports unreviewed local module {imported}"
  else throwError m!"cannot decode trusted header {path}"

run_cmd do
  let localModules := "# ++ nameArray (analysis.modules.map (·.1)) ++ "\n" ++
  "  let trustedModules := " ++ nameArray analysis.reviewedModules ++ "\n" ++
  String.intercalate "\n" calls.toList ++ "\n"

def obligation (value : Obligation) (analysis : Policy.StaticAnalysis) : String :=
  let contractOwner := (Policy.ownerModule value.contract analysis.modules).getD ""
  let implementationOwner := (Policy.ownerModule value.implementation analysis.modules).getD ""
  r#"import Lean.Elab.Command
import Lean.Util.CollectAxioms
import Lean.Compiler.ImplementedByAttr
import Lean.Compiler.ExternAttr
import Lean.Compiler.NoncomputableAttr

open Lean Elab Command

private def originOf? (env : Environment) (name : Name) : Option Name := do
  let index ← env.getModuleIdxFor? name
  env.header.moduleNames[index]?

private def assertOrigin (env : Environment) (name expected : Name) : CommandElabM Unit := do
  let some actual := originOf? env name | throwError m!"missing module origin for {name}"
  unless actual == expected do throwError m!"{name} originates in {actual}, expected {expected}"

private def auditClosure
    (env : Environment) (localModules trusted : Array Name) (trustedOnly : Bool)
    (pending seen : List Name) : CommandElabM Unit := do
  let mut pending := pending
  let mut seen := seen
  for _ in *...100000 do
    let some name := pending.head? | return
    pending := pending.tail!
    if seen.contains name then continue
    seen := name :: seen
    let some origin := originOf? env name | continue
    if !localModules.contains origin then continue
    if trustedOnly && !trusted.contains origin then
      throwError m!"trusted semantics depend on unreviewed local declaration {name} from {origin}"
    let some info := env.find? name | throwError m!"missing local declaration {name}"
    if (Lean.Compiler.getImplementedBy? env name).isSome then
      throwError m!"local declaration {name} has a runtime replacement"
    if Lean.isExtern env name then throwError m!"local declaration {name} has a foreign runtime implementation"
    if !trustedOnly && Lean.isNoncomputable env name then
      throwError m!"local executable dependency {name} is noncomputable"
    match info with
    | .axiomInfo _ => throwError m!"local declaration {name} is an unchecked assumption"
    | .opaqueInfo _ => throwError m!"local declaration {name} is not transparent"
    | .defnInfo data => unless data.safety == .safe do throwError m!"local definition {name} is not total and safe"
    | .inductInfo data => if data.isUnsafe then throwError m!"local inductive {name} is not safe"
    | .ctorInfo data => if data.isUnsafe then throwError m!"local constructor {name} is not safe"
    | .recInfo data => if data.isUnsafe then throwError m!"local recursor {name} is not safe"
    | _ => pure ()
    pending := info.type.foldConsts pending fun dependency queue => dependency :: queue
    pending := match info.value? with
      | some body => body.foldConsts pending fun dependency queue => dependency :: queue
      | none => pending
  throwError "declaration closure exceeded traversal bound"

run_cmd do
  let env ← Lean.importModules #[{ module := `"# ++ value.moduleName ++ " }] {}\n" ++
  "  assertOrigin env `" ++ value.declaration ++ " `" ++ value.moduleName ++ "\n" ++
  "  assertOrigin env `" ++ value.contract ++ " `" ++ contractOwner ++ "\n" ++
  "  assertOrigin env `" ++ value.implementation ++ " `" ++ implementationOwner ++ "\n" ++
  "  let some declaration := env.find? `" ++ value.declaration ++ " | throwError \"missing obligation declaration\"\n" ++
  "  unless declaration.isTheorem do throwError \"obligation declaration is not a theorem\"\n" ++
  "  let some contractInfo := env.find? `" ++ value.contract ++ " | throwError \"missing contract declaration\"\n" ++
  "  unless contractInfo.isDefinition do throwError \"contract root is not a definition\"\n" ++
  "  let some implementationInfo := env.find? `" ++ value.implementation ++ " | throwError \"missing implementation declaration\"\n" ++
  "  unless implementationInfo.isDefinition do throwError \"implementation root is not an executable definition\"\n" ++
  "  match declaration.type.consumeMData with\n" ++
  "  | .app (.const contract _) (.const implementation _) =>\n" ++
  "      unless contract == `" ++ value.contract ++ " && implementation == `" ++ value.implementation ++ " do\n" ++
  "        throwError m!\"wrong contract or implementation root: {repr declaration.type}\"\n" ++
  "  | _ => throwError m!\"not an exact unary contract application: {repr declaration.type}\"\n" ++
  "  let localModules := " ++ nameArray (analysis.modules.map (·.1)) ++ "\n" ++
  "  let trustedModules := " ++ nameArray analysis.reviewedModules ++ "\n" ++
  "  auditClosure env localModules trustedModules true [`" ++ value.contract ++ "] []\n" ++
  "  auditClosure env localModules trustedModules false [`" ++ value.implementation ++ "] []\n" ++
  "  let previous ← getEnv\n  setEnv env\n" ++
  "  let dependencies ← Lean.collectAxioms `" ++ value.declaration ++ "\n  setEnv previous\n" ++
  "  let rendered := Lean.Json.compress <| (dependencies.toList.map toString).toJson\n" ++
  "  logInfo m!\"VERFORM_LOGICAL_DEPS={rendered}\"\n"

def challenge (manifest : Manifest) : String :=
  match manifest.comparator with
  | none => ""
  | some comparator =>
    let theoremChecks := comparator.theoremNames.map fun name =>
      "  assertOrigin env `" ++ name ++ " `" ++ comparator.challengeModule ++ "\n" ++
      "  let some theoremInfo := env.find? `" ++ name ++ " | throwError \"missing challenge theorem\"\n" ++
      "  unless theoremInfo.isTheorem do throwError \"configured theorem is not a theorem\"\n" ++
      "  let theoremReferences := theoremInfo.type.foldConsts #[] fun dependency names => if names.contains dependency then names else names.push dependency\n" ++
      "  unless definitions.any fun definition => theoremReferences.contains definition do throwError \"configured semantic theorem references no configured executable\"\n" ++
      "  referenced := theoremReferences.foldl (init := referenced) fun names dependency => if names.contains dependency then names else names.push dependency"
    let definitionChecks := comparator.definitionNames.map fun name =>
      "  assertOrigin env `" ++ name ++ " `" ++ comparator.challengeModule ++ "\n" ++
      "  let some definitionInfo := env.find? `" ++ name ++ " | throwError \"missing challenge definition\"\n" ++
      "  unless definitionInfo.isDefinition do throwError \"configured executable is not a definition\"\n" ++
      "  unless referenced.contains `" ++ name ++ " do throwError \"configured executable has no theorem reference\""
    r#"import Lean.Elab.Command
open Lean Elab Command
private def originOf? (env : Environment) (name : Name) : Option Name := do
  let index ← env.getModuleIdxFor? name
  env.header.moduleNames[index]?
private def assertOrigin (env : Environment) (name expected : Name) : CommandElabM Unit := do
  let some actual := originOf? env name | throwError m!"missing origin for {name}"
  unless actual == expected do throwError m!"{name} originates in {actual}, expected {expected}"
run_cmd do
  let env ← Lean.importModules #[{ module := `"# ++ comparator.challengeModule ++ " }] {}\n" ++
    "  let definitions := " ++ nameArray comparator.definitionNames ++ "\n" ++
    "  let mut referenced : Array Name := #[]\n" ++
    String.intercalate "\n" theoremChecks.toList ++ "\n" ++
    String.intercalate "\n" definitionChecks.toList ++ "\n"

end Verform.AuditSource
