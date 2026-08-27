#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2 author=${3:-regression} exempt_authors=${4:-}
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR="$author" PR_NUMBER=3006 \
    NM_EXEMPT_AUTHORS="$exempt_authors" \
    python3 "$VERIFY" 2>&1
}

run_legacy_event_verifier() {
  local author=$1 exempt_authors=$2 event_file
  event_file="$TMP_ROOT/event-$author.json"
  printf '%s\n' \
    "{\"pull_request\":{\"body\":\"$SIGNATURE\",\"head\":{\"sha\":\"$NEW_SHA\",\"ref\":\"feature\"},\"user\":{\"login\":\"$author\"},\"number\":3006}}" \
    > "$event_file"
  PR_BODY='' PR_HEAD_SHA='' PR_HEAD_REF='' PR_AUTHOR='' PR_NUMBER='' \
    NM_EXEMPT_AUTHORS="$exempt_authors" GITHUB_EVENT_PATH="$event_file" \
    python3 "$VERIFY" 2>&1
}

test_configured_fork_owner_is_exempt() {
  local output rc
  rc=0
  output=$(run_legacy_event_verifier captain captain) || rc=$?
  expect_code 0 "$rc" "shared action rejected the configured fork owner"
  assert_contains "$output" "author captain is a configured exempt author" \
    "shared action did not report the fork-owner exemption"
  pass "shared action exempts a configured fork owner during a tool-floor transition"
}

test_legacy_non_owner_stays_strict() {
  local output rc
  rc=0
  output=$(run_legacy_event_verifier contributor captain) || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action exempted a non-owner contributor"
  assert_contains "$output" "missing structured pipeline step attestation" \
    "non-owner failure did not preserve the structured-attestation requirement"
  pass "shared action still requires a structured attestation from non-owners"
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

fetch_shared_verifier
test_configured_fork_owner_is_exempt
test_legacy_non_owner_stays_strict
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
