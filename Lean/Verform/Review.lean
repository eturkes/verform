import Verform.Policy
import Verform.Runner

namespace Verform.Review

open Verform

private def hashFor (hashes : Array (String × String)) (label : String) : Option String :=
  hashes.find? (·.1 == label) |>.map (·.2)

private def readBound (path : System.FilePath) (digest : String) : IO String := do
  let data ← IO.FS.readBinFile path
  unless Sha256.hash data == digest do
    throw <| IO.userError s!"review input changed while rendering: {path}"
  let some content := String.fromUTF8? data
    | throw <| IO.userError s!"review input is not UTF-8 text: {path}"
  return content

private def longestTicks (content : String) : Nat :=
  let result := content.toList.foldl (init := (0, 0)) fun state character =>
    if character == '`' then (state.1 + 1, max state.2 (state.1 + 1)) else (0, state.2)
  result.2

private def fence (content : String) : String :=
  String.ofList <| List.replicate (max 4 (longestTicks content + 1)) '`'

private def language (path : System.FilePath) : String :=
  if path.extension == some "lean" then "lean"
  else if path.extension == some "toml" then "toml"
  else "text"

def packet (manifest : Manifest) : IO String := do
  let analysis ← Policy.analyze manifest
  let structuralFailures := analysis.gates.filter fun gate =>
    gate.name != "source policy" && !gate.ok
  unless structuralFailures.isEmpty do
    let summary := structuralFailures.map fun gate => s!"{gate.name}: {gate.summary}"
    throw <| IO.userError s!"cannot render a complete review packet: {String.intercalate "; " summary.toList}"
  let manifestLabel := Path.relativeLabel manifest.root manifest.path
  let some manifestDigest := hashFor analysis.evidence.reviewHashes manifestLabel
    | throw <| IO.userError "manifest digest missing from review evidence"
  let manifestContent := (← readBound manifest.path manifestDigest).trimAsciiEnd.toString
  let manifestFence := fence manifestContent
  let mut lines := #[
    s!"# Verform review — {manifest.project.name}", "",
    s!"- Assurance: `{manifest.lean.assurance}`",
    s!"- Trusted Lean surface: {analysis.evidence.reviewCodeLines}/{manifest.review.maxCodeLines} nonblank lines",
    "- Review the manifest and every trusted file below; generated proofs are deliberately absent.",
    "", "## Declared obligations", ""
  ]
  if !manifest.obligations.isEmpty then
    for obligation in manifest.obligations do
      let allowances := if obligation.allowedAxioms.isEmpty then "(none)"
        else String.intercalate ", " obligation.allowedAxioms.toList
      lines := lines.push s!"- `{obligation.name}`: `{obligation.declaration}` proves `{obligation.statement}`; allowed logical assumptions = `{allowances}`"
  else if let some comparator := manifest.comparator then
    lines := lines ++ #[
      s!"- Challenge: `{comparator.challengeModule}`",
      s!"- Solution: `{comparator.solutionModule}`",
      s!"- Theorems: `{String.intercalate ", " comparator.theoremNames.toList}`",
      s!"- Definitions: `{String.intercalate ", " comparator.definitionNames.toList}`",
      s!"- Permitted logical assumptions: `{String.intercalate ", " comparator.permittedAxioms.toList}`",
      "- Independent nanoda replay: `required`"
    ]
  lines := lines ++ #[
    "", "## Manifest", "", s!"SHA-256 `{manifestDigest}`", "",
    manifestFence ++ "toml", manifestContent, manifestFence
  ]
  if let some sourceGate := analysis.gates.find? (·.name == "source policy") then
    if !sourceGate.ok then
      lines := lines ++ #["", "## Full-tree source-policy failures", "",
        "The trusted packet remains reviewable while implementation/proof work is incomplete.",
        "Final verification still requires every item below to be fixed.", ""]
      for item in sourceGate.detail do lines := lines.push s!"- {item}"
  for (label, digest) in analysis.evidence.reviewHashes do
    if label == manifestLabel then continue
    let path := manifest.root / label
    let content ← readBound path digest
    let codeLines := content.splitOn "\n" |>.foldl (init := 0) fun count line =>
      if line.trimAscii.isEmpty then count else count + 1
    let marker := fence content
    lines := lines ++ #["", s!"## `{label}`", "", s!"SHA-256 `{digest}` · {codeLines} nonblank lines",
      "", marker ++ language path, content.trimAsciiEnd.toString, marker]
  return Runner.plainText (String.intercalate "\n" lines.toList ++ "\n")

end Verform.Review
