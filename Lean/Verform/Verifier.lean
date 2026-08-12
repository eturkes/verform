import Lean.Data.Json
import Verform.AuditSource
import Verform.Json
import Verform.Policy
import Verform.Runner

namespace Verform.Verifier

open Lean Verform

private def commandGate (name : String) (result : Runner.Result) (success : String) : Gate :=
  if result.ok then {name := name, ok := true, summary := success}
  else {
    name := name
    ok := false
    summary := s!"command failed with exit {result.exitCode}"
    detail := Runner.diagnostic result
  }

private def withToolchain (evidence : Evidence) (toolchain : String) : Evidence :=
  {evidence with toolchain}

private def withObligations
    (evidence : Evidence)
    (toolchain : String)
    (obligations : Array ObligationEvidence) : Evidence :=
  {evidence with toolchain, obligations}

private def toolchain (manifest : Manifest) : IO (Gate × String) := do
  let result ← Runner.run #["lake", "env", "lean", "--version"] manifest.root none
    manifest.lean.timeoutSeconds
  if !result.ok then return (commandGate "toolchain" result "", "")
  let lines := result.stdout.splitOn "\n" |>.filter fun line => !line.trimAscii.isEmpty
  let some version := lines.head? | return ({
    name := "toolchain"
    ok := false
    summary := "version command produced no output"
  }, "")
  let version := version.trimAscii.toString
  if version.contains "version 4.32.2," then return ({
    name := "toolchain"
    ok := true
    summary := version
  }, version)
  return ({
    name := "toolchain"
    ok := false
    summary := s!"expected Lean 4.32.2; observed {version}"
  }, version)

private def trustedHeaders
    (isolated : Manifest)
    (sourceRoot : System.FilePath)
    (analysis : Policy.StaticAnalysis) : IO Gate := do
  let source := AuditSource.trustedHeaders sourceRoot analysis
  let result ← Runner.run #["lake", "env", "lean", "--stdin"] isolated.root (some source)
    isolated.lean.timeoutSeconds
  return commandGate "trusted imports" result
    "Lean parser confirms the trusted local import graph is closed"

private def logicalDependencies (output : String) : Except String (Array String) := do
  let marker := "VERFORM_LOGICAL_DEPS="
  let markers := output.splitOn "\n" |>.filterMap fun line =>
    match line.splitOn marker with
    | [_before, value] => some value.trimAscii.toString
    | _ => none
  let [encoded] := markers | .error "expected exactly one logical-dependency marker"
  let value ← Json.parse encoded
  let values ← value.getArr?
  let result ← values.mapM (·.getStr?)
  if result.toList.eraseDups.length != result.size then
    .error "logical-dependency report contains duplicates"
  return result.insertionSort (· < ·)

private def checkObligation
    (manifest : Manifest)
    (analysis : Policy.StaticAnalysis)
    (obligation : Obligation) : IO (Gate × Option ObligationEvidence) := do
  let result ← Runner.run #["lake", "env", "lean", "--stdin"] manifest.root
    (some <| AuditSource.obligation obligation analysis) manifest.lean.timeoutSeconds
  if !result.ok then
    return ({
      name := s!"obligation:{obligation.name}"
      ok := false
      summary := "exact binding, semantic closure, or runtime audit failed"
      detail := Runner.diagnostic result
    }, none)
  let parsed := logicalDependencies (result.stdout ++ "\n" ++ result.stderr)
  if let .error message := parsed then
    return ({
      name := s!"obligation:{obligation.name}"
      ok := false
      summary := "could not parse the environment's logical-dependency report"
      detail := #[message]
    }, none)
  let .ok dependencies := parsed | unreachable!
  let disallowed := dependencies.filter fun item => !obligation.allowedAxioms.contains item
  unless disallowed.isEmpty do
    return ({
      name := s!"obligation:{obligation.name}"
      ok := false
      summary := s!"disallowed logical assumption(s): {String.intercalate ", " disallowed.toList}"
      detail := #[s!"observed: {String.intercalate ", " dependencies.toList}"]
    }, none)
  let evidence : ObligationEvidence := {
    name := obligation.name
    moduleName := obligation.moduleName
    declaration := obligation.declaration
    statement := obligation.statement
    axioms := dependencies
  }
  let rendered := if dependencies.isEmpty then "(none)"
    else String.intercalate ", " dependencies.toList
  return ({
    name := s!"obligation:{obligation.name}"
    ok := true
    summary := s!"exact contract/implementation origins and safe local runtime closure; logical assumptions: {rendered}"
  }, some evidence)

