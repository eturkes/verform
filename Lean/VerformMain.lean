import Verform

namespace Verform.CLI

open Verform

private def help := "" ++
  "Verform 0.2.0 — Lean-native formal synthesis\n\n" ++
  "Usage:\n" ++
  "  verform '<natural-language request>'\n" ++
  "  verform synth [--path DIR] '<natural-language request>'\n" ++
  "  verform review [PATH] [--output FILE]\n" ++
  "  verform check [PATH] [--json]\n" ++
  "  verform attest [PATH] [--output FILE] [--json]\n" ++
  "  verform status [PATH] [--lock FILE] [--json]\n" ++
  "  verform init PATH --name NAME [--module MODULE] [--shape pure|result|machine]\n" ++
  "                   [--assurance kernel|comparator]\n\n" ++
  "Natural-language synthesis uses authenticated ChatGPT Codex with gpt-5.6-sol/max and returns " ++
  "an independently unchecked candidate. Review its contract, then invoke `verform check`; " ++
  "the formal theorem does not decide whether that contract captures the prompt.\n"

private def takeFlag (flag : String) : List String → Bool × List String
  | [] => (false, [])
  | item :: rest =>
      if item == flag then
        let (_, remaining) := takeFlag flag rest
        (true, remaining)
      else
        let (found, remaining) := takeFlag flag rest
        (found, item :: remaining)

private def takeOption
    (flag : String) : List String → Except String (Option String × List String)
  | [] => .ok (none, [])
  | item :: rest =>
      if item == flag then
        match rest with
        | [] => .error s!"{flag} requires a value"
        | value :: tail => do
            if value.startsWith "-" then throw s!"{flag} requires a value"
            let (duplicate, remaining) ← takeOption flag tail
            if duplicate.isSome then throw s!"{flag} may be supplied only once"
            return (some value, remaining)
      else do
        let (found, remaining) ← takeOption flag rest
        return (found, item :: remaining)

private def location (values : List String) : Except String String :=
  match values with
  | [] => .ok "."
  | [value] => if value.startsWith "-" then .error s!"unknown option: {value}" else .ok value
  | _ => .error "expected at most one project path"

private def liftExcept : Except String α → IO α
  | .ok value => pure value
  | .error message => throw <| IO.userError message

private def gatesJson (project : String) (gates : Array Gate) : String :=
  let ok := !gates.isEmpty && gates.all (·.ok)
  Verform.Json.object #[
    ("gates", Verform.Json.array (gates.map (Presentation.gateJson · 4)) 2),
    ("ok", Verform.Json.bool ok),
    ("project", Verform.Json.escape project)
  ] ++ "\n"

private def check (arguments : List String) : IO UInt32 := do
  let (asJson, rest) := takeFlag "--json" arguments
  let manifest ← Config.load (← liftExcept <| location rest)
  let report ← Verifier.verify manifest
  IO.print <| if asJson then Presentation.reportJson report else Presentation.reportText report
  return if report.ok then 0 else 1

private def review (arguments : List String) : IO UInt32 := do
  let (output, rest) ← match takeOption "--output" arguments with
    | .ok value => pure value
    | .error message => throw <| IO.userError message
  let manifest ← Config.load (← liftExcept <| location rest)
  let rendered ← Review.packet manifest
  match output with
  | none => IO.print rendered
  | some requested =>
      let destination ← Attestation.writeOutput manifest requested rendered
      IO.println s!"WROTE {Path.relativeLabel manifest.root destination}"
  return 0

private def attest (arguments : List String) : IO UInt32 := do
  let (asJson, afterJson) := takeFlag "--json" arguments
  let (output, rest) ← match takeOption "--output" afterJson with
    | .ok value => pure value
    | .error message => throw <| IO.userError message
  let manifest ← Config.load (← liftExcept <| location rest)
  let (report, destination) ← Attestation.attest manifest (output.getD Attestation.lockName)
  if asJson then
    let pathJson := match destination with
      | none => "null"
      | some path => Verform.Json.escape (Path.relativeLabel manifest.root path)
    IO.print <| Presentation.reportJsonWith report #[ ("attestation", pathJson) ]
  else IO.print <| Presentation.reportText report
  match destination with
  | none => return 1
  | some path =>
      if !asJson then IO.println s!"ATTESTED {Path.relativeLabel manifest.root path}"
      return 0

