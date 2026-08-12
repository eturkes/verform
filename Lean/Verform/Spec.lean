import Verform.Model

namespace Verform.Spec

open Verform

def expectedPromptChunks (request : String) : Array String := #[
  "Act as Verform's formal-synthesis agent. Convert the natural-language request below into a Lean implementation with a compact human-reviewable Spec, an executable implementation, and an exact proof. Preserve Verform's Spec/Impl/Proof trust boundary and use the kernel assurance profile unless hostile generated code requires Comparator. Inspect the target repository, make the requested project-local changes, run all relevant Lean and Verform gates, and report the exact source-level theorem plus residual trust limits. Never claim that the generated specification proves correspondence to stakeholder intent.\n\nNatural-language request:\n",
  request
]

def expectedInvocation
    (workspaceRoot : System.FilePath)
    (request : String) : Codex.Invocation := {
  executable := "codex"
  arguments := #[
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
    "--cd", workspaceRoot.toString,
    "exec",
    "--ignore-user-config",
    "--ignore-rules",
    "--ephemeral",
    "--json",
    "--color", "never",
    "-"
  ]
  workingDirectory := workspaceRoot
  stdinChunks := expectedPromptChunks request
}

def Contract
    (candidate : System.FilePath → String → Codex.Invocation) : Prop :=
  ∀ workspaceRoot request,
    candidate workspaceRoot request = expectedInvocation workspaceRoot request

theorem contractSatisfiable : ∃ candidate, Contract candidate :=
  ⟨expectedInvocation, by intro workspaceRoot request; rfl⟩

end Verform.Spec
