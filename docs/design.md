# Design and trust model

Verform makes one narrow claim: a named Lean theorem establishes a declared contract for a named
executable definition, under an explicit logical-assumption policy. It reduces the review
surface; it does not perform semantic review of the specification or turn source proofs into a
verified native application.

Verform itself is a Lean 4 executable. Its natural-language layer is an untrusted generator in
front of this claim: authenticated Codex proposes specifications, implementations, and proofs and
may try them inside its synthesis sandbox. Human semantic review precedes a separate explicit
invocation of the deterministic verification pipeline outside that sandbox.

## Natural-language synthesis boundary

```text
natural-language request
        │
        ▼
Codex CLI via ChatGPT subscription
gpt-5.6-sol / max / workspace-write
        │ untrusted filesystem changes + prose
        ▼
UNVERIFIED manifest + declared review surface + Impl + Proof
        │ explicit human review + check invocation
        ▼
independent formal pipeline described below
```

The self-hosting theorem
`Verform.Proof.codexInvocation_correct : Verform.Spec.Contract
Verform.Agent.Plan.codexInvocation` binds the pure routing decision: formal-synthesis instruction
template, executable, model, reasoning effort, service tier, OpenAI provider, workspace, sandbox,
approval policy, ignored user config and execpolicy `.rules`, disabled extension surfaces,
JSONL/ephemeral mode, and the ordered stdin chunks. It has no logical assumptions. Chunk
joining/writing belongs to the runtime adapter. The theorem does not prove Codex identity,
subscription
entitlement, network behavior, filesystem effects, generated-code safety, or prompt-to-contract
correspondence. The runtime checks ChatGPT login status, rejects project `.codex` controls,
ignores user config and execpolicy `.rules`, disables extension/tool surfaces, explicitly selects
the OpenAI provider, removes API-key environment variables, and still treats all generated output
as untrusted. The outer synthesis adapter never independently elaborates Lean or runs generated
supplementary commands; it renders the next review/check commands and exits.

## Verification boundary

```text
human-reviewed                     machine-checked, not human-reviewed
-------------------------------    --------------------------------------
verform.toml                       implementation / solution
contract-bearing Lean modules      proof modules
lakefile.toml                      generated `.olean` files
lean-toolchain                     temporary checker state
lake-manifest.json
declared evidence files
         │
         ├── SHA-256 + review budget
         ├── trusted-import closure
         └── exact symbol boundary ──▶ Contract Implementation
```

The contract is the authority for behavior. A weak, inconsistent, incomplete, or
misinterpreted contract can be proved and still permit an unacceptable program. Review must
cover contract meaning, domain assumptions, completeness, and non-vacuity.

## Pipeline

`verform check` fails closed through these stages:

1. **Strict manifest** — unknown keys, unsafe paths, duplicate names, incompatible profile
   fields, and hard-denied axiom allowances are rejected.
2. **Source inventory** — every non-hidden `*.lean` file below `lean.module_root` is discovered;
   symlinks, invalid module paths, and duplicate module names are rejected.
3. **Build closure** — the root must use `lakefile.toml`, `lean-toolchain` must contain exactly
   `leanprover/lean4:v4.32.2`, and `lake-manifest.json` must use the accepted manifest 1.2.0 schema
   with Git-only dependencies pinned by full lowercase 40-hex revisions. `lakefile.lean` and
   `.lake/package-overrides.json` are rejected.
4. **Defense-in-depth source policy** — raw source is scanned for forbidden identifier
   spellings: `admit`, `axiom`, `constant`, `csimp`, `extern`, `implemented_by`, `opaque`,
   `partial`, `partial_fixpoint`, `skipKernelTC`, `sorry`, and `unsafe`. The scan includes
   comments and literals, so false positives are intentional. Comparator's reviewed challenge
   alone may contain `sorry`; Comparator replaces those declarations from the solution.
5. **Review boundary** — required build controls and declared evidence are reviewed and hashed;
   reviewed Lean nonblank lines must fit the configured budget. Contracts/challenges must be
   reviewed, while implementations, proofs, and solutions must remain outside that surface.
