import Verform.Model
import Verform.Json
import Verform.Runner

namespace Verform.Presentation

open Verform

def gatesText
    (title : String)
    (gates : Array Gate)
    (successLabel := "ACCEPTED") : String :=
  let rendered := gates.foldl (init := #[Runner.plainText title]) fun lines gate =>
    let mark := if gate.ok then "PASS" else "FAIL"
    let lines := lines.push s!"{mark}  {Runner.plainText gate.name} — {Runner.plainText gate.summary}"
    gate.detail.foldl (init := lines) fun current item =>
      current.push s!"      {Runner.plainText item}"
  let passed := gates.foldl (init := 0) fun count gate => if gate.ok then count + 1 else count
  let outcome := if !gates.isEmpty && passed == gates.size then successLabel else "REJECTED"
  String.intercalate "\n" (rendered.push s!"{outcome}  {passed}/{gates.size} gates passed").toList ++ "\n"

def reportText (report : Report) : String :=
  gatesText s!"Verform — {report.project} [{report.assurance}]" report.gates
    s!"ACCEPTED[{report.assurance}]"

def gateJson (gate : Gate) (indent := 0) : String :=
  Verform.Json.object #[
    ("detail", Verform.Json.strings gate.detail (indent + 2)),
    ("name", Verform.Json.escape gate.name),
    ("ok", Verform.Json.bool gate.ok),
    ("summary", Verform.Json.escape gate.summary)
  ] indent

def hashesJson (hashes : Array (String × String)) (indent := 0) : String :=
  Verform.Json.object (hashes.insertionSort (fun left right => left.1 < right.1) |>.map fun item =>
    (item.1, Verform.Json.escape item.2)) indent

def obligationEvidenceJson (item : ObligationEvidence) (indent := 0) : String :=
  Verform.Json.object #[
    ("axioms", Verform.Json.strings item.axioms (indent + 2)),
    ("declaration", Verform.Json.escape item.declaration),
    ("module", Verform.Json.escape item.moduleName),
    ("name", Verform.Json.escape item.name),
    ("statement", Verform.Json.escape item.statement)
  ] indent

def reportJsonWith (report : Report) (extra : Array (String × String)) : String :=
  Verform.Json.object (#[
    ("assurance", Verform.Json.escape (toString report.assurance)),
    ("evidence", Verform.Json.object #[
      ("input_hashes", hashesJson report.evidence.inputHashes 4),
      ("obligations", Verform.Json.array (report.evidence.obligations.map
        (obligationEvidenceJson · 6)) 4),
      ("review_code_lines", Verform.Json.nat report.evidence.reviewCodeLines),
      ("review_hashes", hashesJson report.evidence.reviewHashes 4),
      ("toolchain", Verform.Json.escape report.evidence.toolchain)
    ] 2),
    ("gates", Verform.Json.array (report.gates.map (gateJson · 4)) 2),
    ("ok", Verform.Json.bool report.ok),
    ("project", Verform.Json.escape report.project)
  ] ++ extra) ++ "\n"

def reportJson (report : Report) : String := reportJsonWith report #[]

end Verform.Presentation
