#!/usr/bin/env bash
# ==============================================================================
# Test suite for SalesOfficerNotificationAction DMN decision table
# Decision key: SalesOfficerNotificationAction
#
# Usage:
#   chmod +x tests/dmn/SalesOfficerNotificationAction_test.sh
#   ./tests/dmn/SalesOfficerNotificationAction_test.sh
#
# Requires: curl, python3, running Camunda instance at CAMUNDA_REST_URL
# ==============================================================================

set -euo pipefail

CAMUNDA_REST_URL="${CAMUNDA_REST_URL:-http://localhost:8080/engine-rest}"
DECISION_KEY="SalesOfficerNotificationAction"
ENDPOINT="${CAMUNDA_REST_URL}/decision-definition/key/${DECISION_KEY}/evaluate"

PASS=0
FAIL=0
TOTAL=0

# ------------------------------------------------------------------------------
# Helper: evaluate the decision and assert expected action + notificationType
# Arguments:
#   $1 - Test name
#   $2 - triggerReason (string)
#   $3 - notificationStage (string)
#   $4 - isBusinessHours (true/false)
#   $5 - responseReceived (true/false)
#   $6 - Expected action
#   $7 - Expected notificationType
# ------------------------------------------------------------------------------
evaluate_and_assert() {
  local test_name="$1"
  local trigger="$2"
  local stage="$3"
  local bh="$4"
  local response="$5"
  local expected_action="$6"
  local expected_type="$7"

  TOTAL=$((TOTAL + 1))

  local payload
  payload=$(cat <<EOF
{
  "variables": {
    "triggerReason":      { "value": "${trigger}",  "type": "String" },
    "notificationStage":  { "value": "${stage}",    "type": "String" },
    "isBusinessHours":    { "value": ${bh},         "type": "Boolean" },
    "responseReceived":   { "value": ${response},   "type": "Boolean" }
  }
}
EOF
)

  local resp
  resp=$(curl -s -X POST "${ENDPOINT}" \
    -H "Content-Type: application/json" \
    -d "${payload}" 2>&1)

  local actual_action actual_type
  actual_action=$(echo "${resp}" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['action']['value'])" 2>/dev/null || echo "PARSE_ERROR")
  actual_type=$(echo "${resp}" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['notificationType']['value'])" 2>/dev/null || echo "PARSE_ERROR")

  if [ "${actual_action}" = "${expected_action}" ] && [ "${actual_type}" = "${expected_type}" ]; then
    PASS=$((PASS + 1))
    printf "  PASS  %-60s action=%-22s type=%s\n" "${test_name}" "${actual_action}" "${actual_type}"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL  %-60s\n" "${test_name}"
    printf "        expected: action=%-22s type=%s\n" "${expected_action}" "${expected_type}"
    printf "        actual:   action=%-22s type=%s\n" "${actual_action}" "${actual_type}"
  fi
}

echo "============================================================"
echo " SalesOfficerNotificationAction DMN Test Suite"
echo " Endpoint: ${ENDPOINT}"
echo "============================================================"
echo ""

# ======================================================================
# Rule 1: Kill switch – responseReceived=true overrides everything
# ======================================================================
echo "--- Rule 1: Kill Switch (responseReceived=true) ---"

evaluate_and_assert \
  "Response at INITIAL stage" \
  "MULTI_APPLICATION" "INITIAL" true true \
  "RESUME_PROCESSING" "NONE"

evaluate_and_assert \
  "Response at FU1 stage" \
  "MULTI_APPLICATION" "FU1" true true \
  "RESUME_PROCESSING" "NONE"

evaluate_and_assert \
  "Response at FU2 stage" \
  "INVALID_NO_APPLICATION" "FU2" false true \
  "RESUME_PROCESSING" "NONE"

evaluate_and_assert \
  "Response at DEADLINE stage" \
  "INVALID_BAD_DATA" "DEADLINE" false true \
  "RESUME_PROCESSING" "NONE"

evaluate_and_assert \
  "Response outside business hours" \
  "MULTI_APPLICATION" "FU1" false true \
  "RESUME_PROCESSING" "NONE"

# ======================================================================
# Rule 2: INITIAL notification – within business hours
# ======================================================================
echo ""
echo "--- Rule 2: INITIAL – Business Hours ---"

evaluate_and_assert \
  "MULTI_APPLICATION, INITIAL, BH=true" \
  "MULTI_APPLICATION" "INITIAL" true false \
  "SEND_NOW" "INITIAL_ALERT"

evaluate_and_assert \
  "INVALID_NO_APPLICATION, INITIAL, BH=true" \
  "INVALID_NO_APPLICATION" "INITIAL" true false \
  "SEND_NOW" "INITIAL_ALERT"

