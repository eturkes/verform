---
name: verform-workflow
description: Use when creating, changing, reviewing, or certifying a Verform-managed Lean component, contract, implementation, proof, challenge, solution, manifest, review packet, or attestation.
---

# Verform workflow

Use Verform to keep human-reviewed semantics small and bind an exact executable Lean definition
to them. Read [design and trust model](../../../docs/design.md) and
[`verform.toml` reference](../../../docs/manifest.md) before changing a trust boundary.

## Choose the assurance profile

- `kernel` → implementation/proof is large or agent-generated but non-hostile. Lean build,
  environment audits, axiom closure, and `leanchecker --fresh` detect correctness failures.
- `comparator` → solution may exploit elaboration or metaprogramming. Require Linux, trusted
  Comparator/landrun tooling, and mandatory nanoda replay. Keep supplementary commands absent.

State which profile applies and keep claims within its threat model.

## Build the contract first

1. Put complete behavioral semantics in a small reviewed `Spec` module.
2. Define one unary contract over the executable root. Cover success and failure behavior,
   completeness/progress where relevant, and boundary cases.
3. Add a satisfiability or non-vacuity witness when practical.
4. Keep the contract closure inside reviewed local modules.
5. Put implementation and proof code outside `review.files`.

For kernel mode, declare the exact proof module, theorem, contract, and implementation in one or
more `[[obligations]]`. The theorem type must elaborate exactly to `Contract Implementation`.

For Comparator mode, review `Challenge`, keep `Solution` unreviewed, list at least one semantic
theorem and executable definition, and ensure every listed definition occurs directly in a listed
theorem type.

## Preserve verification closure

- Pin `lean-toolchain` to `leanprover/lean4:v4.32.2`.
- Use reviewed `lakefile.toml`; keep `lakefile.lean` absent.
- Commit a manifest 1.2.0 `lake-manifest.json` containing only Git dependencies pinned to full
  lowercase 40-hex revisions.
- Keep `.lake/package-overrides.json` absent.
- Add every verification-relevant non-Lean file to `lean.evidence_files` and `review.files`.
- Treat the raw forbidden spelling policy as defense in depth. Preserve authoritative Lean
  header/environment, origin, runtime-closure, axiom, and replay gates.
- Keep kernel `allowed_axioms = []` unless reviewed mathematics genuinely needs a standard axiom.
  Comparator's mandatory nanoda replay requires `permitted_axioms` to include
  `Classical.choice`, `Quot.sound`, and `propext`. Never permit `sorryAx`, `Lean.trustCompiler`, or
  `Lean.ofReduceBool`.

## Iterate

```bash
uv run verform review <project>
uv run verform check <project>
```

Review the rendered manifest and every included trusted file. A contract change requires renewed
human semantic review. An implementation/proof change requires a successful formal check but must
not enlarge the human review surface.

When a gate fails, fix the earliest cause. Keep the boundary intact; never move implementation or
proof code into reviewed files to satisfy a gate. Add focused regression coverage when changing
Verform itself.

## Certify and hand off

```bash
uv run verform attest <project>
uv run verform status <project>
```

Commit `verform.lock.json` beside the exact verified inputs. `status` is a Lean-free drift check.
The lock is unsigned local evidence: use external signatures or trusted CI provenance for actor,
machine, and run identity.

Report the exact source-level theorem and profile. Separately disclose that Verform does not
verify compiler/codegen artifacts, unmodeled IO/FFI/concurrency/resources, dependency provenance,
tool binary provenance, the specification's correspondence to intent, or absolute sandbox
soundness.
