# Copy to scripts/env.sh, fill in, then `source scripts/env.sh`.
# scripts/env.sh is gitignored -- it holds passwords.

# ---- cluster access -------------------------------------------------------
# The workload cluster context. This identity already holds cluster-admin on
# this cluster via the binding
#   vmware-system-auth-sync-edit:showcase.tmm.broadcom.lab:navneet.verma
# so no separate admin kubeconfig is needed. Every script routes through
# `kubectl --context "$KUBE_CONTEXT"`.
export KUBE_CONTEXT="vks:workload-vsphere-vks2"

# The Supervisor context, used only to read/resize the node pool (prerequisite 2).
export SUPERVISOR_CONTEXT="vcf:namespace"

# The demo storefront is ALSO published as a plain LoadBalancer Service, on its own IP
# separate from GW_IP:
#   kubectl -n otel-demo get svc frontend-proxy \
#     -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# Browser-side spans must be posted same-origin with however users open the shop.
# NOTE: no :8080 -- the frontend-proxy Service is published on port 80, because only
# 80/443/6443 reach a VIP on this network.
export DEMO_LB_IP="10.138.169.31"
export DEMO_BROWSER_OTLP_ENDPOINT="http://${DEMO_LB_IP}/otlp-http/v1/traces"

# ---- storage --------------------------------------------------------------
# Late-binding so the PV is created in the zone the pod actually lands in.
export STORAGE_CLASS="vsan-esa-default-policy-raid5-latebinding"

# ---- OpenSearch passwords -------------------------------------------------
# Rules for OS_ADMIN_PASSWORD (enforced by OpenSearch's PasswordValidator):
# min 8 chars, at least one upper, one lower, one digit, one special, and it
# must pass a zxcvbn strength check.
export OS_ADMIN_PASSWORD="sCTp[H)RgKzEP=:"
export OS_KIBANASERVER_PASSWORD="sCTp[H)RgKzEP=:"
export OS_INGEST_PASSWORD="sCTp[H)RgKzEP=:"

# Dashboards session cookie key. MUST be >= 32 characters -- this is a hard
# schema constraint and Dashboards refuses to start if it is shorter.
#   openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-48
export OSD_COOKIE_PASSWORD="RPlrp5JYKLmiSkxek0N5wfHlLU1J5rCfzl86KyKpIXc7RFVU"
