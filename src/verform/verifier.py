"""Fresh-workspace formal verification pipeline for Lean projects."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import replace
from pathlib import Path

from verform.errors import ConfigError
from verform.model import Evidence, Gate, Manifest, Obligation, ObligationEvidence, Report
from verform.policy import StaticAnalysis, analyze, owner_module
from verform.runner import CommandResult, diagnostic, run

_AXIOM_MARKER = re.compile(r"(?m)^VERFORM_AXIOMS=(.*)$")
_LEAN_VERSION_PATTERN = re.compile(r"^Lean \(version ([^,)\s]+)")
_LEAN_VERSION = ("lake", "env", "lean", "--version")
_LEAN_HEADER_CHECK = ("lake", "env", "lean", "--stdin")
_LAKE_FRESH = (
    "lake",
    "--rehash",
    "--reconfigure",
    "--no-cache",
    "build",
)
_LEAN_BUILD_PREFIX = (*_LAKE_FRESH, "--wfail")
_LEAN_CHECK = ("lake", "env", "lean", "--stdin")
_LEAN_REPLAY = ("lake", "env", "leanchecker", "--fresh")


def _command_gate(name: str, result: CommandResult, success: str) -> Gate:
    if result.ok:
        return Gate(name, True, success)
    return Gate(name, False, f"command failed with exit {result.returncode}", diagnostic(result))


def _toolchain(manifest: Manifest) -> tuple[Gate, str]:
    result = run(
        _LEAN_VERSION,
        cwd=manifest.root,
        timeout_seconds=manifest.lean.timeout_seconds,
    )
    if not result.ok:
        return _command_gate("toolchain", result, ""), ""
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if not lines:
        return Gate("toolchain", False, "version command produced no output"), ""
    version = lines[0]
    match = _LEAN_VERSION_PATTERN.match(version)
    observed = match.group(1) if match is not None else ""
    if observed != "4.32.2":
        return Gate("toolchain", False, f"expected Lean 4.32.2; observed {version}"), version
    return Gate("toolchain", True, version), version


def _lean_string(value: str) -> str:
    hashes = ""
    while f'"{hashes}' in value:
        hashes += "#"
    return f'r{hashes}"{value}"{hashes}'


def _name_array(names: tuple[str, ...] | list[str]) -> str:
    return "#[" + ", ".join(f"`{name}" for name in names) + "]"


def _trusted_header_source(source_root: Path, analysis: StaticAnalysis) -> str:
    calls = "\n".join(
        "  auditHeader "
        f"{_lean_string(analysis.modules[module].relative_to(source_root).as_posix())} "
        "localModules trustedModules"
        for module in analysis.reviewed_modules
    )
    return f"""import Lean.Parser.Module
import Lean.Elab.Command

open Lean Elab Command

private def auditHeader
    (path : String) (localModules trustedModules : Array Name) : CommandElabM Unit := do
  let input ← IO.FS.readFile path
  let context := Parser.mkInputContext input path
  let (header, _, messages) ← Parser.parseHeader context
  if messages.hasErrors then
    throwError m!"cannot parse trusted header {{path}}"
  if let `(Parser.Module.header| $[module%$moduleTk?]? $[prelude]? $importsStx*) := header then
    for importStx in importsStx do
      if let `(Parser.Module.import|
          $[public%$pubTk?]? $[meta%$metaTk?]? import
          $[all%$allTk?]? $moduleName) := importStx then
        let imported := moduleName.getId
        if localModules.contains imported && !trustedModules.contains imported then
          throwError m!"trusted file {{path}} imports unreviewed local module {{imported}}"
  else
    throwError m!"cannot decode trusted header {{path}}"

