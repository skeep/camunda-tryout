#!/usr/bin/env bash
# ==============================================================================
# Deploy all BPMN and DMN resources to Camunda 7 via the REST API.
#
# Usage:
#   ./scripts/deploy.sh                 # bundle all resources in one deployment
#   ./scripts/deploy.sh --per-file      # one deployment per resource file
#
# Environment variables:
#   CAMUNDA_REST_URL  Base REST URL  (default: http://localhost:8080/engine-rest)
#   DEPLOY_NAME       Deployment name (default: camunda-tryout)
#   WAIT_TIMEOUT      Seconds to wait for Camunda to become ready (default: 120)
#
# Requires: curl, python3 (for JSON parsing)
# ==============================================================================

set -euo pipefail

CAMUNDA_REST_URL="${CAMUNDA_REST_URL:-http://localhost:8080/engine-rest}"
DEPLOY_NAME="${DEPLOY_NAME:-camunda-tryout}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES_DIR="$PROJECT_ROOT/resources"

PER_FILE=false
if [[ "${1:-}" == "--per-file" ]]; then
  PER_FILE=true
fi

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

log()  { printf "[deploy] %s\n" "$*"; }
err()  { printf "[deploy] ERROR: %s\n" "$*" >&2; }
die()  { err "$@"; exit 1; }

wait_for_engine() {
  local url="$CAMUNDA_REST_URL/engine"
  local elapsed=0

  log "Waiting for Camunda at $url (timeout: ${WAIT_TIMEOUT}s) ..."
  while [ "$elapsed" -lt "$WAIT_TIMEOUT" ]; do
    if curl -sf -o /dev/null "$url" 2>/dev/null; then
      log "Camunda is ready."
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  die "Camunda did not become ready within ${WAIT_TIMEOUT}s"
}

collect_resources() {
  local files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$RESOURCES_DIR" \( -name '*.bpmn' -o -name '*.dmn' \) -print0 | sort -z)

  if [ "${#files[@]}" -eq 0 ]; then
    die "No .bpmn or .dmn files found under $RESOURCES_DIR"
  fi

  printf '%s\n' "${files[@]}"
}

parse_deployment_response() {
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception as e:
    print(f'  Failed to parse response: {e}', file=sys.stderr)
    sys.exit(1)

if 'id' not in data:
    msg = data.get('message', json.dumps(data))
    print(f'  Deployment failed: {msg}', file=sys.stderr)
    sys.exit(1)

print(f'  Deployment ID : {data[\"id\"]}')
print(f'  Name          : {data.get(\"name\", \"\")}')
resources = data.get('deployedProcessDefinitions', {}) or {}
resources.update(data.get('deployedDecisionDefinitions', {}) or {})
resources.update(data.get('deployedDecisionRequirementsDefinitions', {}) or {})
if resources:
    print(f'  Resources     :')
    for key in resources:
        print(f'    - {key}')
else:
    print('  (no new resources deployed — already up to date)')
"
}

# ------------------------------------------------------------------------------
# Deploy: all resources in a single deployment
# ------------------------------------------------------------------------------

deploy_bundle() {
  local -a curl_args=(
    -s -X POST "$CAMUNDA_REST_URL/deployment/create"
    -F "deployment-name=$DEPLOY_NAME"
    -F "deploy-changed-only=true"
    -F "deployment-source=deploy-script"
  )

  local count=0
  while IFS= read -r file; do
    local basename
    basename="$(basename "$file")"
    curl_args+=(-F "$basename=@$file")
    count=$((count + 1))
  done <<< "$(collect_resources)"

  log "Deploying $count resource(s) as '$DEPLOY_NAME' ..."
  local response
  response=$(curl "${curl_args[@]}" 2>&1)

  echo "$response" | parse_deployment_response
}

# ------------------------------------------------------------------------------
# Deploy: one deployment per resource file
# ------------------------------------------------------------------------------

deploy_per_file() {
  local pass=0 fail=0 total=0

  while IFS= read -r file; do
    local basename
    basename="$(basename "$file")"
    local name="${DEPLOY_NAME}--${basename}"
    total=$((total + 1))

    log "[$total] Deploying $basename ..."
    local response
    response=$(curl -s -X POST "$CAMUNDA_REST_URL/deployment/create" \
      -F "deployment-name=$name" \
      -F "deploy-changed-only=true" \
      -F "deployment-source=deploy-script" \
      -F "$basename=@$file" 2>&1)

    if echo "$response" | parse_deployment_response; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
    fi
    echo ""
  done <<< "$(collect_resources)"

  log "Results: $pass passed, $fail failed, $total total"
  [ "$fail" -eq 0 ] || exit 1
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

echo "============================================================"
echo " Camunda Resource Deployment"
echo " REST API : $CAMUNDA_REST_URL"
echo " Mode     : $([ "$PER_FILE" = true ] && echo "per-file" || echo "bundle")"
echo "============================================================"
echo ""

wait_for_engine

if [ "$PER_FILE" = true ]; then
  deploy_per_file
else
  deploy_bundle
fi

echo ""
log "Done."
