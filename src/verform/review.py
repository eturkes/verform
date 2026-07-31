"""Human-readable trusted review packet."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

from verform.errors import ConfigError
from verform.model import Manifest
from verform.policy import analyze


def _read_bound(path: Path, digest: str) -> str:
    try:
        data = path.read_bytes()
    except OSError as error:
        raise ConfigError(f"cannot read review input {path}: {error}") from error
    if hashlib.sha256(data).hexdigest() != digest:
        raise ConfigError(f"review input changed while rendering: {path}")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ConfigError(f"review input is not UTF-8 text: {path}") from error


def _fence(content: str) -> str:
    longest = max((len(match.group()) for match in re.finditer(r"`+", content)), default=0)
    return "`" * max(4, longest + 1)


def packet(manifest: Manifest) -> str:
    analysis = analyze(manifest)
    structural_failures = [
        gate for gate in analysis.gates if gate.name != "source policy" and not gate.ok
    ]
    if structural_failures:
        summary = "; ".join(
            f"{gate.name}: {gate.summary}" + (f" ({'; '.join(gate.detail)})" if gate.detail else "")
            for gate in structural_failures
        )
        raise ConfigError(f"cannot render a complete review packet: {summary}")

    manifest_digest = analysis.evidence.review_hashes[manifest.path.name]
    manifest_content = _read_bound(manifest.path, manifest_digest).rstrip()
    manifest_fence = _fence(manifest_content)
    lines = [
        f"# Verform review — {manifest.project.name}",
        "",
        f"- Assurance: `{manifest.lean.assurance}`",
        (
            f"- Trusted Lean surface: {analysis.evidence.review_code_lines}/"
            f"{manifest.review.max_code_lines} nonblank lines"
        ),
        "- Review the manifest and every trusted file below; "
        "generated proofs are deliberately absent.",
        "",
        "## Declared obligations",
        "",
    ]
    if manifest.obligations:
        for obligation in manifest.obligations:
            lines.append(
                f"- `{obligation.name}`: `{obligation.declaration}` proves "
                f"`{obligation.statement}`; allowed axioms = "
                f"`{', '.join(obligation.allowed_axioms) or '(none)'}`"
            )
    elif manifest.comparator is not None:
        lines.extend(
            [
                f"- Challenge: `{manifest.comparator.challenge_module}`",
                f"- Solution: `{manifest.comparator.solution_module}`",
                f"- Theorems: `{', '.join(manifest.comparator.theorem_names) or '(none)'}`",
                f"- Definitions: `{', '.join(manifest.comparator.definition_names) or '(none)'}`",
                (
                    "- Permitted axioms: "
                    f"`{', '.join(manifest.comparator.permitted_axioms) or '(none)'}`"
                ),
                "- Independent nanoda replay: `required`",
            ]
        )
    lines.extend(
        [
            "",
            "## Manifest",
            "",
            f"SHA-256 `{manifest_digest}`",
            "",
            f"{manifest_fence}toml",
            manifest_content,
            manifest_fence,
        ]
    )

    source_policy = next(gate for gate in analysis.gates if gate.name == "source policy")
    if not source_policy.ok:
        lines.extend(
            [
                "",
                "## Full-tree source-policy failures",
                "",
                "The trusted packet remains reviewable while implementation/proof work "
                "is incomplete.",
                "Final verification still requires every item below to be fixed.",
                "",
                *(f"- {item}" for item in source_policy.detail),
            ]
        )

    for relative, digest in analysis.evidence.review_hashes.items():
        if relative == manifest.path.name:
            continue
        path = manifest.root / relative
        content = _read_bound(path, digest)
        code_lines = sum(bool(line.strip()) for line in content.splitlines())
        if path.suffix == ".lean":
            language = "lean"
        else:
            language = "toml" if path.suffix == ".toml" else "text"
        fence = _fence(content)
        lines.extend(
            [
                "",
                f"## `{relative}`",
                "",
                f"SHA-256 `{digest}` · {code_lines} nonblank lines",
                "",
                f"{fence}{language}",
                content.rstrip(),
                fence,
            ]
        )
    return "\n".join(lines) + "\n"
