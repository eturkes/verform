# Verform project memory

## Purpose

Self-hosting Lean formal-synthesis harness. Natural-language request → subscription-backed Codex
generation → unverified candidate → human review → explicit exact-contract verification. A generated contract is a review candidate;
human acceptance of its semantics precedes any intent claim. Implementation/proof volume stays
outside the declared review surface.

## Stack

- Lean 4.32.2 only; declarative Lake package; no external Lake dependencies.
- Source: `Lean/Verform/`; tests: `Lean/VerformTests/`; executable:
  `.lake/build/bin/verform`.
- Pure-Lean SHA-256, bundled `Lake.Toml` + `Lean.Json`, `IO.Process` + GNU `timeout` adapters.
- Codex CLI through ChatGPT subscription: explicit OpenAI provider, `gpt-5.6-sol`, `max`,
  `workspace-write`, ignored user config, ephemeral JSONL, stdin prompt; API-key environment
  removed; project `.codex` controls and optional extension/tool surfaces disabled.
- Profiles: `kernel` for non-hostile generated proofs; `comparator` for hostile solutions.

## Durable invariants

- Manifest parser fails on unknown keys, unsafe/duplicate values, invalid profile fields, and
  denied logical assumptions.
- Discover every non-hidden `.lean` file below one module root; no omission globs.
- Require reviewed `lakefile.toml`, `lean-toolchain`, strict Lake manifest 1.2.0, and pinned Git
  dependency revisions; reject build overrides and symlinked inputs.
- Lean's parser/environment establish trusted imports, declaration origins, exact theorem shape,
  runtime closure, and logical-dependency closure; raw spelling scan is defense in depth.
- Kernel obligations bind `declaration : contract implementation`, audit total/transparent/safe
  executable closure, then run `leanchecker --fresh`.
- Comparator requires reviewed Challenge, unreviewed Solution, theorem-to-definition references,
  sandbox comparison, and nanoda replay.
- Verify a fresh hashed snapshot; hash-check both snapshot and original inputs again before
  success.
- Attestation is deterministic unsigned drift evidence. It is not actor or machine provenance.

## Self-hosted claim

`Verform.Proof.codexInvocation_correct : Verform.Spec.Contract
Verform.Agent.Plan.codexInvocation`, kernel profile, no logical assumptions. It binds exact routing;
including the synthesis instruction template; it excludes process/network/service behavior,
filesystem effects, generated semantics, native
artifacts, and prompt-to-contract correspondence.

## Routine validation

```bash
lake build
lake test
.lake/build/bin/verform check .
.lake/build/bin/verform attest .
.lake/build/bin/verform status .
scripts/verify-templates.sh
```

Keep `docs/design.md`, `docs/manifest.md`, scaffolds, tests, CI, and the root attestation aligned
whenever schema, routing, or trust semantics change.