6. **Fresh snapshot** — Verform copies the manifest, all discovered Lean sources, build inputs,
   evidence, and review files into a new temporary directory. It copies neither `.lake` nor Git
   state. Every copy is rehashed against the initial inventory before prover work starts; final
   hash comparisons reject mutation of either snapshot or original verification inputs during a
   successful run.
7. **Pinned tool observation** — `lake env lean --version` must report exactly 4.32.2. Header and
   environment checks use the same Lake-selected Lean. This checks the tool's self-reported
   version, not its binary hash or provenance.
8. **Authoritative trusted-header audit** — Lean 4.32.2's own module parser reads every reviewed
   Lean header. A reviewed module may import an external module or another reviewed local module;
   it may not import an unreviewed local module. This audit, not an approximate text parser,
   establishes the local trusted-import boundary.
9. **Profile gates** — the kernel or Comparator pipeline below runs in the snapshot.
10. **Input stability** — snapshot and original input hashes must still match the pre-check
    inventory.

The raw forbidden-spelling pass catches obvious escape hatches early and uniformly, including
text that a lexer might otherwise discard. It is deliberately not the soundness argument.
Lean's parser, elaborator environment, kernel, declaration metadata, and checker replays are the
authoritative checks.

## Kernel profile

Use `kernel` for large or frequently regenerated implementation/proof code produced by a
non-hostile agent. It catches ordinary implementation, theorem, tactic, and wiring errors; it is
not a containment system for malicious Lean metaprograms.

For each obligation, the manifest names four things:

- `module`: the unreviewed proof module to import;
- `declaration`: the theorem that carries the proof;
- `contract`: the reviewed unary predicate;
- `implementation`: the unreviewed executable definition supplied to that predicate.

After a cache-free `lake --rehash --reconfigure --no-cache build --wfail`, an environment audit
checks:

- the declaration originates in exactly `module` and is a theorem;
- the contract and implementation originate in their longest matching local owner modules;
- the theorem's top-level metadata-stripped type is exactly `contract implementation`, with no
  wrapper proposition or hidden argument;
- every local declaration reachable through the contract's type and value belongs to a reviewed
  module;
- every reachable local contract/implementation declaration is not an axiom or opaque
  definition and has no `implemented_by` or `extern` runtime replacement; executable definitions
  must be safe and computable, and inductives, constructors, and recursors must not be unsafe.

Lean then computes the theorem's axiom closure. It must be a subset of `allowed_axioms`;
`sorryAx`, `Lean.trustCompiler`, and `Lean.ofReduceBool` can never be allowed. Finally,
`leanchecker --fresh <module>` reloads and checks each obligation module in a fresh environment.
Configured supplementary checks run only after all formal gates pass. They are ordinary,
unsandboxed argv executions and therefore belong only in the non-hostile kernel profile.

## Comparator profile

Use `comparator` when the solution may actively exploit elaboration, metaprogramming, or build
behavior. It requires Linux plus trusted `systemd-run` and a working official Comparator stack
with `landrun`, compatible `lean4export`, and `nanoda_bin` replay available through the checking
environment (or explicit `COMPARATOR_*` executable overrides).

The reviewed challenge contains placeholder definitions and theorems; the unreviewed solution
contains corresponding declarations. Before invoking Comparator, Verform builds only the
reviewed challenge and uses the Lean environment to confirm that:

- every configured challenge theorem and definition originates in the exact challenge module;
- theorem entries are theorems and definition entries are definitions;
- every configured executable definition is directly referenced by at least one configured
  semantic theorem's type.

Verform then emits an ephemeral Comparator configuration, forces `enable_nanoda = true`, and
invokes Comparator through user `systemd-run`, passes a controlled tool `PATH`, and denies
`AF_UNIX` with `RestrictAddressFamilies=~AF_UNIX` as required by Comparator's current Landlock
defense. Comparator delegates hostile solution work to its landrun sandbox. Comparator is
responsible for exact challenge/solution declaration matching, the permitted-axiom policy,
sandboxed solution processing, Lean replay, and independent nanoda replay. Nanoda cannot be
disabled in `verform.toml`. Its current strict declaration check requires the standard prelude
allowance (`Classical.choice`, `Quot.sound`, and `propext`) even when the configured declarations
do not use those axioms. Supplementary commands are forbidden in this profile.

