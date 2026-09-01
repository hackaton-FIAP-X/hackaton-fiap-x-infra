#!/usr/bin/env bash
# Aplica a infra de apoio (PLT-2) e espera ficar pronta.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl

OVERLAY="${INFRA_DIR}/k8s/infra/overlays/local"
ensure_env "${OVERLAY}"

kubectl apply -f "${INFRA_DIR}/k8s/namespace.yaml"
log "aplicando ${OVERLAY}"
kubectl apply -k "${OVERLAY}"

log "aguardando StatefulSets (Postgres, RabbitMQ, MinIO, Redis)..."
for sts in postgres rabbitmq minio redis; do
  kubectl -n "${NAMESPACE}" rollout status "statefulset/${sts}" --timeout=300s
done
kubectl -n "${NAMESPACE}" rollout status deployment/mailhog --timeout=180s

log "PVCs:"
kubectl -n "${NAMESPACE}" get pvc
log "pods:"
kubectl -n "${NAMESPACE}" get pods