evaluate_and_assert \
  "INVALID_BAD_DATA, INITIAL, BH=true" \
  "INVALID_BAD_DATA" "INITIAL" true false \
  "SEND_NOW" "INITIAL_ALERT"

# ======================================================================
# Rule 3: INITIAL notification – outside business hours
# ======================================================================
echo ""
echo "--- Rule 3: INITIAL – Outside Business Hours ---"

evaluate_and_assert \
  "MULTI_APPLICATION, INITIAL, BH=false" \
  "MULTI_APPLICATION" "INITIAL" false false \
  "SCHEDULE_NEXT_WINDOW" "INITIAL_ALERT"

evaluate_and_assert \
  "INVALID_NO_APPLICATION, INITIAL, BH=false" \
  "INVALID_NO_APPLICATION" "INITIAL" false false \
  "SCHEDULE_NEXT_WINDOW" "INITIAL_ALERT"

# ======================================================================
# Rule 4: FU1 – within business hours
# ======================================================================
echo ""
echo "--- Rule 4: FU1 – Business Hours ---"

evaluate_and_assert \
  "MULTI_APPLICATION, FU1, BH=true" \
  "MULTI_APPLICATION" "FU1" true false \
  "SEND_NOW" "FOLLOW_UP_1"

evaluate_and_assert \
  "INVALID_BAD_DATA, FU1, BH=true" \
  "INVALID_BAD_DATA" "FU1" true false \
  "SEND_NOW" "FOLLOW_UP_1"

# ======================================================================
# Rule 5: FU1 – outside business hours
# ======================================================================
echo ""
echo "--- Rule 5: FU1 – Outside Business Hours ---"

evaluate_and_assert \
  "MULTI_APPLICATION, FU1, BH=false" \
  "MULTI_APPLICATION" "FU1" false false \
  "SCHEDULE_NEXT_WINDOW" "FOLLOW_UP_1"

# ======================================================================
# Rule 6: FU2 – within business hours
# ======================================================================
echo ""
echo "--- Rule 6: FU2 – Business Hours ---"

evaluate_and_assert \
  "MULTI_APPLICATION, FU2, BH=true" \
  "MULTI_APPLICATION" "FU2" true false \
  "SEND_NOW" "FOLLOW_UP_2"

# ======================================================================
# Rule 7: FU2 – outside business hours
# ======================================================================
echo ""
echo "--- Rule 7: FU2 – Outside Business Hours ---"

evaluate_and_assert \
  "MULTI_APPLICATION, FU2, BH=false" \
  "MULTI_APPLICATION" "FU2" false false \
  "SCHEDULE_NEXT_WINDOW" "FOLLOW_UP_2"

# ======================================================================
# Rule 8: DEADLINE – close workflow
# ======================================================================
echo ""
echo "--- Rule 8: DEADLINE – Close Workflow ---"

evaluate_and_assert \
  "DEADLINE during business hours" \
  "MULTI_APPLICATION" "DEADLINE" true false \
  "CLOSE_WORKFLOW" "CLOSING_MESSAGE"

evaluate_and_assert \
  "DEADLINE outside business hours" \
  "INVALID_NO_APPLICATION" "DEADLINE" false false \
  "CLOSE_WORKFLOW" "CLOSING_MESSAGE"

# ======================================================================
# Edge case: SUCCESS trigger should NOT reach this DMN
# The not("SUCCESS") filter means no rule matches → empty result
# ======================================================================
echo ""
echo "--- Edge Case: SUCCESS trigger (should not normally occur) ---"

TOTAL=$((TOTAL + 1))
edge_resp=$(curl -s -X POST "${ENDPOINT}" \
  -H "Content-Type: application/json" \
  -d '{"variables":{"triggerReason":{"value":"SUCCESS","type":"String"},"notificationStage":{"value":"INITIAL","type":"String"},"isBusinessHours":{"value":true,"type":"Boolean"},"responseReceived":{"value":false,"type":"Boolean"}}}')
if [ "${edge_resp}" = "[]" ]; then
  PASS=$((PASS + 1))
  printf "  PASS  %-60s result=[] (no rule matched – correct)\n" "SUCCESS trigger returns empty (rejected by not-SUCCESS)"
else
  FAIL=$((FAIL + 1))
  printf "  FAIL  %-60s expected=[], got=%s\n" "SUCCESS trigger returns empty (rejected by not-SUCCESS)" "${edge_resp}"
fi

# ======================================================================
# Summary
# ======================================================================
echo ""
echo "============================================================"
echo " Results: ${PASS} passed, ${FAIL} failed, ${TOTAL} total"
echo "============================================================"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
