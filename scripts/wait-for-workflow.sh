#!/bin/bash
# wait-for-workflow.sh — Security-hardened implementation
# See SECURITY.md for a full audit report.
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()  { echo "ℹ️  $*"; }
log_wait()  { echo "⏳ $*"; }
log_ok()    { echo "✅ $*"; }
log_error() { echo "❌ $*" >&2; }

# ---------------------------------------------------------------------------
# Input validation helpers
# ---------------------------------------------------------------------------
validate_input() {
  local var_name="$1"
  local var_value="$2"
  if [ -z "$var_value" ]; then
    log_error "Missing required input: $var_name"
    exit 1
  fi
}

validate_positive_int() {
  local var_name="$1"
  local var_value="$2"
  if ! [[ "$var_value" =~ ^[0-9]+$ ]] || [ "$var_value" -le 0 ]; then
    log_error "$var_name must be a positive integer, got: $var_value"
    exit 1
  fi
}

validate_numeric_id() {
  local id_name="$1"
  local id_value="$2"
  if ! [[ "$id_value" =~ ^[0-9]+$ ]]; then
    log_error "Invalid $id_name received from API (expected numeric, got non-numeric value)"
    exit 1
  fi
}

validate_commit_sha() {
  local sha_name="$1"
  local sha_value="$2"
  if ! [[ "$sha_value" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    log_error "$sha_name must be a valid Git commit SHA, got: $sha_value"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# API helper: make an authenticated GitHub API request and return the body.
# Usage: api_get <url> <output_file>
# Exits on non-200 HTTP status codes.
# ---------------------------------------------------------------------------
api_get() {
  local url="$1"
  local out_file="$2"
  local http_code
  # Token is written to a temp config file so it is NOT passed as a CLI argument,
  # preventing exposure in process listings (ps aux) and shell history.
  local auth_config="$tmp_dir/curl_auth.conf"
  printf 'header = "Authorization: token %s"\n' "${GITHUB_TOKEN}" > "$auth_config"
  # Capture curl's exit status explicitly so that transport-level failures
  # (DNS, TLS, connection timeout) are reported even under set -e.
  # The || suppresses set -e for this assignment; $? is captured immediately
  # before log_error can overwrite it.
  http_code=$(curl -s -w "%{http_code}" -o "$out_file" \
    -K "$auth_config" \
    -H "Accept: application/vnd.github+json" \
    "$url") || { local curl_exit=$?; log_error "Network error contacting GitHub API (curl exit ${curl_exit})."; exit 1; }
  case "$http_code" in
    200) return 0 ;;
    401) log_error "Authentication failed. Check that GITHUB_TOKEN is valid."; exit 1 ;;
    403) log_error "Permission denied or rate limit exceeded. The token may lack required scopes, or the API secondary rate limit was hit."; exit 1 ;;
    404) log_error "Resource not found. Check org_name, repo_name, and workflow_id inputs."; exit 1 ;;
    429) log_error "API rate limit exceeded. Please try again later."; exit 1 ;;
    *)   log_error "Unexpected API response (HTTP $http_code)."; exit 1 ;;
  esac
}

