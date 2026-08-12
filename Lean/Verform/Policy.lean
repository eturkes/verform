import Lake.Toml
import Lean.Data.Json
import Verform.Config
import Verform.Path
import Verform.Sha256

namespace Verform.Policy

open Lean Lake Lake.Toml Verform

structure StaticAnalysis where
  gates : Array Gate
  evidence : Evidence
  sources : Array System.FilePath
  modules : Array (String × System.FilePath)
  snapshotFiles : Array System.FilePath
  reviewedModules : Array String

def StaticAnalysis.ok (analysis : StaticAnalysis) : Bool :=
  analysis.gates.all (·.ok)

private def configError (message : String) : IO α :=
  throw <| IO.userError message

private def pathLabel (root path : System.FilePath) : String :=
  Verform.Path.relativeLabel root path

private def distinctPush [BEq α] (values : Array α) (value : α) : Array α :=
  if values.contains value then values else values.push value

private def sortStrings (values : Array String) : Array String :=
  values.insertionSort (· < ·)

private def sortPaths (root : System.FilePath) (values : Array System.FilePath) :=
  values.insertionSort fun left right => pathLabel root left < pathLabel root right

private def sortPairs (values : Array (String × String)) :=
  values.insertionSort fun left right => left.1 < right.1

private def readText (path : System.FilePath) (context : String) : IO String := do
  try IO.FS.readFile path catch error =>
    configError s!"{context}: cannot read UTF-8 file {path}: {error}"

private def requiredFile (root : System.FilePath) (relative context : String) :=
  Verform.Path.regularFile root relative context

private def parseToml (path : System.FilePath) (context : String) : IO Table := do
  let content ← readText path context
  match ← (loadToml <| Parser.mkInputContext content path.toString).toBaseIO with
  | .ok value => return value
  | .error messages =>
      let details ← messages.toList.mapM (·.toString)
      configError s!"{context}: invalid {path.fileName.getD "TOML"}: {String.intercalate "; " details}"

private def jsonObject (value : Json) (context : String) : IO (Std.TreeMap.Raw String Json compare) :=
  match value.getObj? with
  | .ok result => return result
  | .error _ => configError s!"{context}: expected an object"

private def jsonField
    (value : Std.TreeMap.Raw String Json compare)
    (key context : String) : IO Json :=
  match value.get? key with
  | some result => return result
  | none => configError s!"{context}: missing key {key}"

private def jsonString (value : Json) (context : String) : IO String :=
  match value.getStr? with
  | .ok result => return result
  | .error _ => configError s!"{context}: expected a string"

private def isJsonBool : Json → Bool
  | .bool _ => true
  | _ => false

private def isJsonString : Json → Bool
  | .str _ => true
  | _ => false

private def isJsonStringOrNull : Json → Bool
  | .str _ | .null => true
  | _ => false

private def sameKeys
    (value : Std.TreeMap.Raw String Json compare)
    (expected : Array String)
    (context : String) : IO Unit := do
  let actual := value.keys.toArray
  let unknown := sortStrings <| actual.filter fun key => !expected.contains key
  let missing := sortStrings <| expected.filter fun key => !actual.contains key
  unless unknown.isEmpty && missing.isEmpty do
    let details := (unknown.map fun key => s!"unknown key {key}") ++
      (missing.map fun key => s!"missing key {key}")
    configError s!"{context}: {String.intercalate "; " details.toList}"

private def validGitRevision (value : String) : Bool :=
  value.length == 40 && value.toList.all fun character =>
    ('0' ≤ character && character ≤ '9') || ('a' ≤ character && character ≤ 'f')

private def relativeLockPath (value : Json) (context : String) (nullable := false) : Option String :=
  if nullable && value.isNull then none
  else match value.getStr? with
    | .error _ => some s!"{context}: expected a non-empty relative path"
    | .ok text =>
        if text.isEmpty || text == "." || (System.FilePath.mk text).isAbsolute ||
            (System.FilePath.mk text).components.contains ".." then
          some s!"{context}: path must remain inside its package"
        else none

