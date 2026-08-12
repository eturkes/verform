import Lean.Data.Json
import Verform.Policy
import Verform.Presentation
import Verform.Verifier

namespace Verform.Attestation

open Lean Verform

def lockName := "verform.lock.json"
def policyProfile := "VERFORM-LAKE-CLOSURE-v1"
def recordKind := "unsigned-local-drift-record"
def version := "0.2.0"

private def comparatorJson (manifest : Manifest) : String :=
  match manifest.comparator with
  | none => "null"
  | some comparator => Verform.Json.object #[
      ("challenge_module", Verform.Json.escape comparator.challengeModule),
      ("definition_names", Verform.Json.strings comparator.definitionNames 4),
      ("enable_nanoda", "true"),
      ("permitted_axioms", Verform.Json.strings comparator.permittedAxioms 4),
      ("solution_module", Verform.Json.escape comparator.solutionModule),
      ("theorem_names", Verform.Json.strings comparator.theoremNames 4)
    ] 2

def payload (manifest : Manifest) (report : Report) : Except String String := do
  unless report.ok do throw "cannot attest a failed verification"
  return Verform.Json.object #[
    ("assurance", Verform.Json.escape (toString manifest.lean.assurance)),
    ("comparator", comparatorJson manifest),
    ("format_version", "1"),
    ("gates", Verform.Json.array (report.gates.map (Presentation.gateJson · 4)) 2),
    ("obligations", Verform.Json.array (report.evidence.obligations.map
      (Presentation.obligationEvidenceJson · 4)) 2),
    ("policy_profile", Verform.Json.escape policyProfile),
    ("project", Verform.Json.escape manifest.project.name),
    ("prover", Verform.Json.escape manifest.project.prover),
    ("record_kind", Verform.Json.escape recordKind),
    ("review", Verform.Json.object #[
      ("code_lines", toString report.evidence.reviewCodeLines),
      ("files", Presentation.hashesJson report.evidence.reviewHashes 4),
      ("max_code_lines", toString manifest.review.maxCodeLines)
    ] 2),
    ("toolchain", Verform.Json.escape report.evidence.toolchain),
    ("verform_version", Verform.Json.escape version),
    ("verification_inputs", Presentation.hashesJson report.evidence.inputHashes 2)
  ] ++ "\n"

def outputPath (manifest : Manifest) (requested : String) : IO System.FilePath := do
  let relative := System.FilePath.mk requested
  if requested.isEmpty || relative.isAbsolute || relative.components.contains ".." then
    throw <| IO.userError s!"output path must be project-relative: {requested}"
  let candidate := manifest.root / relative
  let some parentPath := candidate.parent
    | throw <| IO.userError s!"output parent does not exist: {requested}"
  let parent ← try IO.FS.realPath parentPath catch _ =>
    throw <| IO.userError s!"output parent does not exist: {requested}"
  unless Path.isInside manifest.root parent do
    throw <| IO.userError s!"attestation output escapes project root: {requested}"
  if ← Path.isLink candidate then
    throw <| IO.userError s!"attestation output cannot be a symbolic link: {requested}"
  if let some metadata ← Path.metadata? candidate then
    unless metadata.type == .file do
      throw <| IO.userError s!"output destination is not a regular file: {requested}"
    if metadata.numLinks > 1 then
      throw <| IO.userError s!"output destination has multiple filesystem links: {requested}"
  let destination := parent / candidate.fileName.getD ""
  let analysis ← Policy.analyze manifest
  for item in analysis.evidence.inputHashes do
    if destination == manifest.root / item.1 then
      throw <| IO.userError s!"output cannot overwrite verification input: {item.1}"
  return destination

def writeOutput (manifest : Manifest) (requested data : String) : IO System.FilePath := do
  let destination ← outputPath manifest requested
  let nonce ← IO.monoNanosNow
  let temporary := destination.withFileName s!".{destination.fileName.getD "output"}.{nonce}.tmp"
  try
    let handle ← IO.FS.Handle.mk temporary .writeNew
    handle.putStr data
    handle.flush
    IO.FS.rename temporary destination
  finally
    if ← temporary.pathExists then IO.FS.removeFile temporary
  return destination