validate_json() {
  local file="$1"
  if ! jq . "$file" > /dev/null 2>&1; then
    log_error "Invalid JSON received from GitHub API."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Validate all inputs up front
# ---------------------------------------------------------------------------
validate_input "ORG_NAME"  "${ORG_NAME:-}"
validate_input "REPO_NAME" "${REPO_NAME:-}"
validate_input "GITHUB_TOKEN" "${GITHUB_TOKEN:-}"

max_wait_minutes="${MAX_WAIT_MINUTES:-5}"
timeout="${TIMEOUT:-30}"
interval="${INTERVAL:-10}"

validate_positive_int "max_wait_minutes" "$max_wait_minutes"
validate_positive_int "timeout"          "$timeout"
validate_positive_int "interval"         "$interval"

# Validate REF before normalising it
validate_input "REF" "${REF:-}"

# Check if REF has the prefix "refs/heads/" and append it if not
if [[ ! "${REF}" =~ ^refs/heads/ ]]; then
  REF="refs/heads/${REF}"
fi

branch_name="$(echo "$REF" | sed 's/refs\/heads\///')"

log_info "Reference: $REF"
log_info "Maximum wait time: ${max_wait_minutes} minutes"
log_info "Timeout for the workflow to complete: ${timeout} minutes"
log_info "Interval between checks: ${interval} seconds"

# Temporary directory for API response files; cleaned up on exit
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

counter=0

# ---------------------------------------------------------------------------
# Determine run_id
# ---------------------------------------------------------------------------
if [ -n "${RUN_ID:-}" ]; then
  validate_numeric_id "RUN_ID" "${RUN_ID}"
  run_id="${RUN_ID}"
  log_info "Using provided Run ID."
else
  validate_input "WORKFLOW_ID" "${WORKFLOW_ID:-}"
  workflow_id="${WORKFLOW_ID}"
  ref_file="$tmp_dir/ref.json"
  resp_file="$tmp_dir/runs.json"

  if [ -n "${SHA:-}" ]; then
    target_sha="${SHA}"
    log_info "Using provided SHA."
  else
    api_get \
      "https://api.github.com/repos/${ORG_NAME}/${REPO_NAME}/git/ref/${REF#refs/}" \
      "$ref_file"
    validate_json "$ref_file"

    target_sha=$(jq -r '.object.sha // empty' "$ref_file")
    validate_input "target_sha" "$target_sha"
    log_info "Using latest commit SHA from ${REF}."
  fi

  validate_commit_sha "target_sha" "$target_sha"
  log_info "Target SHA: $target_sha"

  while true; do
    log_wait "Waiting for a matching workflow run for ${target_sha}..."

    api_get \
      "https://api.github.com/repos/${ORG_NAME}/${REPO_NAME}/actions/workflows/${workflow_id}/runs?per_page=100" \
      "$resp_file"
    validate_json "$resp_file"

    matching_run=$(jq -c \
      --arg ref "$branch_name" \
      --arg sha "$target_sha" \
      '[.workflow_runs[] | select(.head_branch == $ref and .head_sha == $sha)] | sort_by(.created_at) | last // empty' \
      "$resp_file")

    if [ -n "$matching_run" ] && [ "$matching_run" != "null" ]; then
      run_id=$(printf '%s' "$matching_run" | jq -r '.id // empty')
      validate_numeric_id "run_id" "$run_id"

      status=$(printf '%s' "$matching_run" | jq -r '.status // empty')
      conclusion=$(printf '%s' "$matching_run" | jq -r '.conclusion // empty')

      if [ "$status" = "completed" ] && [ "$conclusion" = "success" ]; then
        log_ok "A matching workflow run for ${target_sha} has already completed successfully. Exiting."
        exit 0
      fi

      log_ok "Matching workflow run found for ${target_sha}."
      break
    fi

    counter=$((counter + 1))
    if [ $(( counter * interval )) -ge $(( max_wait_minutes * 60 )) ]; then
      log_error "Maximum waiting time for the workflow to be triggered has been reached. Exiting."
      exit 1
    fi

    sleep "$interval"
  done
fi

# ---------------------------------------------------------------------------
# Wait for the triggered workflow run to complete
# ---------------------------------------------------------------------------
timeout_counter=0
run_file="$tmp_dir/run.json"

while true; do
  log_wait "Waiting for the workflow to complete..."

  api_get \
    "https://api.github.com/repos/${ORG_NAME}/${REPO_NAME}/actions/runs/${run_id}" \
    "$run_file"
  validate_json "$run_file"

  status=$(jq -r '.status // empty' "$run_file")

  if [ "$status" = "completed" ]; then
    conclusion=$(jq -r '.conclusion // empty' "$run_file")
    if [ "$conclusion" != "success" ]; then
      log_error "The workflow did not complete successfully (conclusion: ${conclusion:-unknown}). Exiting."
      exit 1
    else
      log_ok "The workflow completed successfully! Exiting."
      break
    fi
  fi

  timeout_counter=$((timeout_counter + 1))
  if [ $(( timeout_counter * interval )) -ge $(( timeout * 60 )) ]; then
    log_error "Timeout waiting for the workflow to complete. Exiting."
    exit 1
  fi

  sleep "$interval"
done
