#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="${REPO_ROOT}/scripts/wait-for-workflow.sh"

assert_contains() {
  local needle="$1"
  local file="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "Expected '${needle}' in ${file}" >&2
    exit 1
  fi
}

assert_contains_line() {
  local needle="$1"
  local file="$2"
  if ! grep -Fxq "$needle" "$file"; then
    echo "Expected line '${needle}' in ${file}" >&2
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1"
  local file="$2"
  if grep -Fq "$needle" "$file"; then
    echo "Did not expect '${needle}' in ${file}" >&2
    exit 1
  fi
}

assert_not_contains_line() {
  local needle="$1"
  local file="$2"
  if grep -Fxq "$needle" "$file"; then
    echo "Did not expect line '${needle}' in ${file}" >&2
    exit 1
  fi
}

assert_empty_file() {
  local file="$1"
  if [ -s "$file" ]; then
    echo "Expected ${file} to be empty" >&2
    exit 1
  fi
}

create_fake_curl() {
  local bin_dir="$1"

  cat > "${bin_dir}/curl" <<'EOF'
#!/bin/bash
set -euo pipefail

out_file=""
url=""
write_out=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out_file="$2"
      shift 2
      ;;
    -w)
      write_out="$2"
      shift 2
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

if [ -z "$out_file" ] || [ -z "$url" ]; then
  exit 1
fi

echo "$url" >> "${FAKE_API_DIR}/requests.log"

response_path=""
case "$url" in
  */git/ref/*)
    response_path="${FAKE_API_DIR}/branch.json"
    ;;
  */actions/workflows/*/runs*)
    runs_count_file="${FAKE_API_DIR}/runs.count"
    runs_count=0
    if [ -f "$runs_count_file" ]; then
      runs_count=$(cat "$runs_count_file")
    fi
    runs_count=$((runs_count + 1))
    echo "$runs_count" > "$runs_count_file"

    if [ -f "${FAKE_API_DIR}/runs_${runs_count}.json" ]; then
      response_path="${FAKE_API_DIR}/runs_${runs_count}.json"
    else
      response_path="${FAKE_API_DIR}/runs.json"
    fi
    ;;
  */actions/runs/*)
    run_id="${url##*/}"
    run_count_file="${FAKE_API_DIR}/run_${run_id}.count"
    run_count=0
    if [ -f "$run_count_file" ]; then
      run_count=$(cat "$run_count_file")
    fi
    run_count=$((run_count + 1))
    echo "$run_count" > "$run_count_file"

    if [ -f "${FAKE_API_DIR}/run_${run_id}_${run_count}.json" ]; then
      response_path="${FAKE_API_DIR}/run_${run_id}_${run_count}.json"
    else
      response_path="${FAKE_API_DIR}/run_${run_id}.json"
    fi
    ;;
  *)
    exit 1
    ;;
esac

cp "$response_path" "$out_file"
if [ -n "$write_out" ]; then
  printf '%s' "${write_out//\%\{http_code\}/200}"
fi
EOF

  chmod +x "${bin_dir}/curl"
}

create_fake_sleep() {
  local bin_dir="$1"

  cat > "${bin_dir}/sleep" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "$1" >> "${FAKE_API_DIR}/sleeps.log"
EOF

  chmod +x "${bin_dir}/sleep"
}

setup_case() {
  local case_dir="$1"
  mkdir -p "${case_dir}/bin"
  : > "${case_dir}/requests.log"
  : > "${case_dir}/sleeps.log"
  create_fake_curl "${case_dir}/bin"
  create_fake_sleep "${case_dir}/bin"
}

run_script() {
  local case_dir="$1"
  local output_file="$2"
  shift 2

  (
    export PATH="${case_dir}/bin:${PATH}"
    export FAKE_API_DIR="${case_dir}"
    export GITHUB_TOKEN="test-token"
    export ORG_NAME="octo-org"
    export REPO_NAME="octo-repo"
    export WORKFLOW_ID="build.yml"
    export MAX_WAIT_MINUTES="1"
    export INTERVAL="1"
    export TIMEOUT="1"
    export REF="main"
    unset RUN_ID
    unset SHA

    while [ "$#" -gt 0 ]; do
      export "$1"
      shift
    done

    bash "${SCRIPT_PATH}"
  ) >"${output_file}" 2>&1
}

