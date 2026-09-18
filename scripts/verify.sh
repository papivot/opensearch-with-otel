#!/usr/bin/env bash
# Read-only health check across the whole stack. Prints a PASS/FAIL line per check.
set -uo pipefail
cd "$(dirname "$0")/.."

KUBE_CONTEXT="${KUBE_CONTEXT-vks:workload-vsphere-vks2}"
k() {
  if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"
  else kubectl "$@"; fi
}

NS=observability
fails=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails+1)); }
info() { printf '        %s\n' "$1"; }

PW=$(k -n $NS get secret opensearch-bootstrap -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
osq() { k -n $NS exec observability-master-0 -- \
          curl -sk -u "admin:${PW}" "https://localhost:9200$1" 2>/dev/null; }

echo "== 1. HelmReleases =="
while read -r name status; do
  [[ -z "$name" ]] && continue
  if [[ "$status" == "True" ]]; then ok "$name"; else bad "$name (Ready=$status)"; fi
done < <(k -n $NS get helmrelease \
          -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)

echo "== 2. bootstrap Job =="
# The Job carries ttlSecondsAfterFinished, so once it has been gone an hour its absence
# is expected. Check 4 below is the durable proof that it actually ran.
if ! k -n $NS get job opensearch-bootstrap >/dev/null 2>&1; then
  info "Job already reaped (ttlSecondsAfterFinished) -- see check 4 for whether it ran"
elif [[ "$(k -n $NS get job opensearch-bootstrap -o jsonpath='{.status.succeeded}' 2>/dev/null)" == "1" ]]; then
  ok "opensearch-bootstrap completed"
else
  bad "opensearch-bootstrap has not succeeded"
  info "kubectl --context $KUBE_CONTEXT -n $NS logs job/opensearch-bootstrap"
fi

echo "== 3. OpenSearch cluster =="
health=$(osq "/_cluster/health" | grep -o '"status":"[a-z]*"' | cut -d'"' -f4)
case "$health" in
  green|yellow) ok "cluster health: $health" ;;
  *)            bad "cluster health: ${health:-unreachable}" ;;
esac

echo "== 4. retention policies are OURS, not Data Prepper's defaults =="
for p in raw-span-policy logs-policy ss4o-metrics-policy; do
  if osq "/_plugins/_ism/policies/$p" | grep -q '"name":"delete"'; then
    ok "$p has a delete state"
  else
    bad "$p is missing a delete state (Data Prepper's rollover-only default won?)"
  fi
done

echo "== 5. index families receiving data =="
for pat in "otel-v1-apm-span-*" "otel-v2-apm-service-map*" "logs-otel-v1-*" "ss4o_metrics-*"; do
  line=$(osq "/_cat/indices/${pat}?h=index,docs.count" | grep -v '^$' | head -1)
  if [[ -n "$line" ]]; then
    docs=$(echo "$line" | awk '{print $2}')
    if [[ "${docs:-0}" -gt 0 ]] 2>/dev/null; then ok "$pat -> $line"; else bad "$pat exists but has 0 docs"; fi
  else
    bad "$pat: no index yet"
  fi
done

echo "== 6. collector export health =="
# The collector's internal Prometheus endpoint binds to ${env:MY_POD_IP}:8888, NOT to
# 0.0.0.0 -- so `kubectl port-forward` (which connects to the pod's loopback) gets
# nothing. Scrape it from another pod instead. The OpenSearch image has curl.
colmetrics=$(k -n $NS exec observability-master-0 -- \
              curl -s --max-time 8 http://otel-gateway-collector:8888/metrics 2>/dev/null)

if [[ -z "$colmetrics" ]]; then
  bad "could not scrape the gateway's :8888 internal telemetry"
else
  for sig in spans log_records metric_points; do
    sent=$(echo "$colmetrics" | grep -E "^otelcol_exporter_sent_${sig}" \
            | awk '{s+=$2} END {printf "%d", s+0}')
    sf=$(echo "$colmetrics"   | grep -E "^otelcol_exporter_send_failed_${sig}" \
            | awk '{s+=$2} END {printf "%d", s+0}')
    if [[ "${sent:-0}" -gt 0 ]]; then ok "exported ${sent} ${sig} (${sf:-0} failed)"
    else bad "exported no ${sig}"; fi
  done
fi

echo "== 7. LoadBalancers =="
daship=$(k -n $NS get svc opensearch-dashboards \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
demoip=$(k -n otel-demo get svc frontend-proxy \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

probe() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$1" 2>/dev/null; }

if [[ -n "$daship" ]]; then
  # 302 is correct: Dashboards redirects "/" to "/app/login" for HTTP Basic auth.
  c=$(probe "http://${daship}/")
  [[ "$c" == "200" || "$c" == "302" ]] && ok "dashboards http://${daship}/ -> $c" \
                      || bad "dashboards http://${daship}/ -> $c"
else bad "opensearch-dashboards has no LoadBalancer IP"; fi

if [[ -n "$demoip" ]]; then
  c=$(probe "http://${demoip}/")
  [[ "$c" == "200" ]] && ok "storefront http://${demoip}/ -> $c" \
                      || bad "storefront http://${demoip}/ -> $c"
else bad "frontend-proxy has no LoadBalancer IP"; fi

echo
if (( fails == 0 )); then
  echo "all checks passed"
else
  echo "$fails check(s) failed"
fi
exit $(( fails > 0 ))
