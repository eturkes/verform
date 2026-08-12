#!/usr/bin/env bash
set -Eeuo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly project_root
readonly verform="$project_root/.lake/build/bin/verform"
temp_root="$(realpath -e "${TMPDIR:-/tmp}")"
readonly temp_root
work_root="$(mktemp -d "$temp_root/verform-templates.XXXXXX")"
readonly work_root

cleanup() {
  local rc=$?
  trap - EXIT HUP INT TERM
  if [[ -d "$work_root" && "$work_root" == "$temp_root"/verform-templates.* ]]; then
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

expect_gate_failure() {
  local project=$1
  local label=$2
  local expected_gate=$3
  local expected_detail=$4
  local output="$work_root/$label.out"
  set +e
  "$verform" check "$project" >"$output" 2>&1
  local rc=$?
  set -e
  command sed -n '1,200p' "$output"
  if ((rc != 1)); then
    printf 'expected formal rejection; rc=%d\n' "$rc" >&2
    return 1
  fi
  command grep -Fq 'PASS  source policy' "$output"
  command grep -Fq "$expected_gate" "$output"
  command grep -Fq "$expected_detail" "$output"
}

for required in grep lake mktemp realpath rm sed sha256sum tee; do
  command -v "$required" >/dev/null
done
[[ -x "$verform" ]]

runtime_project=
header_project=
noncomputable_project=
for assurance in kernel comparator; do
  for shape in pure result machine; do
    module="Template${shape^}${assurance^}"
    destination="$work_root/$shape-$assurance"
    run_step "scaffold $shape/$assurance" \
      "$verform" init "$destination" --name "template-$shape-$assurance" \
      --module "$module" --shape "$shape" --assurance "$assurance"
    if [[ "$assurance" == kernel ]]; then
      run_step "verify $shape/kernel" "$verform" check "$destination"
      case "$shape" in
        pure) runtime_project=$destination ;;
        result) header_project=$destination ;;
        machine) noncomputable_project=$destination ;;
      esac
    else
      run_step "elaborate $shape/comparator Challenge" \
        run_in "$destination" lake --rehash --reconfigure --no-cache build "+$module.Challenge"
      run_step "clean $shape/comparator" run_in "$destination" lake clean
      run_step "elaborate $shape/comparator Solution" \
        run_in "$destination" lake --rehash --reconfigure --no-cache --wfail \
        build "+$module.Solution"
    fi
  done
done

snapshot_project="$work_root/snapshot-kernel"
run_step "scaffold snapshot stability probe" \
  "$verform" init "$snapshot_project" --name template-snapshot-kernel \
  --module TemplateSnapshotKernel --shape pure --assurance kernel
command tee -a "$snapshot_project/verform.toml" >/dev/null <<'EOF'

[[checks]]
name = "mutate-snapshot"
command = ["sh", "-c", "printf '\n' >> TemplateSnapshotKernel/Impl.lean"]
timeout_seconds = 30
EOF
snapshot_source="$snapshot_project/TemplateSnapshotKernel/Impl.lean"
snapshot_digest="$(sha256sum "$snapshot_source")"
expect_gate_failure "$snapshot_project" snapshot-stability \
  'FAIL  snapshot stability' 'changed: TemplateSnapshotKernel/Impl.lean'
[[ "$(sha256sum "$snapshot_source")" == "$snapshot_digest" ]]

runtime_source="$runtime_project/TemplatePureKernel/Impl.lean"
command sed -i '1a import Lean.Elab.Command\
import Lean.Compiler.ImplementedByAttr' "$runtime_source"
command sed -i '/^def run : Spec.Program :=/a\
def alternate : Spec.Program := fun _ => 0\
run_cmd Lean.setImplementedBy `TemplatePureKernel.Impl.run `TemplatePureKernel.Impl.alternate' \
  "$runtime_source"
expect_gate_failure "$runtime_project" runtime-audit \
  'FAIL  obligation:implementation-correct' 'has a runtime replacement'

header_source="$header_project/TemplateResultKernel/Spec.lean"
command sed -i '1i import\
  TemplateResultKernel.Impl' "$header_source"
expect_gate_failure "$header_project" trusted-import-header \
  'FAIL  trusted imports' 'imports unreviewed local module TemplateResultKernel.Impl'

machine_source="$noncomputable_project/TemplateMachineKernel/Impl.lean"
command sed -i 's/^def step : Spec.Program/noncomputable def step : Spec.Program/' "$machine_source"
expect_gate_failure "$noncomputable_project" noncomputable-runtime \
  'FAIL  obligation:implementation-correct' \
  'local executable dependency TemplateMachineKernel.Impl.step is noncomputable'

printf 'All generated-template checks passed.\n'
