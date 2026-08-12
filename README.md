# Verform

Verform is a self-hosting Lean 4 formal-synthesis harness. Its primary interface is a natural-
language request: Verform routes the request to authenticated Codex with `gpt-5.6-sol` at `max`
reasoning and lets the agent build a Lean `Spec` / executable / proof. Codex may try Lean gates
inside its workspace sandbox; Verform returns the result as an independently unverified candidate.
After reviewing the compact contract and build controls, you explicitly run the formal gates.

```text
request ──▶ Codex gpt-5.6-sol/max ──▶ UNVERIFIED Spec + Impl + Proof
                                             │ human semantic review
                                             ▼
                       fresh snapshot + exact theorem binding
                                             │
                       Lean kernel + leanchecker replay ──▶ result
```

The formal result means the generated executable satisfies its declared Lean contract. It does
not mean that contract captures the natural-language request; inspect the generated review packet
before accepting that semantic correspondence.

## Build and run

Prerequisites:

- Lean/Lake via `elan`; the repository pins `leanprover/lean4:v4.32.2`.
- GNU `timeout`, util-linux `unshare`/`setpriv`, enabled unprivileged user namespaces, and POSIX
  `sh` for bounded child-process trees, parent-death cancellation, and output capture.
- An existing target directory inside a Git worktree; `verform init` does not create Git metadata.
- Codex CLI authenticated through ChatGPT: `codex login status` must report
  `Logged in using ChatGPT`.

```bash
lake build
.lake/build/bin/verform 'Implement a verified bounded queue with enqueue and dequeue'
```

Optional user-local installation:

```bash
install -m 0755 .lake/build/bin/verform ~/.local/bin/verform
verform 'Implement a verified parser for length-prefixed byte frames'
```

The default and `synth` forms are equivalent:

```bash
verform '<request>'
verform synth --path ./target '<request>'
```

The subscription adapter always supplies these settings directly to Codex:

- model = `gpt-5.6-sol`;
- provider = OpenAI;
- reasoning effort = `max`;
- service tier = `default`;
- sandbox = `workspace-write`;
- approval policy = `never`;
- ephemeral JSONL session;
- user `config.toml` ignored while ChatGPT auth storage remains available;
- project `.codex` controls rejected; execpolicy `.rules`, apps, browser/computer tools, hooks,
  multi-agent, and plugins disabled;
- prompt transport = stdin.

API-key environment variables are removed for the Codex child. A ChatGPT-login preflight plus the
explicit OpenAI provider and ignored user config make the signed-in subscription the intended
credential path. Authentication and service behavior remain runtime facts, not theorem content.
Codex output is untrusted. Codex may execute project code inside its constrained synthesis
workspace, but the outer Verform process does not execute it. `verform review` is read-only; only a
later explicit `verform check` runs the accepted project's Lean/build code outside that synthesis
sandbox.

## Explicit lifecycle

Natural-language synthesis stops before the executable lifecycle:

```bash
verform init demo --name demo --shape result
verform review demo  # read-only semantic review
verform check demo   # explicit execution after acceptance
verform attest demo
verform status demo
```

Contract shapes:

- `pure` — total `I → O` refinement;
- `result` — `I → Except E O`, including success/error soundness and completeness;
- `machine` — deterministic one-step transition refinement, liftable to traces.

`--assurance comparator` scaffolds a reviewed Challenge and unreviewed Solution for hostile proof
inputs. Certification additionally requires official Comparator, landrun, compatible
`lean4export`, nanoda, user systemd, and a dedicated unprivileged secret-free checker host.

## Assurance pipeline

- **Strict manifest** — bundled `Lake.Toml` parser; unknown keys, unsafe paths, duplicates,
  incompatible profiles, and denied logical assumptions fail closed.
- **Review boundary** — explicit trusted files, nonblank-line budget, pure-Lean SHA-256 packet.
- **Locked controls** — declarative `lakefile.toml`, strict Lake manifest 1.2.0, pinned Lean
  4.32.2, Git-only dependencies at full revisions, no package overrides.
- **Closed semantics** — Lean's module parser rejects reviewed local imports into unreviewed code;
  the elaborated contract dependency closure is audited again.
- **Exact roots** — the named theorem must elaborate exactly to `Contract Implementation`, with
  configured origins and no wrapper proposition.
- **Runtime integrity** — local executable dependencies must be total, safe, transparent,
  computable Lean definitions without foreign/runtime substitutions.
- **Fresh checking** — hashed inputs enter a new temporary tree; Lake performs a cache-free build,
  exact logical-dependency closure is enforced, then `leanchecker --fresh` replays the module.
- **Two-tree stability** — both the isolated snapshot and original inputs are rehashed after all
  prover and supplementary work.
- **Drift record** — `attest` atomically writes deterministic `verform.lock.json`; `status`
  compares hashes without invoking Lean.

## Self-hosting theorem

The repository dogfoods kernel assurance:

```lean
Verform.Proof.codexInvocation_correct :
  Verform.Spec.Contract Verform.Agent.Plan.codexInvocation
```

The reviewed contract binds the exact formal-synthesis instruction template, Codex executable,
OpenAI provider, model, reasoning effort, service tier, workspace, sandbox, approval mode, ignored
user config and execpolicy `.rules`, disabled extension surfaces, ephemeral JSONL mode, and ordered
stdin chunks. The theorem has no logical assumptions. Joining/writing those chunks, process
execution, subscription service behavior, Codex output, filesystem effects, compiler/code
generation, and prompt interpretation are outside this pure theorem and remain explicit trusted or
independently checked layers.

## Threat models and limits

| Profile | Generated input model | Machine-enforced result | Residual trust |
| --- | --- | --- | --- |
| `kernel` | Large or mistaken, non-hostile | Fresh build; exact roots/origins; local semantic/runtime closure; logical policy; fresh replay | Project elaboration, Lean/Lake, dependencies, OS/hardware |
| `comparator` | Potentially hostile solution | Reviewed challenge binding; sandbox comparison; Lean + nanoda replay | Challenge, Comparator/sandbox/checkers, OS/hardware |

Verform does not verify compiler/codegen artifacts, unmodeled IO or concurrency, resource bounds,
dependency/tool provenance, absolute sandbox soundness, actor identity, or the specification's
correspondence to stakeholder intent. A lock is an unsigned local drift record, not a signature.

## Development

```bash
lake build
lake test
.lake/build/bin/verform check .
.lake/build/bin/verform attest .
.lake/build/bin/verform status .
scripts/verify-templates.sh
```

See the [manifest reference](docs/manifest.md), [trust model](docs/design.md), and
[agent workflow](.agents/skills/verform-workflow/SKILL.md).

The former Python implementation remains as a compatibility reference packaged only as
`verform-python-legacy`; it no longer installs the canonical `verform` command.