private def verifyKernel
    (manifest : Manifest)
    (analysis : Policy.StaticAnalysis)
    (observedToolchain : String) : IO (Array Gate × Evidence) := do
  let targets := manifest.obligations.foldl (init := #[]) fun values obligation =>
    if values.contains obligation.moduleName then values else values.push obligation.moduleName
  let command := #["lake", "--rehash", "--reconfigure", "--no-cache", "build", "--wfail"] ++
    targets.map ("+" ++ ·)
  let build ← Runner.run command manifest.root none manifest.lean.timeoutSeconds
  let mut gates := #[commandGate "fresh build" build
    "cache-free, rehashed Lean elaboration + kernel checking passed"]
  if !build.ok then return (gates, withToolchain analysis.evidence observedToolchain)
  let mut obligations := #[]
  for obligation in manifest.obligations do
    let (gate, evidence) ← checkObligation manifest analysis obligation
    gates := gates.push gate
    if let some item := evidence then obligations := obligations.push item
  if gates.any fun gate => !gate.ok then
    return (gates, withObligations analysis.evidence observedToolchain obligations)
  for moduleName in targets do
    let result ← Runner.run #["lake", "env", "leanchecker", "--fresh", moduleName]
      manifest.root none manifest.lean.timeoutSeconds
    gates := gates.push <| commandGate s!"kernel replay:{moduleName}" result
      "leanchecker fresh-environment replay passed"
  if gates.all (·.ok) then
    for check in manifest.checks do
      let result ← Runner.run check.command manifest.root none check.timeoutSeconds
      gates := gates.push <| commandGate s!"check:{check.name}" result "passed"
  return (gates, withObligations analysis.evidence observedToolchain obligations)

private def comparatorPayload (manifest : Manifest) : String :=
  match manifest.comparator with
  | none => "{}"
  | some comparator =>
    Verform.Json.object #[
      ("challenge_module", Verform.Json.escape comparator.challengeModule),
      ("definition_names", Verform.Json.strings comparator.definitionNames 2),
      ("enable_nanoda", "true"),
      ("permitted_axioms", Verform.Json.strings comparator.permittedAxioms 2),
      ("solution_module", Verform.Json.escape comparator.solutionModule),
      ("theorem_names", Verform.Json.strings comparator.theoremNames 2)
    ] ++ "\n"

private def resolveExecutable (manifest : Manifest) (name : String) : IO (Option String) := do
  let result ← Runner.run #["sh", "-c", "command -v -- \"$1\"", "verform-which", name]
    manifest.root none 10
  unless result.ok do return none
  let lines := result.stdout.splitOn "\n" |>.filter fun line => !line.trimAscii.isEmpty
  let [path] := lines | return none
  let path := path.trimAscii.toString
  let candidate := System.FilePath.mk path
  unless candidate.isAbsolute && (← Path.isFile candidate) do return none
  return some path

private def comparatorEnvironment : IO (Option (Array String)) := do
  let some path ← IO.getEnv "PATH" | return none
  if path.isEmpty then return none
  let mut result := #[s!"--setenv=PATH={path}"]
  for name in #["COMPARATOR_LANDRUN", "COMPARATOR_LEAN4EXPORT", "COMPARATOR_NANODA"] do
    if let some value ← IO.getEnv name then
      if !value.isEmpty then result := result.push s!"--setenv={name}={value}"
  return some result