private def status (arguments : List String) : IO UInt32 := do
  let (asJson, afterJson) := takeFlag "--json" arguments
  let (lock, rest) ← match takeOption "--lock" afterJson with
    | .ok value => pure value
    | .error message => throw <| IO.userError message
  let manifest ← Config.load (← liftExcept <| location rest)
  let gates ← Attestation.status manifest (lock.getD Attestation.lockName)
  let ok := !gates.isEmpty && gates.all (·.ok)
  if asJson then IO.print <| gatesJson manifest.project.name gates
  else IO.print <| Presentation.gatesText s!"Verform status — {manifest.project.name}" gates "CURRENT"
  return if ok then 0 else 1

private def initializeProject (arguments : List String) : IO UInt32 := do
  let (name, afterName) ← match takeOption "--name" arguments with
    | .ok value => pure value
    | .error message => throw <| IO.userError message
  let some name := name | throw <| IO.userError "--name is required"
  let (moduleName, afterModule) ← match takeOption "--module" afterName with
    | .ok value => pure value
    | .error message => throw <| IO.userError message
  let (shapeName, afterShape) ← match takeOption "--shape" afterModule with
    | .ok value => pure value
    | .error message => throw <| IO.userError message
  let (assuranceName, rest) ← match takeOption "--assurance" afterShape with
    | .ok value => pure value
    | .error message => throw <| IO.userError message
  let destination ← match rest with
    | [value] => pure value
    | _ => throw <| IO.userError "init requires exactly one destination"
  let some shape := Scaffold.Shape.parse (shapeName.getD "pure")
    | throw <| IO.userError "shape must be pure, result, or machine"
  let some assurance := Assurance.parse (assuranceName.getD "kernel")
    | throw <| IO.userError "assurance must be kernel or comparator"
  let created ← Scaffold.create destination name moduleName shape assurance
  IO.println s!"CREATED {created}"
  return 0

private def synthesize (arguments : List String) : IO UInt32 := do
  let (path, requestParts) ← match takeOption "--path" arguments with
    | .ok value => pure value
    | .error message => throw <| IO.userError message
  let request := String.intercalate " " requestParts
  if request.trimAscii.isEmpty then throw <| IO.userError "natural-language request cannot be empty"
  let workspace := System.FilePath.mk (path.getD ".")
  IO.println "RUN  Codex synthesis [gpt-5.6-sol/max via ChatGPT]"
  let outcome ← Agent.Codex.run workspace request
  IO.println s!"DONE Codex synthesis ({outcome.eventCount} events)"
  IO.println (Runner.plainText outcome.response)
  let root ← IO.FS.realPath workspace
  let manifest ← Config.load workspace.toString
  unless manifest.root == root do
    throw <| IO.userError "generated manifest root differs from the synthesis workspace"
  IO.println "\nUNVERIFIED CANDIDATE — Codex may have tried gates inside its sandbox; Verform has not independently checked it."
  IO.println (Runner.plainText s!"Review it first: verform review {manifest.root}")
  IO.println (Runner.plainText s!"After semantic acceptance, run: verform check {manifest.root}")
  IO.println "Claim limit: no formal result exists until explicit review and check."
  return 0

def run : List String → IO UInt32
  | [] => IO.print help *> pure 0
  | ["--help"] | ["-h"] => IO.print help *> pure 0
  | ["--version"] => IO.println "verform 0.2.0" *> pure 0
  | ["check", "--help"] | ["check", "-h"] => IO.print help *> pure 0
  | ["review", "--help"] | ["review", "-h"] => IO.print help *> pure 0
  | ["attest", "--help"] | ["attest", "-h"] => IO.print help *> pure 0
  | ["status", "--help"] | ["status", "-h"] => IO.print help *> pure 0
  | ["init", "--help"] | ["init", "-h"] => IO.print help *> pure 0
  | ["synth", "--help"] | ["synth", "-h"] => IO.print help *> pure 0
  | "check" :: rest => check rest
  | "review" :: rest => review rest
  | "attest" :: rest => attest rest
  | "status" :: rest => status rest
  | "init" :: rest => initializeProject rest
  | "synth" :: rest => synthesize rest
  | request => synthesize request

end Verform.CLI

def main (arguments : List String) : IO UInt32 := do
  try Verform.CLI.run arguments
  catch error =>
    IO.eprintln s!"verform: {Verform.Runner.plainText (toString error)}"
    return 2
