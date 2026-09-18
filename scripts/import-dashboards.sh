#!/usr/bin/env bash
# Import the OTel index patterns, visualisations and dashboards into OpenSearch Dashboards.
#
# HTTP Basic auth as `admin` -- stage 1 has no OIDC, so this is the only auth path there
# is, over plain HTTP (no Gateway, no TLS).
set -euo pipefail
cd "$(dirname "$0")/.."

KUBE_CONTEXT="${KUBE_CONTEXT-vks:workload-vsphere-vks2}"
k() {
  if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"
  else kubectl "$@"; fi
}

NDJSON="${1:-dashboards/otel-dashboards.ndjson}"
[[ -f "$NDJSON" ]] || { echo "error: $NDJSON not found" >&2; exit 1; }

# Prefer the external LoadBalancer IP; fall back to a port-forward if it is not
# reachable (e.g. the cloud provider hasn't assigned one yet).
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

echo "importing $(wc -l < "$NDJSON" | tr -d ' ') objects into ${url}"
resp=$(curl -s -u "admin:${PW}" -H 'osd-xsrf:true' \
        -F "file=@${NDJSON}" \
        "${url}/api/saved_objects/_import?overwrite=true")

echo "$resp" | python3 -c "
import json, sys
r = json.load(sys.stdin)
print('  success=%s  imported=%s' % (r.get('success'), r.get('successCount')))
for e in (r.get('errors') or []):
    print('  ERROR %s/%s: %s' % (e.get('type'), e.get('id'), json.dumps(e.get('error'))))
" || { echo "unexpected response:"; echo "$resp" | head -c 800; exit 1; }

# Index-pattern objects in dashboards/otel-dashboards.ndjson carry no `fields` cache
# (a real "Refresh field list" click would populate it) -- without it, every
# visualization's aggregation fails at render time with "Could not locate that
# index-pattern-field". Do exactly what that button does, for every index pattern,
# via the same internal API OpenSearch Dashboards' own UI uses.
echo "refreshing field lists for imported index patterns..."
OSD_URL="$url" OSD_PW="$PW" python3 -c "
import json, os, urllib.parse, urllib.request

url = os.environ['OSD_URL']
pw = os.environ['OSD_PW']

def call(method, path, body=None):
    import base64
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url + path, data=data, method=method)
    req.add_header('Authorization', 'Basic ' + base64.b64encode(('admin:' + pw).encode()).decode())
    req.add_header('osd-xsrf', 'true')
    if data is not None:
        req.add_header('content-type', 'application/json')
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)

patterns = call('GET', '/api/saved_objects/_find?type=index-pattern&per_page=100')
for obj in patterns['saved_objects']:
    title = obj['attributes']['title']
    enc = urllib.parse.quote(title, safe='')
    meta = urllib.parse.quote(json.dumps(['_source', '_id', '_type', '_index', '_score']), safe='')
    fields_resp = call('GET', f'/api/index_patterns/_fields_for_wildcard?pattern={enc}&meta_fields={meta}')
    fields_json = json.dumps(fields_resp['fields'])
    call('PUT', f\"/api/saved_objects/index-pattern/{obj['id']}\", {'attributes': {'fields': fields_json}})
    print(f\"  refreshed {obj['id']} ({title}): {len(fields_resp['fields'])} fields\")
"
