#!/usr/bin/env bash
# Aplica os 3 serviços (PLT-1) e espera ficarem prontos.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl

OVERLAY="${INFRA_DIR}/k8s/apps/overlays/local"
ensure_env "${OVERLAY}"

kubectl apply -f "${INFRA_DIR}/k8s/namespace.yaml"
log "aplicando ${OVERLAY}"
kubectl apply -k "${OVERLAY}"

log "aguardando os serviços (pode demorar — imagem de dev compila no start)..."
for svc in "${SERVICES[@]}"; do
  kubectl -n "${NAMESPACE}" rollout status "deployment/${svc}" --timeout=600s
done

kubectl -n "${NAMESPACE}" get pods
