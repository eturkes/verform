"""Fail-closed filesystem, build-input, and review-boundary checks."""

from __future__ import annotations

import hashlib
import json
import re
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from verform.errors import ConfigError
from verform.model import DEFAULT_FORBIDDEN, Evidence, Gate, Manifest

_TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_']*")
_MODULE_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_']*(?:\.[A-Za-z][A-Za-z0-9_']*)*\Z")
_GIT_REV = re.compile(r"[0-9a-f]{40}\Z")
_LAKE_ROOT_KEYS = {
    "version",
    "fixedToolchain",
    "name",
    "lakeDir",
    "packagesDir",
    "packages",
}
_LAKE_PACKAGE_KEYS = {
    "type",
    "name",
    "scope",
    "inherited",
    "configFile",
    "manifestFile",
    "url",
    "rev",
    "inputRev",
    "subDir",
}


@dataclass(frozen=True)
class StaticAnalysis:
    gates: tuple[Gate, ...]
    evidence: Evidence
    sources: tuple[Path, ...]
    modules: dict[str, Path]
    snapshot_files: tuple[Path, ...]
    reviewed_modules: tuple[str, ...]

    @property
    def ok(self) -> bool:
        return all(gate.ok for gate in self.gates)


def _reject_symlink_components(root: Path, candidate: Path, where: str) -> None:
    try:
        relative = candidate.relative_to(root)
    except ValueError:
        return
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise ConfigError(f"{where}: symbolic link components are not accepted: {relative}")


def _inside(root: Path, candidate: Path, where: str) -> Path:
    try:
        resolved = candidate.resolve(strict=True)
    except FileNotFoundError as error:
        raise ConfigError(f"{where}: path not found: {candidate}") from error
    if not resolved.is_relative_to(root):
        raise ConfigError(f"{where}: path escapes project root: {candidate}")
    return resolved


def _file(root: Path, relative: str, where: str) -> Path:
    candidate = root / relative
    _reject_symlink_components(root, candidate, where)
    resolved = _inside(root, candidate, where)
    if not resolved.is_file():
        raise ConfigError(f"{where}: expected a regular file: {relative}")
    return resolved


