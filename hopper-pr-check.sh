#!/usr/bin/env bash
set -euo pipefail

# Exit codes
# 0: Success - scan completed, no blocking issues
# 1: Failure - scan completed, blocking issues found
# 2: Error - API token missing, scan didn't complete, etc.

# Required input
API_TOKEN="${API_TOKEN:-}"
if [[ -z "$API_TOKEN" ]]; then
  echo "Error: API_TOKEN environment variable is required."
  exit 2
fi

# Optional inputs with defaults
BLOCK_ON_CRITICAL="${BLOCK_ON_CRITICAL:-true}"
BLOCK_ON_HIGH="${BLOCK_ON_HIGH:-true}"
BLOCK_ON_MEDIUM="${BLOCK_ON_MEDIUM:-false}"
BLOCK_ON_LOW="${BLOCK_ON_LOW:-false}"
MAX_POLLING_ATTEMPTS="${MAX_POLLING_ATTEMPTS:-30}"
UPLOAD_RESULTS="${UPLOAD_RESULTS:-true}"
ARTIFACT_NAME="${ARTIFACT_NAME:-hopper-security-scan-results}"
ARTIFACT_RETENTION_DAYS="${ARTIFACT_RETENTION_DAYS:-7}"

# Simulated GitHub environment (replace with actual values or set as env vars)
REPO_ID="${REPO_ID:-123456}"
REPO_URL="${REPO_URL:-https://github.com/example/repo}"
BRANCH="${BRANCH:-main}"
COMMIT_HASH="${COMMIT_HASH:-HEAD}"

API_URL="https://api.hopper.security"

echo "Triggering scan..."
SCAN_RESPONSE=$(curl -s -X POST "$API_URL/v1/pr-checks" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"repoId\": \"$REPO_ID\",
    \"repoUrl\": \"$REPO_URL\",
    \"branch\": \"$BRANCH\",
    \"commitHash\": \"$COMMIT_HASH\"
  }")

SCAN_ID=$(echo "$SCAN_RESPONSE" | sed 's/^.*"\([0-9]*\)".*$/\1/')
echo "Scan ID: $SCAN_ID"

echo "Polling for scan status..."
STATUS="PENDING"
ATTEMPT=0
while [[ "$STATUS" != "COMPLETED" && "$STATUS" != "FAILED" && "$STATUS" != "TIMEOUT" && $ATTEMPT -lt $MAX_POLLING_ATTEMPTS ]]; do
  sleep 30
  ((ATTEMPT++))
  echo "Attempt $ATTEMPT of $MAX_POLLING_ATTEMPTS..."

  STATUS_RESPONSE=$(curl -s -X GET "$API_URL/v1/scans/$SCAN_ID/status" \
    -H "Authorization: Bearer $API_TOKEN")

  STATUS=$(echo "$STATUS_RESPONSE" | sed 's/.*"status":"\([^"]*\)".*/\1/')
  echo "Current status: $STATUS"
done

if [[ "$STATUS" != "COMPLETED" ]]; then
  echo "Error: Scan did not complete. Status: $STATUS"
  exit 2
fi

echo "Fetching scan results..."
RESULTS=$(curl -s -X GET "$API_URL/v1/scans/$SCAN_ID" \
  -H "Authorization: Bearer $API_TOKEN")
echo "$RESULTS" > "${ARTIFACT_NAME}.json"

ISSUE_COUNT=$(echo "$RESULTS" | jq '.projectScanIssues | length // 0')
CRITICAL_COUNT=$(echo "$RESULTS" | jq '[.projectScanIssues[] | select(.vulnerability.cvss.severity == "CRITICAL")] | length // 0')
HIGH_COUNT=$(echo "$RESULTS" | jq '[.projectScanIssues[] | select(.vulnerability.cvss.severity == "HIGH")] | length // 0')
MEDIUM_COUNT=$(echo "$RESULTS" | jq '[.projectScanIssues[] | select(.vulnerability.cvss.severity == "MEDIUM")] | length // 0')
LOW_COUNT=$(echo "$RESULTS" | jq '[.projectScanIssues[] | select(.vulnerability.cvss.severity == "LOW")] | length // 0')

echo "Results:"
echo "- Critical: $CRITICAL_COUNT"
echo "- High: $HIGH_COUNT"
echo "- Medium: $MEDIUM_COUNT"
echo "- Low: $LOW_COUNT"
echo "- Total: $ISSUE_COUNT"

# Export environment variables for all CI platforms
export ISSUE_COUNT="${ISSUE_COUNT}"
export CRITICAL_COUNT="${CRITICAL_COUNT}"
export HIGH_COUNT="${HIGH_COUNT}"
export MEDIUM_COUNT="${MEDIUM_COUNT}"
export LOW_COUNT="${LOW_COUNT}"
export SCAN_STATUS="${STATUS}"

# Uploading artifact (manual, optional)
if [[ "$UPLOAD_RESULTS" == "true" ]]; then
  echo "Results saved to ${ARTIFACT_NAME}.json"
fi

# Blocking logic
BLOCK_REASON=""
SHOULD_BLOCK=false

if [[ "$BLOCK_ON_CRITICAL" == "true" && $CRITICAL_COUNT -gt 0 ]]; then
  BLOCK_REASON="critical"
  SHOULD_BLOCK=true
fi
if [[ "$BLOCK_ON_HIGH" == "true" && $HIGH_COUNT -gt 0 ]]; then
  BLOCK_REASON="${BLOCK_REASON:+$BLOCK_REASON and }high"
  SHOULD_BLOCK=true
fi
if [[ "$BLOCK_ON_MEDIUM" == "true" && $MEDIUM_COUNT -gt 0 ]]; then
  BLOCK_REASON="${BLOCK_REASON:+$BLOCK_REASON and }medium"
  SHOULD_BLOCK=true
fi
if [[ "$BLOCK_ON_LOW" == "true" && $LOW_COUNT -gt 0 ]]; then
  BLOCK_REASON="${BLOCK_REASON:+$BLOCK_REASON and }low"
  SHOULD_BLOCK=true
fi

if [[ "$SHOULD_BLOCK" == "true" ]]; then
  echo "❌ PR check failed: Found $BLOCK_REASON issues."
  exit 1
else
  echo "✅ PR check passed: No blocking security issues found."
  exit 0
fi
