# Verform roadmap

## Objective

Ship a self-hosting Lean implementation of Verform: preserve the verification lifecycle, make a
natural-language prompt the primary interface, and delegate synthesis to authenticated Codex
`gpt-5.6-sol` with `max` reasoning while retaining explicit formal gates.

## Success criteria

- Lean executable owns manifest parsing, static policy, verification orchestration, scaffolding,
  review packets, attestations, drift status, and presentation. The retained Python reference is
  renamed `verform-python-legacy` and exposes no canonical `verform` command.
- `verform '<natural-language request>'` launches Codex through the signed-in ChatGPT subscription
  with model/effort pinned to `gpt-5.6-sol`/`max`; legacy lifecycle subcommands remain available.
- A small reviewed Lean contract specifies the immutable synthesis-routing policy and is bound to
  the exact pure executable definition by an axiom-free theorem.
- Compatibility and adversarial tests cover fail-closed configuration, path/build boundaries,
  process failures, synthesis routing, templates, and the verified example.
- CI builds/tests the Lean package, dogfoods `check`/`attest`/`status`, and verifies generated
  templates; docs state source-level guarantees and Codex/IO/toolchain trust limits precisely.

## Work

- [x] Original Python architecture + threat model
- [x] Lean runtime/API feasibility + compatibility inventory
- [x] Reviewed synthesis-routing contract + satisfiability witness
- [x] Pure Lean model/config/policy core + proof
- [x] Lean IO runner/verifier/review/attestation/scaffolding adapters
- [x] Natural-language Codex subscription workflow
- [x] Lean unit/integration/adversarial tests + CI migration
- [x] Documentation + self-hosted attestation
- [x] Final cleanup + scoped commit
