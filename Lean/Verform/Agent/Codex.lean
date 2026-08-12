import Lean.Data.Json
import Verform.Agent.Plan
import Verform.Path
import Verform.Runner

namespace Verform.Agent.Codex

open Lean Verform

structure Outcome where
  threadId : String
  response : String
  eventCount : Nat
  deriving Repr, BEq

private def subscriptionEnvironment : Array (String × Option String) := #[
  ("OPENAI_API_KEY", none),
  ("AZURE_OPENAI_API_KEY", none),
  ("CODEX_API_KEY", none),
  ("OPENAI_BASE_URL", none)
]

private def fieldString? (value : Json) (key : String) : Option String :=
  (value.getObjVal? key >>= (·.getStr?)).toOption

def parseTranscript (content : String) : Except String Outcome := do
  let lines := content.splitOn "\n" |>.filter fun line => !line.trimAscii.isEmpty
  let mut eventCount := 0
  let mut threadId := ""
  let mut response := ""
  let mut completed := false
  let mut failure := none
  for line in lines do
    let event ← Json.parse line
    eventCount := eventCount + 1
    let eventType := fieldString? event "type" |>.getD ""
    if eventType == "thread.started" then
      threadId := fieldString? event "thread_id" |>.getD threadId
    else if eventType == "turn.completed" then
      completed := true
    else if eventType == "turn.failed" then
      failure := some <| fieldString? event "message" |>.getD "Codex turn failed"
    else if eventType == "item.completed" then
      if let .ok item := event.getObjVal? "item" then
        if fieldString? item "type" == some "agent_message" then
          response := fieldString? item "text" |>.getD response
  if let some message := failure then throw message
  unless completed do throw "Codex transcript has no terminal turn.completed event"
  if response.isEmpty then throw "Codex transcript has no completed agent message"
  return {threadId, response, eventCount}

def verifySubscription (workspace : System.FilePath) : IO Unit := do
  let result ← Runner.run #["codex", "login", "status"] workspace none 30
    subscriptionEnvironment
  unless result.ok do
    throw <| IO.userError s!"Codex authentication check failed: {String.intercalate "; " (Runner.diagnostic result).toList}"
  let output := result.stdout ++ "\n" ++ result.stderr
  unless output.contains "Logged in using ChatGPT" do
    throw <| IO.userError "Codex must be authenticated through the ChatGPT subscription"

def validateProjectControls (workspace : System.FilePath) : IO Unit := do
  let mut current := workspace
  for _ in *...256 do
    let projectControl := current / ".codex"
    if ← Path.pathExists projectControl <||> Path.isLink projectControl then
      throw <| IO.userError s!"project-local Codex controls are disabled: {projectControl}"
    if ← Path.pathExists (current / ".git") then return
    let some parent := current.parent
      | throw <| IO.userError "Codex synthesis workspace must be inside a Git repository"
    if parent == current then
      throw <| IO.userError "Codex synthesis workspace must be inside a Git repository"
    current := parent
  throw <| IO.userError "Codex synthesis workspace ancestry exceeds safety bound"

def run (workspace : System.FilePath) (request : String) : IO Outcome := do
  if request.trimAscii.isEmpty then throw <| IO.userError "natural-language request cannot be empty"
  let root ← IO.FS.realPath workspace
  validateProjectControls root
  verifySubscription root
  let invocation := Agent.Plan.codexInvocation root request
  let result ← Runner.run invocation.command root (some invocation.stdinText) 7200
    subscriptionEnvironment (32 * 1024 * 1024)
  unless result.ok do
    throw <| IO.userError s!"Codex synthesis failed: {String.intercalate "; " (Runner.diagnostic result).toList}"
  let outcome ← match parseTranscript result.stdout with
    | .ok value => pure value
    | .error message => throw <| IO.userError s!"invalid Codex JSONL transcript: {message}"
  return outcome

end Verform.Agent.Codex
