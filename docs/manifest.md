# `verform.toml` reference

Verform accepts manifest format 1 and Lean 4 only. Parsing is strict: unknown keys fail, arrays
reject duplicates, and paths must be project-relative without `..` or glob syntax. In kernel
mode, prefer an explicit empty axiom list; omitting it permits Lean's standard classical axioms.

## Kernel example

```toml
manifest_version = 1

[project]
name = "verified-counter"
prover = "lean4"

[review]
files = [
  "VerifiedCounter/Spec.lean",
  "lakefile.toml",
  "lean-toolchain",
  "lake-manifest.json",
]
max_code_lines = 80

[lean]
assurance = "kernel"
module_root = "."
evidence_files = ["lean-toolchain", "lakefile.toml"]
timeout_seconds = 600

[[obligations]]
name = "implementation-correct"
module = "VerifiedCounter.Proof"
declaration = "VerifiedCounter.Proof.implementation_correct"
contract = "VerifiedCounter.Spec.Contract"
implementation = "VerifiedCounter.Impl.run"
allowed_axioms = []

[[checks]]
name = "smoke"
command = ["./scripts/smoke"]
timeout_seconds = 300
```

The declared theorem must have the exact elaborated type:

```lean
VerifiedCounter.Spec.Contract VerifiedCounter.Impl.run
```

## Root tables

| Key | Required | Meaning |
| --- | --- | --- |
| `manifest_version` | yes | Integer `1`. |
| `[project]` | yes | Project identity and prover. |
| `[review]` | yes | Human-reviewed files and Lean line budget. |
| `[lean]` | yes | Assurance profile, source root, extra inputs, timeout. |
| `[[obligations]]` | kernel | One or more exact theorem bindings. Forbidden in Comparator mode. |
| `[comparator]` | comparator | Challenge/solution declaration sets and axiom policy. Forbidden in kernel mode. |
| `[[checks]]` | no | Post-proof commands. Kernel only. |

### `[project]`

| Key | Required/default | Constraint |
| --- | --- | --- |
| `name` | required | Letters, digits, `.`, `_`, `-`; first character alphanumeric. |
| `prover` | `"lean4"` | Only `"lean4"` is accepted. |

### `[review]`

| Key | Required/default | Constraint |
| --- | --- | --- |
| `files` | required | Nonempty, unique project-relative regular files; no symlinks. |
| `max_code_lines` | `200` | Positive integer; counts nonblank lines in reviewed `.lean` files under `module_root`. |

`files` must include the contract owner for each kernel obligation, or the challenge module for
Comparator. It must also include `lakefile.toml`, `lean-toolchain`, `lake-manifest.json`, and every
`lean.evidence_files` entry. Do not include kernel proof/implementation modules or the Comparator
solution. `verform.toml` is always hashed and rendered in the review packet; it need not list
itself.

### `[lean]`

| Key | Required/default | Constraint |
| --- | --- | --- |
| `assurance` | `"kernel"` | `"kernel"` or `"comparator"`. |
| `module_root` | `"."` | Project-relative directory containing the complete local Lean module tree. |
| `evidence_files` | `[]` | Additional unique project-relative regular files to review, hash, and copy into the snapshot. |
| `timeout_seconds` | `600` | Positive per-command timeout in seconds. |

Source discovery recursively includes every non-hidden `*.lean` below `module_root`; no source
glob or opt-out exists. A path component beginning with `.` is excluded. Module paths must map to
dot-separated ASCII Lean identifiers, and source symlinks are rejected.

Use `evidence_files` for every non-Lean input whose bytes affect verification. Declaring a file
does not prove that a tool actually consumed it, and undeclared build-time inputs outside the
enforced Lake controls remain a trust risk.

### `[[obligations]]`

Kernel mode requires at least one obligation. Obligation names must be unique.

| Key | Required/default | Constraint |
| --- | --- | --- |
| `name` | required | Stable report identifier. |
| `module` | required | Local unreviewed module imported for the check. |
| `declaration` | required | Theorem whose environment origin must be exactly `module`. |
| `contract` | required | Unary predicate whose local owner must be reviewed. |
| `implementation` | required | Executable definition whose local owner must be unreviewed and differ from `contract`. |
| `allowed_axioms` | `[`<br>`"Classical.choice",`<br>`"Quot.sound",`<br>`"propext"`<br>`]` | Exact superset permitted for the theorem's observed axiom closure. Use `[]` for an axiom-free obligation. |

Names use a constrained ASCII qualified-name spelling and are resolved authoritatively in the
Lean environment. Verform checks exact declaration origins and requires the theorem's full type
to be the single application `contract implementation`. Local definitions reachable from the
contract and implementation are audited for review ownership, total/safe status, opacity,
axioms, `extern`, and `implemented_by` replacements.

These axioms are always denied and cannot be allowlisted:

- `sorryAx`
- `Lean.trustCompiler`
- `Lean.ofReduceBool`

### `[[checks]]`

