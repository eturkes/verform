"""Strict `verform.toml` loading."""

from __future__ import annotations

import re
import tomllib
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any, NoReturn

from verform.errors import ConfigError
from verform.model import (
    DEFAULT_AXIOMS,
    HARD_DENIED_AXIOMS,
    Comparator,
    ExtraCheck,
    Lean,
    Manifest,
    Obligation,
    Project,
    Review,
)

MANIFEST_NAME = "verform.toml"
_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_']*(?:\.[A-Za-z][A-Za-z0-9_']*)*\Z")
_PROJECT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*\Z")


def _fail(where: str, message: str) -> NoReturn:
    raise ConfigError(f"{where}: {message}")


def _table(value: object, where: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        _fail(where, "expected a table")
    return value


def _only(table: Mapping[str, Any], allowed: set[str], where: str) -> None:
    unknown = sorted(set(table) - allowed)
    if unknown:
        _fail(where, f"unknown key(s): {', '.join(unknown)}")


def _string(table: Mapping[str, Any], key: str, where: str, default: str | None = None) -> str:
    value = table.get(key, default)
    if not isinstance(value, str) or not value:
        _fail(f"{where}.{key}", "expected a non-empty string")
    return value


def _positive_int(table: Mapping[str, Any], key: str, where: str, default: int) -> int:
    value = table.get(key, default)
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        _fail(f"{where}.{key}", "expected a positive integer")
    return value


def _strings(
    table: Mapping[str, Any],
    key: str,
    where: str,
    default: Sequence[str] | None = None,
    *,
    allow_empty: bool = False,
) -> tuple[str, ...]:
    value = table.get(key, default)
    if not isinstance(value, list | tuple) or any(
        not isinstance(item, str) or not item for item in value
    ):
        _fail(f"{where}.{key}", "expected an array of non-empty strings")
    result = tuple(value)
    if not result and not allow_empty:
        _fail(f"{where}.{key}", "must contain at least one item")
    if len(set(result)) != len(result):
        _fail(f"{where}.{key}", "must not contain duplicates")
    return result


def _qualified(value: str, where: str) -> str:
    if not _NAME.fullmatch(value):
        _fail(where, "expected an ASCII Lean qualified name")
    return value


def _relative(value: str, where: str) -> str:
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or value in {"", "."}:
        _fail(where, "must be a project-relative path without '..'")
    if any(char in value for char in "*?[]"):
        _fail(where, "globs are not allowed here")
    return value


def resolve_manifest(location: str | Path) -> Path:
    candidate = Path(location).expanduser()
    if candidate.is_dir():
        candidate /= MANIFEST_NAME
    try:
        resolved = candidate.resolve(strict=True)
    except FileNotFoundError as error:
        raise ConfigError(f"manifest not found: {candidate}") from error
    if not resolved.is_file():
        raise ConfigError(f"manifest is not a file: {resolved}")
    return resolved


def load_manifest(location: str | Path = ".") -> Manifest:
    path = resolve_manifest(location)
    try:
        raw = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, tomllib.TOMLDecodeError) as error:
        raise ConfigError(f"cannot read {path}: {error}") from error

    _only(
        raw,
        {"manifest_version", "project", "review", "lean", "obligations", "comparator", "checks"},
        "manifest",
    )
    if type(raw.get("manifest_version")) is not int or raw["manifest_version"] != 1:
        _fail("manifest.manifest_version", "expected 1")

    project_raw = _table(raw.get("project"), "project")
    _only(project_raw, {"name", "prover"}, "project")
    project_name = _string(project_raw, "name", "project")
    if not _PROJECT_NAME.fullmatch(project_name):
        _fail("project.name", "expected letters, digits, '.', '_' or '-'")
    prover = _string(project_raw, "prover", "project", "lean4")
    if prover != "lean4":
        _fail("project.prover", "only 'lean4' is supported")
    project = Project(project_name, prover)

    review_raw = _table(raw.get("review"), "review")
    _only(review_raw, {"files", "max_code_lines"}, "review")
    review_files = _strings(review_raw, "files", "review")
    for index, item in enumerate(review_files):
        _relative(item, f"review.files[{index}]")
    review = Review(
        review_files,
        _positive_int(review_raw, "max_code_lines", "review", 200),
    )

    lean_raw = _table(raw.get("lean"), "lean")
    _only(
        lean_raw,
        {
            "assurance",
            "module_root",
            "evidence_files",
            "timeout_seconds",
        },
        "lean",
    )
    assurance = _string(lean_raw, "assurance", "lean", "kernel")
    if assurance not in {"kernel", "comparator"}:
        _fail("lean.assurance", "expected 'kernel' or 'comparator'")
    module_root = _string(lean_raw, "module_root", "lean", ".")
    if module_root != ".":
        _relative(module_root, "lean.module_root")
    evidence_files = _strings(lean_raw, "evidence_files", "lean", (), allow_empty=True)
    for index, item in enumerate(evidence_files):
        _relative(item, f"lean.evidence_files[{index}]")
    lean = Lean(
        assurance=assurance,  # type: ignore[arg-type]
        module_root=module_root,
        evidence_files=evidence_files,
        timeout_seconds=_positive_int(lean_raw, "timeout_seconds", "lean", 600),
    )

    obligation_items = raw.get("obligations", [])
    if not isinstance(obligation_items, list):
        _fail("obligations", "expected an array of tables")
    obligations: list[Obligation] = []
    for index, item in enumerate(obligation_items):
        where = f"obligations[{index}]"
        table = _table(item, where)
        _only(
            table,
            {
                "name",
                "module",
                "declaration",
                "contract",
                "implementation",
                "allowed_axioms",
            },
            where,
        )
        name = _string(table, "name", where)
        if not _PROJECT_NAME.fullmatch(name):
            _fail(f"{where}.name", "expected letters, digits, '.', '_' or '-'")
        module = _qualified(_string(table, "module", where), f"{where}.module")
        declaration = _qualified(_string(table, "declaration", where), f"{where}.declaration")
        contract = _qualified(_string(table, "contract", where), f"{where}.contract")
        implementation = _qualified(
            _string(table, "implementation", where), f"{where}.implementation"
        )
        allowed_axioms = _strings(table, "allowed_axioms", where, DEFAULT_AXIOMS, allow_empty=True)
        for axiom_index, axiom in enumerate(allowed_axioms):
            _qualified(axiom, f"{where}.allowed_axioms[{axiom_index}]")
        denied = sorted(set(allowed_axioms) & set(HARD_DENIED_AXIOMS))
        if denied:
            _fail(
                f"{where}.allowed_axioms",
                f"cannot permit hard-denied axiom(s): {', '.join(denied)}",
            )
        obligations.append(
            Obligation(
                name,
                module,
                declaration,
                contract,
                implementation,
                allowed_axioms,
            )
        )
    if len({item.name for item in obligations}) != len(obligations):
        _fail("obligations", "names must be unique")

    comparator_raw_value = raw.get("comparator")
    comparator: Comparator | None = None
    if comparator_raw_value is not None:
        comparator_raw = _table(comparator_raw_value, "comparator")
        _only(
            comparator_raw,
            {
                "challenge_module",
                "solution_module",
                "theorem_names",
                "definition_names",
                "permitted_axioms",
            },
            "comparator",
        )
        theorem_names = _strings(
            comparator_raw, "theorem_names", "comparator", (), allow_empty=True
        )
        definition_names = _strings(
            comparator_raw, "definition_names", "comparator", (), allow_empty=True
        )
        if not theorem_names or not definition_names:
            _fail("comparator", "declare at least one theorem and one executable definition")
        for key, names in (
            ("theorem_names", theorem_names),
            ("definition_names", definition_names),
        ):
            for index, name in enumerate(names):
                _qualified(name, f"comparator.{key}[{index}]")
        permitted_axioms = _strings(
            comparator_raw,
            "permitted_axioms",
            "comparator",
            DEFAULT_AXIOMS,
            allow_empty=True,
        )
        for index, axiom in enumerate(permitted_axioms):
            _qualified(axiom, f"comparator.permitted_axioms[{index}]")
        denied = sorted(set(permitted_axioms) & set(HARD_DENIED_AXIOMS))
        if denied:
            _fail(
                "comparator.permitted_axioms",
                f"cannot permit hard-denied axiom(s): {', '.join(denied)}",
            )
        missing_nanoda_axioms = sorted(set(DEFAULT_AXIOMS) - set(permitted_axioms))
        if missing_nanoda_axioms:
            _fail(
                "comparator.permitted_axioms",
                "mandatory nanoda replay requires the prelude allowance(s): "
                f"{', '.join(missing_nanoda_axioms)}",
            )
        comparator = Comparator(
            challenge_module=_qualified(
                _string(comparator_raw, "challenge_module", "comparator"),
                "comparator.challenge_module",
            ),
            solution_module=_qualified(
                _string(comparator_raw, "solution_module", "comparator"),
                "comparator.solution_module",
            ),
            theorem_names=theorem_names,
            definition_names=definition_names,
            permitted_axioms=permitted_axioms,
        )

    checks_raw = raw.get("checks", [])
    if not isinstance(checks_raw, list):
        _fail("checks", "expected an array of tables")
    checks: list[ExtraCheck] = []
    for index, item in enumerate(checks_raw):
        where = f"checks[{index}]"
        table = _table(item, where)
        _only(table, {"name", "command", "timeout_seconds"}, where)
        checks.append(
            ExtraCheck(
                _string(table, "name", where),
                _strings(table, "command", where),
                _positive_int(table, "timeout_seconds", where, 300),
            )
        )
    if len({item.name for item in checks}) != len(checks):
        _fail("checks", "names must be unique")

    if assurance == "kernel":
        if not obligations:
            _fail("obligations", "kernel assurance requires at least one obligation")
        if comparator is not None:
            _fail("comparator", "allowed only when lean.assurance = 'comparator'")
    else:
        if comparator is None:
            _fail("comparator", "required when lean.assurance = 'comparator'")
        if obligations:
            _fail("obligations", "use comparator.theorem_names in comparator assurance mode")
        if checks:
            _fail(
                "checks",
                "comparator assurance forbids unsandboxed supplementary commands",
            )

    return Manifest(
        root=path.parent,
        path=path,
        project=project,
        review=review,
        lean=lean,
        obligations=tuple(obligations),
        comparator=comparator,
        checks=tuple(checks),
    )