def _label(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _read_text(path: Path, where: str) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise ConfigError(f"{where}: cannot read UTF-8 file {path}: {error}") from error


def _relative_lock_path(value: object, where: str, *, nullable: bool = False) -> None:
    if value is None and nullable:
        return
    if not isinstance(value, str) or not value:
        raise ConfigError(f"{where}: expected a non-empty relative path")
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or value == ".":
        raise ConfigError(f"{where}: path must remain inside its package")


def _build_inputs(manifest: Manifest) -> tuple[tuple[Path, ...], Gate]:
    root = manifest.root
    if (root / "lakefile.lean").exists() or (root / "lakefile.lean").is_symlink():
        raise ConfigError(
            "build configuration: Verform v1 requires declarative lakefile.toml; "
            "lakefile.lean is not accepted"
        )
    lakefile = _file(root, "lakefile.toml", "build configuration")
    toolchain = _file(root, "lean-toolchain", "build configuration")
    lock = _file(root, "lake-manifest.json", "build configuration")
    override = root / ".lake/package-overrides.json"
    if override.exists() or override.is_symlink():
        raise ConfigError(
            "build configuration: .lake/package-overrides.json can override locked dependencies"
        )
    if _read_text(toolchain, "build configuration").strip() != "leanprover/lean4:v4.32.2":
        raise ConfigError("build configuration: lean-toolchain must pin leanprover/lean4:v4.32.2")

    try:
        lake_config = tomllib.loads(_read_text(lakefile, "build configuration"))
    except tomllib.TOMLDecodeError as error:
        raise ConfigError(f"build configuration: invalid lakefile.toml: {error}") from error
    package_name = lake_config.get("name")
    if not isinstance(package_name, str) or not package_name:
        raise ConfigError("build configuration: lakefile.toml requires a package name")

    try:
        raw: Any = json.loads(_read_text(lock, "build configuration"))
    except json.JSONDecodeError as error:
        raise ConfigError(f"build configuration: invalid lake-manifest.json: {error}") from error
    if not isinstance(raw, dict):
        raise ConfigError("build configuration: lake-manifest.json must contain an object")
    unknown = sorted(set(raw) - _LAKE_ROOT_KEYS)
    missing = sorted(_LAKE_ROOT_KEYS - set(raw))
    if unknown or missing:
        detail = [*(f"unknown root key: {key}" for key in unknown)]
        detail.extend(f"missing root key: {key}" for key in missing)
        raise ConfigError(f"build configuration: {'; '.join(detail)}")
    if raw["version"] != "1.2.0":
        raise ConfigError("build configuration: lake-manifest.json version must be exactly 1.2.0")
    if not isinstance(raw["fixedToolchain"], bool):
        raise ConfigError("build configuration: fixedToolchain must be boolean")
    if raw["lakeDir"] != ".lake" or raw["packagesDir"] != ".lake/packages":
        raise ConfigError("build configuration: Lake directories must use .lake defaults")
    expected_names = {package_name, f"«{package_name}»"}
    if not isinstance(raw["name"], str) or raw["name"] not in expected_names:
        raise ConfigError("build configuration: manifest package name differs from lakefile.toml")

    packages = raw["packages"]
    if not isinstance(packages, list):
        raise ConfigError("build configuration: packages must be an array")
    issues: list[str] = []
    names: set[str] = set()
    for index, package in enumerate(packages):
        where = f"lake-manifest.json packages[{index}]"
        if not isinstance(package, dict):
            issues.append(f"{where}: expected an object")
            continue
        unknown_package = sorted(set(package) - _LAKE_PACKAGE_KEYS)
        missing_package = sorted(_LAKE_PACKAGE_KEYS - set(package))
        if unknown_package or missing_package:
            issues.extend(f"{where}: unknown key {key}" for key in unknown_package)
            issues.extend(f"{where}: missing key {key}" for key in missing_package)
            continue
        name = package["name"]
        if not isinstance(name, str) or not name:
            issues.append(f"{where}.name: expected a non-empty string")
        elif name in names:
            issues.append(f"{where}.name: duplicate package {name}")
        else:
            names.add(name)
        if not isinstance(package["scope"], str):
            issues.append(f"{where}.scope: expected a string")
        for key in ("configFile", "url"):
            if not isinstance(package[key], str) or not package[key]:
                issues.append(f"{where}.{key}: expected a non-empty string")
        if package["manifestFile"] is not None and not isinstance(package["manifestFile"], str):
            issues.append(f"{where}.manifestFile: expected string or null")
        if not isinstance(package["inherited"], bool):
            issues.append(f"{where}.inherited: expected a boolean")
        if package["type"] != "git":
            issues.append(f"{where}.type: only pinned git dependencies are accepted")
        if not isinstance(package["rev"], str) or not _GIT_REV.fullmatch(package["rev"]):
            issues.append(f"{where}.rev: expected a full lowercase 40-hex Git revision")
        if package["inputRev"] is not None and not isinstance(package["inputRev"], str):
            issues.append(f"{where}.inputRev: expected string or null")
        try:
            _relative_lock_path(package["configFile"], f"{where}.configFile")
        except ConfigError as error:
            issues.append(str(error))
        try:
            _relative_lock_path(package["manifestFile"], f"{where}.manifestFile", nullable=True)
        except ConfigError as error:
            issues.append(str(error))
        try:
            _relative_lock_path(package["subDir"], f"{where}.subDir", nullable=True)
        except ConfigError as error:
            issues.append(str(error))

    extra = tuple(
        _file(root, item, f"lean.evidence_files[{index}]")
        for index, item in enumerate(manifest.lean.evidence_files)
    )
    files = tuple(dict.fromkeys((lakefile, toolchain, lock, *extra)))
    gate = Gate(
        "build closure",
        not issues,
        (
            f"Lake 1.2.0 lock: {len(packages)} pinned Git package(s); "
            f"{len(files)} hashed control file(s)"
            if not issues
            else f"{len(issues)} build-closure violation(s)"
        ),
        tuple(issues),
    )
    return files, gate


def _source_files(manifest: Manifest) -> tuple[Path, ...]:
    if manifest.lean.module_root == ".":
        module_root = manifest.root
    else:
        requested_root = manifest.root / manifest.lean.module_root
        _reject_symlink_components(manifest.root, requested_root, "lean.module_root")
        module_root = _inside(manifest.root, requested_root, "lean.module_root")
    if not module_root.is_dir():
        raise ConfigError("lean.module_root: expected a directory")
    found: list[Path] = []
    for candidate in module_root.rglob("*.lean"):
        relative = candidate.relative_to(module_root)
        if any(part.startswith(".") for part in relative.parts):
            continue
        if candidate.is_symlink():
            raise ConfigError(f"Lean sources cannot be symbolic links: {candidate}")
        _reject_symlink_components(manifest.root, candidate, "Lean source discovery")
        if not candidate.is_file():
            raise ConfigError(f"Lean sources must be regular files: {candidate}")
        found.append(_inside(manifest.root, candidate, "Lean source discovery"))
    if not found:
        raise ConfigError(f"lean.module_root: no Lean sources found under {module_root}")
    return tuple(sorted(set(found), key=lambda item: _label(manifest.root, item)))


def _module_map(manifest: Manifest, sources: tuple[Path, ...]) -> dict[str, Path]:
    module_root = (
        manifest.root
        if manifest.lean.module_root == "."
        else _inside(manifest.root, manifest.root / manifest.lean.module_root, "lean.module_root")
    )
    modules: dict[str, Path] = {}
    for source in sources:
        try:
            relative = source.relative_to(module_root)
        except ValueError as error:
            raise ConfigError(
                f"lean.module_root: {_label(manifest.root, source)} is outside the module root"
            ) from error
        module = ".".join(relative.with_suffix("").parts)
        if not _MODULE_NAME.fullmatch(module):
            raise ConfigError(
                f"lean.module_root: module paths must be dot-separated ASCII identifiers: {module}"
            )
        if module in modules:
            raise ConfigError(f"lean.module_root: duplicate module {module}")
        modules[module] = source
    return modules


def owner_module(symbol: str, modules: dict[str, Path]) -> str | None:
    """Return the longest local module prefix owning a qualified symbol."""
    candidates = [
        module for module in modules if symbol == module or symbol.startswith(f"{module}.")
    ]
    return max(candidates, key=len, default=None)


def analyze(manifest: Manifest) -> StaticAnalysis:
    sources = _source_files(manifest)
    modules = _module_map(manifest, sources)
    source_text = {
        path: _read_text(path, f"Lean source {_label(manifest.root, path)}") for path in sources
    }
    build_files, build_gate = _build_inputs(manifest)

    challenge_path: Path | None = None
    solution_path: Path | None = None
    source_issues: list[str] = []
    if manifest.comparator is not None:
        challenge_path = modules.get(manifest.comparator.challenge_module)
        solution_path = modules.get(manifest.comparator.solution_module)
        if challenge_path is None:
            source_issues.append(
                f"challenge module not found: {manifest.comparator.challenge_module}"
            )
        if solution_path is None:
            source_issues.append(
                f"solution module not found: {manifest.comparator.solution_module}"
            )
    for obligation in manifest.obligations:
        if obligation.module not in modules:
            source_issues.append(f"obligation module not found: {obligation.module}")
        if owner_module(obligation.contract, modules) is None:
            source_issues.append(f"contract symbol has no local owner: {obligation.contract}")
        if owner_module(obligation.implementation, modules) is None:
            source_issues.append(
                f"implementation symbol has no local owner: {obligation.implementation}"
            )
    source_gate = Gate(
        "sources",
        not source_issues,
        f"{len(sources)} Lean source file(s); {len(modules)} unique module(s)"
        if not source_issues
        else f"{len(source_issues)} source binding violation(s)",
        tuple(source_issues),
    )

    violations: list[str] = []
    forbidden = set(DEFAULT_FORBIDDEN)
    for path, text in source_text.items():
        for match in _TOKEN.finditer(text):
            token = match.group(0)
            if token not in forbidden:
                continue
            if path == challenge_path and token == "sorry":
                continue
            line = text.count("\n", 0, match.start()) + 1
            violations.append(f"{_label(manifest.root, path)}:{line}: forbidden `{token}`")
    policy_gate = Gate(
        "source policy",
        not violations,
        "no forbidden identifier spellings (comments and literals included)"
        if not violations
        else f"{len(violations)} forbidden spelling(s)",
        tuple(violations),
    )

    review_paths = tuple(
        _file(manifest.root, item, f"review.files[{index}]")
        for index, item in enumerate(manifest.review.files)
    )
    source_set = set(sources)
    outside_sources = [
        _label(manifest.root, path)
        for path in review_paths
        if path.suffix == ".lean" and path not in source_set
    ]
    review_lines = sum(
        sum(bool(line.strip()) for line in source_text[path].splitlines())
        for path in review_paths
        if path.suffix == ".lean" and path in source_text
    )
    review_issues = [
        f"trusted Lean file is outside module root: {item}" for item in outside_sources
    ]
    review_set = set(review_paths)
    for path in build_files:
        if path not in review_set:
            review_issues.append(
                f"build input must be human-reviewed: {_label(manifest.root, path)}"
            )
    if review_lines > manifest.review.max_code_lines:
        review_issues.append(
            f"review surface has {review_lines} nonblank lines; "
            f"budget is {manifest.review.max_code_lines}"
        )
    review_gate = Gate(
        "review surface",
        not review_issues,
        f"{len(review_paths)} file(s), {review_lines}/{manifest.review.max_code_lines} lines",
        tuple(review_issues),
    )

    boundary_issues: list[str] = []
    if manifest.comparator is not None:
        if challenge_path is not None and challenge_path not in review_set:
            boundary_issues.append("Comparator challenge module must be human-reviewed")
        if solution_path is not None and solution_path in review_set:
            boundary_issues.append("Comparator solution module must remain outside review")
    for obligation in manifest.obligations:
        proof_path = modules.get(obligation.module)
        contract_owner = owner_module(obligation.contract, modules)
        implementation_owner = owner_module(obligation.implementation, modules)
        contract_path = modules.get(contract_owner) if contract_owner is not None else None
        implementation_path = (
            modules.get(implementation_owner) if implementation_owner is not None else None
        )
        if proof_path is not None and proof_path in review_set:
            boundary_issues.append(f"{obligation.name}: proof module must remain outside review")
        if contract_path is not None and contract_path not in review_set:
            boundary_issues.append(f"{obligation.name}: contract owner must be human-reviewed")
        if implementation_path is not None and implementation_path in review_set:
            boundary_issues.append(
                f"{obligation.name}: implementation owner must remain outside review"
            )
        if obligation.contract == obligation.implementation:
            boundary_issues.append(f"{obligation.name}: contract and implementation must differ")
    boundary_gate = Gate(
        "symbol boundary",
        not boundary_issues,
        "contract roots reviewed; implementation/proof roots isolated"
        if not boundary_issues
        else f"{len(boundary_issues)} symbol-boundary violation(s)",
        tuple(boundary_issues),
    )

    verification_paths = tuple(
        dict.fromkeys((*sources, *build_files, *review_paths, manifest.path))
    )
    input_hashes = {_label(manifest.root, path): _digest(path) for path in verification_paths}
    review_hashes = {_label(manifest.root, path): _digest(path) for path in review_paths}
    review_hashes[manifest.path.name] = _digest(manifest.path)
    reviewed_modules = tuple(
        sorted(module for module, path in modules.items() if path in review_set)
    )
    snapshot_files = tuple(
        sorted(
            set((*verification_paths, *review_paths)),
            key=lambda path: _label(manifest.root, path),
        )
    )
    evidence = Evidence(
        review_code_lines=review_lines,
        review_hashes=dict(sorted(review_hashes.items())),
        input_hashes=dict(sorted(input_hashes.items())),
    )
    return StaticAnalysis(
        gates=(source_gate, policy_gate, build_gate, review_gate, boundary_gate),
        evidence=evidence,
        sources=sources,
        modules=modules,
        snapshot_files=snapshot_files,
        reviewed_modules=reviewed_modules,
    )
