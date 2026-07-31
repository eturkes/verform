# Verform project memory

## Purpose

Domain-general formal-verification-driven development harness: humans review compact Lean
semantics; agents own implementation/proof volume; Verform proves the named executable root meets
the named contract and records exact local inputs.

## Stack

- Python 3.11+ stdlib CLI/package, managed with `uv`.
- Lean-only backend, pinned to `leanprover/lean4:v4.32.2`.
- Source: `src/verform/`; tests: `tests/`; dogfood: `examples/verified_counter/`.
- Profiles: `kernel` for non-hostile generated proofs; `comparator` for hostile solutions.

## Durable invariants

- Manifest parser fails on unknown keys and unsafe/duplicate values.
- Discover every non-hidden `.lean` file below one module root; no configurable omission globs.
- Require reviewed `lakefile.toml`, `lean-toolchain`, and strict manifest 1.2.0
  `lake-manifest.json`; accept only Git dependencies pinned by full lowercase revisions.
- Reject `lakefile.lean`, package overrides, symlinked inputs, and hard-denied axioms.
- Raw forbidden identifier spellings are defense in depth. Lean's parser/environment audits are
  authoritative for imports, declaration origins, exact theorem shape, safe runtime closure, and
  axiom dependencies.
- Kernel obligations bind `declaration : contract implementation`, reject noncomputable/runtime
  substitution roots, then run `leanchecker --fresh`.
- Comparator requires reviewed Challenge, unreviewed Solution, theorem-to-definition references,
  official sandboxed comparison, and mandatory nanoda replay.
- Verify from a fresh copied snapshot; validate every copied byte, then hash-check original inputs
  again before success. Resolve version/header/audit commands through the same `lake env lean`.
- Attestation writes only after a successful full check. Its lock is deterministic but unsigned
  and unauthenticated.

## Claim limits

Proofs cover reviewed source-level Lean propositions. Compiler/codegen artifacts, runtime and
unmodeled effects, dependency/tool provenance, specification validity, OS/hardware, and absolute
sandbox containment remain outside the guarantee.

## Routine validation

```bash
uv run ruff check .
uv run mypy
uv run pytest --cov
uv build
uv run verform check examples/verified_counter
uv run verform attest examples/verified_counter
uv run verform status examples/verified_counter
```

Keep `docs/design.md`, `docs/manifest.md`, scaffolds, tests, and the dogfood attestation aligned
whenever schema or trust semantics change.