def attest
    (manifest : Manifest)
    (requested := lockName) : IO (Report × Option System.FilePath) := do
  let report ← Verifier.verify manifest
  unless report.ok do return (report, none)
  let current ← Policy.analyze manifest
  unless current.evidence.inputHashes == report.evidence.inputHashes &&
      current.evidence.reviewHashes == report.evidence.reviewHashes do
    let failed : Report := {report with gates := report.gates.push {
      name := "pre-attestation stability"
      ok := false
      summary := "inputs changed after checks"
    }}
    return (failed, none)
  let data ← match payload manifest report with
    | .ok value => pure value
    | .error message => throw <| IO.userError message
  return (report, some <| ← writeOutput manifest requested data)

private def load (path : System.FilePath) : IO Json := do
  let content ← try IO.FS.readFile path catch _ =>
    throw <| IO.userError s!"attestation not found: {path}"
  let value ← match Json.parse content with
    | .ok result => pure result
    | .error message => throw <| IO.userError s!"cannot read attestation {path}: {message}"
  let format ← match value.getObjVal? "format_version" >>= (·.getNat?) with
    | .ok result => pure result
    | .error _ => throw <| IO.userError s!"unsupported attestation format: {path}"
  unless format == 1 do throw <| IO.userError s!"unsupported attestation format: {path}"
  return value

private def jsonStringField (value : Json) (key : String) : Option String :=
  (value.getObjVal? key >>= (·.getStr?)).toOption

private def hashMap (value : Json) (key : String) : Option (Array (String × String)) := do
  let field ← value.getObjVal? key |>.toOption
  let object ← field.getObj? |>.toOption
  let mut result := #[]
  for (name, raw) in object.toList do
    let digest ← raw.getStr? |>.toOption
    result := result.push (name, digest)
  return result.insertionSort fun left right => left.1 < right.1

def hashDiff
    (locked : Option (Array (String × String)))
    (current : Array (String × String)) : Array String :=
  match locked with
  | none => #["attestation contains an invalid hash map"]
  | some locked => Id.run do
      let mut detail := #[]
      for item in locked do
        match current.find? (·.1 == item.1) with
        | none => detail := detail.push s!"removed: {item.1}"
        | some value => if value.2 != item.2 then detail := detail.push s!"changed: {item.1}"
      for item in current do
        if (locked.find? (·.1 == item.1)).isNone then detail := detail.push s!"added: {item.1}"
      return detail.insertionSort (· < ·)

def status (manifest : Manifest) (requested := lockName) : IO (Array Gate) := do
  let lockPath ← outputPath manifest requested
  let locked ← load lockPath
  let current ← Policy.analyze manifest
  let mut gates := current.gates
  let identityOk :=
    jsonStringField locked "project" == some manifest.project.name &&
    jsonStringField locked "prover" == some manifest.project.prover &&
    jsonStringField locked "assurance" == some (toString manifest.lean.assurance) &&
    jsonStringField locked "verform_version" == some version &&
    jsonStringField locked "record_kind" == some recordKind &&
    jsonStringField locked "policy_profile" == some policyProfile
  gates := gates.push {
    name := "attestation identity"
    ok := identityOk
    summary := if identityOk then
      "project, prover, assurance, verifier version, and policy profile match"
      else "project, prover, assurance, verifier version, or policy profile drifted"
  }
  let review := (locked.getObjVal? "review" >>= (·.getObjVal? "files")).toOption
    |>.bind fun value => hashMap (Json.mkObj [("value", value)]) "value"
  let reviewDetail := hashDiff review current.evidence.reviewHashes
  gates := gates.push {
    name := "review drift"
    ok := reviewDetail.isEmpty
    summary := if reviewDetail.isEmpty then "trusted review surface is unchanged"
      else "trusted review surface differs from attestation"
    detail := reviewDetail
  }
  let inputDetail := hashDiff (hashMap locked "verification_inputs") current.evidence.inputHashes
  gates := gates.push {
    name := "verification drift"
    ok := inputDetail.isEmpty
    summary := if inputDetail.isEmpty then "all verification inputs are unchanged"
      else "verification inputs differ; rerun `verform attest`"
    detail := inputDetail
  }
  return gates

end Verform.Attestation