| Key | Required/default | Constraint |
| --- | --- | --- |
| `name` | required | Unique report identifier. |
| `command` | required | Nonempty argv array; executed directly without a shell. |
| `timeout_seconds` | `300` | Positive per-command timeout. |

Checks execute in the fresh snapshot after every kernel obligation and fresh checker replay
passes. They are unsandboxed and cannot strengthen the formal claim unless their semantics are
separately justified. Comparator mode rejects all `[[checks]]` entries.

## Comparator example

```toml
manifest_version = 1

[project]
name = "verified-counter"
prover = "lean4"

[review]
files = [
  "VerifiedCounter/Spec.lean",
  "VerifiedCounter/Challenge.lean",
  "lakefile.toml",
  "lean-toolchain",
  "lake-manifest.json",
]
max_code_lines = 100

[lean]
assurance = "comparator"
module_root = "."
evidence_files = ["lean-toolchain", "lakefile.toml"]
timeout_seconds = 1200

[comparator]
challenge_module = "VerifiedCounter.Challenge"
solution_module = "VerifiedCounter.Solution"
theorem_names = ["VerifiedCounter.implementation_correct"]
definition_names = ["VerifiedCounter.run"]
permitted_axioms = ["Classical.choice", "Quot.sound", "propext"]
```

| Key | Required/default | Constraint |
| --- | --- | --- |
| `challenge_module` | required | Reviewed local module containing placeholder declarations. |
| `solution_module` | required | Unreviewed local module containing candidate declarations. |
| `theorem_names` | required | Nonempty unique theorem names originating in the challenge. |
| `definition_names` | required | Nonempty unique executable definition names originating in the challenge. Every entry must be directly referenced by a configured theorem type. |
| `permitted_axioms` | standard three above | Comparator-wide axiom allowance; must include all three standard prelude axioms because mandatory nanoda replay rejects undeclared prelude axioms. Hard-denied axioms remain forbidden. |

The challenge may contain raw `sorry`; no other source receives that exemption. The configuration
is passed to official Comparator with `enable_nanoda = true`. This setting is mandatory and is
not a manifest key, so `enable_nanoda = false` fails as an unknown key. Current nanoda rejects
even unused prelude axiom declarations unless allowlisted, so Comparator manifests must permit
`Classical.choice`, `Quot.sound`, and `propext`; Comparator still checks that solution declarations
use no axioms beyond that set. Comparator mode requires Linux and trusted `systemd-run`,
`comparator`, `landrun`, compatible `lean4export`, and current `nanoda_bin` replay available to
Comparator (or the corresponding `COMPARATOR_*` executable overrides).

## Required Lake controls

Every project must contain reviewed, nonsymlinked root files:

```text
lean-toolchain       exactly: leanprover/lean4:v4.32.2
lakefile.toml        valid TOML with a nonempty package name
lake-manifest.json   exact accepted manifest 1.2.0 schema
```

`lakefile.lean` is always rejected. Declarative `lakefile.toml` is not otherwise normalized or
semantically restricted; reviewers must examine every build option. `.lake/package-overrides.json`
is rejected because it can replace locked packages.

The lock root must contain exactly:

```json
{
  "version": "1.2.0",
  "fixedToolchain": false,
  "name": "«package-name»",
  "lakeDir": ".lake",
  "packagesDir": ".lake/packages",
  "packages": []
}
```

`fixedToolchain` may be either boolean. `name` must match the `lakefile.toml` package name, with
or without Lean guillemets. Directory values are fixed as shown. Unknown or missing root keys
fail.

Each dependency object must contain exactly these keys:

```json
{
  "type": "git",
  "name": "dependency",
  "scope": "",
  "inherited": false,
  "configFile": "lakefile.toml",
  "manifestFile": null,
  "url": "https://host/repository.git",
  "rev": "0123456789abcdef0123456789abcdef01234567",
  "inputRev": "main",
  "subDir": null
}
```

Rules: `name` is nonempty and unique; `scope` is a string and may be empty; `configFile` and `url`
are nonempty strings; `manifestFile` is a relative nonempty string or null; `inherited` is boolean;
`type` is `"git"`; `rev` is a full lowercase 40-hex revision; `inputRev` is a string or null;
`configFile`, non-null `manifestFile`, and non-null `subDir` are relative and contain no `..`.
Path dependencies and extra/missing fields fail.

This validates lock structure, not dependency provenance. Verform does not authenticate URLs,
fetches, owners, Git objects, transitive code, or signatures; dependency source bytes are not
part of the root input hash map.

## CLI lifecycle

```bash
verform review  .   # render manifest + reviewed files + SHA-256 digests
verform check   .   # run static, build, environment, and replay gates
verform attest  .   # rerun check; atomically write verform.lock.json on success
verform status  .   # static checks + unsigned local hash-drift comparison; no Lean
```

`verform.lock.json` is a deterministic local record, not a signature. Authenticate it with an
external signing or CI provenance mechanism before treating it as evidence from another actor or
machine.