private def verifyComparator
    (manifest : Manifest)
    (analysis : Policy.StaticAnalysis)
    (observedToolchain : String) : IO (Array Gate × Evidence) := do
  let some comparator := manifest.comparator | throw <| IO.userError "missing comparator configuration"
  let mut gates := #[]
  let build ← Runner.run #["lake", "--rehash", "--reconfigure", "--no-cache", "build",
    "+" ++ comparator.challengeModule] manifest.root none manifest.lean.timeoutSeconds
  gates := gates.push <| commandGate "challenge build" build
    "reviewed challenge built in the fresh workspace"
  if !build.ok then return (gates, withToolchain analysis.evidence observedToolchain)
  let challenge ← Runner.run #["lake", "env", "lean", "--stdin"] manifest.root
    (some <| AuditSource.challenge manifest) manifest.lean.timeoutSeconds
  gates := gates.push <| commandGate "challenge semantics" challenge
    "configured declaration origins and theorem-to-executable links confirmed"
  if !challenge.ok then return (gates, withToolchain analysis.evidence observedToolchain)
  let identity ← Runner.run #["id", "-u"] manifest.root none 10
  let uid := if identity.ok then identity.stdout.trimAscii.toString.toNat? else none
  if uid.isNone then
    gates := gates.push {
      name := "comparator"
      ok := false
      summary := "cannot establish an unprivileged checker identity"
      detail := Runner.diagnostic identity
    }
    return (gates, withToolchain analysis.evidence observedToolchain)
  if uid == some 0 then
    gates := gates.push {
      name := "comparator"
      ok := false
      summary := "adversarial assurance requires an unprivileged user"
    }
    return (gates, withToolchain analysis.evidence observedToolchain)
  let toolNames := #["systemd-run", "env", "lake", "comparator"]
  let resolved ← toolNames.mapM fun name => resolveExecutable manifest name
  let missing := toolNames.zip resolved |>.filterMap fun (name, path) =>
    if path.isNone then some name else none
  unless missing.isEmpty do
    gates := gates.push {
      name := "comparator"
      ok := false
      summary := s!"required trusted tool(s) not found: {String.intercalate ", " missing.toList}"
    }
    return (gates, withToolchain analysis.evidence observedToolchain)
  let [some systemdRun, some envBin, some lakeBin, some comparatorBin] := resolved.toList
    | unreachable!
  let some serviceEnvironment ← comparatorEnvironment
    | gates := gates.push {
        name := "comparator"
        ok := false
        summary := "PATH is required for the Comparator service environment"
      }
      return (gates, withToolchain analysis.evidence observedToolchain)
  let nonce ← IO.monoNanosNow
  let config := manifest.root / s!".verform-comparator-{nonce}.json"
  try
    let handle ← IO.FS.Handle.mk config .writeNew
    handle.putStr (comparatorPayload manifest)
    handle.flush
    let command := #[
      systemdRun, "--user", "--pipe", "--wait", "--collect", "--quiet",
      "--property=RestrictAddressFamilies=~AF_UNIX",
      s!"--property=RuntimeMaxSec={manifest.lean.timeoutSeconds}s",
      "--property=TimeoutStopSec=5s",
      s!"--working-directory={manifest.root}"] ++ serviceEnvironment ++ #["--", envBin,
      "-u", "ELAN_TOOLCHAIN", "-u", "LEAN_PATH", "-u", "LEAN_SRC_PATH",
      "-u", "LEAN_GITHASH", "-u", "LAKE_PKG_URL_MAP", "-u", "LAKE_CONFIG",
      "-u", "LAKE_HOME", "-u", "LD_PRELOAD", "-u", "LD_LIBRARY_PATH",
      lakeBin, "env", comparatorBin, config.toString
    ]
    let result ← Runner.run command manifest.root none manifest.lean.timeoutSeconds
    gates := gates.push <| commandGate "comparator" result
      "challenge declarations, logical policy, sandbox build, Lean replay, and nanoda replay passed"
  finally
    if ← config.pathExists then IO.FS.removeFile config
  return (gates, withToolchain analysis.evidence observedToolchain)

private def copySnapshot
    (manifest : Manifest)
    (analysis : Policy.StaticAnalysis)
    (root : System.FilePath) : IO Manifest := do
  for source in analysis.snapshotFiles do
    let label := Path.relativeLabel manifest.root source
    let destination := root / label
    if let some parent := destination.parent then IO.FS.createDirAll parent
    let data ← IO.FS.readBinFile source
    IO.FS.writeBinFile destination data
    let some expected := analysis.evidence.inputHashes.find? (·.1 == label) |>.map (·.2)
      | throw <| IO.userError s!"missing input digest: {label}"
    unless Sha256.hash data == expected do
      throw <| IO.userError s!"input changed while snapshotting: {label}"
  return {manifest with root, path := root / Path.relativeLabel manifest.root manifest.path}