private def buildInputs (manifest : Manifest) : IO (Array System.FilePath × Gate) := do
  let root := manifest.root
  if ← Verform.Path.pathExists (root / "lakefile.lean") <||>
      Verform.Path.isLink (root / "lakefile.lean") then
    configError "build configuration: Verform v1 requires declarative lakefile.toml"
  let lakefile ← requiredFile root "lakefile.toml" "build configuration"
  let toolchain ← requiredFile root "lean-toolchain" "build configuration"
  let lock ← requiredFile root "lake-manifest.json" "build configuration"
  let override := root / ".lake/package-overrides.json"
  if ← Verform.Path.pathExists override <||> Verform.Path.isLink override then
    configError "build configuration: package-overrides.json can override locked dependencies"
  unless (← readText toolchain "build configuration").trimAscii.toString ==
      "leanprover/lean4:v4.32.2" do
    configError "build configuration: lean-toolchain must pin leanprover/lean4:v4.32.2"

  let lakeTable ← parseToml lakefile "build configuration"
  let packageName ← match lakeTable.find? `name with
    | some (.string _ name) => pure name
    | _ => configError "build configuration: lakefile.toml requires a package name"
  if packageName.isEmpty then
    configError "build configuration: lakefile.toml requires a package name"

  let lockText ← readText lock "build configuration"
  let lockJson ← match Json.parse lockText with
    | .ok value => pure value
    | .error message => configError s!"build configuration: invalid lake-manifest.json: {message}"
  let rootObject ← jsonObject lockJson "build configuration: lake-manifest.json must contain an object"
  let rootKeys := #["version", "fixedToolchain", "name", "lakeDir", "packagesDir", "packages"]
  sameKeys rootObject rootKeys "build configuration"
  unless (← jsonString (← jsonField rootObject "version" "build configuration")
      "build configuration: version") == "1.2.0" do
    configError "build configuration: lake-manifest.json version must be exactly 1.2.0"
  let fixed ← jsonField rootObject "fixedToolchain" "build configuration"
  unless isJsonBool fixed do
    configError "build configuration: fixedToolchain must be boolean"
  let lakeDirectory ← jsonString (← jsonField rootObject "lakeDir" "build configuration")
    "build configuration: lakeDir"
  let packagesDirectory ← jsonString (← jsonField rootObject "packagesDir" "build configuration")
    "build configuration: packagesDir"
  unless lakeDirectory == ".lake" && packagesDirectory == ".lake/packages" do
    configError "build configuration: Lake directories must use .lake defaults"
  let lockedName ← jsonString (← jsonField rootObject "name" "build configuration")
    "build configuration: name"
  unless lockedName == packageName || lockedName == s!"«{packageName}»" do
    configError "build configuration: manifest package name differs from lakefile.toml"
  let packages ← match (← jsonField rootObject "packages" "build configuration").getArr? with
    | .ok values => pure values
    | .error _ => configError "build configuration: packages must be an array"

  let packageKeys := #["type", "name", "scope", "inherited", "configFile", "manifestFile",
    "url", "rev", "inputRev", "subDir"]
  let mut issues := #[]
  let mut names := #[]
  for index in *...packages.size do
    let context := s!"lake-manifest.json packages[{index}]"
    let .ok package := packages[index]!.getObj? | issues := issues.push s!"{context}: expected an object"; continue
    let actual := package.keys.toArray
    let unknown := actual.filter fun key => !packageKeys.contains key
    let missing := packageKeys.filter fun key => !actual.contains key
    for key in unknown do issues := issues.push s!"{context}: unknown key {key}"
    for key in missing do issues := issues.push s!"{context}: missing key {key}"
    unless unknown.isEmpty && missing.isEmpty do continue
    let field key := package.get? key |>.getD .null
    let nameResult := (field "name").getStr?
    match nameResult with
    | .ok name =>
        if name.isEmpty then issues := issues.push s!"{context}.name: expected a non-empty string"
        else if names.contains name then issues := issues.push s!"{context}.name: duplicate package {name}"
        else names := names.push name
    | .error _ => issues := issues.push s!"{context}.name: expected a non-empty string"
    unless isJsonString (field "scope") do
      issues := issues.push s!"{context}.scope: expected a string"
    for key in #["configFile", "url"] do
      match (field key).getStr? with
      | .ok value => if value.isEmpty then issues := issues.push s!"{context}.{key}: expected a non-empty string"
      | .error _ => issues := issues.push s!"{context}.{key}: expected a non-empty string"
    unless isJsonStringOrNull (field "manifestFile") do
      issues := issues.push s!"{context}.manifestFile: expected string or null"
    unless isJsonBool (field "inherited") do
      issues := issues.push s!"{context}.inherited: expected a boolean"
    let typeOk := match (field "type").getStr? with
      | .ok "git" => true
      | _ => false
    unless typeOk do
      issues := issues.push s!"{context}.type: only pinned git dependencies are accepted"
    match (field "rev").getStr? with
    | .ok revision => unless validGitRevision revision do
        issues := issues.push s!"{context}.rev: expected a full lowercase 40-hex Git revision"
    | .error _ => issues := issues.push s!"{context}.rev: expected a full lowercase 40-hex Git revision"
    unless isJsonStringOrNull (field "inputRev") do
      issues := issues.push s!"{context}.inputRev: expected string or null"
    for (key, nullable) in #[
      ("configFile", false), ("manifestFile", true), ("subDir", true)
    ] do
      if let some issue := relativeLockPath (field key) s!"{context}.{key}" nullable then
        issues := issues.push issue

  let mut extras := #[]
  for index in *...manifest.lean.evidenceFiles.size do
    extras := extras.push <| ← requiredFile root manifest.lean.evidenceFiles[index]!
      s!"lean.evidence_files[{index}]"
  let files := extras.foldl (init := #[lakefile, toolchain, lock]) distinctPush
  let summary := if issues.isEmpty then
      s!"Lake 1.2.0 lock: {packages.size} pinned Git package(s); {files.size} hashed control file(s)"
    else s!"{issues.size} build-closure violation(s)"
  return (files, {name := "build closure", ok := issues.isEmpty, summary, detail := issues})

private def discoverSourcesAt (directory : System.FilePath) : IO (Array System.FilePath) := do
  let mut result := #[]
  let paths ← System.FilePath.walkDir directory fun path => do
    let hidden := path.fileName.any (·.startsWith ".")
    if hidden then return false
    let metadata ← path.symlinkMetadata
    return metadata.type == .dir
  for path in paths do
    if path == directory then continue
    if path.components.drop directory.components.length |>.any (·.startsWith ".") then continue
    let metadata ← path.symlinkMetadata
    if path.toString.endsWith ".lean" then
      match metadata.type with
      | .file => result := result.push path
      | .symlink => configError s!"Lean sources cannot be symbolic links: {path}"
      | _ => configError s!"Lean sources must be regular files: {path}"
  return result

private def sourceFiles (manifest : Manifest) : IO (System.FilePath × Array System.FilePath) := do
  let requested := if manifest.lean.moduleRoot == "." then manifest.root
    else manifest.root / manifest.lean.moduleRoot
  if manifest.lean.moduleRoot != "." then
    Verform.Path.rejectLinkComponents manifest.root manifest.lean.moduleRoot "lean.module_root"
  let moduleRoot ← Verform.Path.canonicalInside manifest.root requested "lean.module_root"
  unless ← Verform.Path.isDirectory moduleRoot do
    configError "lean.module_root: expected a directory"
  let found := sortPaths manifest.root (← discoverSourcesAt moduleRoot)
  if found.isEmpty then configError s!"lean.module_root: no Lean sources found under {moduleRoot}"
  return (moduleRoot, found)

private def asciiLetter (character : Char) : Bool :=
  ('A' ≤ character && character ≤ 'Z') || ('a' ≤ character && character ≤ 'z')

private def asciiDigit (character : Char) : Bool :=
  '0' ≤ character && character ≤ '9'

private def validModuleName (value : String) : Bool :=
  value.splitOn "." |>.all fun component => match component.toList with
    | [] => false
    | first :: rest => asciiLetter first && rest.all fun character =>
        asciiLetter character || asciiDigit character || character == '_' || character == '\''

private def moduleMap
    (moduleRoot : System.FilePath)
    (sources : Array System.FilePath) : IO (Array (String × System.FilePath)) := do
  let mut modules := #[]
  for source in sources do
    let relative := Verform.Path.relativeLabel moduleRoot source
    let withoutSuffix := relative.toSlice.dropEnd 5 |>.toString
    let moduleName := String.intercalate "." (withoutSuffix.splitOn "/")
    unless validModuleName moduleName do
      configError s!"lean.module_root: module paths must be dot-separated ASCII identifiers: {moduleName}"
    if modules.any fun item => item.1 == moduleName then
      configError s!"lean.module_root: duplicate module {moduleName}"
    modules := modules.push (moduleName, source)
  return modules

def ownerModule (symbol : String) (modules : Array (String × System.FilePath)) : Option String :=
  modules.foldl (init := none) fun current item =>
    let name := item.1
    if symbol == name || symbol.startsWith (name ++ ".") then
      match current with
      | none => some name
      | some previous => if previous.length < name.length then some name else current
    else current

private def identifierCharacter (character : Char) : Bool :=
  asciiLetter character || asciiDigit character || character == '_' || character == '\''

private def forbiddenWords : Array String := #[
  "ad" ++ "mit", "ax" ++ "iom", "con" ++ "stant", "csi" ++ "mp", "ex" ++ "tern",
  "implemented" ++ "_by", "op" ++ "aque", "par" ++ "tial", "par" ++ "tial_fixpoint",
  "skip" ++ "KernelTC", "sor" ++ "ry", "un" ++ "safe"
]

private def tokenViolations
    (label content : String)
    (challenge : Bool) : Array String :=
  let rec visit : List Char → Nat → String → Array String → Array String
    | [], line, token, issues =>
        if forbiddenWords.contains token && !(challenge && token == "sor" ++ "ry") then
          issues.push s!"{label}:{line}: forbidden `{token}`"
        else issues
    | character :: rest, line, token, issues =>
        if identifierCharacter character then visit rest line (token.push character) issues
        else
          let issues := if forbiddenWords.contains token && !(challenge && token == "sor" ++ "ry") then
              issues.push s!"{label}:{line}: forbidden `{token}`" else issues
          visit rest (if character == '\n' then line + 1 else line) "" issues
  visit content.toList 1 "" #[]

private def countCodeLines (content : String) : Nat :=
  content.splitOn "\n" |>.foldl (init := 0) fun count line =>
    if line.trimAscii.isEmpty then count else count + 1

private def findModule?
    (modules : Array (String × System.FilePath))
    (name : String) : Option System.FilePath :=
  modules.find? (·.1 == name) |>.map (·.2)

def analyze (manifest : Manifest) : IO StaticAnalysis := do
  let (moduleRoot, sources) ← sourceFiles manifest
  let modules ← moduleMap moduleRoot sources
  let (buildFiles, buildGate) ← buildInputs manifest
  let challengePath := manifest.comparator.bind fun comparator =>
    findModule? modules comparator.challengeModule
  let solutionPath := manifest.comparator.bind fun comparator =>
    findModule? modules comparator.solutionModule

  let mut sourceIssues := #[]
  if let some comparator := manifest.comparator then
    if challengePath.isNone then sourceIssues := sourceIssues.push s!"challenge module not found: {comparator.challengeModule}"
    if solutionPath.isNone then sourceIssues := sourceIssues.push s!"solution module not found: {comparator.solutionModule}"
  for obligation in manifest.obligations do
    if (findModule? modules obligation.moduleName).isNone then
      sourceIssues := sourceIssues.push s!"obligation module not found: {obligation.moduleName}"
    if (ownerModule obligation.contract modules).isNone then
      sourceIssues := sourceIssues.push s!"contract symbol has no local owner: {obligation.contract}"
    if (ownerModule obligation.implementation modules).isNone then
      sourceIssues := sourceIssues.push s!"implementation symbol has no local owner: {obligation.implementation}"
  let sourceGate : Gate := {
    name := "sources"
    ok := sourceIssues.isEmpty
    summary := if sourceIssues.isEmpty then s!"{sources.size} Lean source file(s); {modules.size} unique module(s)"
      else s!"{sourceIssues.size} source binding violation(s)"
    detail := sourceIssues
  }

  let mut policyIssues := #[]
  for source in sources do
    let label := pathLabel manifest.root source
    let issues := tokenViolations label (← readText source s!"Lean source {label}")
      (challengePath == some source)
    policyIssues := policyIssues ++ issues
  let policyGate : Gate := {
    name := "source policy"
    ok := policyIssues.isEmpty
    summary := if policyIssues.isEmpty then "no forbidden identifier spellings (comments and literals included)"
      else s!"{policyIssues.size} forbidden spelling(s)"
    detail := policyIssues
  }

  let mut reviewPaths := #[]
  for index in *...manifest.review.files.size do
    reviewPaths := reviewPaths.push <| ← requiredFile manifest.root manifest.review.files[index]!
      s!"review.files[{index}]"
  let mut sourceTexts : Array (System.FilePath × String) := #[]
  for source in sources do sourceTexts := sourceTexts.push (source, ← readText source "Lean source")
  let mut reviewLines := 0
  let mut reviewIssues := #[]
  for path in reviewPaths do
    if path.extension == some "lean" then
      match sourceTexts.find? (·.1 == path) with
      | some item => reviewLines := reviewLines + countCodeLines item.2
      | none => reviewIssues := reviewIssues.push s!"trusted Lean file is outside module root: {pathLabel manifest.root path}"
  for path in buildFiles do
    unless reviewPaths.contains path do
      reviewIssues := reviewIssues.push s!"build input must be human-reviewed: {pathLabel manifest.root path}"
  if reviewLines > manifest.review.maxCodeLines then
    reviewIssues := reviewIssues.push s!"review surface has {reviewLines} nonblank lines; budget is {manifest.review.maxCodeLines}"
  let reviewGate : Gate := {
    name := "review surface"
    ok := reviewIssues.isEmpty
    summary := s!"{reviewPaths.size} file(s), {reviewLines}/{manifest.review.maxCodeLines} lines"
    detail := reviewIssues
  }

  let mut boundaryIssues := #[]
  if manifest.comparator.isSome then
    if let some challenge := challengePath then unless reviewPaths.contains challenge do
      boundaryIssues := boundaryIssues.push "Comparator challenge module must be human-reviewed"
    if let some solution := solutionPath then if reviewPaths.contains solution then
      boundaryIssues := boundaryIssues.push "Comparator solution module must remain outside review"
  for obligation in manifest.obligations do
    let proofPath := findModule? modules obligation.moduleName
    let contractPath := (ownerModule obligation.contract modules).bind (findModule? modules)
    let implementationPath := (ownerModule obligation.implementation modules).bind (findModule? modules)
    if proofPath.any reviewPaths.contains then
      boundaryIssues := boundaryIssues.push s!"{obligation.name}: proof module must remain outside review"
    if contractPath.any fun path => !reviewPaths.contains path then
      boundaryIssues := boundaryIssues.push s!"{obligation.name}: contract owner must be human-reviewed"
    if implementationPath.any reviewPaths.contains then
      boundaryIssues := boundaryIssues.push s!"{obligation.name}: implementation owner must remain outside review"
    if obligation.contract == obligation.implementation then
      boundaryIssues := boundaryIssues.push s!"{obligation.name}: contract and implementation must differ"
  let boundaryGate : Gate := {
    name := "symbol boundary"
    ok := boundaryIssues.isEmpty
    summary := if boundaryIssues.isEmpty then "contract roots reviewed; implementation/proof roots isolated"
      else s!"{boundaryIssues.size} symbol-boundary violation(s)"
    detail := boundaryIssues
  }

  let verificationPaths := (sources ++ buildFiles ++ reviewPaths ++ #[manifest.path]).foldl
    (init := #[]) distinctPush
  let mut inputHashes := #[]
  for path in verificationPaths do
    inputHashes := inputHashes.push (pathLabel manifest.root path, ← Sha256.hashFile path)
  let mut reviewHashes := #[]
  for path in reviewPaths do
    reviewHashes := reviewHashes.push (pathLabel manifest.root path, ← Sha256.hashFile path)
  reviewHashes := reviewHashes.filter (·.1 != pathLabel manifest.root manifest.path)
  reviewHashes := reviewHashes.push (pathLabel manifest.root manifest.path, ← Sha256.hashFile manifest.path)
  let reviewedModules := sortStrings <| modules.filterMap fun item =>
    if reviewPaths.contains item.2 then some item.1 else none
  let evidence : Evidence := {
    reviewCodeLines := reviewLines
    reviewHashes := sortPairs reviewHashes
    inputHashes := sortPairs inputHashes
  }
  return {
    gates := #[sourceGate, policyGate, buildGate, reviewGate, boundaryGate]
    evidence
    sources
    modules
    snapshotFiles := sortPaths manifest.root verificationPaths
    reviewedModules
  }

end Verform.Policy
