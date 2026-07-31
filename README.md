# Verform

Verform is a Lean-first harness for formal-verification-driven development: humans review a
small behavioral contract; agents own the implementation and proof; independent gates confirm
that the declared executable root satisfies that exact contract.

It generalizes the architecture demonstrated by
[`verified-3d-mesh-intersection`](https://github.com/schildep/verified-3d-mesh-intersection)
without copying its geometry domain. “General purpose” currently means reusable pure,
checked-result, and state-machine kernels. Unmodeled IO, concurrency, FFI, resource bounds, and
native artifacts remain outside the theorem.

## Assurance pipeline

```text
reviewed Spec + Lake controls ──▶ Contract(executable)
          │                              ▲
          │ Lean-parsed import closure   │ exact theorem type + origins
          ▼                              │
     review packet               agent-owned Impl + Proof
                                           │
                fresh snapshot + clean build + environment audit
                                           │
                            axiom closure + leanchecker replay
```

- **Review boundary** — explicit files, nonblank-line budget, SHA-256 packet.
- **Closed semantics** — Lean’s own header parser rejects reviewed files importing unreviewed
  local modules; the elaborated contract dependency closure is audited again.
- **Exact roots** — every kernel obligation separately names its theorem, contract, and executable;
  the elaborated environment must report their configured origin modules and the theorem type must
  be exactly `Contract executable`.
- **Runtime integrity** — every local executable dependency is traversed after elaboration. Local
  axioms, opaque/unsafe/partial/noncomputable definitions, FFI, and `implemented_by` replacements
  fail. A raw forbidden-spelling scan—including comments/literals—is conservative defense in depth.
- **Fresh checking** — only hashed, discovered root inputs enter a new temporary workspace, and
  copied bytes are rehashed before use. Lake runs with
  `--rehash --reconfigure --no-cache --wfail`; the selected modules then pass an exact axiom
  allowlist and `leanchecker --fresh`.
- **Locked controls** — profile `VERFORM-LAKE-CLOSURE-v1` pins Lean 4.32.2, requires declarative
  `lakefile.toml`, strict Lake manifest 1.2.0, and full-revision Git dependencies. Path dependencies,
  package overrides, cached artifacts, and Lean/Lake environment overrides fail or are removed.
- **Adversarial profile** — official
  [Comparator](https://github.com/leanprover/comparator) orchestration checks a reviewed Challenge
  against a potentially hostile Solution in its sandbox. At least one semantic theorem must
  reference every configured executable; nanoda replay is mandatory.
- **Drift record** — `attest` atomically writes deterministic `verform.lock.json`; `status` compares
  hashes without Lean. The file is unsigned and establishes local checked-state continuity—not
  author identity, review approval, dependency provenance, or supply-chain provenance.

## Quick start

Prerequisites: Python 3.11+, [uv](https://docs.astral.sh/uv/), and
[elan](https://lean-lang.org/doc/reference/latest/Build-Tools-and-Distribution/Managing-Toolchains-with-Elan/).

```bash
uv sync --locked
uv run verform init demo --name demo --shape result
uv run verform review demo
uv run verform check demo
uv run verform attest demo
uv run verform status demo
```

Contract shapes:

- `pure` — total `I → O` refinement;
- `result` — `I → Except E O` with success/error soundness **and completeness**;
- `machine` — deterministic one-step transition refinement, liftable to traces.

Use `--assurance comparator` to scaffold reviewed `Spec`/`Challenge` modules and an agent-owned
`Solution`. Certification additionally requires official `comparator`, `landrun`, compatible
`lean4export`, and a current `nanoda_bin` executable (or `COMPARATOR_NANODA` override). Run
Comparator only from a clean, unprivileged Linux checker host. Mandatory nanoda replay requires Comparator's standard prelude allowance
(`Classical.choice`, `Quot.sound`, and `propext`).

## Threat models and limits

| Profile | Inputs allowed to be hostile | Machine-enforced result | Still trusted / unproved |
|---|---|---|---|
| `kernel` | None; agent output may be huge or mistaken, but must not attack the host | Fresh source build; exact contract/root/origin; local semantic/runtime closure; axiom policy; fresh Lean replay | Project metaprograms during build, Lean/Lake/compiler, pinned dependencies, OS/hardware |
| `comparator` | Solution/proof | Reviewed challenge binding; sandboxed declaration comparison; axiom policy; Lean + mandatory nanoda replay | Spec/Challenge/Lake controls, Comparator/sandbox/checkers, dependency semantics, OS/hardware |

Kernel mode’s temporary workspace is isolation from stale files, **not a security sandbox**.
Potentially malicious Lean can execute code during elaboration; use Comparator mode. Lean’s
[validation guide](https://lean-lang.org/doc/reference/latest/ValidatingProofs/) makes the same
distinction. Lean 4.32.2 is pinned because its release fixes a soundness issue that could affect
Comparator; checker diversity reduces correlated failures but never makes kernels infallible.
See the [Lean 4.32.2 release note](https://lean-lang.org/doc/reference/latest/releases/v4.32.2/).

Lake’s manifest records dependency resolution but is not a cryptographic build attestation.
Verform starts without `.lake`, rejects mutable path dependencies/overrides, disables artifact
caches, and binds root inputs; Git hosts, SHA-1 revision identity, downloaded dependency bytes,
dependency configuration, the toolchain distribution, and the host remain trusted. Native output
additionally trusts Lean’s compiler/runtime, C toolchain, linked libraries, and adapters.

Comparator's hostile-build sandbox is an integrity boundary, not a confidentiality boundary: the
official policy grants read access to the host filesystem. Use a checker account/host containing
no secrets. Repository CI exercises the kernel profile and Comparator template elaboration; a full
Comparator/landrun/nanoda run requires the separately installed trusted stack.

## Development

```bash
uv sync --locked
uv run ruff check .
uv run mypy
uv run pytest --cov=verform --cov-report=term-missing
uv build
scripts/verify-templates.sh
```

See the [manifest reference](docs/manifest.md), [design and trust model](docs/design.md),
[agent workflow](.agents/skills/verform-workflow/SKILL.md), and
[checked-result example](examples/verified_counter/README.md).