Exact declaration identity does not make a theorem meaningful. Human review of the challenge
must establish that every listed theorem constrains every listed executable strongly enough for
the intended use.

Comparator/landrun grants hostile build processes read access to the host filesystem. The sandbox
protects integrity and limits writes/network; it does not protect local secrets. Run it under a
dedicated unprivileged checker identity on a secret-free host. The runtime limit terminates the
transient systemd unit; the output-size check runs after capture and is not a memory bound.
Systemd, Landlock, the OS, and hardware remain trusted.

## Assurance comparison

| Property | `kernel` | `comparator` |
| --- | --- | --- |
| Intended solution | Large, non-hostile | Potentially malicious |
| Reviewed semantics | Contract owner modules | Spec + challenge modules |
| Executable binding | Exact theorem type + environment origins | Challenge theorem references + Comparator identity |
| Axiom policy | Per obligation | Comparator-wide |
| Replay | `leanchecker --fresh` | Lean + mandatory nanoda via Comparator |
| Build isolation | Fresh filesystem snapshot | Fresh snapshot + Comparator/landrun boundary |
| Extra commands | Allowed after proof gates | Forbidden |
| Main residual risk | Malicious elaboration/build code | Checker/sandbox/TCB compromise |

## Attestation and drift

`verform attest` reruns the complete selected profile and writes `verform.lock.json` only when
every gate succeeds. The JSON binds Verform version/policy labels, reported Lean version, gate results,
review hashes, every verification-input hash, obligation evidence, and Comparator configuration.
Writing is atomic within the destination directory.

`verform status` reruns static analysis and compares identity and SHA-256 maps without invoking
Lean. It answers only: “does this local tree match this local successful-run record?” The lock is
unsigned and unauthenticated. Anyone able to modify both the tree and lock can forge consistency;
the lock proves neither author identity, execution provenance, nor remote CI success. Add an
external signature or trusted CI provenance envelope when those properties matter.

## Trusted computing base and non-claims

The guarantee depends on the reviewed semantics and build controls, Verform's Lean executable,
Lean 4.32.2's parser/elaborator/kernel/checker, GNU `timeout`, util-linux PID/user namespaces and
parent-death signaling, Comparator/nanoda/landrun when selected, executable resolution through
`PATH`, the operating system, and hardware. Each command enters a fresh PID namespace; teardown bounds
descendants even if they create a new session. Captured output is size-checked only after command
completion. Hashes identify bytes; they do not authenticate their origin.

Verform does **not** establish:

- **Compiler or artifact correctness** — checked Lean source is not proof that native/codegen
  output, the C/LLVM backend, linker, runtime, packaging, or deployed binary preserves it.
- **Unmodeled effects** — IO, FFI, filesystem/network behavior, concurrency, nondeterminism,
  exceptions, allocation, timing, resource limits, and side channels are outside the claim unless
  represented in the reviewed model and theorem.
- **Dependency provenance** — the Lake lock permits only a URL plus pinned Git revision, but
  Verform neither authenticates the repository/operator nor hashes, reviews, or recursively
  audits fetched dependency sources. External declarations used by local code remain part of the
  TCB. URL transport and revision availability are not reproducibility guarantees.
- **Tool provenance** — the toolchain file and version output do not attest the Lean binary;
  Comparator-side tool names are likewise resolved from the local environment.
- **Generator/service correctness** — the Codex executable, ChatGPT authentication, model service,
  network, inference, and natural-language interpretation remain outside the Lean theorem.
- **Specification validity** — satisfiability witnesses help expose vacuity but cannot establish
  correspondence to stakeholder intent.
- **Absolute hostile-code containment** — sandboxing reduces exposure; its implementation, host
  configuration, kernel, and allowed interfaces remain trusted.

Treat the final theorem as a source-level mathematical result with an explicit TCB. Add separate
verified extraction, reproducible builds, artifact attestation, runtime validation, effect models,
and signed provenance according to the deployment claim.