run_cmd do
  let localModules := {_name_array(list(analysis.modules))}
  let trustedModules := {_name_array(list(analysis.reviewed_modules))}
{calls}
"""


def _trusted_headers(manifest: Manifest, analysis: StaticAnalysis, source_root: Path) -> Gate:
    result = run(
        _LEAN_HEADER_CHECK,
        cwd=manifest.root,
        timeout_seconds=manifest.lean.timeout_seconds,
        stdin=_trusted_header_source(source_root, analysis),
    )
    return _command_gate(
        "trusted imports",
        result,
        "Lean parser confirms the trusted local import graph is closed",
    )


def _parse_axioms(output: str) -> tuple[str, ...] | None:
    markers = _AXIOM_MARKER.findall(output)
    if len(markers) != 1:
        return None
    try:
        value = json.loads(markers[0])
    except json.JSONDecodeError:
        return None
    if (
        not isinstance(value, list)
        or any(not isinstance(item, str) or not item for item in value)
        or len(set(value)) != len(value)
    ):
        return None
    return tuple(sorted(value))


def _obligation_source(obligation: Obligation, analysis: StaticAnalysis) -> str:
    contract_owner = owner_module(obligation.contract, analysis.modules)
    implementation_owner = owner_module(obligation.implementation, analysis.modules)
    if contract_owner is None or implementation_owner is None:
        raise AssertionError("static symbol-owner gate was bypassed")
    return f"""import Lean.Elab.Command
import Lean.Util.CollectAxioms
import Lean.Compiler.ImplementedByAttr
import Lean.Compiler.ExternAttr
import Lean.Compiler.NoncomputableAttr

open Lean Elab Command

private def originOf? (env : Environment) (name : Name) : Option Name := do
  let index ← env.getModuleIdxFor? name
  env.header.moduleNames[index]?

private def assertOrigin (env : Environment) (name expected : Name) : CommandElabM Unit := do
  let some actual := originOf? env name
    | throwError m!"missing module origin for {{name}}"
  unless actual == expected do
    throwError m!"{{name}} originates in {{actual}}, expected {{expected}}"

private partial def auditClosure
    (env : Environment) (localModules trusted : Array Name) (trustedOnly : Bool)
    (pending seen : List Name) : CommandElabM Unit := do
  let some name := pending.head? | return
  let rest := pending.tail!
  if seen.contains name then
    auditClosure env localModules trusted trustedOnly rest seen
    return
  let seen := name :: seen
  let some origin := originOf? env name
    | auditClosure env localModules trusted trustedOnly rest seen
      return
  if !localModules.contains origin then
    auditClosure env localModules trusted trustedOnly rest seen
    return
  if trustedOnly && !trusted.contains origin then
    throwError m!"trusted semantics depend on unreviewed local declaration {{name}} from {{origin}}"
  let some info := env.find? name | throwError m!"missing local declaration {{name}}"
  if (Lean.Compiler.getImplementedBy? env name).isSome then
    throwError m!"local declaration {{name}} has an implemented_by runtime replacement"
  if Lean.isExtern env name then
    throwError m!"local declaration {{name}} has an external runtime implementation"
  if !trustedOnly && Lean.isNoncomputable env name then
    throwError m!"local executable dependency {{name}} is noncomputable"
  match info with
  | .axiomInfo _ => throwError m!"local declaration {{name}} is an axiom"
  | .opaqueInfo _ => throwError m!"local declaration {{name}} is opaque"
  | .defnInfo value =>
      unless value.safety == .safe do
        throwError m!"local definition {{name}} is not total and safe"
  | .inductInfo value =>
      if value.isUnsafe then throwError m!"local inductive {{name}} is unsafe"
  | .ctorInfo value =>
      if value.isUnsafe then throwError m!"local constructor {{name}} is unsafe"
  | .recInfo value =>
      if value.isUnsafe then throwError m!"local recursor {{name}} is unsafe"
  | _ => pure ()
  let pending := info.type.foldConsts rest fun dependency queue => dependency :: queue
  let pending := match info.value? with
    | some value => value.foldConsts pending fun dependency queue => dependency :: queue
    | none => pending
  auditClosure env localModules trusted trustedOnly pending seen

