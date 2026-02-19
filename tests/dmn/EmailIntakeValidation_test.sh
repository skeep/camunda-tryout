#!/usr/bin/env bash
# ==============================================================================
# Test suite for EmailIntakeValidation DMN decision table
# Decision key: Decision_0pz9531
#
# Usage:
#   chmod +x tests/dmn/EmailIntakeValidation_test.sh
#   ./tests/dmn/EmailIntakeValidation_test.sh
#
# Requires: curl, running Camunda instance at CAMUNDA_REST_URL
# ==============================================================================

set -euo pipefail

CAMUNDA_REST_URL="${CAMUNDA_REST_URL:-http://localhost:8080/engine-rest}"
DECISION_KEY="Decision_0pz9531"
ENDPOINT="${CAMUNDA_REST_URL}/decision-definition/key/${DECISION_KEY}/evaluate"

PASS=0
FAIL=0
TOTAL=0

# ------------------------------------------------------------------------------
# Helper: evaluate the decision and assert the expected routingDecision value
# Arguments:
#   $1 - Test name
#   $2 - loanApplicationCount (integer)
#   $3 - requirementsPresent (true/false)
#   $4 - Expected routingDecision string
# ------------------------------------------------------------------------------
evaluate_and_assert() {
  local test_name="$1"
  local count="$2"
  local requirements="$3"
  local expected="$4"

  TOTAL=$((TOTAL + 1))

  local payload
  payload=$(cat <<EOF
{
  "variables": {
    "loanApplicationCount": { "value": ${count}, "type": "Integer" },
    "requirementsPresent":  { "value": ${requirements}, "type": "Boolean" }
  }
}
EOF
)

  local response
  response=$(curl -s -X POST "${ENDPOINT}" \
    -H "Content-Type: application/json" \
    -d "${payload}" 2>&1)

  local actual
  actual=$(echo "${response}" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['routingDecision']['value'])" 2>/dev/null || echo "PARSE_ERROR")

  if [ "${actual}" = "${expected}" ]; then
    PASS=$((PASS + 1))
    printf "  PASS  %-55s got: %s\n" "${test_name}" "${actual}"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL  %-55s expected: %s, got: %s\n" "${test_name}" "${expected}" "${actual}"
  fi
}

echo "============================================================"
echo " EmailIntakeValidation DMN Test Suite"
echo " Endpoint: ${ENDPOINT}"
echo "============================================================"
echo ""

# ------ Rule 1: SUCCESS (count=1, requirements=true) -------------------------
echo "--- Rule 1: SUCCESS ---"
evaluate_and_assert \
  "Exactly 1 application, requirements present" \
  1 true "SUCCESS"

# ------ Rule 2: MULTI_APPLICATION (count > 1) --------------------------------
echo ""
echo "--- Rule 2: MULTI_APPLICATION ---"
evaluate_and_assert \
  "2 applications, requirements present" \
  2 true "MULTI_APPLICATION"

evaluate_and_assert \
  "5 applications, requirements present" \
  5 true "MULTI_APPLICATION"

evaluate_and_assert \
  "100 applications, requirements present" \
  100 true "MULTI_APPLICATION"

evaluate_and_assert \
  "2 applications, requirements missing" \
  2 false "MULTI_APPLICATION"

evaluate_and_assert \
  "10 applications, requirements missing" \
  10 false "MULTI_APPLICATION"

# ------ Rule 3: INVALID_NO_APPLICATION (count=0) -----------------------------
echo ""
echo "--- Rule 3: INVALID_NO_APPLICATION ---"
evaluate_and_assert \
  "0 applications, requirements present" \
  0 true "INVALID_NO_APPLICATION"

evaluate_and_assert \
  "0 applications, requirements missing" \
  0 false "INVALID_NO_APPLICATION"

# ------ Rule 4: INVALID_BAD_DATA (catch-all) ----------------------------------
echo ""
echo "--- Rule 4: INVALID_BAD_DATA (catch-all) ---"
evaluate_and_assert \
  "1 application, requirements missing (bad data)" \
  1 false "INVALID_BAD_DATA"

evaluate_and_assert \
  "Negative count (-1), requirements present" \
  -1 true "INVALID_BAD_DATA"

evaluate_and_assert \
  "Negative count (-99), requirements missing" \
  -99 false "INVALID_BAD_DATA"

# ------ Hit Policy: FIRST (priority order) ------------------------------------
echo ""
echo "--- Hit Policy: FIRST (priority verification) ---"
evaluate_and_assert \
  "count=1,req=true matches rule 1 before catch-all" \
  1 true "SUCCESS"

evaluate_and_assert \
  "count=3,req=false matches rule 2 before catch-all" \
  3 false "MULTI_APPLICATION"

evaluate_and_assert \
  "count=0,req=true matches rule 3 before catch-all" \
  0 true "INVALID_NO_APPLICATION"

# ------ Summary ---------------------------------------------------------------
echo ""
echo "============================================================"
echo " Results: ${PASS} passed, ${FAIL} failed, ${TOTAL} total"
echo "============================================================"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
