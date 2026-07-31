# Verform roadmap

## Objective

Ship a domain-general, Lean-first formal-verification-driven development harness inspired by `verified-3d-mesh-intersection`: minimize the human-reviewed contract surface; treat implementation + proof as untrusted; let Lean certify exact conformance; make trust assumptions machine-auditable.

## Success criteria

- One manifest declares trusted files, review budget, Lean source roots, forbidden escape hatches, exact proof obligations, allowed axioms, and supplementary checks.
- `verform check` validates configuration/path safety, closed trusted imports, forbidden Lean constructs, proof build, exact obligation types, axiom dependencies, and configured checks.
- `verform attest` records a deterministic proof/review attestation; `verform status` detects trusted-surface or policy drift without invoking the prover.
- `verform init` scaffolds a compiling Lean project with separated `Spec` / `Impl` / `Proof` layers and an example contract.
- CLI/library behavior has unit + integration coverage; the repository dogfoods the workflow against a real pinned Lean toolchain.
- Documentation states the trust boundary and guarantee limits precisely; CI reproduces kernel gates and Comparator template checks, while an installed-stack integration run covers Comparator.

## Work

- [x] Reference + ecosystem analysis
- [x] Architecture + threat model
- [x] Python package + CLI
- [x] Lean adapter + lexical/import policy
- [x] Scaffolding template + dogfood example
- [x] Tests + CI + docs
- [x] Real-toolchain verification + adversarial review
- [x] Cleanup + scoped commit