private def hashDiff
    (before after : Array (String × String)) : Array String :=
  Id.run do
    let mut detail := #[]
    for item in before do
      match after.find? (·.1 == item.1) with
      | none => detail := detail.push s!"removed: {item.1}"
      | some current => if current.2 != item.2 then detail := detail.push s!"changed: {item.1}"
    for item in after do
      if (before.find? (·.1 == item.1)).isNone then detail := detail.push s!"added: {item.1}"
    return detail.insertionSort (· < ·)

private def snapshotStability
    (isolated : Manifest)
    (expected : Array (String × String)) : IO Gate := do
  try
    let current ← Policy.analyze isolated
    let detail := hashDiff expected current.evidence.inputHashes
    return {
      name := "snapshot stability"
      ok := detail.isEmpty
      summary := if detail.isEmpty then "snapshot inputs unchanged after prover work"
        else "snapshot inputs changed during prover work"
      detail := detail
    }
  catch error =>
    return {
      name := "snapshot stability"
      ok := false
      summary := "cannot inventory snapshot after prover work"
      detail := #[toString error]
    }

private def cleanupSnapshot (path : System.FilePath) : IO Unit := do
  let metadata ← path.symlinkMetadata
  unless metadata.type == .dir do
    throw <| IO.userError s!"refusing snapshot cleanup: root type changed: {path}"
  IO.FS.removeDirAll path

def verify (manifest : Manifest) : IO Report := do
  let analysis ← Policy.analyze manifest
  let mut gates := analysis.gates
  if !analysis.ok then return {
    project := manifest.project.name
    assurance := manifest.lean.assurance
    gates := gates
    evidence := analysis.evidence
  }
  let temporary ← IO.FS.createTempDir
  let mut evidence := analysis.evidence
  try
    let isolated ← copySnapshot manifest analysis temporary
    gates := gates.push {
      name := "isolated snapshot"
      ok := true
      summary := s!"fresh workspace contains {analysis.snapshotFiles.size} hashed file(s)"
    }
    let (toolchainGate, observed) ← toolchain isolated
    gates := gates.push toolchainGate
    if !toolchainGate.ok then
      return {
        project := manifest.project.name
        assurance := manifest.lean.assurance
        gates := gates
        evidence := analysis.evidence
      }
    let headerGate ← trustedHeaders isolated manifest.root analysis
    gates := gates.push headerGate
    if !headerGate.ok then
      return {
        project := manifest.project.name
        assurance := manifest.lean.assurance
        gates := gates
        evidence := withToolchain analysis.evidence observed
      }
    let (modeGates, modeEvidence) ← match manifest.lean.assurance with
      | .kernel => verifyKernel isolated analysis observed
      | .comparator => verifyComparator isolated analysis observed
    gates := gates ++ modeGates
    evidence := modeEvidence
    gates := gates.push (← snapshotStability isolated analysis.evidence.inputHashes)
  catch error =>
    gates := gates.push {
      name := "isolated snapshot"
      ok := false
      summary := s!"cannot create fresh workspace: {error}"
    }
    return {
      project := manifest.project.name
      assurance := manifest.lean.assurance
      gates := gates
      evidence := analysis.evidence
    }
  finally
    cleanupSnapshot temporary
  if gates.all (·.ok) then
    let current ← Policy.analyze manifest
    let detail := hashDiff evidence.inputHashes current.evidence.inputHashes
    gates := gates.push {
      name := "input stability"
      ok := detail.isEmpty
      summary := if detail.isEmpty then "verification inputs unchanged during checks"
        else "verification inputs changed during checks"
      detail := detail
    }
  return {
    project := manifest.project.name
    assurance := manifest.lean.assurance
    gates := gates
    evidence := evidence
  }

end Verform.Verifier