run_cmd do
  let env ← Lean.importModules #[{{ module := `{obligation.module} }}] {{}}
  assertOrigin env `{obligation.declaration} `{obligation.module}
  assertOrigin env `{obligation.contract} `{contract_owner}
  assertOrigin env `{obligation.implementation} `{implementation_owner}
  let some declaration := env.find? `{obligation.declaration}
    | throwError "missing obligation declaration"
  unless declaration.isTheorem do
    throwError "obligation declaration is not a theorem"
  let some contractInfo := env.find? `{obligation.contract}
    | throwError "missing contract declaration"
  unless contractInfo.isDefinition do
    throwError "contract root is not a definition"
  let some implementationInfo := env.find? `{obligation.implementation}
    | throwError "missing implementation declaration"
  unless implementationInfo.isDefinition do
    throwError "implementation root is not an executable definition"
  match declaration.type.consumeMData with
  | .app (.const contract _) (.const implementation _) =>
      unless contract == `{obligation.contract} && implementation == `{obligation.implementation} do
        throwError m!"wrong contract or implementation root: {{repr declaration.type}}"
  | _ =>
      throwError m!"not an exact unary contract application: {{repr declaration.type}}"
  let localModules := {_name_array(list(analysis.modules))}
  let trustedModules := {_name_array(list(analysis.reviewed_modules))}
  auditClosure env localModules trustedModules true [`{obligation.contract}] []
  auditClosure env localModules trustedModules false [`{obligation.implementation}] []
  let previous ← getEnv
  setEnv env
  let axioms ← Lean.collectAxioms `{obligation.declaration}
  setEnv previous
  let rendered := Lean.Json.compress <| (axioms.toList.map toString).toJson
  logInfo m!"VERFORM_AXIOMS={{rendered}}"
"""


def _check_obligation(
    manifest: Manifest, analysis: StaticAnalysis, obligation: Obligation
) -> tuple[Gate, ObligationEvidence | None]:
    result = run(
        _LEAN_CHECK,
        cwd=manifest.root,
        timeout_seconds=manifest.lean.timeout_seconds,
        stdin=_obligation_source(obligation, analysis),
    )
    if not result.ok:
        return (
            Gate(
                f"obligation:{obligation.name}",
                False,
                "exact binding, semantic closure, or runtime audit failed",
                diagnostic(result),
            ),
            None,
        )
    output = f"{result.stdout}\n{result.stderr}"
    axioms = _parse_axioms(output)
    if axioms is None:
        return (
            Gate(
                f"obligation:{obligation.name}",
                False,
                "could not parse the environment's axiom report",
                diagnostic(result),
            ),
            None,
        )
    disallowed = sorted(set(axioms) - set(obligation.allowed_axioms))
    if disallowed:
        return (
            Gate(
                f"obligation:{obligation.name}",
                False,
                f"disallowed axiom(s): {', '.join(disallowed)}",
                (f"observed: {', '.join(axioms) or '(none)'}",),
            ),
            None,
        )
    summary = (
        "exact contract/implementation origins and safe local runtime closure; "
        f"axioms: {', '.join(axioms) or '(none)'}"
    )
    evidence = ObligationEvidence(
        obligation.name,
        obligation.module,
        obligation.declaration,
        obligation.statement,
        axioms,
    )
    return Gate(f"obligation:{obligation.name}", True, summary), evidence


def _verify_kernel(
    manifest: Manifest, analysis: StaticAnalysis, toolchain: str
) -> tuple[list[Gate], Evidence]:
    gates: list[Gate] = []
    targets = tuple(dict.fromkeys(item.module for item in manifest.obligations))
    command = (*_LEAN_BUILD_PREFIX, *(f"+{module}" for module in targets))
    build = run(command, cwd=manifest.root, timeout_seconds=manifest.lean.timeout_seconds)
    gates.append(
        _command_gate(
            "fresh build",
            build,
            "cache-free, rehashed Lean elaboration + kernel checking passed",
        )
    )
    if not build.ok:
        return gates, replace(analysis.evidence, toolchain=toolchain)

    obligations: list[ObligationEvidence] = []
    for obligation in manifest.obligations:
        gate, evidence = _check_obligation(manifest, analysis, obligation)
        gates.append(gate)
        if evidence is not None:
            obligations.append(evidence)
    if any(not gate.ok for gate in gates):
        return gates, replace(
            analysis.evidence, toolchain=toolchain, obligations=tuple(obligations)
        )

    for module in targets:
        result = run(
            (*_LEAN_REPLAY, module),
            cwd=manifest.root,
            timeout_seconds=manifest.lean.timeout_seconds,
        )
        gates.append(
            _command_gate(
                f"kernel replay:{module}",
                result,
                "leanchecker fresh-environment replay passed",
            )
        )

    if all(gate.ok for gate in gates):
        for check in manifest.checks:
            result = run(
                check.command,
                cwd=manifest.root,
                timeout_seconds=check.timeout_seconds,
            )
            gates.append(_command_gate(f"check:{check.name}", result, "passed"))

    return gates, replace(analysis.evidence, toolchain=toolchain, obligations=tuple(obligations))


def _comparator_payload(manifest: Manifest) -> dict[str, object]:
    comparator = manifest.comparator
    if comparator is None:
        raise AssertionError("missing comparator configuration")
    return {
        "challenge_module": comparator.challenge_module,
        "solution_module": comparator.solution_module,
        "theorem_names": list(comparator.theorem_names),
        "definition_names": list(comparator.definition_names),
        "permitted_axioms": list(comparator.permitted_axioms),
        "enable_nanoda": True,
    }


def _challenge_source(manifest: Manifest) -> str:
    comparator = manifest.comparator
    if comparator is None:
        raise AssertionError("missing comparator configuration")
    theorem_checks = "\n".join(
        f"  assertOrigin env `{name} `{comparator.challenge_module}\n"
        f'  let some theoremInfo := env.find? `{name} | throwError "missing challenge theorem"\n'
        '  unless theoremInfo.isTheorem do throwError "configured theorem is not a theorem"\n'
        "  let theoremReferences := theoremInfo.type.foldConsts #[] fun dependency names => "
        "if names.contains dependency then names else names.push dependency\n"
        "  unless definitions.any fun definition => theoremReferences.contains definition do\n"
        '    throwError "configured semantic theorem references no configured executable"\n'
        "  referenced := theoremReferences.foldl (init := referenced) fun names dependency => "
        "if names.contains dependency then names else names.push dependency"
        for name in comparator.theorem_names
    )
    definition_checks = "\n".join(
        f"  assertOrigin env `{name} `{comparator.challenge_module}\n"
        f"  let some definitionInfo := env.find? `{name} | "
        'throwError "missing challenge definition"\n'
        "  unless definitionInfo.isDefinition do\n"
        '    throwError "configured executable is not a definition"\n'
        f"  unless referenced.contains `{name} do\n"
        f'    throwError "no configured semantic theorem directly references {name}"'
        for name in comparator.definition_names
    )
    return f"""import Lean.Elab.Command

open Lean Elab Command

private def originOf? (env : Environment) (name : Name) : Option Name := do
  let index ← env.getModuleIdxFor? name
  env.header.moduleNames[index]?

private def assertOrigin (env : Environment) (name expected : Name) : CommandElabM Unit := do
  let some actual := originOf? env name | throwError m!"missing origin for {{name}}"
  unless actual == expected do
    throwError m!"{{name}} originates in {{actual}}, expected {{expected}}"

run_cmd do
  let env ← Lean.importModules #[{{ module := `{comparator.challenge_module} }}] {{}}
  let definitions := {_name_array(list(comparator.definition_names))}
  let mut referenced : Array Name := #[]
{theorem_checks}
{definition_checks}
"""


def _verify_comparator(
    manifest: Manifest, analysis: StaticAnalysis, toolchain: str
) -> tuple[list[Gate], Evidence]:
    comparator = manifest.comparator
    if comparator is None:
        raise AssertionError("missing comparator configuration")
    gates: list[Gate] = []
    challenge_build = run(
        (*_LAKE_FRESH, f"+{comparator.challenge_module}"),
        cwd=manifest.root,
        timeout_seconds=manifest.lean.timeout_seconds,
    )
    gates.append(
        _command_gate(
            "challenge build",
            challenge_build,
            "reviewed challenge built in the fresh workspace",
        )
    )
    if not challenge_build.ok:
        return gates, replace(analysis.evidence, toolchain=toolchain)
    challenge = run(
        _LEAN_CHECK,
        cwd=manifest.root,
        timeout_seconds=manifest.lean.timeout_seconds,
        stdin=_challenge_source(manifest),
    )
    gates.append(
        _command_gate(
            "challenge semantics",
            challenge,
            "configured declaration origins and theorem-to-executable links confirmed",
        )
    )
    if not challenge.ok:
        return gates, replace(analysis.evidence, toolchain=toolchain)
    if sys.platform != "linux":
        gates.append(Gate("comparator", False, "adversarial assurance requires Linux sandboxing"))
        return gates, replace(analysis.evidence, toolchain=toolchain)
    if os.geteuid() == 0:
        gates.append(
            Gate("comparator", False, "adversarial assurance requires an unprivileged user")
        )
        return gates, replace(analysis.evidence, toolchain=toolchain)
    systemd_run = shutil.which("systemd-run")
    comparator_bin = shutil.which("comparator")
    env_bin = shutil.which("env")
    lake_bin = shutil.which("lake")
    missing = [
        name
        for name, value in (
            ("systemd-run", systemd_run),
            ("comparator", comparator_bin),
            ("env", env_bin),
            ("lake", lake_bin),
        )
        if value is None
    ]
    if missing:
        gates.append(
            Gate(
                "comparator",
                False,
                f"required trusted tool(s) not found: {', '.join(missing)}",
            )
        )
        return gates, replace(analysis.evidence, toolchain=toolchain)
    assert (
        systemd_run is not None
        and comparator_bin is not None
        and env_bin is not None
        and lake_bin is not None
    )
    temporary: Path | None = None
    result: CommandResult
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=manifest.root,
            prefix=".verform-comparator-",
            suffix=".json",
            delete=False,
        ) as stream:
            json.dump(_comparator_payload(manifest), stream, sort_keys=True)
            stream.write("\n")
            temporary = Path(stream.name)
        command = (
            systemd_run,
            "--user",
            "--pipe",
            "--wait",
            "--collect",
            "--quiet",
            "--property=RestrictAddressFamilies=~AF_UNIX",
            f"--property=RuntimeMaxSec={manifest.lean.timeout_seconds}s",
            "--property=TimeoutStopSec=5s",
            f"--working-directory={manifest.root}",
            f"--setenv=PATH={os.environ.get('PATH', '')}",
            "--",
            env_bin,
            "-u",
            "ELAN_TOOLCHAIN",
            "-u",
            "LEAN_PATH",
            "-u",
            "LEAN_SRC_PATH",
            "-u",
            "LEAN_GITHASH",
            "-u",
            "LAKE_PKG_URL_MAP",
            "-u",
            "LAKE_CONFIG",
            "-u",
            "LAKE_HOME",
            "-u",
            "LD_PRELOAD",
            "-u",
            "LD_LIBRARY_PATH",
            lake_bin,
            "env",
            comparator_bin,
            str(temporary),
        )
        result = run(command, cwd=manifest.root, timeout_seconds=manifest.lean.timeout_seconds)
    except OSError as error:
        result = CommandResult(
            (systemd_run, comparator_bin),
            126,
            "",
            "",
            f"cannot prepare Comparator invocation: {error}",
        )
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    gates.append(
        _command_gate(
            "comparator",
            result,
            "challenge declarations, axiom policy, sandbox build, "
            "Lean replay, and nanoda replay passed",
        )
    )
    return gates, replace(analysis.evidence, toolchain=toolchain)


@contextmanager
def _isolated_snapshot(manifest: Manifest, analysis: StaticAnalysis) -> Iterator[Manifest]:
    with tempfile.TemporaryDirectory(prefix="verform-check-") as temporary:
        root = Path(temporary)
        for source in analysis.snapshot_files:
            relative = source.relative_to(manifest.root)
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
            actual = hashlib.sha256(destination.read_bytes()).hexdigest()
            expected = analysis.evidence.input_hashes[relative.as_posix()]
            if actual != expected:
                raise ConfigError(f"input changed while snapshotting: {relative.as_posix()}")
        yield replace(manifest, root=root, path=root / manifest.path.name)


def _input_stability(manifest: Manifest, evidence: Evidence) -> Gate:
    after = analyze(manifest)
    stable = evidence.input_hashes == after.evidence.input_hashes
    detail: tuple[str, ...] = ()
    if not stable:
        before_keys = set(evidence.input_hashes)
        after_keys = set(after.evidence.input_hashes)
        changed = sorted(
            key
            for key in before_keys & after_keys
            if evidence.input_hashes[key] != after.evidence.input_hashes[key]
        )
        detail = tuple(
            item
            for group in (
                (f"changed: {item}" for item in changed),
                (f"added: {item}" for item in sorted(after_keys - before_keys)),
                (f"removed: {item}" for item in sorted(before_keys - after_keys)),
            )
            for item in group
        )
    return Gate(
        "input stability",
        stable,
        "verification inputs unchanged during checks"
        if stable
        else "verification inputs changed during checks",
        detail,
    )


def verify(manifest: Manifest) -> Report:
    analysis = analyze(manifest)
    gates = list(analysis.gates)
    if not analysis.ok:
        return Report(
            manifest.project.name, manifest.lean.assurance, tuple(gates), analysis.evidence
        )

    try:
        with _isolated_snapshot(manifest, analysis) as isolated:
            gates.append(
                Gate(
                    "isolated snapshot",
                    True,
                    f"fresh workspace contains {len(analysis.snapshot_files)} hashed file(s)",
                )
            )
            toolchain_gate, toolchain = _toolchain(isolated)
            gates.append(toolchain_gate)
            if not toolchain_gate.ok:
                return Report(
                    manifest.project.name,
                    manifest.lean.assurance,
                    tuple(gates),
                    analysis.evidence,
                )
            header_gate = _trusted_headers(isolated, analysis, manifest.root)
            gates.append(header_gate)
            if not header_gate.ok:
                return Report(
                    manifest.project.name,
                    manifest.lean.assurance,
                    tuple(gates),
                    replace(analysis.evidence, toolchain=toolchain),
                )
            if manifest.lean.assurance == "kernel":
                mode_gates, evidence = _verify_kernel(isolated, analysis, toolchain)
            else:
                mode_gates, evidence = _verify_comparator(isolated, analysis, toolchain)
            gates.extend(mode_gates)
    except (OSError, ConfigError) as error:
        gates.append(Gate("isolated snapshot", False, f"cannot create fresh workspace: {error}"))
        return Report(
            manifest.project.name, manifest.lean.assurance, tuple(gates), analysis.evidence
        )

    if all(gate.ok for gate in gates):
        gates.append(_input_stability(manifest, evidence))
    return Report(manifest.project.name, manifest.lean.assurance, tuple(gates), evidence)
