"""Deterministic console and JSON presentation."""

from __future__ import annotations

import json
from typing import Any

from verform.model import Gate, Report


def gate_dict(gate: Gate) -> dict[str, Any]:
    return {
        "name": gate.name,
        "ok": gate.ok,
        "summary": gate.summary,
        "detail": list(gate.detail),
    }


def report_dict(report: Report) -> dict[str, Any]:
    return {
        "project": report.project,
        "assurance": report.assurance,
        "ok": report.ok,
        "gates": [gate_dict(gate) for gate in report.gates],
        "evidence": {
            "toolchain": report.evidence.toolchain,
            "review_code_lines": report.evidence.review_code_lines,
            "review_hashes": report.evidence.review_hashes,
            "input_hashes": report.evidence.input_hashes,
            "obligations": [
                {
                    "name": item.name,
                    "module": item.module,
                    "declaration": item.declaration,
                    "statement": item.statement,
                    "axioms": list(item.axioms),
                }
                for item in report.evidence.obligations
            ],
        },
    }


def json_text(value: object) -> str:
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def gates_text(
    title: str,
    gates: tuple[Gate, ...] | list[Gate],
    *,
    success_label: str = "ACCEPTED",
) -> str:
    lines = [title]
    for gate in gates:
        mark = "PASS" if gate.ok else "FAIL"
        lines.append(f"{mark:4}  {gate.name} — {gate.summary}")
        lines.extend(f"      {item}" for item in gate.detail)
    passed = sum(gate.ok for gate in gates)
    outcome = success_label if gates and passed == len(gates) else "REJECTED"
    lines.append(f"{outcome}  {passed}/{len(gates)} gates passed")
    return "\n".join(lines) + "\n"


def report_text(report: Report) -> str:
    return gates_text(
        f"Verform — {report.project} [{report.assurance}]",
        report.gates,
        success_label=f"ACCEPTED[{report.assurance}]",
    )
