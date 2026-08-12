import Verform.Proof

namespace VerformTests.Plan

open Verform

private def assert (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

def tests : IO Unit := do
  let workspace : System.FilePath := "/work/project"
  let prompt := "Implement a verified queue"
  let invocation := Agent.Plan.codexInvocation workspace prompt
  assert (invocation.executable == "codex") "planner executable"
  assert (invocation.workingDirectory == workspace) "planner workspace"
  assert (invocation.stdinChunks == Agent.Plan.workflowPromptChunks prompt) "planner stdin"
  assert (invocation.stdinText.contains "Natural-language request:\nImplement a verified queue")
    "planner workflow prompt"
  assert (invocation.arguments == #[
    "--model", "gpt-5.6-sol",
    "--config", "model_provider=\"openai\"",
    "--config", "model_reasoning_effort=\"max\"",
    "--config", "service_tier=\"default\"",
    "--disable", "apps",
    "--disable", "browser_use",
    "--disable", "computer_use",
    "--disable", "hooks",
    "--disable", "multi_agent",
    "--disable", "plugins",
    "--sandbox", "workspace-write",
    "--ask-for-approval", "never",
    "--cd", workspace.toString,
    "exec",
    "--ignore-user-config",
    "--ignore-rules",
    "--ephemeral",
    "--json",
    "--color", "never",
    "-"
  ]) "planner arguments"
  assert (invocation.command[0]? == some "codex") "planner command"

end VerformTests.Plan
