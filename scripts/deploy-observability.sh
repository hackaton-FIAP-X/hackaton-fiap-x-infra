#!/usr/bin/env bash
# PLT-7 — aplica Prometheus + Grafana. Requer deploy-infra.sh antes
# (Grafana le a senha do Secret infra-credentials).
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl

OVERLAY="${INFRA_DIR}/k8s/observability/overlays/local"

if ! kubectl -n "${NAMESPACE}" get secret infra-credentials >/dev/null 2>&1; then
  die "Secret infra-credentials nao existe. Rode ./scripts/deploy-infra.sh antes."
fi

kubectl apply -f "${INFRA_DIR}/k8s/namespace.yaml"
log "aplicando ${OVERLAY}"
kubectl apply -k "${OVERLAY}"

log "aguardando Prometheus e Grafana..."
kubectl -n "${NAMESPACE}" rollout status deployment/prometheus --timeout=180s
kubectl -n "${NAMESPACE}" rollout status deployment/grafana --timeout=180s

log "alvos raspados pelo Prometheus:"
kubectl -n "${NAMESPACE}" get pods -o json \
  | python3 -c "import json,sys
for p in json.load(sys.stdin)['items']:
    a = p['metadata'].get('annotations', {})
    if a.get('prometheus.io/scrape') == 'true':
        print('  -', p['metadata']['name'], a.get('prometheus.io/path'), a.get('prometheus.io/port'))"

log "Grafana:    kubectl -n ${NAMESPACE} port-forward svc/grafana 3000:3000   (admin / GRAFANA_ADMIN_PASSWORD)"
log "Prometheus: kubectl -n ${NAMESPACE} port-forward svc/prometheus 9090:9090"
