#!/usr/bin/env bash
# Export saved objects from OpenSearch Dashboards back into dashboards/otel-dashboards.ndjson.
#
# This is the other half of import-dashboards.sh. Anything you build or edit in the UI lives
# only in the .kibana index until you run this -- the repo file is not updated automatically.
#
# The output is NORMALISED so it is diff-friendly and re-importable anywhere:
#   * the export API's trailing {"exportedCount":...} summary line is dropped
#   * per-install churn fields (updated_at, version, migrationVersion, namespaces,
#     coreMigrationVersion) are stripped -- otherwise every export is a noisy diff
#   * objects are sorted by type then id, so ordering is stable run to run
#
# Usage:
#   scripts/export-dashboards.sh                 # everything (default)
#   scripts/export-dashboards.sh --ours          # only the OTel dashboards + their references
#   scripts/export-dashboards.sh --out other.ndjson
set -euo pipefail
cd "$(dirname "$0")/.."

KUBE_CONTEXT="${KUBE_CONTEXT-vks:workload-vsphere-vks2}"
k() {
  if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"
  else kubectl "$@"; fi
}

OUT="dashboards/otel-dashboards.ndjson"
MODE="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ours) MODE="ours"; shift ;;
    --out)  OUT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

ip=$(k -n observability get svc opensearch-dashboards \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
PW=$(k -n observability get secret opensearch-bootstrap \
      -o jsonpath='{.data.admin-password}' | base64 -d)

url="http://${ip}"
if [[ -z "$ip" ]] || ! curl -s -o /dev/null --max-time 10 "${url}/api/status"; then
  echo "external LoadBalancer IP unreachable, falling back to port-forward"
  k -n observability port-forward svc/opensearch-dashboards 5601:5601 >/dev/null 2>&1 &
  pf=$!; trap 'kill $pf 2>/dev/null' EXIT
  sleep 4
  url="http://127.0.0.1:5601"
fi

if [[ "$MODE" == "ours" ]]; then
  body='{"objects":[
    {"type":"dashboard","id":"otel-traces-dash"},
    {"type":"dashboard","id":"otel-logs-dash"},
    {"type":"dashboard","id":"otel-metrics-dash"}],
    "includeReferencesDeep":true}'
else
  body='{"type":["index-pattern","visualization","dashboard","search"],
         "includeReferencesDeep":true}'
fi

echo "exporting ($MODE) from ${url}"
raw=$(curl -s -u "admin:${PW}" -H 'osd-xsrf:true' -H 'content-type:application/json' \
        -X POST "${url}/api/saved_objects/_export" -d "$body")

tmp=$(mktemp); trap 'rm -f "$tmp"' RETURN
printf '%s' "$raw" | python3 -c '
import json, sys

STRIP = ("updated_at", "version", "migrationVersion", "namespaces",
         "coreMigrationVersion", "managed", "typeMigrationVersion", "created_at")

objs, summary = [], None
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    o = json.loads(line)
    if "exportedCount" in o:
        summary = o
        continue
    for f in STRIP:
        o.pop(f, None)
    objs.append(o)

objs.sort(key=lambda o: (o.get("type", ""), o.get("id", "")))
for o in objs:
    print(json.dumps(o, sort_keys=True))
if summary:
    print("# exported %s objects, missingRefCount=%s"
          % (summary.get("exportedCount"), summary.get("missingRefCount")),
          file=sys.stderr)
' > "$tmp"

if [[ ! -s "$tmp" ]]; then
  echo "error: export produced nothing. Response was:" >&2
  printf '%s' "$raw" | head -c 500 >&2; echo >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
if [[ -f "$OUT" ]] && diff -q "$OUT" "$tmp" >/dev/null 2>&1; then
  echo "no change: $OUT is already up to date ($(wc -l < "$tmp" | tr -d ' ') objects)"
else
  if [[ -f "$OUT" ]]; then
    changed=$(diff "$OUT" "$tmp" | grep -c '^[<>]' || true)
  else
    changed="all (new file)"
  fi
  cp "$tmp" "$OUT"
  echo "wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') objects; changed lines: $changed)"
fi

# Portability guard: the file must not carry anything environment-specific.
if grep -qiE '10\.[0-9]+\.[0-9]+\.[0-9]+|sslip\.io|googleusercontent' "$OUT"; then
  echo "WARNING: $OUT contains what look like environment-specific values:" >&2
  grep -ioE '10\.[0-9]+\.[0-9]+\.[0-9]+|sslip\.io|googleusercontent[a-z.]*' "$OUT" \
    | sort -u | sed 's/^/  /' >&2
  echo "  Saved objects should be portable -- check for a hardcoded URL in a panel." >&2
fi
