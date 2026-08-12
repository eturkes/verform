import Verform.Agent.Codex

namespace VerformTests.Codex

private def assert (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def isError : Except α β → Bool
  | .error _ => true
  | .ok _ => false

def tests : IO Unit := do
  let transcript :=
    "{\"type\":\"thread.started\",\"thread_id\":\"thread-1\"}\n" ++
    "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"done\"}}\n" ++
    "{\"type\":\"turn.completed\"}\n"
  let .ok outcome := Verform.Agent.Codex.parseTranscript transcript
    | throw <| IO.userError "valid Codex transcript"
  assert (outcome.threadId == "thread-1") "Codex thread"
  assert (outcome.response == "done") "Codex response"
  assert (isError <| Verform.Agent.Codex.parseTranscript
    "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"x\"}}\n")
    "Codex terminal event required"
  let prompt := String.join (Verform.Agent.Plan.workflowPromptChunks "build a queue").toList
  assert (prompt.contains "Natural-language request:\nbuild a queue") "workflow request"
  let root ← IO.FS.createTempDir
  try
    IO.FS.createDir (root / ".git")
    Verform.Agent.Codex.validateProjectControls root
    IO.FS.createDir (root / ".codex")
    let mut rejected := false
    try Verform.Agent.Codex.validateProjectControls root
    catch _ => rejected := true
    assert rejected "project Codex controls must be rejected"
  finally
    IO.FS.removeDirAll root

end VerformTests.Codex