test_waits_for_latest_sha_run_instead_of_stale_branch_run() {
  local case_dir
  case_dir="$(mktemp -d)"
  setup_case "${case_dir}"

  cat > "${case_dir}/branch.json" <<'EOF'
{"object":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}
EOF

  cat > "${case_dir}/runs.json" <<'EOF'
{"workflow_runs":[
  {"id":101,"head_branch":"main","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"completed","conclusion":"success","created_at":"2026-08-20T11:00:00Z"},
  {"id":202,"head_branch":"main","head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","status":"in_progress","conclusion":null,"created_at":"2026-08-20T11:05:00Z"}
]}
EOF

  cat > "${case_dir}/run_202_1.json" <<'EOF'
{"status":"in_progress","conclusion":null}
EOF

  cat > "${case_dir}/run_202_2.json" <<'EOF'
{"status":"completed","conclusion":"success"}
EOF

  local output_file="${case_dir}/output.log"
  run_script "${case_dir}" "${output_file}"

  assert_contains "Target SHA: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "${output_file}"
  assert_contains_line "https://api.github.com/repos/octo-org/octo-repo/actions/runs/202" "${case_dir}/requests.log"
  assert_not_contains_line "https://api.github.com/repos/octo-org/octo-repo/actions/runs/101" "${case_dir}/requests.log"
  assert_contains "1" "${case_dir}/sleeps.log"
}

test_exits_immediately_when_latest_sha_already_succeeded() {
  local case_dir
  case_dir="$(mktemp -d)"
  setup_case "${case_dir}"

  cat > "${case_dir}/branch.json" <<'EOF'
{"object":{"sha":"cccccccccccccccccccccccccccccccccccccccc"}}
EOF

  cat > "${case_dir}/runs.json" <<'EOF'
{"workflow_runs":[
  {"id":303,"head_branch":"main","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"completed","conclusion":"success","created_at":"2026-08-20T11:00:00Z"},
  {"id":404,"head_branch":"main","head_sha":"cccccccccccccccccccccccccccccccccccccccc","status":"completed","conclusion":"success","created_at":"2026-08-20T11:05:00Z"}
]}
EOF

  local output_file="${case_dir}/output.log"
  run_script "${case_dir}" "${output_file}"

  assert_contains "already completed successfully" "${output_file}"
  assert_not_contains_line "https://api.github.com/repos/octo-org/octo-repo/actions/runs/404" "${case_dir}/requests.log"
  assert_empty_file "${case_dir}/sleeps.log"
}

test_waits_for_matching_run_to_appear_and_then_complete() {
  local case_dir
  case_dir="$(mktemp -d)"
  setup_case "${case_dir}"

  cat > "${case_dir}/branch.json" <<'EOF'
{"object":{"sha":"dddddddddddddddddddddddddddddddddddddddd"}}
EOF

  cat > "${case_dir}/runs_1.json" <<'EOF'
{"workflow_runs":[
  {"id":505,"head_branch":"main","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"completed","conclusion":"success","created_at":"2026-08-20T11:00:00Z"}
]}
EOF

  cat > "${case_dir}/runs_2.json" <<'EOF'
{"workflow_runs":[
  {"id":606,"head_branch":"main","head_sha":"dddddddddddddddddddddddddddddddddddddddd","status":"queued","conclusion":null,"created_at":"2026-08-20T11:06:00Z"}
]}
EOF

  cat > "${case_dir}/run_606_1.json" <<'EOF'
{"status":"queued","conclusion":null}
EOF

  cat > "${case_dir}/run_606_2.json" <<'EOF'
{"status":"completed","conclusion":"success"}
EOF

  local output_file="${case_dir}/output.log"
  run_script "${case_dir}" "${output_file}"

  assert_contains_line "https://api.github.com/repos/octo-org/octo-repo/actions/workflows/build.yml/runs?per_page=100" "${case_dir}/requests.log"
  assert_contains_line "https://api.github.com/repos/octo-org/octo-repo/actions/runs/606" "${case_dir}/requests.log"
  assert_contains "The workflow completed successfully! Exiting." "${output_file}"
}

test_explicit_run_id_skips_branch_and_workflow_lookup() {
  local case_dir
  case_dir="$(mktemp -d)"
  setup_case "${case_dir}"

  cat > "${case_dir}/run_777_1.json" <<'EOF'
{"status":"completed","conclusion":"success"}
EOF

  local output_file="${case_dir}/output.log"
  run_script "${case_dir}" "${output_file}" "RUN_ID=777"

  assert_contains "Using provided Run ID." "${output_file}"
  assert_contains_line "https://api.github.com/repos/octo-org/octo-repo/actions/runs/777" "${case_dir}/requests.log"
  assert_not_contains "/git/ref/" "${case_dir}/requests.log"
  assert_not_contains "/actions/workflows/" "${case_dir}/requests.log"
}

test_explicit_sha_skips_branch_lookup() {
  local case_dir
  case_dir="$(mktemp -d)"
  setup_case "${case_dir}"

  cat > "${case_dir}/runs.json" <<'EOF'
{"workflow_runs":[
  {"id":808,"head_branch":"main","head_sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","status":"completed","conclusion":"success","created_at":"2026-08-20T11:05:00Z"}
]}
EOF

  local output_file="${case_dir}/output.log"
  run_script "${case_dir}" "${output_file}" "SHA=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

  assert_contains "Using provided SHA." "${output_file}"
  assert_contains_line "https://api.github.com/repos/octo-org/octo-repo/actions/workflows/build.yml/runs?per_page=100" "${case_dir}/requests.log"
  assert_not_contains "/git/ref/" "${case_dir}/requests.log"
}

test_waits_for_latest_sha_run_instead_of_stale_branch_run
test_exits_immediately_when_latest_sha_already_succeeded
test_waits_for_matching_run_to_appear_and_then_complete
test_explicit_run_id_skips_branch_and_workflow_lookup
test_explicit_sha_skips_branch_lookup

echo "All wait-for-workflow tests passed."
