#!/usr/bin/env bash
set -Eeuo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly project_root
temp_root="$(realpath -e "${TMPDIR:-/tmp}")"
readonly temp_root
work_root="$(mktemp -d "$temp_root/verform-templates.XXXXXX")"
readonly work_root
readonly -a verform=(uv run --frozen --project "$project_root" verform)

cleanup() {
  local rc=$?
  trap - EXIT HUP INT TERM
  if [[ -n "${work_root:-}" && -d "$work_root" &&
        "$work_root" == "$temp_root"/verform-templates.* ]]; then
    rm -rf -- "$work_root"
  fi
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

run_step() {
  local label=$1
  shift
  printf 'RUN  %s\n' "$label"
  set +e
  "$@"
  local rc=$?
  set -e
  printf 'DONE %s (rc=%d)\n' "$label" "$rc"
  return "$rc"
}

run_in() {
  local directory=$1
  shift
  (cd -- "$directory" && "$@")
}

install_runtime_substitution() {
  local source=$1
  if ! command grep -Fq 'def run : Spec.Program := fun input => input + 1' "$source"; then
    printf 'runtime-audit probe target not found: %s\n' "$source" >&2
    return 1
  fi
  sed -i '1a import Lean.Elab.Command\
import Lean.Compiler.ImplementedByAttr' "$source"
  # Lean name quotations below are literal backticks.
  # shellcheck disable=SC2016
  sed -i '/^def run : Spec.Program :=/a\
def alternate : Spec.Program := fun _ => 0\
run_cmd Lean.setImplementedBy `TemplatePureKernel.Impl.run `TemplatePureKernel.Impl.alternate' \
    "$source"
  command grep -Fq 'run_cmd Lean.setImplementedBy' "$source"
}

install_newline_import() {
  local source=$1
  if ! command grep -Fq 'namespace TemplateResultKernel' "$source"; then
    printf 'trusted-import probe target not found: %s\n' "$source" >&2
    return 1
  fi
  sed -i '1i import\
  TemplateResultKernel.Impl' "$source"
  command grep -Fq '  TemplateResultKernel.Impl' "$source"
}

install_noncomputable_root() {
  local source=$1
  if ! command grep -Fq 'def step : Spec.Program' "$source"; then
    printf 'noncomputable probe target not found: %s\n' "$source" >&2
    return 1
  fi
  sed -i 's/^def step : Spec.Program/noncomputable def step : Spec.Program/' "$source"
  command grep -Fq 'noncomputable def step : Spec.Program' "$source"
}

expect_gate_failure() {
  local project=$1
  local label=$2
  local expected_gate=$3
  local expected_detail=$4
  local output="$work_root/$label.out"
  printf 'RUN  %s must fail verification\n' "$label"
  set +e
  "${verform[@]}" check "$project" >"$output" 2>&1
  local rc=$?
  set -e
  command sed -n '1,200p' "$output"
  printf 'DONE %s check (rc=%d; expected=1)\n' "$label" "$rc"
  if ((rc != 1)); then
    printf 'expected a formal gate failure (rc=1), received rc=%d\n' "$rc" >&2
    return 1
  fi
  if ! command grep -Fq 'PASS  source policy' "$output"; then
    printf '%s did not pass the literal source-policy gate\n' "$label" >&2
    return 1
  fi
  if ! command grep -Fq "$expected_gate" "$output"; then
    printf '%s did not fail at expected gate: %s\n' "$label" "$expected_gate" >&2
    return 1
  fi
  if ! command grep -Fq "$expected_detail" "$output"; then
    printf '%s omitted expected diagnostic: %s\n' "$label" "$expected_detail" >&2
    return 1
  fi
}

for required in uv lake sed realpath mktemp; do
  if ! command -v "$required" >/dev/null 2>&1; then
    printf 'required command is unavailable: %s\n' "$required" >&2
    exit 2
  fi
done

runtime_project=""
header_project=""
noncomputable_project=""
for assurance in kernel comparator; do
  for shape in pure result machine; do
    module="Template${shape^}${assurance^}"
    destination="$work_root/${shape}-${assurance}"
    run_step "scaffold $shape/$assurance" \
      "${verform[@]}" init "$destination" \
      --name "template-$shape-$assurance" \
      --module "$module" \
      --shape "$shape" \
      --assurance "$assurance"

    if [[ "$assurance" == kernel ]]; then
      run_step "formally verify $shape/kernel" \
        "${verform[@]}" check "$destination"
      if [[ "$shape" == pure ]]; then
        runtime_project="$destination"
      elif [[ "$shape" == result ]]; then
        header_project="$destination"
      elif [[ "$shape" == machine ]]; then
        noncomputable_project="$destination"
      fi
      continue
    fi

    # Generator smoke tests only: these fixed fixtures are not hostile-solution certification.
    # Real comparator verification additionally requires Comparator, landrun, and nanoda.
    run_step "elaborate $shape/comparator Challenge (expected sorry holes)" \
      run_in "$destination" lake --rehash --reconfigure --no-cache \
      build "+$module.Challenge"
    run_step "clean $shape/comparator Challenge artifacts" \
      run_in "$destination" lake clean
    run_step "elaborate $shape/comparator Solution in a fresh build" \
      run_in "$destination" lake --rehash --reconfigure --no-cache --wfail \
      build "+$module.Solution"
  done
done

if [[ -z "$runtime_project" || -z "$header_project" || -z "$noncomputable_project" ]]; then
  printf 'internal error: kernel probe projects were not generated\n' >&2
  exit 2
fi
run_step "install nonliteral runtime substitution" \
  install_runtime_substitution "$runtime_project/TemplatePureKernel/Impl.lean"
expect_gate_failure \
  "$runtime_project" \
  runtime-audit \
  'FAIL  obligation:implementation-correct' \
  'has an implemented_by runtime replacement'

run_step "install newline-form trusted local import" \
  install_newline_import "$header_project/TemplateResultKernel/Spec.lean"
expect_gate_failure \
  "$header_project" \
  trusted-import-header \
  'FAIL  trusted imports' \
  'imports unreviewed local module TemplateResultKernel.Impl'

run_step "mark executable root noncomputable" \
  install_noncomputable_root "$noncomputable_project/TemplateMachineKernel/Impl.lean"
expect_gate_failure \
  "$noncomputable_project" \
  noncomputable-runtime \
  'FAIL  obligation:implementation-correct' \
  'local executable dependency TemplateMachineKernel.Impl.step is noncomputable'

printf 'All generated-template checks passed.\n'
