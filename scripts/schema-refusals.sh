#!/usr/bin/env bash
# Proves that the chart refuses what it promises to refuse (values.schema.json and the checks in _helpers.tpl) and
# accepts what the organization's workflow passes. Each case renders the chart with the prod values and one change.
# Needs helm. Usage: scripts/schema-refusals.sh
set -uo pipefail

chart="$(cd "$(dirname "$0")/.." && pwd)/helm"
failed=0

render() { helm template database "$chart" --namespace prod -f "$chart/values-prod.yaml" "$@" > /dev/null 2>&1; }

refuses() {
  local why=$1
  shift
  if render "$@"; then
    echo "FAIL accepted: $why"
    failed=1
  else
    echo "ok refused: $why"
  fi
}

accepts() {
  local why=$1
  shift
  if render "$@"; then
    echo "ok accepted: $why"
  else
    echo "FAIL refused: $why"
    failed=1
  fi
}

accepts "the prod values as they are"
accepts "the workflow's podAnnotations.checksum/app-env" --set-string 'podAnnotations.checksum/app-env=0123abcd'
refuses "an unknown top-level key (a typo)" --set 'persistance.size=4Gi'
refuses "a password in the values (superuser.password)" --set-string 'superuser.password=example-not-a-secret'
refuses "a password where a key name goes" --set-string 'superuser.passwordKey=hunter2'
refuses "another Service name" --set 'serviceName=db'
refuses "another port" --set 'port=5433'
refuses "an image without a digest" --set-string 'image.digest='
refuses "another major version" --set-string 'image.tag=17.6-alpine'
refuses "a CPU limit" --set-string 'resources.limits.cpu=500m'
# Lists: "--set list[i].key=..." would replace the whole list (Helm does not merge lists), so these cases change a
# copy of a complete values file instead.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
variant() { sed -e "$1" "$2" > "$tmp/variant.yaml"; }
base="$chart/values.yaml"
extra="$(dirname "$0")/test-values.yaml"
variant 's/^    role: tenants$/    role: tenants\n    password: example-not-a-secret/' "$base"
refuses "a password field on a database" -f "$tmp/variant.yaml"
variant 's/^    role: tenants$/    role: pg_tenants/' "$base"
refuses "a role name with the reserved prefix pg_" -f "$tmp/variant.yaml"
variant 's/^    role: payments$/    role: tenants/' "$base"
refuses "a role used twice" -f "$tmp/variant.yaml"
variant 's/^  - name: payments$/  - name: tenants/' "$base"
refuses "a database listed twice" -f "$tmp/variant.yaml"
variant 's/PAYMENTS_DB_PASSWORD/TENANTS_DB_PASSWORD/' "$base"
refuses "a Secret key used twice" -f "$tmp/variant.yaml"
variant 's/^    role: tenants$/    role: postgres/' "$base"
refuses "a role named like the superuser" -f "$tmp/variant.yaml"
variant 's/^      - name: trading_app$/      - name: trading/' "$extra"
refuses "an extra role named like its service's role" -f "$tmp/variant.yaml"
variant '/passwordKey: TRADING_APP_DB_PASSWORD/d' "$extra"
refuses "an extra role without a key" -f "$tmp/variant.yaml"
refuses "connection limits above max_connections" --set-string 'config.max_connections=50'
accepts "an extra role with key and limit (scripts/test-values.yaml)" -f "$extra"

if [[ "$failed" -ne 0 ]]; then
  echo "schema refusals FAILED"
  exit 1
fi
echo "schema refusals passed"
