# OpenSearch as an observability platform, for developers and DevOps

[Partnered with Claude.]

This repo answers one question: *what does it look like to give a developer or DevOps
engineer full observability — logs, metrics and traces — into a microservice app running
on Kubernetes, using OpenSearch as the single backend?*

The sample app is the **OpenTelemetry Demo**: ~20 real microservices that are already
instrumented for OTLP, deployed with an ordinary Helm chart, no code changes required.
It plays the role your own app would play. **OpenSearch is the point** — its Trace
Analytics, Discover and Metrics surfaces are what a developer actually opens to answer
"why is checkout slow" or "what changed at 3pm." Everything else in this repo exists to
get signals from the app into OpenSearch correctly.

There is an OpenTelemetry Collector doing the plumbing in between (agent + gateway,
deployed and managed via the OpenTelemetry Operator). How the collector is configured is
intentionally kept out of this document — see
**[docs/otel-collector.md](docs/otel-collector.md)** if you need to change what it
captures. This document is about the platform: Data Prepper, OpenSearch and Dashboards.

Everything installs through the **Flux helm-controller** already running on the cluster.
This is **stage 1**: no Gateway API, no cert-manager/TLS, no OIDC, and no cluster-wide
Prometheus metrics — the demo storefront and Dashboards are each a plain `Service type:
LoadBalancer`, and only the demo app's own OTLP signals are collected. Every manifest is
static (no templating, no render step) — see
[docs/opensearch-design-doc.md](docs/opensearch-design-doc.md) for what's deliberately
deferred to a later stage and why.

---

## Contents

