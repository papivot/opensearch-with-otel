#!/usr/bin/env bash
# Applies manifests/ in order. No templating, no per-stage scripts -- every file is
# static. Safe to re-run.
#
# Usage:
#   scripts/apply.sh preflight   # check context + permissions only, change nothing
#   scripts/apply.sh all         # apply every manifest in order
set -euo pipefail
cd "$(dirname "$0")/.."

KUBE_CONTEXT="${KUBE_CONTEXT-vks:workload-vsphere-vks2}"
k() {
  if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"
  else kubectl "$@"; fi
}

cmd="${1:-}"
[[ "$cmd" =~ ^(preflight|all)$ ]] || {
  echo "usage: $0 {preflight|all}" >&2
  exit 1
}

preflight() {
  if ! k version -o json >/dev/null 2>&1; then
    echo "error: cannot reach the cluster with --context $KUBE_CONTEXT" >&2
    echo "       contexts available:" >&2
    kubectl config get-contexts -o name | sed 's/^/         /' >&2
    exit 1
  fi
  who=$(k auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null || echo unknown)
  echo "context: $KUBE_CONTEXT   identity: $who"
  for r in namespaces clusterroles helmreleases.helm.toolkit.fluxcd.io; do
    printf '  %-46s %s\n' "$r" "$(k auth can-i create "$r" 2>/dev/null || echo no)"
  done
}

preflight
[[ "$cmd" == "preflight" ]] && { echo "preflight only -- nothing applied"; exit 0; }

echo "== namespaces + chart sources =="
k apply -f manifests/00-namespaces.yaml
k apply -f manifests/01-sources.yaml

echo "== OpenTelemetry Operator (Helm chart via helm-controller) =="
k apply -f manifests/02-hr-otel-operator.yaml
k -n observability wait --for=condition=Ready helmrelease/otel-operator --timeout=3m
# The HelmRelease reporting Ready means Helm's install call returned, not that the
# operator's admission webhook is serving yet (its self-signed cert Secret is created by
# a Helm hook a few seconds later). Wait for the Deployment itself before submitting any
# OpenTelemetryCollector CR, or the apply below can fail with a webhook TLS/connection
# error -- re-running this script is the fix if that happens.
k -n observability rollout status deployment/otel-operator-opentelemetry-operator --timeout=3m

echo "== gateway collector (OpenTelemetryCollector CR, mode: deployment) =="
k apply -f manifests/03-otel-collector-gateway.yaml

echo "== agent collector (OpenTelemetryCollector CR, mode: daemonset) =="
k apply -f manifests/04-otel-collector-agent.yaml

echo "== admin credential =="
k apply -f manifests/05-secret-opensearch-admin.yaml

echo "== OpenSearch (Helm chart via helm-controller) =="
k apply -f manifests/06-hr-opensearch.yaml

echo "== OpenSearch Dashboards (Helm chart via helm-controller) =="
k apply -f manifests/07-hr-opensearch-dashboards.yaml

echo "== Data Prepper (Helm chart via helm-controller) =="
# Blocks on an initContainer until the bootstrap Job's raw-span-policy exists -- that is
# the intended ordering, not a fault.
k apply -f manifests/08-hr-data-prepper.yaml

echo "== bootstrap payloads + Job (ISM policies + index templates) =="
k apply -f manifests/09-bootstrap-payloads.yaml
# Job spec is immutable -- a changed payload needs the old object gone first.
k -n observability delete job opensearch-bootstrap --ignore-not-found --wait=true
k apply -f manifests/10-bootstrap-job.yaml

echo "== OpenTelemetry Demo (Helm chart via helm-controller) =="
k apply -f manifests/11-hr-otel-demo.yaml

echo
echo "done. watch progress with:"
echo "  kubectl --context $KUBE_CONTEXT -n observability get helmrelease -w"
echo "  kubectl --context $KUBE_CONTEXT -n observability get pods"
echo "  kubectl --context $KUBE_CONTEXT -n otel-demo get pods"
echo
echo "REQUIRED FOLLOW-UP -- the demo's browser-side OTLP endpoint cannot be known before"
echo "the frontend-proxy LoadBalancer gets an IP:"
echo "  kubectl --context $KUBE_CONTEXT -n otel-demo get svc frontend-proxy \\"
echo "    -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
echo "then edit PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT in manifests/11-hr-otel-demo.yaml"
echo "and re-apply just that file."
echo
echo "then import the dashboards:"
echo "  scripts/import-dashboards.sh"
