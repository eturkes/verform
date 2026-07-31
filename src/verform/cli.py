"""Verform command-line interface."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence

from verform import __version__
from verform.attestation import LOCK_NAME, attest, status, write_output
from verform.config import load_manifest
from verform.errors import VerformError
from verform.presentation import gates_text, json_text, report_dict, report_text
from verform.review import packet
from verform.scaffold import create
from verform.verifier import verify


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="verform",
        description="Formal-verification-driven development gates for Lean kernels.",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    commands = parser.add_subparsers(dest="command", required=True)

    check = commands.add_parser("check", help="run the configured verification gates")
    check.add_argument("path", nargs="?", default=".", help="project directory or verform.toml")
    check.add_argument("--json", action="store_true", help="emit structured JSON")

    review = commands.add_parser("review", help="render only the human-reviewable trust surface")
    review.add_argument("path", nargs="?", default=".", help="project directory or verform.toml")
    review.add_argument(
        "--output", metavar="PATH", help="write inside the project instead of stdout"
    )

    attest = commands.add_parser("attest", help="check and atomically lock all verification inputs")
    attest.add_argument("path", nargs="?", default=".", help="project directory or verform.toml")
    attest.add_argument(
        "--output", default=LOCK_NAME, metavar="PATH", help="project-relative lock path"
    )
    attest.add_argument("--json", action="store_true", help="emit the verification report as JSON")

    state = commands.add_parser("status", help="detect review/proof drift without invoking Lean")
    state.add_argument("path", nargs="?", default=".", help="project directory or verform.toml")
    state.add_argument(
        "--lock", default=LOCK_NAME, metavar="PATH", help="project-relative lock path"
    )
    state.add_argument("--json", action="store_true", help="emit structured JSON")

    init = commands.add_parser("init", help="scaffold a verified Lean kernel")
    init.add_argument("path", help="new or empty destination")
    init.add_argument("--name", required=True, help="project name")
    init.add_argument("--module", help="Lean root module; derived from name by default")
    init.add_argument(
        "--shape",
        choices=("pure", "result", "machine"),
        default="pure",
        help="contract pattern",
    )
    init.add_argument(
        "--assurance",
        choices=("kernel", "comparator"),
        default="kernel",
        help="honest-agent loop or adversarial-proof certification",
    )
    return parser


def _write_review(manifest_path: str, requested: str | None) -> int:
    manifest = load_manifest(manifest_path)
    rendered = packet(manifest)
    if requested is None:
        sys.stdout.write(rendered)
        return 0
    destination = write_output(manifest, requested, rendered)
    print(f"WROTE {destination.relative_to(manifest.root)}")
    return 0


def _check(manifest_path: str, as_json: bool) -> int:
    report = verify(load_manifest(manifest_path))
    sys.stdout.write(json_text(report_dict(report)) if as_json else report_text(report))
    return 0 if report.ok else 1


def _attest(manifest_path: str, requested: str, as_json: bool) -> int:
    manifest = load_manifest(manifest_path)
    report, destination = attest(manifest, requested)
    if as_json:
        value = report_dict(report)
        value["attestation"] = (
            destination.relative_to(manifest.root).as_posix() if destination is not None else None
        )
        sys.stdout.write(json_text(value))
    else:
        sys.stdout.write(report_text(report))
    if destination is None:
        return 1
    if not as_json:
        print(f"ATTESTED {destination.relative_to(manifest.root)}")
    return 0


def _status(manifest_path: str, requested: str, as_json: bool) -> int:
    manifest = load_manifest(manifest_path)
    gates = status(manifest, requested)
    ok = bool(gates) and all(gate.ok for gate in gates)
    if as_json:
        value = {
            "project": manifest.project.name,
            "ok": ok,
            "gates": [
                {
                    "name": gate.name,
                    "ok": gate.ok,
                    "summary": gate.summary,
                    "detail": list(gate.detail),
                }
                for gate in gates
            ],
        }
        sys.stdout.write(json_text(value))
    else:
        sys.stdout.write(
            gates_text(
                f"Verform status — {manifest.project.name}",
                gates,
                success_label="CURRENT",
            )
        )
    return 0 if ok else 1


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "check":
            return _check(args.path, args.json)
        if args.command == "review":
            return _write_review(args.path, args.output)
        if args.command == "attest":
            return _attest(args.path, args.output, args.json)
        if args.command == "status":
            return _status(args.path, args.lock, args.json)
        if args.command == "init":
            destination = create(
                args.path,
                name=args.name,
                module=args.module,
                shape=args.shape,
                assurance=args.assurance,
            )
            print(f"CREATED {destination}")
            return 0
    except VerformError as error:
        print(f"verform: {error}", file=sys.stderr)
        return 2
    raise AssertionError(f"unhandled command: {args.command}")
