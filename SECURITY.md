# Security Audit Report — wait-for-workflow-action

This document describes the 8 security vulnerabilities identified in the original `scripts/wait-for-workflow.sh` and the fixes applied to each one.

---

## 🔴 Critical Issues

### 1. GitHub Token Exposure in Command History

**Severity:** CRITICAL

**Original code:**
```bash
response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" ...)
```

When the token is interpolated directly into a command-line argument it can appear in:
- Process listings (`ps aux`)
- Shell history files (`.bash_history`, `.zsh_history`)
- Verbose log output

**Fix:** The token is still read from the `GITHUB_TOKEN` environment variable (which GitHub Actions automatically masks in log output), but it is **not** expanded into a positional argument that would be visible in process listings. The `api_get` helper function centralises all curl calls so the pattern cannot regress.

---

### 2. Sensitive Data in Error Messages & Logs

**Severity:** CRITICAL

**Original code:**
```bash
echo "ℹ️ Organization: ${ORG_NAME}"
echo "ℹ️ Repository: ${REPO_NAME}"
```

Startup messages revealed the exact organisation, repository, and workflow being monitored. In a shared CI environment this leaks internal infrastructure details.

**Fix:** Organisation and repository names are no longer echoed at startup. Structured `log_info` / `log_error` helpers are used throughout; error messages are descriptive but do not expose raw API responses.

---

## 🟠 High-Severity Issues

### 3. Unvalidated JSON Parsing

**Severity:** HIGH

**Original code:**
```bash
run_id=$(echo "$response" | jq -r '...')
```

No check that `jq` parsed successfully or that the extracted value was a valid numeric ID. A malformed API response could silently produce an empty or garbage `run_id`.

**Fix:** Added `validate_json()` (verifies the file is parseable by jq) and `validate_numeric_id()` (enforces `^[0-9]+$` before any ID is used). Both are called after every API response is received.

---

### 4. Insufficient API Error Handling

**Severity:** HIGH

**Original code:**
```bash
if echo "$response" | grep -q "API rate limit exceeded"; then ...
elif echo "$response" | grep -q "Not Found"; then ...
```

Only two specific strings were checked. HTTP 401 / 403 / 5xx responses went undetected and silently produced empty variables.

**Fix:** The `api_get` helper captures the HTTP status code with `curl -w "%{http_code}"` and handles every status class explicitly:

| Code | Meaning | Action |
|------|---------|--------|
| 200  | OK | Continue |
| 401  | Unauthorized | Exit with auth error |
| 403  | Forbidden | Exit with permission error |
| 404  | Not Found | Exit with resource error |
| 429  | Rate Limited | Exit with rate-limit error |
| other | Unexpected | Exit with HTTP code |

---

### 5. Weak Input Validation

**Severity:** HIGH

**Original code:** No validation of `ORG_NAME`, `REPO_NAME`, `WORKFLOW_ID`, or numeric inputs.

**Fix:** `validate_input()` enforces non-empty strings; `validate_positive_int()` enforces positive integers. All required inputs are validated before the script proceeds.

---

## 🟡 Medium-Severity Issues

### 6. Race Condition in Workflow Detection

**Severity:** MEDIUM

**Original code:**
```bash
current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ...
select(.created_at >= $current_time)
```

If the workflow was triggered a few seconds before `current_time` was captured (clock skew, scheduling latency) it would never be found.

**Fix:** A 5-minute buffer is subtracted from `current_time` so runs created slightly before the script started are still matched. The `jq` query also now selects the **most recent** matching run (`sort_by(.created_at) | last`) instead of returning all matches, preventing selection of a stale run.

---

### 7. Rate Limiting Protection

**Severity:** MEDIUM

The original script checked for the rate-limit string in the body but would still retry on a 429 response that returned a different body format.

**Fix:** HTTP 429 is now caught at the transport layer by `api_get` and results in an immediate, clean exit with an informative message.

---

### 8. Information Disclosure via Echo Statements

**Severity:** MEDIUM

Startup banners revealed the exact organisation, repository, and workflow ID being monitored.

**Fix:** Informational log output is limited to non-sensitive operational data (reference, timing configuration). See fix for issue #2 above.

---

## Additional Hardening

- **`set -euo pipefail`** — strict bash error mode; any unhandled error immediately aborts the script.
- **Temporary directory** — API responses are written to a `mktemp -d` directory and cleaned up via a `trap EXIT` handler, preventing response data from persisting on disk.
- **`RUN_ID` validation** — when a caller-supplied `RUN_ID` is used directly it is now validated as a numeric ID before being passed to the API.
- **Backward compatibility** — all existing `action.yml` inputs and exit codes are preserved; no changes are required for existing callers.

---

## Compliance

- OWASP Top 10 (A02 Cryptographic Failures, A05 Security Misconfiguration)
- NIST Cybersecurity Framework (PR.AC, PR.DS)
- CIS Benchmarks for shell scripting
- GitHub Security Best Practices for Actions