- [What this builds](#what-this-builds)
- [How the platform is configured to receive telemetry](#how-the-platform-is-configured-to-receive-telemetry)
- [Prerequisites](#prerequisites)
- [Repository layout](#repository-layout)
- [Install](#install)
- [Verify](#verify)
- [Where to look in Dashboards](#where-to-look-in-dashboards)
- [Retention](#retention)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)

---

## What this builds

```
                     ┌────────────── OTel Demo (ns: otel-demo) ──────────────┐
                     │  20 services + k6 load generator                      │
                     │  OTEL_COLLECTOR_NAME -> otel-gateway-collector         │
                     └───────────────────────┬───────────────────────────────┘
                                             │ OTLP  4317 / 4318
  container logs                             ▼
  ┌─ otel-agent ──────────OTLP──────► ┌──────────────────────────────┐
  │  DaemonSet                        │  otel-gateway  (1 replica)   │
  │  filelog receiver +               │  otlp receiver only --       │
  │  k8s_attributes processor         │  no cluster-metrics scraping │
  └───────────────────────────────────┤  transform/k6_cardinality    │
                                      └──────────────┬───────────────┘
                                                     │
                          all three signals, OTLP gRPC 21893
                                                     ▼
                            ┌────────────────────────────────────┐
                            │            Data Prepper             │
                            │  otlp source, routed by event type │
                            │  ├ traces  -> otel_traces          │
                            │  ├ traces  -> service_map      (v1) │
                            │  ├ traces  -> otel_apm_service_map  │
                            │  ├ logs                            │
                            │  └ metrics -> otel_metrics         │
                            └─────────────────┬──────────────────┘
                                              ▼
       ┌────────────────── OpenSearch 3.8.0 (single node) ────────────────────┐
       │  otel-v1-apm-span-*         traces      → Trace Analytics            │
       │  otel-v2-apm-service-map    service map → Application / service map  │
       │  logs-otel-v1-*             logs        → Discover, joined on traceId│
       │  ss4o_metrics-otel-*        metrics     → Observability → Metrics    │
       └───────────┬────────────────────────────────────────────┬───────────┘
                   │                                             │
        Service: LoadBalancer                          Service: LoadBalancer
        (opensearch-dashboards, :80)                    (frontend-proxy, :80)
                   │                                             │
      http://<dashboards-lb-ip>/                    http://<demo-lb-ip>/
```

Two independent `Service type: LoadBalancer` objects, no shared hostname, no TLS, no
Gateway. HTTP Basic auth only (`admin` + Dashboards' own `kibanaserver` backend account).

### Signal routing

| Signal | Path | Index | Rendered by |
|---|---|---|---|
| Traces | Collector → Data Prepper (`otel_traces`) | `otel-v1-apm-span-*` | Trace Analytics — trace list, span waterfall |
| Service map (classic) | Collector → Data Prepper (`service_map`) | `otel-v1-apm-service-map` | Trace Analytics → **Service map** |
| Service map (APM) | Collector → Data Prepper (`otel_apm_service_map`) | `otel-v2-apm-service-map` | OpenSearch 3.6+ APM application map |
| Logs | Agent → Collector → Data Prepper | `logs-otel-v1-*` | Discover; correlates to spans on `traceId` |
| App metrics | Collector → Data Prepper (`otel_metrics`) | `ss4o_metrics-otel-<date>.<hour>` | Observability → Metrics (PPL) |

Every signal goes through Data Prepper. That is not the original design — see
[decision 1](#1-everything-goes-through-data-prepper-including-metrics). There is no
cluster-metrics row: stage 1 collects only the demo app's own OTLP signals — see
[decision 2](#2-no-cluster-metrics-at-all-in-stage-1).

### Component versions

Verified against the live chart indexes, not from memory.

| Component | Chart | App |
|---|---|---|
| `opensearch/opensearch` | 3.8.0 | 3.8.0 |
| `opensearch/opensearch-dashboards` | 3.8.0 | 3.8.0 |
| `opensearch/data-prepper` | 0.3.1 | 2.8.0 → **pinned to image 2.16.0** |
| `open-telemetry/opentelemetry-operator` | 0.123.0 | 0.159.0 |
| `open-telemetry/opentelemetry-demo` | 0.41.2 | 3.0.0 |

The Data Prepper chart was last published in January 2025 and is still eight minor
releases behind, so `image.tag` is pinned to `2.16.0` to get the unified `otlp` source
and the `otel_apm_service_map` processor.

The two collectors are **not** a Helm chart. They are `OpenTelemetryCollector` custom
resources (`manifests/03-otel-collector-gateway.yaml`,
`manifests/04-otel-collector-agent.yaml`) managed by the operator above, running
`ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-k8s:0.159.0`
— matching the operator's own app version. That image is pulled directly from ghcr.io;
unlike the Docker-Hub-hosted `-contrib` image this stack used before, it needs no
`mirror.gcr.io` rewrite.

---

## How the platform is configured to receive telemetry

This is the part worth understanding in detail — it is the actual subject of this repo.
Data Prepper sits between the collector and OpenSearch, and *how* it's configured is
what makes OpenSearch's trace, log and metric views work at all. None of this was
obvious going in; each of the points below is a place where the first, more
direct-sounding approach does not work.

### Pipeline walkthrough

Everything Data Prepper does lives inline in `manifests/08-hr-data-prepper.yaml`'s
`pipelineConfig.config` (a native Helm values map the chart turns into a Secret itself —
no separate file, no substitution step). Reading it top to bottom:

1. **`otlp-pipeline`** — the single entry point, one `otlp` source on port `21893`.
   Both collectors' `otlp_grpc/dataprepper` exporter sends here regardless of signal
   type. A `route` block splits the stream by `getEventType()` into three named routes
   (`logs`, `traces`, `metrics`), each fanning out to its own downstream pipeline.
2. **`otel-logs-pipeline`** — runs `copy_values` to lift `serviceName`, `k8sNamespace`,
   `k8sPod`, `k8sContainer` and `hostName` out of the `flat_object` attribute subtree
   into real top-level `keyword` fields (see [Which fields you can group
   by](#which-fields-you-can-group-by)), then writes with `index_type:
   log-analytics` → the `logs-otel-v1-*` family, correlatable to spans on `traceId`.
3. **`otel-traces-pipeline`** — fans the same span stream into three sibling
   pipelines: `traces-raw-pipeline` (writes `otel-v1-apm-span-*`, what Trace
   Analytics' trace list and waterfall read), `service-map-pipeline` (the
   `otel_apm_service_map` processor → `otel-v2-apm-service-map`, the newer APM map),
   and `service-map-v1-pipeline` (the older `service_map` processor →
   `otel-v1-apm-service-map`, the classic Service map view). Both service-map
   pipelines are stateful, correlating client/server spans over a 30s window — see
   [decision 1](#1-everything-goes-through-data-prepper-including-metrics) for why
   both schemas have to run.
4. **`otel-metrics-pipeline`** — runs `otel_metrics` (with histogram bucket
   calculation on) then the same `copy_values` promotion pattern as logs, and writes
   with `index_type: custom` to `ss4o_metrics-otel-%{yyyy.MM.dd.HH}` — an explicit,
   hourly-suffixed name rather than Data Prepper's built-in `metric-analytics` type,
   because the Metrics view hardcodes the `ss4o_metrics-*-*` pattern (see
   [decision 1](#1-everything-goes-through-data-prepper-including-metrics)).

Every sink authenticates to OpenSearch as `admin`, using the one static password in
`manifests/05-secret-opensearch-admin.yaml` (duplicated as a literal string in the
pipeline config — see that file's header comment for why, and keep the two in sync by
hand if you change it). Stage 1 has no separate ingest user. Once documents land, the
bootstrap Job's index templates and ISM policies (see [Retention](#retention)) are what
keep the four families correctly mapped and aged out, and `dashboards/otel-dashboards.ndjson`
(imported in [step 6](#6-import-the-dashboards)) is what turns them into the charts
described in [Where to look in Dashboards](#where-to-look-in-dashboards).

### 1. Everything goes through Data Prepper, including metrics

Two separate findings force this, and both were confirmed against upstream source rather
than docs.

**Traces cannot bypass Data Prepper.** Pointing the collector's `opensearchexporter` at
OpenSearch produces `ss4o_traces-*` documents, and OpenSearch's trace UIs cannot read
them. The Trace Analytics docs state the plugin *"requires you to use Data Prepper"*, its
data-source selector offers only Jaeger and Data Prepper, and OpenSearch 3.6's APM UI
binds Traces to `otel-v1-apm-span-*` and the application map to
`otel-v2-apm-service-map*`. collector-contrib issue #38680 on exactly this was closed as
*not planned*. The exporter's `mapping.mode: otel-v1` would make the trace list work, but
no collector component can compute the service-map documents — that is Data Prepper's
`otel_apm_service_map` processor and nothing else.

**There are two service-map schemas and they are not interchangeable.** Data Prepper has
two processors, writing two different indices:

| Processor | Index | Read by |
|---|---|---|
| `service_map` (older; deprecatedName `service_map_stateful`) | `otel-v1-apm-service-map` | classic Observability → Trace Analytics → Service map |
| `otel_apm_service_map` (newer, powers OpenSearch 3.6 APM) | `otel-v2-apm-service-map` | the APM application map |

Writing only v2 leaves the classic service map **silently blank** — the view renders, it
just has nothing to draw. The bundled `observabilityDashboards` plugin hardcodes
`otel-v1-apm-service-map` in 14 places and v2 in exactly one, so this is not a
configuration you can talk it out of. Both pipelines therefore run
(`service-map-pipeline` and `service-map-v1-pipeline`), which costs a second stateful
window over the same span stream. On a memory-constrained Data Prepper, drop whichever
schema your UI does not use rather than shrinking the windows.

**Metrics cannot use the exporter at all yet.** Metrics could in principle go straight
from the collector to OpenSearch in `ss4o` mode. That does not work on any released
collector. In contrib **v0.158.0** (the appVersion the collector image was pinned to
before this stack tracked the operator's newer default):

```yaml
# exporter/opensearchexporter/metadata.yaml
status:
  stability:
    alpha: [traces, logs]      # <- no metrics entry at all
```
```go
// exporter/opensearchexporter/factory.go
exporter.WithTraces(createTracesExporter, metadata.TracesStability),
exporter.WithLogs(createLogsExporter, metadata.LogsStability),
// ...no WithMetrics
```

Metrics support (and the `metrics_index` / `metrics_index_time_format` settings) exist only
on contrib `main`. Configuring them against a released image fails at startup with:

```
'opensearchexporter.Config' has invalid keys: metrics_index, metrics_index_time_format
```

So metrics go through Data Prepper's `otel_metrics` processor instead. The index name still
has to satisfy the Metrics view, which hardcodes its pattern:

```
// dashboards-observability/common/constants/metrics.ts
export const DATA_PREPPER_INDEX_NAME = 'ss4o_metrics-*-*';
```

Hence `index_type: custom` with `index: "ss4o_metrics-otel-%{yyyy.MM.dd.HH}"` rather than
Data Prepper's built-in `metric-analytics` type, which would write `metrics-otel-v1-*` —
correct mappings, but a name that view will never look at.

### 2. No cluster metrics at all, in stage 1

An earlier version of this stack had the gateway collector scrape node-exporter,
kube-state-metrics, kubelet and cAdvisor with a `prometheus` receiver and no Prometheus
server (`kubernetes_sd_configs` directly). Stage 1 drops that entirely — only the demo
app's own OTLP traces/logs/metrics are collected. This means:

- The gateway collector needs no Kubernetes API access at all (no ClusterRole).
- The Observability → Metrics view and the **OTel · Metrics** dashboard show only
  application metrics — there is nothing to plot by node or container.
- The APM **Services** view's RED-metric columns were never populated by this stack
  anyway (they need a Prometheus data source), so nothing regresses there.

See [docs/opensearch-design-doc.md](docs/opensearch-design-doc.md#future-goals-stage-2)
for what adding cluster metrics back looks like — it's purely additive, a receiver block
in `manifests/03-otel-collector-gateway.yaml`.

### 3. The collector is two collectors, and that's plumbing, not platform

This repo runs both an `otel-agent` DaemonSet (tails container logs) and a
single-replica `otel-gateway` Deployment (OTLP ingest). Both are `OpenTelemetryCollector`
custom resources managed by the OpenTelemetry Operator.

Why two, and how to point another app or another scrape target at the same pipeline is
covered in **[docs/otel-collector.md](docs/otel-collector.md)** — deliberately kept
separate from this document, because none of it changes how OpenSearch or Data Prepper
are configured.

---

## Prerequisites

### Cluster baseline

This was built against, and verified on:

| | |
|---|---|
| Cluster | `workload-vsphere-vks2`, Kubernetes `v1.36.1+vmware.4`, VKS addons `3.7.0-20260723` |
| Flux | `helm-controller` 1.5.5 + `source-controller`, `--watch-all-namespaces`, `cluster-admin`. `helm.toolkit.fluxcd.io/v2`, `source.toolkit.fluxcd.io/v1` |
| Storage | `vsan-esa-default-policy-raid5-latebinding` |
| Context | `vks:workload-vsphere-vks2` (identity holds `cluster-admin`) |

Stage 1 needs nothing else on the cluster — no Istio/Gateway API, no cert-manager, no
Prometheus Operator. If your cluster already runs those (this one does, for other
workloads), this stack simply doesn't use them.

> **kustomize-controller is not installed.** The cluster serves no
> `kustomize.toolkit.fluxcd.io` CRD, so there is no `Kustomization` kind and no GitOps
> reconcile loop. Charts go through `HelmRelease` objects; everything else is applied with
> `kubectl`. If kustomize-controller is added later, the same manifests can be wrapped in
> a `Kustomization`.

### 1. Cluster context

All scripts route every call through `kubectl --context "$KUBE_CONTEXT"`, defaulting to:

```
vks:workload-vsphere-vks2
```

That identity already holds `cluster-admin` on this cluster through a pre-existing
binding, so **no separate admin kubeconfig is required**. `scripts/apply.sh` preflights
this before touching anything, but you can check by hand:

```bash
export KUBE_CONTEXT=vks:workload-vsphere-vks2
for r in namespaces clusterroles helmreleases.helm.toolkit.fluxcd.io; do
  printf '%-46s %s\n' "$r" "$(kubectl --context $KUBE_CONTEXT auth can-i create $r)"
done
```

All three must answer `yes`.

### 2. Worker capacity

Measured requirement (from `helm template` of the actual releases):

| | CPU requests | Memory requests |
|---|---|---|
| OpenSearch | 0.50 | 3072 Mi |
| Dashboards | 0.20 | 1024 Mi |
| Data Prepper | 0.30 | 1024 Mi |
| Gateway collector | 0.30 | 512 Mi |
| Agent collector (per node) | 0.10 | 192 Mi |
| **Stack total** | **1.40** | **5824 Mi** |
| OTel Demo | 0.00 | 0 Mi (but ~3.8 GiB of *limits*) |

The demo declares no resource requests at all, so it schedules into whatever is left —
and is correspondingly the first thing the kernel OOM-kills under memory pressure. Size
your node pool with headroom above the stack total.

### 3. Egress

Nodes need internet access. Docker Hub images are pulled through **`mirror.gcr.io`** (set
via `global.dockerRegistry` where the chart supports it, and on `image.repository`
otherwise); `ghcr.io` images are pulled directly. Confirm before starting:

```bash
kubectl run egress-test --rm -it --restart=Never \
  --image=mirror.gcr.io/curlimages/curl:8.11.1 -- \
  -sSI https://opensearch-project.github.io/helm-charts/index.yaml | head -1
```

---

## Repository layout

```
.
├── README.md
├── docs/
│   └── otel-collector.md             # sidebar: collector agent/gateway config, not the platform
├── manifests/                        # applied as-is, in order, no templating
│   ├── 00-namespaces.yaml            # observability + otel-demo, PSA privileged
│   ├── 01-sources.yaml               # HelmRepository x2
│   ├── 02-hr-otel-operator.yaml      # OTel Operator (Helm, via helm-controller)
│   ├── 03-otel-collector-gateway.yaml# OpenTelemetryCollector CR (deployment)
│   ├── 04-otel-collector-agent.yaml  # OpenTelemetryCollector CR (daemonset)
│   ├── 05-secret-opensearch-admin.yaml # the one static credential this stack needs
│   ├── 06-hr-opensearch.yaml
│   ├── 07-hr-opensearch-dashboards.yaml # includes Service:LoadBalancer + port patch
│   ├── 08-hr-data-prepper.yaml       # pipelines inlined as native Helm values
│   ├── 09-bootstrap-payloads.yaml    # ISM policies + index templates as JSON
│   ├── 10-bootstrap-job.yaml         # applies them to OpenSearch
│   └── 11-hr-otel-demo.yaml          # includes Service:LoadBalancer + port patch
├── dashboards/
│   └── otel-dashboards.ndjson        # 4 index patterns, 16 visualisations, 3 dashboards
└── scripts/
    ├── apply.sh                      # applies manifests/ in order
    ├── import-dashboards.sh          # ndjson -> Dashboards
    ├── export-dashboards.sh          # Dashboards -> ndjson (captures UI edits)
    └── verify.sh
```

Every manifest is static and self-contained — its own `HelmRepository`/`HelmRelease`/
`Secret`/RBAC where needed — with comments marking the handful of values you'd actually
change (the storage class in `06`, the one password in `05`, and the demo's browser-OTLP
endpoint in `11`, which genuinely cannot be known before the first apply — see
[Install](#install)).

---

## Install

### 1. Adjust the values that are specific to your cluster

Two files have a comment telling you what to change:

- `manifests/06-hr-opensearch.yaml` → `persistence.storageClass`. The committed value
  (`vsan-esa-default-policy-raid5-latebinding`) is this repo's original vSphere/VKS
  cluster and will not exist elsewhere.
- `manifests/05-secret-opensearch-admin.yaml` → `admin-password`. Change it before
  anything but a throwaway demo — see that file's comment for every place the value is
  duplicated (`admin-password` is read live by three manifests via `secretKeyRef`, but
  Data Prepper's pipeline sinks in `manifests/08-hr-data-prepper.yaml` duplicate it as a
  **literal string**, since Data Prepper's inline pipeline config is native Helm values,
  not env-substituted — keep both in sync by hand).

Everything else is ready to apply as committed.

### 2. Preflight, then apply

```bash
scripts/apply.sh preflight   # checks context + permissions only, changes nothing
scripts/apply.sh all         # applies manifests/00 through manifests/11, in order
```

Watch it converge — first pull plus OpenSearch bootstrap takes several minutes, and the
autoscaler may need to add a node:

```bash
kubectl -n observability get helmrelease -w
kubectl -n observability get pods
kubectl -n otel-demo get pods
```

### 3. Confirm the bootstrap Job ran

Nothing else will work correctly until this has succeeded, because it installs the
retention policies and the metrics mapping.

```bash
kubectl -n observability logs job/opensearch-bootstrap
```

Expect `creating ISM policy ...`, `putting legacy template otel-defaults`,
`putting index template ss4o-metrics`, then `done`. Data Prepper blocks on an
initContainer until `raw-span-policy` exists, so it will sit in `Init:0/1` until this
completes — that is the intended ordering, not a fault.

### 4. Point the demo's browser-side traces at its own LoadBalancer

This one value genuinely cannot be static up front: it depends on an IP the cloud
provider assigns after the Service exists.

```bash
kubectl -n otel-demo get svc frontend-proxy \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
```

Edit `PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` in `manifests/11-hr-otel-demo.yaml` to
`http://<that IP>/otlp-http/v1/traces`, then re-apply just that file:

```bash
kubectl --context vks:workload-vsphere-vks2 apply -f manifests/11-hr-otel-demo.yaml
```

Browser-side spans are POSTed by the browser to `/otlp-http/v1/traces`; if that URL is
not same-origin with the page users actually open, they are lost.

### 5. Read the two LoadBalancer IPs

```bash
kubectl -n otel-demo get svc frontend-proxy \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
kubectl -n observability get svc opensearch-dashboards \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
```

Open `http://<demo-ip>/` for the storefront and `http://<dashboards-ip>/` for Dashboards.
Log in to Dashboards as `admin` with the password from
`manifests/05-secret-opensearch-admin.yaml`.

### 6. Import the dashboards

```bash
scripts/import-dashboards.sh
```

See [Prebuilt dashboards](#prebuilt-dashboards).

---

## Verify

```bash
scripts/verify.sh
```

Checks HelmRelease readiness, the bootstrap Job, cluster health, that the ISM policies are
*ours* (a `delete` state rather than Data Prepper's rollover-only default), that all four
index families exist and have documents, collector export/failure counters per signal, and
that both LoadBalancers answer `200` over plain HTTP.

Manual equivalents:

```bash
PW=$(kubectl -n observability get secret opensearch-bootstrap \
      -o jsonpath='{.data.admin-password}' | base64 -d)
osq() { kubectl -n observability exec observability-master-0 -- \
          curl -sk -u "admin:$PW" "https://localhost:9200$1"; }

osq '/_cluster/health?pretty'
osq '/_cat/indices/otel-v1-apm-span-*,otel-v2-apm-service-map*,logs-otel-v1-*,ss4o_metrics-*?v'
osq '/_plugins/_ism/explain/otel-v1-apm-span-*?pretty'
osq '/_plugins/_security/authinfo?pretty'

# collector counters (must be scraped in-cluster, not via port-forward)
kubectl -n observability exec observability-master-0 -- \
  curl -s http://otel-gateway-collector:8888/metrics | grep otelcol_exporter_
```

And end to end:

```bash
curl -o /dev/null -w 'dashboards: %{http_code}\n' http://<dashboards-lb-ip>/
curl -o /dev/null -w 'demo shop:  %{http_code}\n' http://<demo-lb-ip>/
```

Expect **200** for the shop and **200 or 302** for Dashboards (it redirects `/` to
`/app/login` for HTTP Basic auth).

### Reaching the demo storefront

```bash
kubectl -n otel-demo get svc frontend-proxy \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
```

`frontend-proxy` (Envoy) is the Service exposed, not the bare `frontend` Service — Envoy is
what serves `/otlp-http`, so exposing `frontend` directly would silently break
browser-side spans.

**The LoadBalancer must be on port 80.** This is a property of this repo's original
network, not the chart: the vSphere LB will program any port (the `VirtualMachineService`
showed `tcp-service:8080->32427`, and the VIP answered from *inside* the cluster) but 8080
was not reachable from outside — only standard ports (80/443/6443) were. Since the chart
derives `targetPort` from `service.port`, 80 → 8080 cannot be expressed in values alone,
so the demo HelmRelease carries a `postRenderers` patch on the Service. Remove that patch
if your LoadBalancer accepts arbitrary ports — see the comment in
`manifests/11-hr-otel-demo.yaml`.

Load is generated continuously by the demo's k6 load generator
(`LOAD_GENERATOR_VUS=5`, browser traffic on). Spans take up to ~3 minutes to appear:
`otel_traces` buffers with a 180s trace flush interval, so an empty
`otel-v1-apm-span-*` immediately after a Data Prepper restart is normal, not a fault.
The service map lands sooner, on 30s windows.

## Where to look in Dashboards

Log in at `http://<dashboards-lb-ip>/` with `admin` and the password from
`manifests/05-secret-opensearch-admin.yaml` (HTTP Basic — there is no SSO in stage 1).

### A first look, as a developer chasing a slow request

This is the loop the platform is actually built for. With the [prebuilt
dashboards](#prebuilt-dashboards) imported:

1. Open the **OTel · Traces** dashboard. The p95-duration-by-service and error-spans
   panels are where "something is wrong" turns into "it's this service."
2. Drill into **Observability → Trace Analytics** (data source: **Data Prepper**) and
   find a slow or failed trace for that service. The span waterfall shows exactly which
   downstream call ate the time.
3. Switch to **Trace Analytics → Service map** to see whether the slow service's
   *callers* are also degraded, or whether it's isolated.
4. Open **Discover** against `logs-otel-v1-*`, filtered to that `traceId`. Every log
   line the request touched is correlated by that field, across every service and
   node it passed through — no manual timestamp/host correlation needed.
5. If the cause looks resource-related rather than logic-related, check the **OTel ·
   Metrics** dashboard or **Observability → Metrics** for that service over the same
   window. There are no cluster/node metrics in stage 1 (see
   [decision 2](#2-no-cluster-metrics-at-all-in-stage-1)) — only application metrics.

That five-step loop — dashboard → trace → service map → correlated logs → metrics — is
the entire value proposition of routing every signal through one backend. See [Which
fields you can group by](#which-fields-you-can-group-by) for the field names each step
above actually filters on.

### About the `data_source` / `workspace` / `explore` prompt

On first login Dashboards may suggest enabling three settings. **None of them are required
for this stack**, and they are all off deliberately:

| Setting | What it turns on | Verdict here |
|---|---|---|
| `data_source.enabled` | Connecting Dashboards to *additional* OpenSearch clusters | Skip — there is one local cluster; it only adds a data-source picker to every screen |
| `workspace.enabled` | The workspace paradigm (saved objects grouped into workspaces) | Skip — significantly rearranges navigation for no benefit at this size |
| `explore.enabled` | The newer Explore surface (Discover Traces / Discover Metrics) | Optional. Nice if you want the modern trace explorer; the classic Trace Analytics below already works |

The classic `observabilityDashboards` plugin — Trace Analytics, Metrics, Event Analytics —
is installed and needs none of them. If you do want the OpenSearch 3.6+ **APM**
experience, that one needs all three (`workspace`, `data_source`, `explore`), and it binds
to the same `otel-v1-apm-span-*` / `otel-v2-apm-service-map*` indices this stack already
writes. Enable them in `manifests/07-hr-opensearch-dashboards.yaml` under
`config.opensearch_dashboards.yml` if you want to try it.

### Prebuilt dashboards

```bash
scripts/import-dashboards.sh
```

Idempotent (`overwrite=true`), and authenticates as `admin` over HTTP Basic. It imports
23 objects from `dashboards/otel-dashboards.ndjson`: 4 index patterns, 16
visualisations, 3 dashboards. After importing, the script also refreshes each index
pattern's field cache via the same internal API the Dashboards UI's "Refresh field
list" button uses — see the troubleshooting entry below for why that step exists.

If you import the file by hand instead (**Dashboards Management → Saved objects →
Import**), you must also manually click the refresh icon on each of the 4 index
patterns under **Dashboards Management → Index patterns**, or every visualization will
render blank.

### Moving the dashboards to another cluster

Everything is already in the repo, and the saved-object file is **portable as-is** —
it contains no IPs, hostnames, cluster names or client IDs. Index names
(`logs-otel-v1-*`, `otel-v1-apm-span-*`, `ss4o_metrics-*`) are the same in every install of
this stack, so nothing needs substituting.

```bash
# on the new cluster, after the stack is up:
KUBE_CONTEXT=<other-context> scripts/import-dashboards.sh
```

Round-tripping is symmetric:

```bash
scripts/export-dashboards.sh          # cluster -> dashboards/otel-dashboards.ndjson
scripts/export-dashboards.sh --ours   # only the 3 OTel dashboards + their references
scripts/import-dashboards.sh          # dashboards/otel-dashboards.ndjson -> cluster
```

**Anything you build or edit in the UI lives only in the `.kibana` index until you export
it** — the repo file is not updated automatically. Run `export-dashboards.sh` to capture UI
work before it is lost, then commit the diff.

The export is normalised so it behaves in version control: the API's trailing
`{"exportedCount":…}` summary line is dropped, per-install churn fields (`updated_at`,
`version`, `migrationVersion`, `namespaces`, `coreMigrationVersion`) are stripped, and
objects are sorted by type then id. Without that, every export would be a large meaningless
diff. Export → import → export is verified to report **no change**, so a clean tree means
the cluster and the repo genuinely agree. The script also warns if an exported object has
picked up something environment-specific, which usually means a hardcoded URL in a panel.

To confirm a cluster matches the repo:

```bash
scripts/export-dashboards.sh && git diff --stat dashboards/
```

### What is in each dashboard

| Dashboard | Panels |
|---|---|
| **OTel · Traces** | total spans; span rate; spans by service; error spans by service (`status.code >= 1`); p95 duration by service; slowest operations table |
| **OTel · Logs** | logs correlated to a trace; volume over time; by service; by severity; by namespace; errors and warnings by service |
| **OTel · Metrics** | distinct metric names; datapoints over time; top metric names; by source (scrape job/service) |

All three default to the last hour with a 30s refresh.

### Index patterns and their time fields

The time field differs per signal — this catches people out:

| Index pattern | Time field |
|---|---|
| `otel-v1-apm-span-*` | `startTime` |
| `logs-otel-v1-*` | `@timestamp` |
| `ss4o_metrics-*` | `time` (there is no `@timestamp` on metric documents) |
| `otel-v2-apm-service-map-*` | `timestamp` |

### Built-in views that need no dashboard

| To see | Go to |
|---|---|
| Trace list, span waterfall | Observability → **Trace Analytics** (data source: **Data Prepper**) |
| Service / application map | Trace Analytics → **Service map** (reads `otel-v1-apm-service-map`) |
| Metrics browser | Observability → **Metrics** (reads `ss4o_metrics-*-*`) — app metrics only in stage 1 |
| Ad-hoc search on any signal | **Discover**, using the index patterns above |

### Which fields you can group by

`attributes` and `resource.attributes` are mapped `flat_object`. That makes dotted OTel
attribute keys indexable and filterable in Discover (`resource.attributes.host.arch: x86_64`
works), but **flat_object sub-keys are not aggregatable** — they cannot be a terms bucket in
a visualisation. So the pipeline promotes a small set of high-value dimensions to real
top-level `keyword` fields:

| Signal | Promoted fields |
|---|---|
| Logs | `serviceName`, `k8sNamespace`, `k8sPod`, `k8sContainer`, `hostName` |
| Metrics | `serviceName`, `k8sNamespace`, `k8sNode`, `k8sPod` |
| Traces | `serviceName` already exists in Data Prepper's span schema |

They are copied by `copy_values` in `manifests/08-hr-data-prepper.yaml` and typed as
`keyword` in the bootstrap templates. To add another, do both — a `copy_values` entry
*and* a mapping entry — then roll the index, because mappings are immutable:

```bash
kubectl -n observability exec observability-master-0 -- \
  curl -sk -u "admin:$PW" -X POST https://localhost:9200/logs-otel-v1/_rollover
```

Two other field notes worth knowing:

- `severityText` is `text` with a `.keyword` subfield, so aggregate on
  **`severityText.keyword`**.
- Most log records have an **empty** `severityText`: container logs tailed from files carry
  no severity, and at this volume they are the large majority. The severity chart therefore
  filters with `not severityText.keyword: ""`. Application logs arriving over OTLP do carry
  one — inconsistently cased (`INFO`, `Information`, `info`) because the demo services use
  different SDKs.

## Retention

One day, implemented with ISM. The mechanism is worth understanding because it is not
obvious.

Data Prepper creates its own ISM policies for the index families it manages, but **only if
they do not already exist** — and its defaults roll indices without ever deleting them.
So the bootstrap Job pre-creates them with a `delete` state. The policy ids are not
arbitrary; they are the exact ids Data Prepper looks for, taken from
`IndexConstants.java` in the 2.16.0 source:

| Policy id | Family | Behaviour |
|---|---|---|
| `raw-span-policy` | `otel-v1-apm-span-*` | roll at 1h/10GB, delete 1 day after rollover |
| `logs-policy` | `logs-otel-v1-*` | roll at 1h/10GB, delete 1 day after rollover |
| `otel-v2-apm-service-map-policy` | `otel-v2-apm-service-map-*` | roll daily, **never delete** — rebuilt continuously, so deleting it would blank the map for no benefit |
| _(none)_ | `otel-v1-apm-service-map` | No policy, and deliberately so. Data Prepper defines no ISM policy for this type; the index is a plain index, not a rollover alias. It stays small because documents are keyed by `hashId`, so it is bounded by distinct service/operation/trace-group combinations rather than by traffic (~100 docs for this demo). Deleting it would blank the classic service map. |
| `ss4o-metrics-policy` | `ss4o_metrics-*` | delete 1 day after index creation (indices are **hourly**, so metrics age out granularly) |

Effective retention is **24–48 hours**, not exactly 24: ISM evaluates on an interval
(tightened here to 1 minute with `plugins.index_state_management.job_interval: 1`), and
`min_rollover_age` counts from rollover rather than from the newest document.

ISM's own audit history is disabled, since its 30-day default would outlive every index it
manages.

### The index-template trap

There are two template systems in OpenSearch and mixing them breaks traces.

Data Prepper 2.16.0 defaults to `TemplateType.V1` — it registers **legacy `_template`**
objects for its families (verified in `IndexConfiguration.determineTemplateType`). In
OpenSearch, a matching **composable `_index_template` takes precedence over legacy
templates entirely; it does not merge.** A composable template matching `otel-v1-*` would
therefore silently shadow Data Prepper's span mappings and Trace Analytics would stop
resolving fields.

So the bootstrap Job uses both, deliberately:

- `legacy--otel-defaults.json` → `PUT _template/otel-defaults`, `order: 100`, **settings
  only**. Legacy templates *do* merge by order, so this contributes
  `number_of_replicas: 0` (mandatory on a single node, or every index stays yellow)
  without touching Data Prepper's mappings.
- `template--ss4o-metrics.json` → `PUT _index_template/ss4o-metrics`. Data Prepper never
  touches this family, so a composable template with full mapping control is correct here.

The ss4o metrics template is **required before the first metric is indexed**: without it
OpenSearch's dynamic mapping infers field types from whatever it sees first — `date`
(millisecond) for nanosecond timestamps, `integer` for int64 counters — and then rejects
every later document that does not fit.

Its mappings are **not hand-written**. They are Data Prepper 2.16.0's own
`metrics-otel-v1-index-standard-template.json` mappings, re-pointed at `ss4o_metrics-*`,
with two changes:

- the `*.attributes.*` dynamic templates are removed and the attribute subtrees are mapped
  `flat_object` instead, because dotted OTel attribute keys otherwise collide (see the
  `KeywordFieldMapper cannot be cast to ObjectMapper` troubleshooting entry);
- `numeric_detection` is off.

Reusing Data Prepper's mappings matters because Data Prepper is what writes these
documents, so its shape is the authoritative one. Regenerate with:

```bash
curl -sfL https://raw.githubusercontent.com/opensearch-project/data-prepper/2.16.0/\
data-prepper-plugins/opensearch/src/main/resources/metrics-otel-v1-index-standard-template.json
```

and wrap its `.mappings` in `index_patterns` / `priority` / `settings`.

### Metric index granularity

Metrics are written to `ss4o_metrics-otel-%{yyyy.MM.dd.HH}` — **hourly**, not daily. Metrics
are the largest stream by a wide margin, so a single daily index would grow large enough to
approach OpenSearch's 95% `flood_stage` watermark — which flips every index to read-only.
Hourly indices let ISM retire metrics an hour at a time and keep peak usage roughly flat.
`ss4o_metrics-otel-2026.08.27.04` still matches the `ss4o_metrics-*-*` pattern the Metrics
view requires.

### The k6 cardinality trap

Hourly indices alone were not enough. This stack originally filled its 30 GiB volume to 92%
in a single day and tripped OpenSearch's cluster-wide **create-index block**, which stops
ingest dead. The cause is worth understanding, because it is a property of the upstream demo
rather than anything configured here — and it is unrelated to cluster-metrics scraping,
which stage 1 doesn't do at all (see [decision 2](#2-no-cluster-metrics-at-all-in-stage-1)).

The demo's load generator is k6, and its `browser` scenario drives a real headless Chromium.
k6 tags every resulting metric data point with the full request URL — **including a
per-session UUID**:

```
url:  http://frontend-proxy:8080/api/recommendations
      ?productIds=&sessionId=0f944ada-6e77-4ca5-948a-7547403dac96&currencyCode=USD
```

Every session therefore mints a fresh time series. Measured on this cluster:

| | Before | After |
|---|---|---|
| Distinct series, `k6.browser_http_req_duration` | **1,563** | **62** |
| Export cycles/hour | 360 (every 10s) | 60 (every 60s) |
| Docs/hour, that one metric | **562,680** | ~15,400 |
| Docs/min, **all** metrics | **42,813** | **~3,585** |
| Metrics written per hour | ~1 GB | **~80 MB** |

`k6.browser_*` alone was **87.9% of every metric document in the cluster**, produced by a
single virtual user. Because k6 exports with **cumulative** temporality, all 1,563 series
were re-sent every 10 seconds whether or not anything had changed — the series averaged 13.9
observations each, so the overwhelming majority of writes were redundant re-exports.

Two changes fix it, and both matter:

1. **`transform/k6_cardinality`** in the gateway
   (`manifests/03-otel-collector-gateway.yaml`) strips the query string and then
   aggregates. **The strip alone would achieve nothing** — `transform` rewrites attributes
   but does not merge data points, so you would get the same document count with duplicate
   attributes. `aggregate_on_attributes` is what actually collapses them. Note that for
   histogram types only `sum` is a valid aggregation, and merging requires identical
   explicit bucket bounds — k6 uses a fixed 16-bucket layout, so this holds.
2. **`K6_OTEL_EXPORT_INTERVAL=60s`** on the load generator
   (`manifests/11-hr-otel-demo.yaml`) cuts export cycles 6× across *all* k6 metrics,
   including the `k6.http_*` family that the transform deliberately leaves alone (its
   `status` / `expected_response` attributes are worth keeping).

Traces are untouched by the transform — it only sits in the metrics pipeline.

With metrics at ~80 MB/hour, 24h of all four index families lands around **5–6 GB on the
30 GiB volume (~18%)**, against the ~27 GB that previously pinned it above the watermark.

If you add your own instrumentation, this is the failure mode to watch for: **an unbounded
value (session ID, request ID, raw URL) in a metric attribute**. Metric attributes must be
low-cardinality. Traces are where per-request detail belongs.

---

## Troubleshooting

**A dashboard panel shows "Trying to initialize aggs without index pattern."** A
`visualization` saved object's `kibanaSavedObjectMeta.searchSourceJSON` is missing an
`indexRefName` key matching its top-level `references` entry
(`{"name": "kibanaSavedObjectMeta.searchSourceJSON.index", "type": "index-pattern", ...}`).
Unlike some older Kibana versions, OpenSearch Dashboards 3.8.0 does **not** strip this
key on export and does not inject it purely by convention from the top-level reference
on import — both must be present in the stored JSON. Confirm by comparing a broken
object against one saved fresh through the UI (`GET
/api/saved_objects/visualization/<id>` for each). If you hand-edit
`dashboards/otel-dashboards.ndjson`, every visualization's `searchSourceJSON` string
must include `"indexRefName":"kibanaSavedObjectMeta.searchSourceJSON.index"` alongside
the top-level reference.

**A dashboard panel shows "Could not locate that index-pattern-field (id: ...)."**
The index-pattern saved object has no `fields` cache — `dashboards/otel-dashboards.ndjson`'s
index-pattern objects intentionally carry only `title`/`timeFieldName` (portable, no
per-cluster mapping baked in), so nothing populates `fields` until something asks
OpenSearch for the mapping. `scripts/import-dashboards.sh` does this automatically after
import, calling the same internal API the Dashboards UI's "Refresh field list" button
uses (`GET /api/index_patterns/_fields_for_wildcard?pattern=<title>` then `PUT
/api/saved_objects/index-pattern/<id>` with the result). If you imported by hand, do the
same thing by hand: **Dashboards Management → Index patterns**, open each of the 4,
click the refresh icon top-right, confirm. Discover works without this step (it fetches
fields dynamically for its own field list); visualizations' `AggConfigs` do not.

**A HelmRelease is not Ready.**

```bash
kubectl -n observability get helmrelease -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].message}{"\n"}{end}'
kubectl -n vmware-system-helm logs deploy/helm-controller --tail=100
```

**`scripts/apply.sh` fails applying the gateway or agent CR with a webhook TLS/connection
error, right after `helmrelease/otel-operator` reports Ready.** That script already waits
on the operator Deployment's rollout, not just the HelmRelease condition; if you still hit
this, retry the apply — the operator's self-signed webhook cert (a Helm hook, since stage
1 has no cert-manager) can lag a few seconds behind the Deployment becoming Ready. See
[docs/otel-collector.md](docs/otel-collector.md#operational-notes-specific-to-running-via-the-operator).

**OpenSearch crash-loops with `No SSL configuration found`.**

```
failed to load plugin class [org.opensearch.security.OpenSearchSecurityPlugin]
Caused by: OpenSearchException[No SSL configuration found]
```

`opensearch.yml` contains a key beginning with `plugins.security`. At startup the
demo-config installer calls
`SecuritySettingsConfigurer.checkIfSecurityPluginIsAlreadyConfigured()`, which walks the
top-level keys of that file and, on finding *any* `plugins.security*` key, prints
"seems to be already configured for Security. Quit." and exits — **before** it writes the
TLS settings or generates the demo certificates. Remove the key; the installer writes
`plugins.security.ssl.*`, `authcz.admin_dn`, `audit.type` and
`plugins.security.restapi.roles_enabled` itself. Other causes of a startup crash: too weak
an `OPENSEARCH_INITIAL_ADMIN_PASSWORD`, a duplicate key (the installer *appends* to this
file), or `vm.max_map_count` below 262144 — check
`kubectl -n observability logs observability-master-0 -c sysctl`.

**Data Prepper crash-loops on `config/default_certificate.pem`.**

```
ERROR FileCertificateProvider - Error encountered while reading the certificate
java.nio.file.NoSuchFileException: config/default_certificate.pem
Exception in thread "main" ... PeerForwarderServerProxy.start
```

`otel_traces` and `otel_apm_service_map` are stateful processors, so Data Prepper always
starts its peer-forwarding server — even at one replica with local discovery.
`PeerForwarderConfiguration` defaults `ssl` to **true** with a certificate path that does
not exist in the image. Fix: `peer_forwarder: {ssl: false}` in `data-prepper-config.yaml`
(already set in `manifests/08-hr-data-prepper.yaml`).

**Data Prepper is SIGTERMed ~5 seconds after start (exit 143), log ends at
"No transformation needed".** The chart hardcodes `livenessProbe.initialDelaySeconds: 2`
with `failureThreshold: 2` and exposes no values to tune it, so the kubelet kills the JVM
before it has parsed `pipelines.yaml`. The HelmRelease works around this with a
`postRenderers` kustomize patch that replaces both probes.

**Documents rejected with HTTP 400 and `KeywordFieldMapper cannot be cast to
ObjectMapper`, or `Existing mapping for [attributes.x] must be of type object but found
[keyword]`.** Data Prepper's templates map `*.attributes.*` to `keyword` via dynamic
templates. OTel attribute keys are dotted, so a span carrying both `url` and `url.scheme`
makes the second one unmappable and every subsequent document in that shape is dropped.
Fix: map the attribute subtrees as `flat_object`, which is what
`legacy--otel-defaults.json` and `template--ss4o-metrics.json` do for `attributes`,
`log.attributes`, `span.attributes`, `events.attributes`, `resource.attributes` and
`instrumentationScope.attributes`.

**Mappings are immutable**, so after changing a template you must delete the affected
indices and let Data Prepper recreate them:

```bash
kubectl -n observability exec observability-master-0 -- \
  curl -sk -u "admin:$PW" -X DELETE 'https://localhost:9200/logs-otel-v1-*,otel-v1-apm-span-*'
kubectl -n observability rollout restart deploy/data-prepper
```

**A HelmRelease sits at `Reconciling: Running 'install' action` for many minutes.**
Helm is waiting for a workload that will never become ready, and until that action ends
your newer values are not rendered at all. Cancel it:

```bash
kubectl -n observability patch helmrelease <name> --type=merge -p '{"spec":{"suspend":true}}'
kubectl -n observability patch helmrelease <name> --type=merge -p '{"spec":{"suspend":false}}'
```

**`kubectl port-forward` to the collector's :8888 returns nothing.** The chart binds
internal telemetry to `${env:MY_POD_IP}:8888`, not `0.0.0.0`, and port-forward connects to
the pod's loopback. Scrape it from another pod instead:

```bash
kubectl -n observability exec observability-master-0 -- curl -s http://otel-gateway-collector:8888/metrics
```

**Ingest stops and Data Prepper logs a `ClusterBlockException`, or new hourly metric
indices stop appearing.** The disk crossed OpenSearch's 90% high watermark and OpenSearch
put a **cluster-wide create-index block** on. Data Prepper then cannot create the next
`ss4o_metrics-otel-<date>.<hour>` index, so metrics ingest halts while logs and traces keep
writing to their existing indices.

```bash
# Is the block on?
kubectl -n observability exec observability-master-0 -c opensearch -- \
  curl -sk -u "admin:$PW" 'https://localhost:9200/_cluster/state/blocks?filter_path=blocks'
# -> {"blocks":{"global":{"10":{"description":"cluster create-index blocked (api)", ...
#    {} means no block.

kubectl -n observability exec observability-master-0 -c opensearch -- \
  df -h /usr/share/opensearch/data
kubectl -n observability logs observability-master-0 -c opensearch | grep -i watermark | tail -3
```

Free space by deleting the oldest metric indices — they are hourly, so this is granular and
ISM would have deleted them within the day anyway:

```bash
kubectl -n observability exec observability-master-0 -c opensearch -- \
  curl -sk -u "admin:$PW" -XDELETE \
  'https://localhost:9200/ss4o_metrics-otel-2026.08.27.05,ss4o_metrics-otel-2026.08.27.06'
```

`DiskThresholdMonitor` re-evaluates about every 60 s and lifts the block itself once usage
drops — you do not clear it manually.

Do not treat this as routine maintenance. If it happens at all, something is writing more
than the volume can hold, and the fix is upstream in the pipeline — see
[The k6 cardinality trap](#the-k6-cardinality-trap). Note that the watermark is **not**
disabled by `cluster.routing.allocation.disk.watermark.enable_for_single_data_node: false`;
that setting governs shard-allocation decisions, and the create-index block still applies on
a single-node cluster.

**Cluster health is `yellow`, not `green`.** Expected. `.opendistro-ism-config` is a
plugin-managed system index created with one replica, which cannot be assigned on a
single node — and it is protected, so even `admin` gets
`security_exception` trying to change its settings. All *data* indices are green:
`legacy--otel-defaults.json` sets `number_of_replicas: 0` for them.

**Trace Analytics → Service map is empty, but traces work.** You are writing the wrong
schema. The classic view queries `otel-v1-apm-service-map`; the `otel_apm_service_map`
processor writes `otel-v2-apm-service-map`, which only the newer APM UI reads. Check which
index actually has documents:

```bash
kubectl -n observability exec observability-master-0 -- \
  curl -sk -u "admin:$PW" 'https://localhost:9200/_cat/indices/otel-v*apm-service-map*?h=index,docs.count'
```

and which one your Dashboards build asks for:

```bash
kubectl -n observability exec deploy/opensearch-dashboards -- \
  sh -c 'grep -rho "otel-v[12]-apm-service-map[a-z*-]*" plugins/observabilityDashboards | sort | uniq -c'
```

The fix is the `service-map-v1-pipeline` in `manifests/08-hr-data-prepper.yaml`. Allow a
couple of minutes after it starts: `service_map` correlates client and server spans across
*consecutive* windows, so with `window_duration: 30` the first documents appear after two
windows, not immediately. A useful confirmation that edges exist:

```bash
kubectl -n observability exec observability-master-0 -- \
  curl -sk -u "admin:$PW" -H content-type:application/json \
  'https://localhost:9200/otel-v1-apm-service-map/_search' \
  -d '"'"'{"size":0,"query":{"term":{"kind":"SPAN_KIND_CLIENT"}},
        "aggs":{"e":{"multi_terms":{"terms":[{"field":"serviceName"},{"field":"destination.domain"}],"size":15}}}}'"'"'
```

**A LoadBalancer Service gets a VIP but never answers from outside.** Check whether it
answers from *inside* the cluster first:

```bash
kubectl -n observability exec observability-master-0 -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://<VIP>:<port>/
```

If that returns 200, the Service and the VIP are fine and the problem is upstream —
usually a network/firewall policy on the LoadBalancer implementation that only permits
certain external ports. See [Reaching the demo storefront](#reaching-the-demo-storefront)
for how this stack works around exactly that on its original cluster.

**Traces and the service map go nearly empty, but every HelmRelease is Ready and the
collectors report zero export failures.** The demo has stopped generating traffic. Check the
load generator first:

```bash
kubectl -n otel-demo logs deploy/load-generator --tail=50 | grep -i 'timeout\|Request Failed'
```

`dial: i/o timeout` to `http://frontend-proxy:8080` means the `frontend-proxy` Service is not
publishing port 8080. Packets to a Service port with no kube-proxy rule are silently dropped
rather than refused, which is why this looks like a timeout rather than a connection error.
The Service must publish **both** 80 (for the VIP) and 8080 (for in-cluster clients such as
`K6_TARGET_URL`) — see the postRenderer in `manifests/11-hr-otel-demo.yaml`.

```bash
kubectl -n otel-demo get svc frontend-proxy -o jsonpath='{range .spec.ports[*]}{.name} {.port}->{.targetPort}{"\n"}{end}'
# expect BOTH:  http 80->8080   and   http-alt 8080->8080
kubectl -n observability exec observability-master-0 -c opensearch -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://frontend-proxy.otel-demo.svc.cluster.local:8080/
```

**Two things make this failure mode deceptive, and both are worth internalising:**

- **k6 reuses keep-alive connections.** A load generator already running when the Service
  port changes keeps working off its existing conntrack entries and only breaks at its next
  restart — potentially many hours later. The restart then looks like the cause when it was
  merely the trigger.
- **Cumulative metrics hide it.** k6 exports cumulative series, so the series recorded while
  traffic was healthy keep being re-exported indefinitely, complete with `status: 200`
  attributes. Metric dashboards therefore look fine while no requests are actually
  succeeding.

**Use the span rate as the health signal, not metrics** — it is the only one of the three
that drops immediately:

```bash
kubectl -n observability exec observability-master-0 -c opensearch -- curl -sk -u "admin:$PW" \
  -H 'Content-Type: application/json' 'https://localhost:9200/otel-v1-apm-span-*/_search?size=0' \
  -d '{"query":{"range":{"startTime":{"gte":"now-15m"}}},
       "aggs":{"m":{"date_histogram":{"field":"startTime","fixed_interval":"1m"}}}}'
```

**The demo storefront's `/jaeger` and `/grafana` links 503.** Expected. `frontend-proxy`
is an Envoy with static clusters for the bundled backends, which are disabled. Other
routes are unaffected.

---

## Limitations

Stated plainly, because several are deliberate trades rather than oversights.

1. **`opensearchexporter` is not used at all.** In the newest released contrib line it
   is alpha for traces and logs and has no metrics support whatsoever, and traces
   written by it are unreadable by OpenSearch's trace UIs. Everything therefore flows
   through Data Prepper, which makes Data Prepper a single point of failure for all three
   signals.
2. **No cluster metrics at all.** Stage 1 collects only the demo app's own OTLP signals —
   see [decision 2](#2-no-cluster-metrics-at-all-in-stage-1). The APM Services view's RED
   metrics need a Prometheus data source regardless, so that limitation predates this
   change; it's now just explicit rather than partially worked around.
3. **Data Prepper is single-replica.** `otel_apm_service_map` keeps its time-window state
   in `db_path` on local disk; a second replica would see a subset of spans and emit
   partial maps.
4. **No SSO.** Dashboards is HTTP Basic only, a single shared `admin` login — see
   [docs/opensearch-design-doc.md](docs/opensearch-design-doc.md#future-goals-stage-2)
   for the stage-2 OIDC plan.
5. **The `frontend-proxy` Service must publish both 80 and 8080.** 80 is what reaches the
   VIP; 8080 is what in-cluster clients (notably `K6_TARGET_URL`) hardcode. Publishing only
   one silently breaks either external access or all demo traffic, and the break can stay
   hidden for hours behind connection reuse and cumulative metrics.
6. **Attribute subtrees are `flat_object`.** That is what makes dotted OTel attribute keys
   indexable at all, but `flat_object` supports term queries rather than the full
   aggregation surface of typed fields, so aggregating *on an attribute value* is limited.
7. **No TLS.** Both LoadBalancers serve plain HTTP. Fine for a demo/dev cluster; put a
   TLS-terminating ingress in front for anything else.
8. **Retention is 24–48h**, not exactly 24 — see [Retention](#retention).
9. **The demo's LLM services are disabled** (`chatbot`, `agent`, `mcp`) — they need an
   external model API key. `telemetry-docs` and `opamp-server` are off too; OpAMP exists
   only to configure the bundled collector, which is disabled.
10. **OpenSearch runs `singleNode` with `number_of_replicas: 0`.** There is no redundancy;
    losing the PVC loses the data. Acceptable given one-day retention.
11. **No GitOps loop.** Without kustomize-controller there is nothing reconciling the raw
    manifests, so drift in the bootstrap payloads/Job is not corrected. The HelmReleases
    themselves do have `driftDetection.mode: enabled`.
12. **`k6.browser_*` metrics are aggregated, losing per-URL detail.**
    `transform/k6_cardinality` keeps `scenario`, `method`, `proto`, `resource_type` and the
    query-stripped `url`, and drops the rest. Two consequences worth knowing: summing
    *cumulative* series is approximate when the underlying series churn, so treat browser
    metric rates as indicative rather than exact; and per-session or per-query-string
    breakdowns are gone. The corresponding **traces are unaffected** and remain the place to
    look for per-request detail. See
    [The k6 cardinality trap](#the-k6-cardinality-trap).
13. **`null` does not remove chart defaults through a HelmRelease.** The Kubernetes API
    server prunes null values out of `spec.values`, and Helm then merges the chart's own
    defaults back in. Relevant to every HelmRelease in this stack.
14. **The two collectors' CRDs are installed by the operator's chart, not tracked the way
    HelmRelease `values:` are.** `driftDetection.mode: enabled` on `otel-operator` covers
    the operator's own Deployment/RBAC/webhook config, but a hand-edit to the
    `OpenTelemetryCollector` CRD itself (as opposed to the CRs in
    `manifests/03-otel-collector-gateway.yaml` / `04-otel-collector-agent.yaml`, which are
    plain manifests Flux does not manage at all) would not be caught by anything in this
    stack. Same "no GitOps loop" gap as item 11, one layer lower.
